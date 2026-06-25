import AmbitCore
import AmbitUI
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class StatusViewModel: ObservableObject {
    @Published var snapshot = StatusSnapshot()
    @Published var settings: AppSettings
    @Published var routerPassword: String
    @Published var selectedEndpoint: EndpointSelection?
    @Published var commandPalette: [CommandPaletteItem] = []
    @Published var providerDisplayNames: [ProviderID: String] = [:]
    @Published var moduleUsageSnapshots: [ModuleUsageSnapshot] = []
    @Published var lastCommandResult: CommandExecutionResult?
    @Published var executingCommandID: String?
    @Published var installedProviders: [InstalledProviderRecord] = []
    @Published var providerSetupSummaries: [ProviderSetupSummary] = []
    @Published var providerSetupError: String?
    @Published var providerCredentialValues: [ProviderID: [String: String]] = [:]
    @Published var providerLayouts: [ProviderID: ProviderManifest.Layout] = [:]
    @Published var providerAlertRuleCounts: [ProviderID: Int] = [:]

    // Ping UI state
    @Published var pingRange: TimeRange = .fiveMinutes {
        didSet { UserDefaults.standard.set(pingRange.rawValue, forKey: "pingRange") }
    }
    @Published var pingHostRows: [PingHostRow] = []
    @Published var pingDiagnosis: NetworkPerspectiveDiagnosis?
    /// Per-slot surface values (plan + data + glyph + hostOptions), keyed by SlotID.
    @Published var slotSurfaces: [SlotID: SlotSurface] = [:]
    /// Per-slot focused instance (nil = show all resolved instances for the slot).
    @Published var slotFocus: [SlotID: IntegrationInstanceID] = [:]

    // Menu-bar slots (P3). Seeded with one dedicated Ping slot for parity; the chrome renders
    // one status item per slot.
    @Published var slots: [Slot] = []
    private let configStore: any PresentationConfigStore

    private let pingDiagnoser = NetworkPerspectiveDiagnoser()
    private let pingTierClassifier = NetworkTierClassifier()
    private var pingAlertMonitor = PingAlertMonitor()

    @Published var diagnosisSensitivity: DiagnosisSensitivity = .balanced {
        didSet {
            pingAlertMonitor.sensitivity = diagnosisSensitivity
            UserDefaults.standard.set(diagnosisSensitivity.rawValue, forKey: "pingDiagnosisSensitivity")
        }
    }

    // Set by the app model to bridge SwiftUI actions to AppKit windows.
    var toggleOverlay: (() -> Void)?
    var showPopover: (() -> Void)?
    var openSettings: (() -> Void)?

    private let engine: Engine
    private let installedProviderStore: any InstalledProviderStore
    private let credentialStore: any CredentialStore
    private let integrationRegistry: any IntegrationRegistry
    private let addressDiscovery: any RouterAddressDiscovery
    private var alertEngine = AlertEngine()
    private var attentionEngine = AttentionEngine()
    private let alertNotifier: AlertNotifier
    private var subscriptionTask: Task<Void, Never>?
    private var staleTickTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        installedProviderStore: any InstalledProviderStore = UserDefaultsInstalledProviderStore(),
        endpointSelector: EndpointSelector = EndpointSelector(),
        reachabilityProbe: ReachabilityProbeProtocol = ReachabilityProbe(),
        addressDiscovery: any RouterAddressDiscovery = SystemRouterAddressDiscovery(),
        configStore: any PresentationConfigStore = UserDefaultsPresentationConfigStore()
    ) {
        let settings = (try? settingsStore.load()) ?? AppSettings()
        let routerPassword = (try? credentialStore.password(account: settings.username)) ?? RouterDefaults.routerPassword
        self.settings = settings
        self.routerPassword = routerPassword
        self.alertNotifier = AlertNotifier()
        self.installedProviderStore = installedProviderStore
        self.credentialStore = credentialStore
        self.addressDiscovery = addressDiscovery
        self.configStore = configStore
        self.slots = Self.loadOrSeedSlots(configStore)
        let integrationRegistry = UserDefaultsIntegrationRegistry()
        self.integrationRegistry = integrationRegistry
        Self.migrateRetiredPingscopeRecords(integrationRegistry)
        Self.seedIntegrationRegistryIfNeeded(integrationRegistry, settings: settings)
        Self.dedupePingHostsByAddress(integrationRegistry)
        if let raw = UserDefaults.standard.string(forKey: "pingDiagnosisSensitivity"),
           let sensitivity = DiagnosisSensitivity(rawValue: raw) {
            diagnosisSensitivity = sensitivity
            pingAlertMonitor.sensitivity = sensitivity
        }
        if let raw = UserDefaults.standard.string(forKey: "pingRange"), let range = TimeRange(rawValue: raw) {
            pingRange = range
        }
        let historyStore: any HistoryStore = (try? SQLiteHistoryStore.defaultURL()).map { SQLiteHistoryStore(url: $0) } ?? InMemoryHistoryStore()
        self.engine = Engine(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            endpointSelector: endpointSelector,
            reachabilityProbe: reachabilityProbe,
            settings: settings,
            routerPassword: routerPassword,
            integrationRegistry: integrationRegistry,
            installedProviderStore: installedProviderStore,
            history: HistoryService(store: historyStore),
            activeMeasurementProcessRunner: SystemProcessRunner()
        )
    }

    deinit {
        subscriptionTask?.cancel()
        staleTickTask?.cancel()
    }

    /// Load persisted slots; seed one dedicated Ping slot on first run (parity with today's
    /// single menu item). `.integrationType` resolves to the live ping hosts, so the slot needs
    /// no membership maintenance as hosts come and go.
    private static func loadOrSeedSlots(_ store: any PresentationConfigStore) -> [Slot] {
        var config = store.load()
        if config.slots.isEmpty {
            config.slots = [Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping), barReadout: .dynamic)]
            store.save(config)
        }
        return config.slots
    }

    /// First-run seed: the built-in integrations are listed (so they remain toggleable) but
    /// disabled at the integration-type level, leaving only pingscope active (pingscope hosts
    /// are seeded in M1). Existing installs keep their saved state.
    private static func seedIntegrationRegistryIfNeeded(_ registry: any IntegrationRegistry, settings: AppSettings) {
        guard ((try? registry.instances()) ?? []).isEmpty else { return }
        // Built-ins listed but disabled (toggleable later); pingscope seeded with sensible
        // default public DNS hosts so the app isn't empty. The detected gateway is added
        // asynchronously on start (it needs network detection).
        let builtIns = BuiltInIntegrationSeed.records(ecoflowEnabled: settings.ecoflowEnabled, includeActiveMeasurement: true)
        let defaultHosts = [
            PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443),
            PingHostConfig(displayName: "Google DNS", address: "8.8.8.8", method: .tcp, port: 443)
        ]
        try? registry.save(builtIns + defaultHosts.map { IntegrationInstanceRecord.ping($0) })
        try? registry.setDisabledIntegrationIDs(BuiltInIntegrationSeed.integrationIDs)
    }

    /// One-shot RESET migration for the "pingscope" → "ping" rename. Records saved under the
    /// now-retired "pingscope" integration id no longer resolve to any integration, so drop them
    /// — scoped to that explicit id, NOT a blanket "unregistered integration" sweep (which would
    /// nuke installed/manifest providers that merely failed to load this launch). If dropping
    /// them leaves no ping hosts, reseed the ping defaults so the app isn't empty (the first-run
    /// seed guard won't fire while built-in records are present). Old "pingscope@…" history is
    /// disposable dev data — orphaned and pruned by retention. Self-removing: a no-op once gone.
    private static func migrateRetiredPingscopeRecords(_ registry: any IntegrationRegistry) {
        // Part A: drop retired-basic-ping artifacts — records under the renamed "pingscope" id,
        // AND the old basic-ping built-in *instance* (id == "ping"; real ping hosts are "ping@…").
        // That stale instance carries integrationID "ping" with empty config, so it produces no
        // provider yet would mask the "no ping hosts" check below. Reseed ping defaults if dropping
        // them leaves no ping hosts (so the app isn't empty).
        let isRetiredPingArtifact: (IntegrationInstanceRecord) -> Bool = {
            $0.integrationID == "pingscope" || $0.id == IntegrationInstanceIDs.ping
        }
        if let all = try? registry.instances(), all.contains(where: isRetiredPingArtifact) {
            var kept = all.filter { !isRetiredPingArtifact($0) }
            if !kept.contains(where: { $0.integrationID == IntegrationIDs.ping }) {
                let defaultHosts = [
                    PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443),
                    PingHostConfig(displayName: "Google DNS", address: "8.8.8.8", method: .tcp, port: 443)
                ]
                kept += defaultHosts.map { IntegrationInstanceRecord.ping($0) }
            }
            try? registry.save(kept)
        }
        // Part B (independent of Part A — a half-migrated install may have already dropped the
        // pingscope records): the retired basic-ping built-in was default-disabled under "ping",
        // so the persisted disabled set can still carry it. Ping is now pingscope's successor and
        // the active reference integration (pingscope was never type-disabled), so drop the stale
        // "ping" from the disabled set. Self-removing once gone.
        if let disabled = try? registry.disabledIntegrationIDs(), disabled.contains(IntegrationIDs.ping) {
            try? registry.setDisabledIntegrationIDs(disabled.subtracting([IntegrationIDs.ping]))
        }
    }

    /// Remove pingscope hosts that target an address already monitored (keeping the primary,
    /// else the first), cleaning up duplicates left by earlier seeding changes.
    private static func dedupePingHostsByAddress(_ registry: any IntegrationRegistry) {
        guard let all = try? registry.instances() else { return }
        let hosts = all.filter { $0.integrationID == IntegrationIDs.ping }
        let primary = (try? registry.primaryInstanceID()) ?? nil
        let ordered = hosts.filter { $0.id == primary } + hosts.filter { $0.id != primary }
        var seen = Set<String>()
        var removeIDs = Set<IntegrationInstanceID>()
        for record in ordered {
            guard let address = PingHostConfig(configObject: record.config)?.address else { continue }
            if seen.contains(address) { removeIDs.insert(record.id) } else { seen.insert(address) }
        }
        guard !removeIDs.isEmpty else { return }
        try? registry.save(all.filter { !removeIDs.contains($0.id) })
    }

    nonisolated static func reconciledGatewaySeedRecords(
        _ records: [IntegrationInstanceRecord],
        currentGateway: String
    ) -> (records: [IntegrationInstanceRecord], changed: Bool) {
        let currentHost = PingHostConfig(displayName: "Gateway", address: currentGateway, method: .icmp)
        let currentID = currentHost.integrationInstanceID
        var changed = false
        var reconciled: [IntegrationInstanceRecord] = []
        var hasCurrentGateway = false

        for record in records {
            guard Self.isAutoSeededGateway(record) else {
                reconciled.append(record)
                continue
            }
            if record.id == currentID {
                reconciled.append(record)
                hasCurrentGateway = true
            } else {
                changed = true
            }
        }

        if !hasCurrentGateway {
            reconciled.append(.ping(currentHost))
            changed = true
        }

        return (reconciled, changed)
    }

    nonisolated private static func isAutoSeededGateway(_ record: IntegrationInstanceRecord) -> Bool {
        guard record.integrationID == IntegrationIDs.ping,
              record.displayName == "Gateway",
              let host = PingHostConfig(configObject: record.config)
        else { return false }
        return host.displayName == "Gateway" && host.method == .icmp && host.port == nil
    }

    /// Detect the default gateway and add it as a third pingscope host (ICMP — truest hop
    /// latency, no port guessing) via the registry-add + reload path. Idempotent: skips if a
    /// host for that target already exists.
    private func seedGatewayHostIfNeeded() async {
        guard let gateway = await addressDiscovery.defaultGatewayHost(), !gateway.isEmpty else { return }
        let all = (try? integrationRegistry.instances()) ?? []
        let result = Self.reconciledGatewaySeedRecords(all, currentGateway: gateway)
        guard result.changed else { return }
        try? integrationRegistry.save(result.records)
        await engine.reloadProviders()
        await refreshAlertRules()
        await engine.refresh()
    }

    func start() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.engine.snapshots {
                self.snapshot = snapshot
                self.selectedEndpoint = await self.engine.currentSelectedEndpoint()
                self.providerDisplayNames = await self.engine.providerDisplayNames()
                await self.refreshPing()
                await self.refreshModuleUsage()
                let events = await self.alertEngine.evaluate(snapshot.engineSnapshot)
                await self.alertNotifier.deliver(events)
            }
        }
        // Time-driven staleness tick — recomputes staleness/diagnosis against wall-clock `now`
        // on a cadence INDEPENDENT of the engine snapshot stream. When the poll loop stalls (no
        // snapshots), this is what flips entities to .stale and the banner to "Monitoring paused"
        // instead of freezing on the last .online snapshot.
        staleTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.refreshPing()
            }
        }
        Task { await engine.start() }
        Task { await refreshAlertRules() }
        Task { await seedGatewayHostIfNeeded() }
        refreshInstalledProviders()
        refreshCommandPalette()
    }

    /// Kick a fresh poll cycle (called by the wake observer on system wake).
    func kickPoll() {
        Task { await engine.pollNow() }
    }

    func refresh() async {
        await engine.updateSettings(settings, routerPassword: routerPassword)
        await engine.refresh()
        selectedEndpoint = await engine.currentSelectedEndpoint()
        await refreshModuleUsage()
        refreshCommandPalette()
    }

    func saveSettings() {
        Task {
            let error = await engine.saveSettings(settings, routerPassword: routerPassword)
            if let error {
                snapshot.router.errorMessage = error
            }
            await refreshModuleUsage()
            refreshCommandPalette()
        }
    }

    func refreshCommandPalette() {
        Task {
            commandPalette = await engine.commandPalette()
            providerDisplayNames = await engine.providerDisplayNames()
            providerLayouts = await engine.providerLayouts()
            providerAlertRuleCounts = await engine.alertRules().reduce(into: [ProviderID: Int]()) { counts, rule in
                counts[rule.providerID, default: 0] += 1
            }
        }
    }

    func refreshInstalledProviders() {
        installedProviders = (try? installedProviderStore.load()) ?? []
        providerSetupSummaries = installedProviders.map {
            ProviderSetupSummary.make(record: $0, credentialStore: credentialStore)
        }
        loadProviderCredentialValues()
    }

    func credentialRequirements(for provider: InstalledProviderRecord) -> [ProviderManifest.Credential] {
        (try? ProviderManifestPackage.load(from: URL(fileURLWithPath: provider.packagePath, isDirectory: true)).manifest.credentials) ?? []
    }

    func credentialBinding(providerID: ProviderID, credentialID: String) -> Binding<String> {
        Binding(
            get: { self.providerCredentialValues[providerID]?[credentialID] ?? "" },
            set: { self.providerCredentialValues[providerID, default: [:]][credentialID] = $0 }
        )
    }

    func saveInstalledProviderCredentials(_ provider: InstalledProviderRecord) {
        do {
            for credential in credentialRequirements(for: provider) {
                let value = providerCredentialValues[provider.id]?[credential.id]
                try credentialStore.setCredential(
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value,
                    for: CredentialKey(providerID: provider.id, id: credential.id)
                )
            }
            providerSetupError = nil
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    func installManifestProvider(from directory: URL) {
        do {
            _ = try installedProviderStore.installManifestPackage(at: directory)
            providerSetupError = nil
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    func refreshInstalledProviderValidation(_ providerID: ProviderID) {
        do {
            switch try installedProviderStore.refreshManifestPackageValidation(providerID: providerID) {
            case .valid, .missing:
                providerSetupError = nil
            case .invalid(_, let message):
                providerSetupError = message
            }
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    func setInstalledProvider(_ providerID: ProviderID, enabled: Bool) {
        do {
            try installedProviderStore.setEnabled(enabled, providerID: providerID)
            providerSetupError = nil
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    func removeInstalledProvider(_ providerID: ProviderID) {
        do {
            try installedProviderStore.remove(providerID: providerID)
            providerSetupError = nil
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    private func reloadInstalledProviders() {
        refreshInstalledProviders()
        Task {
            await engine.reloadInstalledProviders()
            await refreshAlertRules()
            await refresh()
            refreshCommandPalette()
        }
    }

    private func refreshAlertRules() async {
        alertEngine = AlertEngine(rules: await engine.alertRules())
    }

    private func loadProviderCredentialValues() {
        var values = providerCredentialValues
        for provider in installedProviders {
            for credential in credentialRequirements(for: provider) {
                values[provider.id, default: [:]][credential.id] = (try? credentialStore.credential(
                    CredentialKey(providerID: provider.id, id: credential.id)
                )) ?? values[provider.id]?[credential.id] ?? ""
            }
        }
        providerCredentialValues = values
    }

    func executeCommand(_ item: CommandPaletteItem, arguments: CommandArguments = CommandArguments()) async {
        _ = await runProviderCommand(
            providerID: item.providerID,
            providerName: item.providerName,
            commandID: item.command.id,
            commandLabel: item.command.label,
            arguments: arguments
        )
    }

    @discardableResult
    private func runProviderCommand(
        providerID: ProviderID,
        providerName: String,
        commandID: String,
        commandLabel: String,
        arguments: CommandArguments = CommandArguments()
    ) async -> CommandExecutionResult {
        let itemID = "\(providerID).\(commandID)"
        executingCommandID = itemID
        lastCommandResult = nil
        let result = await engine.runCommand(
            provider: providerID,
            providerName: providerName,
            commandID: commandID,
            commandLabel: commandLabel,
            arguments: arguments
        )
        lastCommandResult = result
        switch result.status {
        case .succeeded:
            snapshot = await engine.currentSnapshot()
            selectedEndpoint = await engine.currentSelectedEndpoint()
            await refreshModuleUsage()
        case .failed:
            await refreshModuleUsage()
        }
        refreshCommandPalette()
        executingCommandID = nil
        return result
    }

    func refreshModuleUsage() async {
        moduleUsageSnapshots = Array(await engine.usageSnapshots().values)
    }

    func setPingRange(_ range: TimeRange) {
        pingRange = range
        Task { await refreshPing() }
    }

    /// Set or clear the per-slot focus. Clears focus when `id` is nil (show all).
    func selectInstance(_ slot: SlotID, _ id: IntegrationInstanceID?) {
        slotFocus[slot] = id
        Task { await refreshPing() }
    }

    /// Rebuild per-host rows + diagnosis/alerts (settings), then build per-slot surfaces.
    func refreshPing() async {
        let now = Date()
        let allRegistryRecords = (try? integrationRegistry.instances()) ?? []
        let allRecords = allRegistryRecords.filter { $0.integrationID == IntegrationIDs.ping }
        let disabledTypes = (try? integrationRegistry.disabledIntegrationIDs()) ?? []
        let primaryID = (try? integrationRegistry.primaryInstanceID()) ?? nil
        let activeRecords = disabledTypes.contains(IntegrationIDs.ping) ? [] : allRecords.filter(\.enabled)
        let fallbackPrimary = primaryID ?? activeRecords.first?.id

        // All hosts (enabled + disabled) for the Settings list.
        pingHostRows = allRecords.compactMap { record in
            guard let config = PingHostConfig(configObject: record.config) else { return nil }
            return PingHostRow(instanceID: record.id, config: config, enabled: record.enabled, isPrimary: record.id == fallbackPrimary)
        }

        // Active hosts: per-host readout for diagnosis + alert inputs.
        var diagnosisHosts: [DiagnosisHost] = []
        var alertHosts: [AlertHost] = []
        var newestSample: Date?
        for record in activeRecords {
            guard let host = PingHostConfig(configObject: record.config) else { continue }
            let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
            let samples = await engine.historySamples(latencyID, since: now.addingTimeInterval(-pingRange.seconds))
            let health = HealthStatus(legacy: snapshot.providers[providerInstance]?.value?.health ?? .unknown)
            // Staleness is evaluated against wall-clock `now` from the last sample — so a stalled
            // loop (stale data) suppresses fault inference rather than reporting a false "down".
            let isStale = Staleness.isStale(lastUpdate: samples.last?.timestamp, interval: host.interval, now: now)
            if let last = samples.last?.timestamp, last > (newestSample ?? .distantPast) { newestSample = last }
            diagnosisHosts.append(DiagnosisHost(id: record.id.rawValue, tier: pingTierClassifier.tier(for: host), status: health, isStale: isStale))
            alertHosts.append(AlertHost(id: record.id.rawValue, name: record.displayName, status: health,
                                        notifyOnRecovery: host.policy.notifyOnRecovery, cooldown: host.policy.cooldown))
        }

        // Tier diagnosis + network/host alerts. Enrich a stalled diagnosis with the data age
        // (the diagnoser stays timestamp-free; the host knows when data last arrived).
        var diagnosis = pingDiagnoser.diagnose(hosts: diagnosisHosts)
        if case .monitoringStalled = diagnosis.verdict {
            let age = Int(now.timeIntervalSince(newestSample ?? now).rounded())
            diagnosis.detail = "Monitoring paused — data is \(age)s old."
        }
        pingDiagnosis = diagnosis
        let events = pingAlertMonitor.evaluate(hosts: alertHosts, diagnosis: diagnosis, now: now)
        await alertNotifier.deliver(events)

        // Build per-slot surfaces.
        let allDescriptors = await engine.entityDescriptors()
        let allStates = await engine.entityStates(now: now)
        var newSurfaces: [SlotID: SlotSurface] = [:]

        for slot in slots {
            let surface = await buildSlotSurface(
                slot: slot,
                diagnosis: diagnosis,
                allRecords: activeRecords,
                allRegistryRecords: allRegistryRecords,
                allDescriptors: allDescriptors,
                allStates: allStates,
                firedAlertEvents: events,
                now: now
            )
            newSurfaces[slot.id] = surface
        }
        slotSurfaces = newSurfaces
    }

    private func buildSlotSurface(
        slot: Slot,
        diagnosis: NetworkPerspectiveDiagnosis,
        allRecords: [IntegrationInstanceRecord],         // enabled ping records
        allRegistryRecords: [IntegrationInstanceRecord], // all records (for SlotResolver)
        allDescriptors: [ProviderInstanceID: [EntityDescriptor]],
        allStates: [EntityID: EntityState],
        firedAlertEvents: [AlertEvent],
        now: Date
    ) async -> SlotSurface {
        // Flatten descriptors for SlotResolver.
        let flatDescriptors = allDescriptors.values.flatMap { $0 }

        // Resolve the slot's selection to descriptors.
        let resolved = SlotResolver.resolve(slot.selection, descriptors: flatDescriptors, records: allRegistryRecords)

        // Distinct integration instances the slot resolved to (for hostOptions).
        let resolvedInstanceIDs = Set(resolved.map { $0.instanceID.integrationInstanceID })
        let resolvedRecords = allRecords.filter { resolvedInstanceIDs.contains($0.id) }
        let hostOptions = resolvedRecords.map { InstanceSelectorCard.Option(id: $0.id.rawValue, label: $0.displayName) }

        // Apply per-slot focus: filter to the focused instance if set.
        let focusedID = slotFocus[slot.id]
        let shownRecords = focusedID.map { id in resolvedRecords.filter { $0.id == id } } ?? resolvedRecords
        let shownInstanceIDs = Set(shownRecords.map(\.id))
        let shownResolved = focusedID == nil
            ? resolved
            : resolved.filter { descriptor in
                shownInstanceIDs.contains(descriptor.instanceID.integrationInstanceID)
            }
        let isPingSlot: Bool
        if case .integrationType(let integID) = slot.selection, integID == IntegrationIDs.ping {
            isPingSlot = true
        } else {
            isPingSlot = false
        }

        if !isPingSlot {
            return StatusSlotSurfaceBuilder.genericSurface(
                slot: slot,
                descriptors: shownResolved,
                states: allStates,
                config: configStore.load(),
                now: now,
                attentionEngine: &attentionEngine
            )
        }

        // Build SurfaceData: latency descriptors for shown hosts (renamed to host displayName
        // for multi-host legend, matching today's behaviour).
        var descriptors: [EntityID: EntityDescriptor] = [:]
        var states: [EntityID: EntityState] = [:]
        var series: [EntityID: [Sample]] = [:]
        var attentionDescriptors = shownResolved
        var detailDescriptors: [EntityDescriptor] = []
        for record in shownRecords {
            let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
            guard var latency = allDescriptors[providerInstance]?.first(where: { $0.id == latencyID }) else { continue }
            latency.name = record.displayName
            detailDescriptors.append(latency)
            descriptors[latencyID] = latency
            let samples = await engine.historySamples(latencyID, since: now.addingTimeInterval(-pingRange.seconds))
            series[latencyID] = samples
            // States from engine.entityStates(now:) are already enriched (.stale + severity); no
            // ad-hoc staleness overlay needed here (P4.2).
            if let state = Self.latencyStateForSurface(id: latencyID, current: allStates[latencyID], samples: samples) {
                states[latencyID] = state
            }
        }

        if isPingSlot, let (diagnosisDescriptor, diagnosisState) = DiagnosisEntity.make(diagnosis) {
            descriptors[diagnosisDescriptor.id] = diagnosisDescriptor
            states[diagnosisDescriptor.id] = diagnosisState
            attentionDescriptors.append(diagnosisDescriptor)
            detailDescriptors.append(diagnosisDescriptor)
        }

        let candidates = attentionDescriptors.compactMap { descriptor -> AttentionCandidate? in
            guard let state = states[descriptor.id] ?? allStates[descriptor.id] else { return nil }
            return AttentionCandidate(descriptor: descriptor, state: state)
        }
        let alertingIDs = Self.alertingEntityIDs(from: firedAlertEvents, candidates: candidates)
        let glyph = StatusSlotReadout.resolveGlyph(
            mode: slot.barReadout,
            candidates: candidates,
            descriptors: descriptors,
            states: states,
            alertingIDs: alertingIDs,
            config: configStore.load(),
            now: now,
            attentionEngine: &attentionEngine
        )

        let planCards = SurfaceComposer.detailPlan(descriptors: detailDescriptors, states: states).cards

        return SlotSurface(
            plan: SurfacePlan(cards: planCards),
            data: SurfaceData(descriptors: descriptors, states: states, series: series),
            glyph: glyph,
            hostOptions: hostOptions
        )
    }

    private static func alertingEntityIDs(from events: [AlertEvent], candidates: [AttentionCandidate]) -> Set<EntityID> {
        let candidateIDs = Set(candidates.map(\.descriptor.id))
        let ids = events.flatMap { event -> [EntityID] in
            if event.providerID == "ping.network" {
                return candidateIDs.contains(DiagnosisEntity.entityID) ? [DiagnosisEntity.entityID] : []
            }
            let pingLatencyID = EntityID(rawValue: "\(event.providerID)/probe.latency_ms")
            return candidateIDs.contains(pingLatencyID) ? [pingLatencyID] : []
        }
        return Set(ids)
    }

    nonisolated static func latencyStateForSurface(id: EntityID, current: EntityState?, samples: [Sample]) -> EntityState? {
        if let current, current.value != nil {
            return current
        }
        guard let latest = samples.last, latest.ok, let value = latest.value else {
            return current
        }
        var state = current ?? EntityState(id: id, availability: .online)
        state.value = .number(value)
        state.availability = .online
        state.lastUpdated = latest.timestamp
        state.severity = state.severity ?? .normal
        return state
    }

    // MARK: Ping host management (Settings)

    func addOrUpdatePingHost(_ host: PingHostConfig, replacing oldID: IntegrationInstanceID? = nil) {
        if let oldID, oldID != host.integrationInstanceID { try? integrationRegistry.remove(oldID) }
        try? integrationRegistry.upsert(.ping(host))
        reloadPingProviders()
    }

    func deletePingHost(_ id: IntegrationInstanceID) {
        try? integrationRegistry.remove(id)
        if (try? integrationRegistry.primaryInstanceID()) == id { try? integrationRegistry.setPrimaryInstanceID(nil) }
        reloadPingProviders()
    }

    func setPrimaryPingHost(_ id: IntegrationInstanceID) {
        try? integrationRegistry.setPrimaryInstanceID(id)
        reloadPingProviders()
    }

    func setPingHostEnabled(_ id: IntegrationInstanceID, enabled: Bool) {
        try? integrationRegistry.setInstanceEnabled(enabled, instanceID: id)
        reloadPingProviders()
    }

    func clearHistory() {
        Task { await engine.clearHistory(); await refreshPing() }
    }

    func resetPingHostsToDefaults() {
        let others = ((try? integrationRegistry.instances()) ?? []).filter { $0.integrationID != IntegrationIDs.ping }
        let defaults = [
            PingHostConfig(displayName: "Cloudflare DNS", address: "1.1.1.1", method: .tcp, port: 443),
            PingHostConfig(displayName: "Google DNS", address: "8.8.8.8", method: .tcp, port: 443)
        ].map { IntegrationInstanceRecord.ping($0) }
        try? integrationRegistry.save(others + defaults)
        try? integrationRegistry.setPrimaryInstanceID(nil)
        reloadPingProviders()
        Task { await seedGatewayHostIfNeeded() }
    }

    private func reloadPingProviders() {
        Task {
            await engine.reloadProviders()
            await refreshAlertRules()
            await engine.refresh()
            await refreshPing()
        }
    }

    func setSpeedifyFocused(_ isFocused: Bool) {
        Task { await engine.setSpeedifyFocused(isFocused) }
    }

    func refreshSpeedifyNow() async {
        await engine.refreshSpeedifyNow()
    }

    func toggleVPN() async {
        await runProviderCommand(
            providerID: ProviderIDs.vpn,
            providerName: providerDisplayNames[ProviderIDs.vpn] ?? "VPN",
            commandID: ProviderCommandIDs.vpnToggle,
            commandLabel: "Toggle VPN"
        )
    }

    func toggleSpeedify() async {
        await runProviderCommand(
            providerID: ProviderIDs.speedify,
            providerName: providerDisplayNames[ProviderIDs.speedify] ?? "Speedify",
            commandID: ProviderCommandIDs.speedifyToggle,
            commandLabel: "Toggle Speedify"
        )
    }

    func setSpeedifyBondingMode(_ mode: SpeedifyBondingMode) async {
        await runProviderCommand(
            providerID: ProviderIDs.speedify,
            providerName: providerDisplayNames[ProviderIDs.speedify] ?? "Speedify",
            commandID: ProviderCommandIDs.speedifySetBondingMode,
            commandLabel: "Set Bonding Mode",
            arguments: CommandArguments(values: ["mode": .string(mode.commandCode)])
        )
    }

    func setSpeedifyNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String) async {
        await runProviderCommand(
            providerID: ProviderIDs.speedify,
            providerName: providerDisplayNames[ProviderIDs.speedify] ?? "Speedify",
            commandID: ProviderCommandIDs.speedifySetNetworkPriority,
            commandLabel: "Set Network Priority",
            arguments: CommandArguments(values: ["priority": .number(Double(priority.rawValue)), "networkID": .string(networkID)])
        )
    }

    func setEcoFlowOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async -> EcoFlowControlResponse? {
        executingCommandID = "\(ProviderIDs.ecoflow).\(ProviderCommandIDs.ecoFlowSetOutput)"
        lastCommandResult = nil
        let response = await engine.setEcoFlowOutput(target, state: state)
        if response == nil {
            lastCommandResult = .failure(
                providerID: ProviderIDs.ecoflow,
                providerName: providerDisplayNames[ProviderIDs.ecoflow] ?? "EcoFlow",
                commandID: ProviderCommandIDs.ecoFlowSetOutput,
                commandLabel: "Set Output",
                errorMessage: "EcoFlow output command did not return a control response."
            )
        } else {
            lastCommandResult = .success(
                providerID: ProviderIDs.ecoflow,
                providerName: providerDisplayNames[ProviderIDs.ecoflow] ?? "EcoFlow",
                commandID: ProviderCommandIDs.ecoFlowSetOutput,
                commandLabel: "Set Output"
            )
        }
        snapshot = await engine.currentSnapshot()
        selectedEndpoint = await engine.currentSelectedEndpoint()
        await refreshModuleUsage()
        refreshCommandPalette()
        executingCommandID = nil
        return response
    }
}

struct StatusSlotReadout {
    private static let surfaceID = SurfaceID(rawValue: "macos.bar")

    static func resolveSelection(
        candidates: [AttentionCandidate],
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date,
        attentionEngine: inout AttentionEngine
    ) -> AttentionSelection {
        attentionEngine.evaluate(
            candidates: candidates,
            surfaces: [surfaceID: SurfaceCapacity(lanes: 1, overflow: .countBadge)],
            alertingIDs: alertingIDs,
            config: config,
            now: now
        )[surfaceID] ?? AttentionSelection()
    }

    static func resolveGlyph(
        mode: BarReadoutMode,
        candidates: [AttentionCandidate],
        descriptors: [EntityID: EntityDescriptor],
        states: [EntityID: EntityState],
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date,
        attentionEngine: inout AttentionEngine
    ) -> MenuBarGlyph {
        switch mode {
        case .fixed(let id):
            if let descriptor = descriptors[id] {
                return glyph(descriptor: descriptor, state: states[id])
            }
            return staticFallback(candidates: candidates, states: states)
        case .dynamic:
            let selection = resolveSelection(
                candidates: candidates,
                alertingIDs: alertingIDs,
                config: config,
                now: now,
                attentionEngine: &attentionEngine
            )
            guard
                let selectedID = selection.lanes.first?.id,
                let selectedCandidate = candidates.first(where: { $0.descriptor.id == selectedID })
            else {
                return staticFallback(candidates: candidates, states: states)
            }
            let descriptor = descriptors[selectedID] ?? selectedCandidate.descriptor
            return glyph(descriptor: descriptor, state: states[selectedID] ?? selectedCandidate.state)
        }
    }

    private static func staticFallback(candidates: [AttentionCandidate], states: [EntityID: EntityState]) -> MenuBarGlyph {
        guard let fallback = (candidates.first { $0.descriptor.isPrimary } ?? candidates.first) else {
            return MenuBarGlyph(latencyText: "--ms", tone: .neutral)
        }
        return glyph(descriptor: fallback.descriptor, state: states[fallback.descriptor.id] ?? fallback.state)
    }

    private static func glyph(descriptor: EntityDescriptor, state: EntityState?) -> MenuBarGlyph {
        let readout = EntityReadout.make(descriptor: descriptor, state: state)
        return MenuBarGlyph(latencyText: readout.text, tone: LatencyTone(readout.tone))
    }
}

enum StatusSlotSurfaceBuilder {
    static func genericSurface(
        slot: Slot,
        descriptors resolved: [EntityDescriptor],
        states allStates: [EntityID: EntityState],
        config: PresentationConfig,
        now: Date,
        attentionEngine: inout AttentionEngine
    ) -> SlotSurface {
        let descriptors = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        let states = allStates.filter { descriptors.keys.contains($0.key) }
        let candidates = resolved.compactMap { descriptor -> AttentionCandidate? in
            guard let state = states[descriptor.id] else { return nil }
            return AttentionCandidate(descriptor: descriptor, state: state)
        }
        let glyph = StatusSlotReadout.resolveGlyph(
            mode: slot.barReadout,
            candidates: candidates,
            descriptors: descriptors,
            states: states,
            alertingIDs: [],
            config: config,
            now: now,
            attentionEngine: &attentionEngine
        )

        return SlotSurface(
            plan: SurfaceComposer.detailPlan(descriptors: resolved, states: states, config: config),
            data: SurfaceData(descriptors: descriptors, states: states),
            glyph: glyph,
            hostOptions: []
        )
    }
}

private extension LatencyTone {
    init(_ tone: DisplayTone) {
        switch tone {
        case .neutral: self = .neutral
        case .good: self = .good
        case .warn: self = .warn
        case .bad: self = .bad
        }
    }
}

private struct AlertNotifier: Sendable {
    func deliver(_ events: [AlertEvent]) async {
        guard !events.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.message
            content.sound = event.severity == .critical ? .defaultCritical : .default
            let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}

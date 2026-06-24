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
    @Published var pingSelection: IntegrationInstanceID?   // nil = All Hosts
    @Published var pingHosts: [PingHostDisplay] = []
    @Published var pingHostRows: [PingHostRow] = []
    @Published var menuGlyph = MenuBarGlyph(latencyText: "--ms", tone: .neutral)
    @Published var pingDiagnosis: NetworkPerspectiveDiagnosis?
    @Published var surfaceData = SurfaceData()
    @Published var surfacePlan = SurfacePlan()

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
    private let alertNotifier: AlertNotifier
    private var subscriptionTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        installedProviderStore: any InstalledProviderStore = UserDefaultsInstalledProviderStore(),
        endpointSelector: EndpointSelector = EndpointSelector(),
        reachabilityProbe: ReachabilityProbeProtocol = ReachabilityProbe(),
        addressDiscovery: any RouterAddressDiscovery = SystemRouterAddressDiscovery()
    ) {
        let settings = (try? settingsStore.load()) ?? AppSettings()
        let routerPassword = (try? credentialStore.password(account: settings.username)) ?? RouterDefaults.routerPassword
        self.settings = settings
        self.routerPassword = routerPassword
        self.alertNotifier = AlertNotifier()
        self.installedProviderStore = installedProviderStore
        self.credentialStore = credentialStore
        self.addressDiscovery = addressDiscovery
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

    /// Detect the default gateway and add it as a third pingscope host (ICMP — truest hop
    /// latency, no port guessing) via the registry-add + reload path. Idempotent: skips if a
    /// host for that target already exists.
    private func seedGatewayHostIfNeeded() async {
        guard let gateway = await addressDiscovery.defaultGatewayHost(), !gateway.isEmpty else { return }
        let host = PingHostConfig(displayName: "Gateway", address: gateway, method: .icmp)
        // Dedup by target address (not exact id) so a gateway already monitored under any
        // method/port isn't added again.
        let alreadyMonitored = ((try? integrationRegistry.instances()) ?? [])
            .filter { $0.integrationID == IntegrationIDs.ping }
            .compactMap { PingHostConfig(configObject: $0.config)?.address }
            .contains(gateway)
        guard !alreadyMonitored else { return }
        try? integrationRegistry.upsert(.ping(host))
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
        Task { await engine.start() }
        Task { await refreshAlertRules() }
        Task { await seedGatewayHostIfNeeded() }
        refreshInstalledProviders()
        refreshCommandPalette()
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

    func selectPingHost(_ id: IntegrationInstanceID?) {
        pingSelection = id
        Task { await refreshPing() }
    }

    /// Rebuild per-host displays (readout + windowed samples + stats) for the pingscope UI,
    /// plus the full host list for Settings.
    func refreshPing() async {
        let now = Date()
        let freshness = max(pingRange.seconds, 30)
        let allRecords = ((try? integrationRegistry.instances()) ?? [])
            .filter { $0.integrationID == IntegrationIDs.ping }
        let disabledTypes = (try? integrationRegistry.disabledIntegrationIDs()) ?? []
        let primaryID = (try? integrationRegistry.primaryInstanceID()) ?? nil
        let activeRecords = disabledTypes.contains(IntegrationIDs.ping) ? [] : allRecords.filter(\.enabled)
        let fallbackPrimary = primaryID ?? activeRecords.first?.id

        // All hosts (enabled + disabled) for the Settings list.
        pingHostRows = allRecords.compactMap { record in
            guard let config = PingHostConfig(configObject: record.config) else { return nil }
            return PingHostRow(instanceID: record.id, config: config, enabled: record.enabled, isPrimary: record.id == fallbackPrimary)
        }

        // Active hosts (windowed history) for the popover, plus diagnosis/alert inputs.
        var displays: [PingHostDisplay] = []
        var diagnosisHosts: [DiagnosisHost] = []
        var alertHosts: [AlertHost] = []
        for (index, record) in activeRecords.enumerated() {
            guard let host = PingHostConfig(configObject: record.config) else { continue }
            let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
            let samples = await engine.historySamples(latencyID, since: now.addingTimeInterval(-pingRange.seconds))
            let health = HealthStatus(legacy: snapshot.providers[providerInstance]?.value?.health ?? .unknown)
            let readout = PingPresenter.readout(latest: samples.last, health: health, now: now, freshness: freshness)
            displays.append(PingHostDisplay(
                instanceID: record.id,
                providerInstanceID: providerInstance,
                latencyEntityID: latencyID,
                name: record.displayName,
                detail: host.detailLine,
                samples: samples,
                readout: readout,
                stats: SampleStats.from(samples),
                isPrimary: record.id == fallbackPrimary,
                colorIndex: index
            ))
            diagnosisHosts.append(DiagnosisHost(id: record.id.rawValue, tier: pingTierClassifier.tier(for: host), status: health))
            alertHosts.append(AlertHost(id: record.id.rawValue, name: record.displayName, status: health,
                                        notifyOnRecovery: host.policy.notifyOnRecovery, cooldown: host.policy.cooldown))
        }
        pingHosts = displays
        let primary = displays.first(where: \.isPrimary) ?? displays.first
        menuGlyph = primary.map { MenuBarGlyph(latencyText: $0.readout.text, tone: $0.readout.tone) }
            ?? MenuBarGlyph(latencyText: "--ms", tone: .neutral)

        // Tier diagnosis + network/host alerts (integration-internal).
        let diagnosis = pingDiagnoser.diagnose(hosts: diagnosisHosts)
        pingDiagnosis = diagnosis
        let events = pingAlertMonitor.evaluate(hosts: alertHosts, diagnosis: diagnosis, now: now)
        await alertNotifier.deliver(events)

        // Generic surface: latency entities of the shown hosts (single host when one is selected,
        // all enabled hosts otherwise) + the diagnosis banner. The composer collapses same-class
        // latency series into one multi-line graph; a single host stays single-series (keeps stats).
        let shown = pingSelection.map { id in activeRecords.filter { $0.id == id } } ?? activeRecords
        let allDescriptors = await engine.entityDescriptors()
        let allStates = await engine.entityStates()
        var descriptors: [EntityID: EntityDescriptor] = [:]
        var states: [EntityID: EntityState] = [:]
        var series: [EntityID: [Sample]] = [:]
        var latencyDescriptors: [EntityDescriptor] = []
        for record in shown {
            let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
            guard var latency = allDescriptors[providerInstance]?.first(where: { $0.id == latencyID }) else { continue }
            latency.name = record.displayName    // legend/label reads the host, not "Latency"
            latencyDescriptors.append(latency)
            descriptors[latencyID] = latency
            states[latencyID] = allStates[latencyID]
            series[latencyID] = await engine.historySamples(latencyID, since: now.addingTimeInterval(-pingRange.seconds))
        }

        var planCards: [CardSpec] = []
        if let (diagnosisDescriptor, diagnosisState) = DiagnosisEntity.make(diagnosis) {
            descriptors[diagnosisDescriptor.id] = diagnosisDescriptor
            states[diagnosisDescriptor.id] = diagnosisState
            planCards.append(CardSpec(id: "card.\(diagnosisDescriptor.id.rawValue)", kind: .statusBanner,
                                      title: diagnosisDescriptor.name, entities: [diagnosisDescriptor.id], role: .banner))
        }
        planCards.append(contentsOf: SurfaceComposer.detailPlan(descriptors: latencyDescriptors, states: states).cards)
        surfaceData = SurfaceData(descriptors: descriptors, states: states, series: series)
        surfacePlan = SurfacePlan(cards: planCards)
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

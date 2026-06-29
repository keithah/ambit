import AmbitCore
import AmbitUI
import Foundation
import SwiftUI

enum IntegrationInstanceDraftError: Error, Equatable {
    case unsupportedIntegration(IntegrationID)
    case invalidValues
}

struct LocalNetworkPermissionHintRow: Equatable, Identifiable, Sendable {
    var id: String { title }
    var title: String
    var detail: String
}

private extension EntityPresentationOverride {
    var isEmpty: Bool {
        visibility == nil &&
            pinned == nil &&
            displayThreshold == nil &&
            alertPolicy == nil &&
            graphStyle == nil &&
            graphRange == nil &&
            enabled == nil &&
            interval == nil
    }
}

private extension SlotPresentationOverride {
    var isEmpty: Bool {
        shownItems == nil &&
            hiddenItems.isEmpty &&
            tableRowLimit == nil &&
            graphRange == nil &&
            selectedInstanceID == nil &&
            primaryInstanceID == nil &&
            showsAllInstances == false
    }
}

private extension Slot {
    func coversIntegrationRecord(_ record: IntegrationInstanceRecord) -> Bool {
        switch selection {
        case .integration(let instanceID):
            return instanceID == record.id
        case .integrations(let instanceIDs):
            return instanceIDs.contains(record.id)
        case .integrationType(let integrationID):
            return integrationID == record.integrationID
        case .capability, .entities:
            return id.rawValue == record.id.rawValue
        }
    }
}

private extension GraphRange {
    init(timeRange: TimeRange) {
        switch timeRange {
        case .oneMinute: self = .m1
        case .fiveMinutes: self = .m5
        case .tenMinutes: self = .m10
        case .oneHour: self = .h1
        }
    }
}

private extension TimeRange {
    init(graphRange: GraphRange) {
        switch graphRange {
        case .m1: self = .oneMinute
        case .m5: self = .fiveMinutes
        case .m10: self = .tenMinutes
        case .h1: self = .oneHour
        }
    }
}

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

    private var fallbackGraphRange: GraphRange = .m5
    @Published var monitoringDiagnosis: MonitoringDiagnosis?
    /// Per-slot surface values (plan + data + glyph + hostOptions), keyed by SlotID.
    @Published var slotSurfaces: [SlotID: SlotSurface] = [:]
    @Published var presentationSettings = PresentationSettingsModel(integrations: [], slots: [])
    /// Per-slot focused instance (nil = show all resolved instances for the slot).
    @Published var slotFocus: [SlotID: IntegrationInstanceID] = [:]
    /// Floating overlay selected slot. Nil reconciles to the first available slot.
    @Published var overlaySlotID: SlotID?
    @Published var startAtLoginEnabled = false
    @Published var startAtLoginMessage: String?

    // Menu-bar slots (P3). Seeded with one dedicated Ping slot for parity; the chrome renders
    // one status item per slot.
    @Published var slots: [Slot] = []
    private let configStore: any PresentationConfigStore
    let historyRetentionInterval = HistoryService.defaultRetentionInterval

    private var monitoringDiagnosisCoordinator = MonitoringSlotDiagnosisCoordinator()

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
    private let slotSurfaceCoordinator = SlotSurfaceCoordinator()
    private let alertTargetResolver = AlertTargetResolver()
    private let alertNotificationService = AlertNotificationService()
    private let notificationDeliverer: any NotificationDelivering
    private let notificationSettingsOpener: any NotificationSettingsOpening
    private let startAtLoginCoordinator: StartAtLoginCoordinator
    private let networkChangeSource: (any NetworkChangeSource)?
    private var networkPathSnapshot: NetworkPathSnapshot = .connected
    private var networkAlertStateMachine = MonitoringAlertStateMachine(warmUpCycles: 0)
    private var subscriptionTask: Task<Void, Never>?
    private var staleTickTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        installedProviderStore: any InstalledProviderStore = UserDefaultsInstalledProviderStore(),
        endpointSelector: EndpointSelector = EndpointSelector(),
        reachabilityProbe: ReachabilityProbeProtocol = ReachabilityProbe(),
        integrationRegistry: (any IntegrationRegistry)? = nil,
        addressDiscovery: any RouterAddressDiscovery = SystemRouterAddressDiscovery(),
        configStore: any PresentationConfigStore = UserDefaultsPresentationConfigStore(),
        notificationDeliverer: any NotificationDelivering = MacNotificationDeliverer(),
        notificationSettingsOpener: any NotificationSettingsOpening = MacNotificationSettingsOpener(),
        startAtLoginCoordinator: StartAtLoginCoordinator = StartAtLoginCoordinator(),
        networkChangeSource: (any NetworkChangeSource)? = NWPathNetworkChangeSource()
    ) {
        let settings = (try? settingsStore.load()) ?? AppSettings()
        let routerPassword = (try? credentialStore.password(account: settings.username)) ?? RouterDefaults.routerPassword
        self.settings = settings
        self.routerPassword = routerPassword
        self.notificationDeliverer = notificationDeliverer
        self.notificationSettingsOpener = notificationSettingsOpener
        self.startAtLoginCoordinator = startAtLoginCoordinator
        self.networkChangeSource = networkChangeSource
        self.installedProviderStore = installedProviderStore
        self.credentialStore = credentialStore
        self.addressDiscovery = addressDiscovery
        self.configStore = configStore
        self.startAtLoginEnabled = startAtLoginCoordinator.isEnabled()
        let integrationRegistry = integrationRegistry ?? UserDefaultsIntegrationRegistry()
        self.integrationRegistry = integrationRegistry
        IntegrationConfigMigrator(settings: settings).migrate(integrationRegistry)
        self.slots = Self.loadOrSeedSlots(configStore, registry: integrationRegistry)
        if let raw = UserDefaults.standard.string(forKey: "pingRange"), let range = TimeRange(rawValue: raw) {
            fallbackGraphRange = GraphRange(timeRange: range)
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
        refreshPresentationSettingsFromRegistry()
    }

    deinit {
        subscriptionTask?.cancel()
        staleTickTask?.cancel()
        let networkChangeSource = networkChangeSource
        Task { @MainActor in
            networkChangeSource?.cancel()
        }
    }

    /// Load persisted slots, then backfill enabled built-in integration slots. `.integrationType`
    /// keeps ping host membership dynamic; single-instance built-ins use `.integration`.
    ///
    /// This intentionally runs at launch before AppKit status items are created. If a user deletes
    /// an auto slot, there is not yet a durable "suppressed auto slot" marker, so an enabled built-in
    /// integration with no covering slot is re-added on next launch.
    private static func loadOrSeedSlots(
        _ store: any PresentationConfigStore,
        registry: any IntegrationRegistry
    ) -> [Slot] {
        var config = store.load()
        let autoRecords = autoSlotRecords(registry: registry)
        var changed = false
        if config.slots.isEmpty {
            config.slots = [pingSlot()]
            changed = true
        }
        for record in autoRecords where !config.slots.contains(where: { $0.coversIntegrationRecord(record) }) {
            config.slots.append(autoSlot(for: record))
            changed = true
        }
        if changed {
            store.save(config)
        }
        return config.slots
    }

    private static func pingSlot() -> Slot {
        Slot(id: "ping", title: "Ping", selection: .integrationType(IntegrationIDs.ping), barReadout: .dynamic)
    }

    private static func autoSlotRecords(registry: any IntegrationRegistry) -> [IntegrationInstanceRecord] {
        ((try? registry.activeInstances()) ?? [])
            .filter { record in
                record.origin == .builtIn && record.integrationID != IntegrationIDs.ping
            }
    }

    private static func autoSlot(for record: IntegrationInstanceRecord) -> Slot {
        Slot(id: SlotID(rawValue: record.id.rawValue), title: record.displayName, selection: .integration(record.id), barReadout: .dynamic)
    }

    nonisolated static func reconciledGatewaySeedRecords(
        _ records: [IntegrationInstanceRecord],
        currentGateway: String
    ) -> (records: [IntegrationInstanceRecord], changed: Bool) {
        var changed = false
        var reconciled: [IntegrationInstanceRecord] = []
        var insertedGateway = false

        for record in records {
            guard Self.isAutoSeededGateway(record) else {
                reconciled.append(record)
                continue
            }
            let stableRecord = Self.autoGatewayRecord(currentGateway: currentGateway, preserving: record)
            if !insertedGateway {
                reconciled.append(stableRecord)
                insertedGateway = true
            } else {
                changed = true
            }
            if stableRecord != record {
                changed = true
            }
        }

        if !insertedGateway {
            reconciled.append(Self.autoGatewayRecord(currentGateway: currentGateway, preserving: nil))
            changed = true
        }

        return (reconciled, changed)
    }

    nonisolated static var autoGatewayInstanceID: IntegrationInstanceID {
        IntegrationInstanceID(rawValue: "ping@gateway")
    }

    nonisolated private static func autoGatewayRecord(
        currentGateway: String,
        preserving existing: IntegrationInstanceRecord?
    ) -> IntegrationInstanceRecord {
        var host = existing
            .flatMap { PingHostConfig(configObject: $0.config, displayNameFallback: $0.displayName) }
            ?? PingHostConfig(displayName: "Gateway", address: currentGateway, method: .icmp)
        host.displayName = "Gateway"
        host.address = currentGateway
        host.method = .icmp
        host.port = nil
        return IntegrationInstanceRecord(
            id: autoGatewayInstanceID,
            integrationID: IntegrationIDs.ping,
            displayName: "Gateway",
            enabled: existing?.enabled ?? true,
            origin: existing?.origin ?? .user,
            config: host.asConfigObject()
        )
    }

    nonisolated private static func isAutoSeededGateway(_ record: IntegrationInstanceRecord) -> Bool {
        guard record.integrationID == IntegrationIDs.ping,
              record.displayName == "Gateway",
              let host = PingHostConfig(configObject: record.config)
        else { return false }
        return host.displayName == "Gateway" && host.method == .icmp && host.port == nil
    }

    nonisolated private static func autoGatewayAddress(in records: [IntegrationInstanceRecord]) -> String? {
        records.first(where: isAutoSeededGateway)
            .flatMap { PingHostConfig(configObject: $0.config, displayNameFallback: $0.displayName)?.address }
    }

    nonisolated static func networkChangeEvent(
        previousGateway: String?,
        currentGateway: String?,
        now: Date = Date()
    ) -> AlertEvent? {
        var machine = MonitoringAlertStateMachine(warmUpCycles: 0)
        return machine.networkChangeEvent(MonitoringNetworkChange(previousGateway: previousGateway, currentGateway: currentGateway), now: now)
    }

    /// Detect the default gateway and add/update the stable auto gateway pingscope host (ICMP —
    /// truest hop latency, no port guessing) via the registry-add + reload path.
    @discardableResult
    private func seedGatewayHostIfNeeded() async -> Bool {
        guard let gateway = await addressDiscovery.defaultGatewayHost(), !gateway.isEmpty else { return false }
        let all = (try? integrationRegistry.instances()) ?? []
        let migratedGatewayIDs = Set(all.filter(Self.isAutoSeededGateway).map(\.id))
            .subtracting([Self.autoGatewayInstanceID])
        let result = Self.reconciledGatewaySeedRecords(all, currentGateway: gateway)
        guard result.changed else { return false }
        try? integrationRegistry.save(result.records)
        migrateAutoGatewayReferences(from: migratedGatewayIDs)
        await engine.reloadProviders()
        await refreshAlertRules()
        await engine.refresh()
        return true
    }

    private func migrateAutoGatewayReferences(from oldIDs: Set<IntegrationInstanceID>) {
        guard !oldIDs.isEmpty else { return }
        if let primary = try? integrationRegistry.primaryInstanceID(), oldIDs.contains(primary) {
            try? integrationRegistry.setPrimaryInstanceID(Self.autoGatewayInstanceID)
        }
        var config = configStore.load()
        var changed = false
        for (slotID, var override) in config.slotOverrides {
            if let selected = override.selectedInstanceID, oldIDs.contains(selected) {
                override.selectedInstanceID = Self.autoGatewayInstanceID
                changed = true
            }
            if let primary = override.primaryInstanceID, oldIDs.contains(primary) {
                override.primaryInstanceID = Self.autoGatewayInstanceID
                changed = true
            }
            if override.isEmpty {
                config.slotOverrides.removeValue(forKey: slotID)
            } else {
                config.slotOverrides[slotID] = override
            }
        }
        for (slotID, focus) in slotFocus where oldIDs.contains(focus) {
            slotFocus[slotID] = Self.autoGatewayInstanceID
        }
        if changed {
            configStore.save(config)
            rebuildPresentationSettings(config: config)
        }
    }

    func handleNetworkConfigurationChanged(_ snapshot: NetworkPathSnapshot = .connected) async {
        let previousStatus = networkPathSnapshot.connectivityStatus
        networkPathSnapshot = snapshot
        let previousGateway = Self.autoGatewayAddress(in: (try? integrationRegistry.instances()) ?? [])
        await seedGatewayHostIfNeeded()
        let currentGateway = Self.autoGatewayAddress(in: (try? integrationRegistry.instances()) ?? [])
        if let event = networkAlertStateMachine.evaluateNetworkStatus(previous: previousStatus, current: snapshot.connectivityStatus) {
            await deliverAlerts([event], descriptors: await engine.entityDescriptors())
        }
        if let event = networkAlertStateMachine.networkChangeEvent(MonitoringNetworkChange(previousGateway: previousGateway, currentGateway: currentGateway)) {
            await deliverAlerts([event], descriptors: await engine.entityDescriptors())
        }
        await engine.pollNow()
        await refreshPing()
    }

    func handleSystemWillSleep() {
        Task { await engine.prepareForSleep() }
    }

    func handleSystemDidWake() async {
        monitoringDiagnosisCoordinator.resetAlertWarmUp()
        await handleNetworkConfigurationChanged(.connected)
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
                let descriptors = await self.engine.entityDescriptors()
                await self.deliverAlerts(events, descriptors: descriptors)
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
        networkChangeSource?.onChange = { [weak self] snapshot in
            await self?.handleNetworkConfigurationChanged(snapshot)
        }
        networkChangeSource?.start()
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

    func refreshPresentationSettingsFromRegistry() {
        let records = (try? integrationRegistry.instances()) ?? []
        rebuildPresentationSettings(
            registryRecords: records,
            config: configStore.load()
        )
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

    func setSlotGraphRange(_ slot: SlotID, _ range: GraphRange?) {
        mutateSlotOverride(slot) { override in
            override.graphRange = range
        }
        Task { await refreshPing() }
    }

    /// Set or clear the per-slot focus. `nil` is an explicit All Hosts selection.
    func selectInstance(_ slot: SlotID, _ id: IntegrationInstanceID?) {
        var config = configStore.load()
        var override = config.slotOverrides[slot] ?? SlotPresentationOverride()
        override.selectedInstanceID = id
        override.showsAllInstances = id == nil
        if override.isEmpty {
            config.slotOverrides.removeValue(forKey: slot)
        } else {
            config.slotOverrides[slot] = override
        }
        configStore.save(config)
        if let id {
            slotFocus[slot] = id
        } else {
            slotFocus.removeValue(forKey: slot)
        }
        rebuildPresentationSettings(config: config)
        Task { await refreshPing() }
    }

    func setSlotPrimaryInstance(_ slot: SlotID, _ id: IntegrationInstanceID?) {
        mutateSlotOverride(slot) { override in
            override.primaryInstanceID = id
        }
        Task { await refreshPing() }
    }

    func selectOverlaySlot(_ slot: SlotID?) {
        overlaySlotID = OverlaySlotSelection.reconciled(slot, slots: slots)
    }

    /// Rebuild diagnosis/alerts, then build per-slot surfaces.
    func refreshPing() async {
        let now = Date()
        let allRegistryRecords = (try? integrationRegistry.instances()) ?? []
        let disabledTypes = (try? integrationRegistry.disabledIntegrationIDs()) ?? []

        let loadedConfig = configStore.load()
        let diagnosisGraphRange = Self.diagnosisGraphRange(slots: slots, config: loadedConfig, fallback: fallbackGraphRange)
        let allDescriptors = await engine.entityDescriptors()
        let monitoringInstanceIDs = Set(
            allDescriptors.values
                .flatMap { $0 }
                .filter { $0.monitoring?.diagnosticSummary == .member || $0.monitoring?.role != nil }
                .map { $0.instanceID.integrationInstanceID }
        )
        let activeRecords = allRegistryRecords.filter { record in
            record.enabled &&
                !disabledTypes.contains(record.integrationID) &&
                monitoringInstanceIDs.contains(record.id)
        }
        let diagnosisResult = await monitoringDiagnosisCoordinator.evaluate(
            activeRecords: activeRecords,
            descriptors: allDescriptors,
            snapshot: snapshot,
            networkStatus: networkPathSnapshot.connectivityStatus,
            now: now,
            range: TimeRange(graphRange: diagnosisGraphRange)
        ) { [engine] id, since in
            await engine.historySamples(id, since: since)
        }
        monitoringDiagnosis = diagnosisResult.diagnosis
        let events = diagnosisResult.events

        // Build per-slot surfaces.
        await deliverAlerts(events, descriptors: allDescriptors)
        let allStates = await engine.entityStates(now: now)
        let primaryPingInstanceID = (try? integrationRegistry.primaryInstanceID()) ?? nil
        presentationSettings = Self.presentationSettingsModel(
            registryRecords: allRegistryRecords,
            descriptors: allDescriptors,
            states: allStates,
            config: configStore.load(),
            disabledIntegrationIDs: disabledTypes
        )
        var newSurfaces: [SlotID: SlotSurface] = [:]

        for slot in slots {
            let surface = await slotSurfaceCoordinator.buildSurface(
                slot: slot,
                monitoringDiagnosis: diagnosisResult.diagnosis,
                allRegistryRecords: allRegistryRecords,
                allDescriptors: allDescriptors,
                allStates: allStates,
                firedAlertEvents: events,
                slotFocus: slotFocus,
                primaryPingInstanceID: primaryPingInstanceID,
                fallbackGraphRange: fallbackGraphRange,
                config: loadedConfig,
                now: now
            ) { [engine] id, since in
                await engine.historySamples(id, since: since)
            }
            newSurfaces[slot.id] = surface
        }
        slotSurfaces = newSurfaces
    }

    private func deliverAlerts(_ events: [AlertEvent], descriptors: [ProviderInstanceID: [EntityDescriptor]]) async {
        guard !events.isEmpty else { return }
        var allDescriptors = descriptors.values.flatMap { $0 }
        let summaryEntityID = DiagnosticSummaryEntity.Owner.ping.entityID
        if events.contains(where: { $0.target == .entity(summaryEntityID) }),
           !allDescriptors.contains(where: { $0.id == summaryEntityID }) {
            allDescriptors.append(DiagnosticSummaryEntity.descriptor(owner: .ping))
        }
        let resolved = events.map { event in
            ResolvedAlertEvent(event: event, entityIDs: alertTargetResolver.resolve(event, descriptors: allDescriptors))
        }
        _ = await alertNotificationService.deliver(resolved, using: notificationDeliverer)
    }

    nonisolated static func presentationSettingsModel(
        registryRecords: [IntegrationInstanceRecord],
        descriptors: [ProviderInstanceID: [EntityDescriptor]],
        states: [EntityID: EntityState],
        config: PresentationConfig,
        disabledIntegrationIDs: Set<IntegrationID> = []
    ) -> PresentationSettingsModel {
        PresentationSettingsModel.build(
            integrations: registryRecords,
            descriptors: descriptors,
            states: states,
            overrides: config,
            schemas: knownIntegrationSchemas(),
            disabledIntegrationIDs: disabledIntegrationIDs
        )
    }

    nonisolated private static func knownIntegrationSchemas() -> [IntegrationID: IntegrationConfigSchema] {
        Dictionary(
            uniqueKeysWithValues: [PingIntegration()]
                .compactMap { integration in
                    integration.configSchema.map { (integration.id, $0) }
                }
        )
    }

    nonisolated private static func diagnosisGraphRange(
        slots: [Slot],
        config: PresentationConfig,
        fallback: GraphRange
    ) -> GraphRange {
        guard let slot = slots.first(where: { config.slotOverrides[$0.id]?.graphRange != nil }) else { return fallback }
        return config.slotOverrides[slot.id]?.graphRange ?? fallback
    }

    func setEntityVisibility(_ id: EntityID, _ visibility: GlanceVisibility?) {
        mutateEntityOverride(id) { override in
            override.visibility = visibility
        }
    }

    func setEntityPinned(_ id: EntityID, _ pinned: Bool?) {
        mutateEntityOverride(id) { override in
            override.pinned = pinned
        }
    }

    func setEntityEnabled(_ id: EntityID, _ enabled: Bool?) {
        mutateEntityOverride(id) { override in
            override.enabled = enabled
        }
    }

    func setEntityDisplayThreshold(_ id: EntityID, _ threshold: DisplayThreshold?) {
        mutateEntityOverride(id) { override in
            override.displayThreshold = threshold
        }
    }

    func setEntityGraphRange(_ id: EntityID, _ range: GraphRange?) {
        mutateEntityOverride(id) { override in
            override.graphRange = range
        }
    }

    func setEntityGraphStyle(_ id: EntityID, _ style: GraphStyle?) {
        mutateEntityOverride(id) { override in
            override.graphStyle = style
        }
    }

    func setEntityAlertPolicy(_ id: EntityID, _ policy: AlertPolicy?) {
        mutateEntityOverride(id) { override in
            override.alertPolicy = policy
        }
    }

    func surfaceItems(for slot: Slot) -> [SurfaceComposer.SurfaceItem] {
        let config = configStore.load()
        let records = registryRecordsFromPresentationSettings()
        let descriptors = descriptorsFromPresentationSettings()
        let states = statesFromPresentationSettings()
        let resolved = SlotResolver.resolve(
            slot.selection,
            descriptors: descriptors.values.flatMap { $0 },
            records: records
        )
        return SurfaceComposer.surfaceItems(
            descriptors: resolved,
            states: states,
            config: config,
            slotID: slot.id
        )
    }

    func setSlotShownItems(_ slotID: SlotID, _ shownItems: [SurfaceItemID]?) {
        mutateSlotOverride(slotID) { override in
            override.shownItems = shownItems
            if shownItems != nil {
                override.hiddenItems.removeAll()
            }
        }
    }

    func removeSlotSurfaceItem(_ slotID: SlotID, _ itemID: SurfaceItemID) {
        mutateSlotOverride(slotID) { override in
            if var shownItems = override.shownItems {
                shownItems.removeAll { $0 == itemID }
                override.shownItems = shownItems
            } else {
                override.hiddenItems.insert(itemID)
            }
        }
    }

    func addSlotSurfaceItem(_ slotID: SlotID, _ itemID: SurfaceItemID) {
        mutateSlotOverride(slotID) { override in
            if var shownItems = override.shownItems {
                if !shownItems.contains(itemID) {
                    shownItems.append(itemID)
                }
                override.shownItems = shownItems
            } else {
                override.hiddenItems.remove(itemID)
            }
        }
    }

    func resetSlotSurfaceItems(_ slotID: SlotID) {
        var config = configStore.load()
        config.slotOverrides.removeValue(forKey: slotID)
        configStore.save(config)
        rebuildPresentationSettings(config: config)
    }

    func slotTableRowLimit(_ slotID: SlotID) -> Int {
        configStore.load().slotOverrides[slotID]?.tableRowLimit ?? StatTableCard.Model.defaultRowLimit
    }

    func setSlotTableRowLimit(_ slotID: SlotID, _ limit: Int?) {
        mutateSlotOverride(slotID) { override in
            override.tableRowLimit = limit.map { max(1, $0) }
        }
    }

    func historyExportTargetOptions() -> [HistoryExportTargetOption] {
        Self.historyExportTargetOptions(model: presentationSettings)
    }

    func historyExportData(
        target: HistoryExportTarget,
        range: HistoryExportRange,
        format: HistoryExportFormat,
        now: Date = Date()
    ) async throws -> Data {
        let model = presentationSettings
        let descriptors = Self.historyExportDescriptors(model: model)
        let records = Self.historyExportRecords(model: model)
        let exportDescriptors = HistoryExport.exportDescriptors(
            target: target,
            descriptors: descriptors,
            slots: model.slots,
            records: records
        )
        let since = now.addingTimeInterval(-range.seconds(retentionInterval: historyRetentionInterval))
        var samplesByEntity: [EntityID: [Sample]] = [:]
        for descriptor in exportDescriptors {
            samplesByEntity[descriptor.id] = await engine.historySamples(descriptor.id, since: since)
        }
        let rows = HistoryExport.rows(
            target: target,
            descriptors: descriptors,
            slots: model.slots,
            records: records,
            samplesByEntity: samplesByEntity
        )
        return try HistoryExport.data(rows: rows, format: format)
    }

    func clearHistory() async {
        await engine.clearHistory()
        await refreshPing()
    }

    func notificationAuthorizationStatus() async -> NotificationAuthorizationStatus {
        await notificationDeliverer.authorizationStatus()
    }

    func requestNotificationAuthorization() async -> NotificationAuthorizationStatus {
        await alertNotificationService.requestAuthorization(using: notificationDeliverer)
    }

    func sendTestNotification(now: Date = Date()) async -> [NotificationDeliveryResult] {
        let intent = NotificationIntent.testNotification(now: now)
        let event = ResolvedAlertEvent(
            event: AlertEvent(
                id: intent.id,
                ruleID: "notification.test",
                providerID: "notification.test",
                target: nil,
                phase: intent.phase,
                title: intent.title,
                message: intent.body,
                severity: intent.severity,
                triggeredAt: intent.triggeredAt
            ),
            entityIDs: ["notification.test"]
        )
        return await alertNotificationService.deliver([event], using: notificationDeliverer)
    }

    func openNotificationSettings() {
        notificationSettingsOpener.openNotificationSettings()
    }

    func localNetworkPermissionHints() -> [LocalNetworkPermissionHintRow] {
        let records = (try? integrationRegistry.instances()) ?? []
        return Self.localNetworkPermissionHints(records: records)
    }

    nonisolated static func localNetworkPermissionHints(records: [IntegrationInstanceRecord]) -> [LocalNetworkPermissionHintRow] {
        records.compactMap { record in
            guard record.enabled,
                  let host = PingHostConfig(configObject: record.config, displayNameFallback: record.displayName),
                  LocalNetworkPrivacyHint.requiresLocalNetworkPermission(host: host.address)
            else { return nil }
            return LocalNetworkPermissionHintRow(
                title: host.displayName,
                detail: LocalNetworkPrivacyHint.guidance(for: host.displayName, host: host.address)
            )
        }
    }

    func setStartAtLoginEnabled(_ enabled: Bool) async {
        let result = await startAtLoginCoordinator.setEnabled(enabled)
        switch result {
        case .applied(let value):
            startAtLoginEnabled = value
            startAtLoginMessage = nil
        case .failed(let rolledBackTo, let message):
            startAtLoginEnabled = rolledBackTo
            startAtLoginMessage = message
        }
    }

    nonisolated static func historyExportTargetOptions(model: PresentationSettingsModel) -> [HistoryExportTargetOption] {
        let slotOptions = model.slots.map { slot in
            HistoryExportTargetOption(
                id: "slot:\(slot.id.rawValue)",
                target: .slot(slot.id),
                label: slot.title ?? slot.id.rawValue,
                detail: "Slot"
            )
        }
        let entityOptions = model.integrations.flatMap { group in
            group.entities
                .filter { $0.descriptor.stateClass != nil }
                .map { row in
                    HistoryExportTargetOption(
                        id: "entity:\(row.descriptor.id.rawValue)",
                        target: .entity(row.descriptor.id),
                        label: "\(group.displayName) - \(row.descriptor.name)",
                        detail: row.descriptor.deviceClass?.rawValue ?? "Measurement"
                    )
                }
        }
        return slotOptions + entityOptions
    }

    nonisolated static func historyExportRows(
        target: HistoryExportTarget,
        model: PresentationSettingsModel,
        samplesByEntity: [EntityID: [Sample]]
    ) -> [HistoryExportRow] {
        HistoryExport.rows(
            target: target,
            descriptors: historyExportDescriptors(model: model),
            slots: model.slots,
            records: historyExportRecords(model: model),
            samplesByEntity: samplesByEntity
        )
    }

    func saveIntegrationInstanceDraft(_ draft: IntegrationInstanceDraft) throws {
        switch draft.integrationID {
        case IntegrationIDs.ping:
            try savePingIntegrationInstanceDraft(draft)
        default:
            throw IntegrationInstanceDraftError.unsupportedIntegration(draft.integrationID)
        }
    }

    private func savePingIntegrationInstanceDraft(_ draft: IntegrationInstanceDraft) throws {
        let existing = try draft.replacing.flatMap { try integrationRegistry.instance($0) }
        let existingHost = existing.flatMap { PingHostConfig(configObject: $0.config) }
        let method = draft.values["method"]?.stringValue.flatMap(ProbeMethod.init(rawValue:)) ?? existingHost?.method ?? .tcp
        let port = method.requiresPort
            ? UInt16(clamping: Int(draft.values["port"]?.numberValue ?? Double(existingHost?.port ?? method.defaultPort ?? 443)))
            : nil
        let host = PingHostConfig(
            displayName: draft.values["name"]?.stringValue ?? existingHost?.displayName ?? "Host",
            address: draft.values["address"]?.stringValue ?? existingHost?.address ?? "",
            method: method,
            port: port,
            interval: draft.values["interval"]?.numberValue ?? existingHost?.interval ?? 2,
            timeout: draft.values["timeout"]?.numberValue ?? existingHost?.timeout ?? 2,
            thresholds: HealthThresholds(
                degradedAt: draft.values["degradedAfter"]?.numberValue ?? existingHost?.thresholds.degradedAt ?? 100,
                downAfterFailures: Int(draft.values["downAfter"]?.numberValue ?? Double(existingHost?.thresholds.downAfterFailures ?? 3))
            ),
            policy: existingHost?.policy ?? .preset(.balanced),
            tier: existingHost?.tier
        )
        guard host.isValid else {
            throw IntegrationInstanceDraftError.invalidValues
        }

        var config = host.asConfigObject()
        if let diagnosisSensitivity = draft.values["diagnosisSensitivity"] {
            config["diagnosisSensitivity"] = diagnosisSensitivity
        }
        let record = IntegrationInstanceRecord(
            id: host.integrationInstanceID,
            integrationID: IntegrationIDs.ping,
            displayName: host.displayName,
            enabled: existing?.enabled ?? true,
            origin: existing?.origin ?? .user,
            config: config
        )

        try integrationRegistry.replaceInstance(replacing: draft.replacing, with: record)
        let records = try integrationRegistry.instances()
        rebuildPresentationSettings(
            registryRecords: records,
            config: configStore.load()
        )
        reloadProvidersAndRefresh()
    }

    func deleteIntegrationInstance(_ id: IntegrationInstanceID) throws {
        try integrationRegistry.remove(id)
        if (try? integrationRegistry.primaryInstanceID()) == id {
            try? integrationRegistry.setPrimaryInstanceID(nil)
        }
        let records = (try? integrationRegistry.instances()) ?? []
        rebuildPresentationSettings(
            registryRecords: records,
            config: configStore.load()
        )
        reloadProvidersAndRefresh()
    }

    private func mutateEntityOverride(
        _ id: EntityID,
        mutate: (inout EntityPresentationOverride) -> Void
    ) {
        var config = configStore.load()
        var override = config.entityOverrides[id] ?? EntityPresentationOverride()
        mutate(&override)
        if override.isEmpty {
            config.entityOverrides.removeValue(forKey: id)
        } else {
            config.entityOverrides[id] = override
        }
        configStore.save(config)
        rebuildPresentationSettings(config: config)
    }

    private func mutateSlotOverride(
        _ id: SlotID,
        mutate: (inout SlotPresentationOverride) -> Void
    ) {
        var config = configStore.load()
        var override = config.slotOverrides[id] ?? SlotPresentationOverride()
        mutate(&override)
        if override.isEmpty {
            config.slotOverrides.removeValue(forKey: id)
        } else {
            config.slotOverrides[id] = override
        }
        configStore.save(config)
        rebuildPresentationSettings(config: config)
    }

    private func rebuildPresentationSettings(config: PresentationConfig) {
        let registryRecords = registryRecordsFromPresentationSettings()
        rebuildPresentationSettings(registryRecords: registryRecords, config: config)
    }

    private func rebuildPresentationSettings(
        registryRecords: [IntegrationInstanceRecord],
        config: PresentationConfig
    ) {
        var descriptors: [ProviderInstanceID: [EntityDescriptor]] = [:]
        var states: [EntityID: EntityState] = [:]
        for group in presentationSettings.integrations {
            for row in group.entities {
                descriptors[row.descriptor.instanceID, default: []].append(row.descriptor)
                if let state = row.state {
                    states[row.descriptor.id] = state
                }
            }
        }
        presentationSettings = Self.presentationSettingsModel(
            registryRecords: registryRecords,
            descriptors: descriptors,
            states: states,
            config: config,
            disabledIntegrationIDs: (try? integrationRegistry.disabledIntegrationIDs()) ?? []
        )
    }

    private func registryRecordsFromPresentationSettings() -> [IntegrationInstanceRecord] {
        presentationSettings.integrations.map { group in
            IntegrationInstanceRecord(
                id: group.id,
                integrationID: group.integrationID,
                displayName: group.displayName,
                enabled: group.enabled,
                config: group.configValues
            )
        }
    }

    private func descriptorsFromPresentationSettings() -> [ProviderInstanceID: [EntityDescriptor]] {
        var descriptors: [ProviderInstanceID: [EntityDescriptor]] = [:]
        for group in presentationSettings.integrations {
            for row in group.entities {
                descriptors[row.descriptor.instanceID, default: []].append(row.descriptor)
            }
        }
        return descriptors
    }

    private func statesFromPresentationSettings() -> [EntityID: EntityState] {
        var states: [EntityID: EntityState] = [:]
        for group in presentationSettings.integrations {
            for row in group.entities where row.state != nil {
                states[row.descriptor.id] = row.state
            }
        }
        return states
    }

    nonisolated static func latencyStateForSurface(id: EntityID, current: EntityState?, samples: [Sample]) -> EntityState? {
        SlotSurfaceCoordinator.latencyStateForSurface(id: id, current: current, samples: samples)
    }

    private func reloadProvidersAndRefresh() {
        Task {
            await engine.reloadProviders()
            await refreshAlertRules()
            await engine.refresh()
            await refreshPing()
        }
    }

    nonisolated static func historyBackedCards(in cards: [CardSpec]) -> [CardSpec] {
        SlotSurfaceCoordinator.historyBackedCards(in: cards)
    }

    nonisolated private static func historyExportDescriptors(model: PresentationSettingsModel) -> [EntityDescriptor] {
        model.integrations.flatMap { group in
            group.entities.map(\.descriptor)
        }
    }

    nonisolated private static func historyExportRecords(model: PresentationSettingsModel) -> [IntegrationInstanceRecord] {
        model.integrations.map { group in
            IntegrationInstanceRecord(
                id: group.id,
                integrationID: group.integrationID,
                displayName: group.displayName,
                enabled: group.enabled,
                config: group.configValues
            )
        }
    }

    var historyRetentionLabel: String {
        HistoryExportRange.retention.label(retentionInterval: historyRetentionInterval)
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

import Foundation

public typealias RouterClientFactory = @Sendable (URL, String, @escaping @Sendable () throws -> String?) async -> any GLiNetClientProtocol
public typealias StarlinkStatusProvider = @Sendable (String) async -> StarlinkStatus
public typealias EcoFlowClientFactory = @Sendable (URL) -> any EcoFlowClientProtocol

public actor Engine {
    public nonisolated let snapshots: AsyncStream<StatusSnapshot>
    public nonisolated let engineSnapshots: AsyncStream<EngineSnapshot>

    private let snapshotContinuation: AsyncStream<StatusSnapshot>.Continuation
    private let engineSnapshotContinuation: AsyncStream<EngineSnapshot>.Continuation
    private let settingsStore: SettingsStore
    private let credentialStore: CredentialStore
    private let endpointSelector: EndpointSelector
    private let explicitProviders: [any Provider]
    private let registerBuiltInProviders: Bool
    private let builtInProviderFactory: BuiltInProviderFactory?
    private let builtInIntegrations: [IntegrationID: any Integration]
    private let registry: any IntegrationRegistry
    private let ownsRegistry: Bool
    private let installedProviderStore: (any InstalledProviderStore)?
    private let manifestHTTPClient: any ManifestHTTPClient
    private var providers: [any Provider]
    private let resetRouterClients: @Sendable () async -> Void
    private let usageMeter: ModuleUsageMeter

    private var snapshot = StatusSnapshot()
    private var providerStates: [ProviderInstanceID: SourceState<ProviderSnapshot>] = [:]
    private var lastRegisteredProviderPolls: [ProviderInstanceID: Date] = [:]
    private var settings: AppSettings
    private var routerPassword: String
    private var selectedEndpoint: EndpointSelection?
    private var pollTask: Task<Void, Never>?
    private var speedifyFocusTask: Task<Void, Never>?
    private var routerBackoffUntil: Date?
    private var installedProviderRecords: [InstalledProviderRecord] = []
    private var installedAlertRules: [AlertRule] = []

    public init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        endpointSelector: EndpointSelector = EndpointSelector(),
        reachabilityProbe: ReachabilityProbeProtocol = ReachabilityProbe(),
        routerSpeedifyClient: any RouterSpeedifyClientProtocol = RouterSpeedifyClient(),
        settings: AppSettings? = nil,
        routerPassword: String? = nil,
        routerClientFactory: RouterClientFactory? = nil,
        providers: [any Provider] = [],
        registerBuiltInProviders: Bool = true,
        integrationRegistry: (any IntegrationRegistry)? = nil,
        installedProviderStore: (any InstalledProviderStore)? = nil,
        manifestHTTPClient: any ManifestHTTPClient = URLSessionManifestHTTPClient(),
        resetRouterClients: (@Sendable () async -> Void)? = nil,
        usageMeter: ModuleUsageMeter = ModuleUsageMeter(),
        starlinkStatusProvider: @escaping StarlinkStatusProvider = { path in
            await StarlinkClient(path: path).status()
        },
        ecoFlowClientFactory: @escaping EcoFlowClientFactory = { baseURL in
            EcoFlowHTTPClient(baseURL: baseURL)
        },
        activeMeasurementProcessRunner: (any ProcessRunner)? = nil
    ) {
        let stream = AsyncStream<StatusSnapshot>.makeStream()
        self.snapshots = stream.stream
        self.snapshotContinuation = stream.continuation
        let engineStream = AsyncStream<EngineSnapshot>.makeStream()
        self.engineSnapshots = engineStream.stream
        self.engineSnapshotContinuation = engineStream.continuation
        let loadedSettings = settings ?? ((try? settingsStore.load()) ?? AppSettings())
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.endpointSelector = endpointSelector
        self.settings = loadedSettings
        let loadedRouterPassword = routerPassword ?? ((try? credentialStore.password(account: loadedSettings.username)) ?? RouterDefaults.routerPassword)
        self.routerPassword = loadedRouterPassword
        self.usageMeter = usageMeter
        let actualRouterClientFactory: RouterClientFactory
        let actualResetRouterClients: @Sendable () async -> Void
        if let routerClientFactory {
            actualRouterClientFactory = routerClientFactory
            actualResetRouterClients = resetRouterClients ?? {}
        } else {
            let pool = GLiNetClientPool()
            actualRouterClientFactory = { endpoint, username, passwordProvider in
                await pool.client(endpoint: endpoint, username: username, passwordProvider: passwordProvider)
            }
            actualResetRouterClients = {
                await pool.removeAll()
            }
        }
        self.resetRouterClients = actualResetRouterClients
        self.explicitProviders = providers
        self.registerBuiltInProviders = registerBuiltInProviders
        self.installedProviderStore = installedProviderStore
        self.manifestHTTPClient = manifestHTTPClient
        let builtInProviderFactory = registerBuiltInProviders ? BuiltInProviderFactory(
            routerClientFactory: actualRouterClientFactory,
            reachabilityProbe: reachabilityProbe,
            routerSpeedifyClient: routerSpeedifyClient,
            starlinkStatusProvider: starlinkStatusProvider,
            ecoFlowClientFactory: ecoFlowClientFactory,
            activeMeasurementProcessRunner: activeMeasurementProcessRunner
        ) : nil
        self.builtInProviderFactory = builtInProviderFactory
        // pingscope is the reference integration — always available; its instances (hosts)
        // come from the registry, so it costs nothing when no host is configured.
        let integrationList = (builtInProviderFactory?.integrations() ?? []) + [PingScopeIntegration()]
        self.builtInIntegrations = Dictionary(uniqueKeysWithValues: integrationList.map { ($0.id, $0) })
        // Registry: injected (app) is authoritative; otherwise a default in-memory registry
        // seeded to reproduce the previous built-in set exactly (keeps existing tests green).
        if let integrationRegistry {
            self.registry = integrationRegistry
            self.ownsRegistry = false
        } else {
            let defaultRegistry = InMemoryIntegrationRegistry()
            try? defaultRegistry.save(builtInProviderFactory?.defaultInstanceSeed(settings: loadedSettings) ?? [])
            self.registry = defaultRegistry
            self.ownsRegistry = true
        }
        self.providers = []
        let installed = Self.loadInstalledManifestProviders(
            store: installedProviderStore,
            credentialStore: credentialStore,
            httpClient: manifestHTTPClient
        )
        self.installedProviderRecords = installed.records
        self.installedAlertRules = installed.alertRules
        let builtInProviders = Self.assembleBuiltInProviders(integrations: self.builtInIntegrations, registry: self.registry)
        self.providers = Self.mergedProviders(builtIns: builtInProviders + installed.providers, explicit: providers)
    }

    /// Build the active built-in/registry-driven providers: every enabled instance whose
    /// integration type is enabled, expanded through its integration. Disabled instances
    /// produce nothing, so are never polled.
    private static func assembleBuiltInProviders(
        integrations: [IntegrationID: any Integration],
        registry: any IntegrationRegistry
    ) -> [any Provider] {
        let active = (try? registry.activeInstances()) ?? []
        return active.flatMap { record in
            integrations[record.integrationID]?.makeProviders(instance: record) ?? []
        }
    }

    deinit {
        pollTask?.cancel()
        speedifyFocusTask?.cancel()
        snapshotContinuation.finish()
        engineSnapshotContinuation.finish()
    }

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let interval = await max(self.settings.pollInterval, 2)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        speedifyFocusTask?.cancel()
        speedifyFocusTask = nil
    }

    public func currentSnapshot() -> StatusSnapshot {
        snapshot
    }

    public func currentSelectedEndpoint() -> EndpointSelection? {
        selectedEndpoint
    }

    public func usageSnapshots() async -> [ProviderID: ModuleUsageSnapshot] {
        await usageMeter.allSnapshots()
    }

    public func commands(provider providerID: ProviderID) -> [CommandDescriptor] {
        let builtInCommands = ProviderCommandCatalog.commands(for: providerID)
        let registeredCommands = providers.first { $0.id == providerID }?.commands ?? []
        guard !registerBuiltInProviders else {
            return registeredCommands
        }
        var seenCommandIDs = Set(builtInCommands.map(\.id))
        var commands = builtInCommands
        for command in registeredCommands where !seenCommandIDs.contains(command.id) {
            commands.append(command)
            seenCommandIDs.insert(command.id)
        }
        return commands
    }

    public func commandPalette() -> [CommandPaletteItem] {
        providers.flatMap { provider in
            commands(provider: provider.id).map { command in
                CommandPaletteItem(providerID: provider.id, providerName: provider.displayName, command: command)
            }
        }
    }

    public func providerDisplayNames() -> [ProviderID: String] {
        providers.reduce(into: [:]) { names, provider in
            names[provider.id] = provider.displayName
        }
    }

    public func providerLayouts() -> [ProviderID: ProviderManifest.Layout] {
        providers.reduce(into: [:]) { layouts, provider in
            if let layout = provider.layout {
                layouts[provider.id] = layout
            }
        }
    }

    public func alertRules() -> [AlertRule] {
        AlertRule.defaultRules + installedAlertRules
    }

    public func installedProviders() -> [InstalledProviderRecord] {
        installedProviderRecords
    }

    public func reloadInstalledProviders() {
        rebuildProviders()
    }

    /// Re-assemble providers from the (possibly mutated) registry — e.g. after a pingscope
    /// host is added/removed/toggled.
    public func reloadProviders() {
        rebuildProviders()
    }

    public func refresh() async {
        markRegisteredProvidersLoading()
        publish()

        let endpoint = await resolveEndpoint()
        selectedEndpoint = endpoint.value
        providerStates = await pollRegisteredProviders(routerHost: selectedEndpoint?.host)
        snapshot.lastUpdated = Date()
        publish()
    }

    public func updateSettings(_ settings: AppSettings, routerPassword: String) {
        self.settings = settings
        self.routerPassword = routerPassword
        rebuildBuiltInProvidersIfNeeded()
    }

    public func saveSettings(_ settings: AppSettings, routerPassword: String) async -> String? {
        do {
            try settingsStore.save(settings)
            try credentialStore.setPassword(routerPassword.isEmpty ? nil : routerPassword, account: settings.username)
            self.settings = settings
            self.routerPassword = routerPassword
            rebuildBuiltInProvidersIfNeeded()
            await resetRouterClients()
            return nil
        } catch {
            snapshot.router.errorMessage = error.localizedDescription
            publish()
            return error.localizedDescription
        }
    }

    public func setFocused(_ providerID: ProviderID?, focused: Bool) {
        setSpeedifyFocused(focused && providerID == ProviderIDs.speedify)
    }

    public func setSpeedifyFocused(_ isFocused: Bool) {
        if isFocused {
            guard speedifyFocusTask == nil else { return }
            speedifyFocusTask = Task { [weak self] in
                guard let self else { return }
                await self.refreshSpeedifyOnly(markLoading: false)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await self.refreshSpeedifyOnly(markLoading: false)
                }
            }
        } else {
            speedifyFocusTask?.cancel()
            speedifyFocusTask = nil
        }
    }

    public func refreshSpeedifyNow() async {
        await refreshSpeedifyOnly(markLoading: true)
    }

    public func dispatch(
        provider: ProviderID,
        commandID: String,
        arguments: CommandArguments = CommandArguments()
    ) async throws {
        if let registeredProvider = registeredProvider(provider, supporting: commandID) {
            try await executeRegisteredProviderCommand(
                registeredProvider,
                commandID: commandID,
                arguments: arguments
            )
            return
        }

        guard let registeredProvider = providers.first(where: { $0.id == provider }) else {
            throw JSONRPCClientError.commandFailed("Unsupported provider command \(provider).\(commandID).")
        }
        try await executeRegisteredProviderCommand(
            registeredProvider,
            commandID: commandID,
            arguments: arguments
        )
    }

    public func runCommand(
        provider providerID: ProviderID,
        providerName: String,
        commandID: String,
        commandLabel: String,
        arguments: CommandArguments = CommandArguments()
    ) async -> CommandExecutionResult {
        do {
            try await dispatch(provider: providerID, commandID: commandID, arguments: arguments)
            return .success(
                providerID: providerID,
                providerName: providerName,
                commandID: commandID,
                commandLabel: commandLabel
            )
        } catch {
            return .failure(
                providerID: providerID,
                providerName: providerName,
                commandID: commandID,
                commandLabel: commandLabel,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func registeredProvider(_ providerID: ProviderID, supporting commandID: String) -> (any Provider)? {
        providers.first { provider in
            provider.id == providerID && provider.commands.contains { $0.id == commandID }
        }
    }

    private func executeRegisteredProviderCommand(
        _ provider: any Provider,
        commandID: String,
        arguments: CommandArguments
    ) async throws {
        let started = Date()
        let context = EnvironmentContext(routerHost: selectedEndpoint?.host, settings: settings, routerPassword: routerPassword)
        do {
            try await provider.execute(commandID: commandID, arguments: arguments, context: context)
            let providerSnapshot = await provider.poll(context: context)
            providerStates[provider.instanceID] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
            lastRegisteredProviderPolls[provider.instanceID] = Date()
            await recordUsage(providerID: provider.id, operation: .command, started: started)
            publish()
        } catch {
            await recordUsage(providerID: provider.id, operation: .command, started: started, error: error.localizedDescription)
            throw error
        }
    }

    public func toggleVPN() async {
        try? await dispatch(provider: ProviderIDs.vpn, commandID: ProviderCommandIDs.vpnToggle)
    }

    public func toggleSpeedify() async {
        try? await dispatch(provider: ProviderIDs.speedify, commandID: ProviderCommandIDs.speedifyToggle)
    }

    public func setSpeedifyBondingMode(_ mode: SpeedifyBondingMode) async {
        try? await dispatch(
            provider: ProviderIDs.speedify,
            commandID: ProviderCommandIDs.speedifySetBondingMode,
            arguments: CommandArguments(values: ["mode": .string(mode.commandCode)])
        )
    }

    public func setSpeedifyNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String) async {
        try? await dispatch(
            provider: ProviderIDs.speedify,
            commandID: ProviderCommandIDs.speedifySetNetworkPriority,
            arguments: CommandArguments(values: ["priority": .number(Double(priority.rawValue)), "networkID": .string(networkID)])
        )
    }

    public func setEcoFlowOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async -> EcoFlowControlResponse? {
        guard let provider = providers.first(where: { $0.id == ProviderIDs.ecoflow }) else {
            return nil
        }
        guard let outputProvider = provider as? any EcoFlowOutputControllingProvider else {
            try? await dispatch(
                provider: ProviderIDs.ecoflow,
                commandID: ProviderCommandIDs.ecoFlowSetOutput,
                arguments: CommandArguments(values: ["target": .string(target.rawValue), "state": .string(state.rawValue)])
            )
            return nil
        }

        let started = Date()
        let context = EnvironmentContext(routerHost: selectedEndpoint?.host, settings: settings, routerPassword: routerPassword)
        do {
            let response = try await outputProvider.setOutput(target, state: state, context: context)
            let providerSnapshot = await provider.poll(context: context)
            providerStates[provider.instanceID] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
            lastRegisteredProviderPolls[provider.instanceID] = Date()
            await recordUsage(providerID: provider.id, operation: .command, started: started)
            publish()
            return response
        } catch {
            await recordUsage(providerID: provider.id, operation: .command, started: started, error: error.localizedDescription)
            return nil
        }
    }

    private func refreshSpeedifyOnly(markLoading: Bool) async {
        guard let provider = providers.first(where: { $0.id == ProviderIDs.speedify }) else { return }
        if markLoading {
            let previous = providerStates[provider.instanceID]
            providerStates[provider.instanceID] = SourceState(
                value: previous?.value,
                isLoading: true,
                errorMessage: previous?.errorMessage
            )
            publish()
        }
        if selectedEndpoint == nil {
            let endpoint = await resolveEndpoint()
            selectedEndpoint = endpoint.value
        }
        let started = Date()
        let context = EnvironmentContext(routerHost: selectedEndpoint?.host, settings: settings, routerPassword: routerPassword)
        let providerSnapshot = await provider.poll(context: context)
        providerStates[provider.instanceID] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
        lastRegisteredProviderPolls[provider.instanceID] = Date()
        await recordUsage(providerID: provider.id, operation: .poll, started: started, error: providerSnapshot.error)
        snapshot.lastUpdated = Date()
        publish()
    }

    private func resolveEndpoint() async -> SourceState<EndpointSelection> {
        do {
            let endpoint = try await endpointSelector.select(settings: settings)
            return SourceState(value: endpoint)
        } catch {
            return SourceState(errorMessage: error.localizedDescription)
        }
    }

    private func markRegisteredProvidersLoading() {
        for provider in providers {
            let previous = providerStates[provider.instanceID]
            providerStates[provider.instanceID] = SourceState(
                value: previous?.value,
                isLoading: true,
                errorMessage: previous?.errorMessage
            )
        }
    }

    private func rebuildBuiltInProvidersIfNeeded() {
        guard registerBuiltInProviders || installedProviderStore != nil else { return }
        rebuildProviders()
    }

    private func rebuildProviders() {
        // For the engine-owned default registry, re-seed so settings-driven gating (EcoFlow)
        // tracks changes. An injected registry is user-authoritative and left untouched.
        if ownsRegistry, let defaultRegistry = registry as? InMemoryIntegrationRegistry {
            try? defaultRegistry.save(builtInProviderFactory?.defaultInstanceSeed(settings: settings) ?? [])
        }
        let builtIns = Self.assembleBuiltInProviders(integrations: builtInIntegrations, registry: registry)
        let installed = loadInstalledManifestProviders()
        providers = Self.mergedProviders(
            builtIns: builtIns + installed,
            explicit: explicitProviders
        )
        let activeInstanceIDs = Set(providers.map(\.instanceID))
        let inactiveInstanceIDs = Set(providerStates.keys)
            .union(snapshot.providers.keys)
            .subtracting(activeInstanceIDs)
        for instanceID in inactiveInstanceIDs {
            providerStates[instanceID] = nil
            lastRegisteredProviderPolls[instanceID] = nil
            snapshot.providers[instanceID] = nil
        }
    }

    private func loadInstalledManifestProviders() -> [any Provider] {
        let result = Self.loadInstalledManifestProviders(
            store: installedProviderStore,
            credentialStore: credentialStore,
            httpClient: manifestHTTPClient
        )
        installedProviderRecords = result.records
        installedAlertRules = result.alertRules
        return result.providers
    }

    private static func loadInstalledManifestProviders(
        store installedProviderStore: (any InstalledProviderStore)?,
        credentialStore: any CredentialStore,
        httpClient: any ManifestHTTPClient
    ) -> InstalledManifestProviderLoadResult {
        guard let installedProviderStore else {
            return InstalledManifestProviderLoadResult(records: [], providers: [])
        }
        do {
            return try InstalledManifestProviderLoader(
                store: installedProviderStore,
                credentialStore: credentialStore,
                httpClient: httpClient
            ).load()
        } catch {
            return InstalledManifestProviderLoadResult(records: [], providers: [])
        }
    }

    private func pollRegisteredProviders(routerHost: String?) async -> [ProviderInstanceID: SourceState<ProviderSnapshot>] {
        var states: [ProviderInstanceID: SourceState<ProviderSnapshot>] = [:]
        let context = EnvironmentContext(routerHost: routerHost, settings: settings, routerPassword: routerPassword)
        let now = Date()
        for provider in providers {
            if Self.usesRouterLogin(provider.id),
               let backoff = routerBackoffUntil,
               backoff > Date() {
                states[provider.instanceID] = SourceState(
                    value: providerStates[provider.instanceID]?.value,
                    errorMessage: Self.routerBackoffMessage(until: backoff)
                )
                continue
            }
            if let lastPoll = lastRegisteredProviderPolls[provider.instanceID],
               now.timeIntervalSince(lastPoll) < provider.pollInterval,
               let previous = providerStates[provider.instanceID] {
                states[provider.instanceID] = SourceState(value: previous.value, errorMessage: previous.errorMessage)
                continue
            }
            let started = Date()
            let providerSnapshot = await provider.poll(context: context)
            if Self.usesRouterLogin(provider.id),
               let wait = providerSnapshot.retryAfterSeconds {
                routerBackoffUntil = Date().addingTimeInterval(TimeInterval(wait))
            }
            states[provider.instanceID] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
            lastRegisteredProviderPolls[provider.instanceID] = Date()
            await recordUsage(providerID: provider.id, operation: .poll, started: started, error: providerSnapshot.error)
        }
        return states
    }

    private static func usesRouterLogin(_ providerID: ProviderID) -> Bool {
        providerID == ProviderIDs.router || providerID == ProviderIDs.vpn
    }

    private static func routerBackoffMessage(until date: Date) -> String {
        "Router login paused for \(formatRemaining(until: date))."
    }

    private func publish() {
        let registeredProviderStates = providerStates
        for (instanceID, state) in registeredProviderStates {
            snapshot.providers[instanceID] = state
        }
        snapshotContinuation.yield(snapshot)
        engineSnapshotContinuation.yield(snapshot.engineSnapshot)
    }

    private func recordUsage(
        providerID: ProviderID,
        operation: ModuleUsageOperation,
        started: Date,
        error: String? = nil
    ) async {
        await usageMeter.record(
            providerID: providerID,
            operation: operation,
            duration: Date().timeIntervalSince(started),
            error: error
        )
    }

    private static func formatRemaining(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 {
            return "\(remainder)s"
        }
        if remainder == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainder)s"
    }

    private static func mergedProviders(builtIns: [any Provider], explicit: [any Provider]) -> [any Provider] {
        let explicitIDs = Set(explicit.map(\.id))
        return builtIns.filter { !explicitIDs.contains($0.id) } + explicit
    }
}

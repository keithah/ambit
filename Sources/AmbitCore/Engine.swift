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
    private var providers: [any Provider]
    private let resetRouterClients: @Sendable () async -> Void
    private let usageMeter: ModuleUsageMeter

    private var snapshot = StatusSnapshot()
    private var providerStates: [ProviderID: SourceState<ProviderSnapshot>] = [:]
    private var lastRegisteredProviderPolls: [ProviderID: Date] = [:]
    private var settings: AppSettings
    private var routerPassword: String
    private var selectedEndpoint: EndpointSelection?
    private var pollTask: Task<Void, Never>?
    private var speedifyFocusTask: Task<Void, Never>?
    private var routerBackoffUntil: Date?

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
        let builtInProviderFactory = registerBuiltInProviders ? BuiltInProviderFactory(
            routerClientFactory: actualRouterClientFactory,
            reachabilityProbe: reachabilityProbe,
            routerSpeedifyClient: routerSpeedifyClient,
            starlinkStatusProvider: starlinkStatusProvider,
            ecoFlowClientFactory: ecoFlowClientFactory,
            activeMeasurementProcessRunner: activeMeasurementProcessRunner
        ) : nil
        self.builtInProviderFactory = builtInProviderFactory
        if registerBuiltInProviders {
            self.providers = Self.mergedProviders(
                builtIns: builtInProviderFactory?.providers(settings: loadedSettings) ?? [],
                explicit: providers
            )
        } else {
            self.providers = providers
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
            providerStates[provider.id] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
            lastRegisteredProviderPolls[provider.id] = Date()
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
            providerStates[provider.id] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
            lastRegisteredProviderPolls[provider.id] = Date()
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
            let previous = providerStates[ProviderIDs.speedify]
            providerStates[ProviderIDs.speedify] = SourceState(
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
        providerStates[provider.id] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
        lastRegisteredProviderPolls[provider.id] = Date()
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
            let previous = providerStates[provider.id]
            providerStates[provider.id] = SourceState(
                value: previous?.value,
                isLoading: true,
                errorMessage: previous?.errorMessage
            )
        }
    }

    private func rebuildBuiltInProvidersIfNeeded() {
        guard registerBuiltInProviders, let builtInProviderFactory else { return }
        providers = Self.mergedProviders(
            builtIns: builtInProviderFactory.providers(settings: settings),
            explicit: explicitProviders
        )
        let activeProviderIDs = Set(providers.map(\.id))
        let inactiveBuiltInIDs = BuiltInProviderFactory.providerIDs.subtracting(activeProviderIDs)
        for providerID in inactiveBuiltInIDs {
            providerStates[providerID] = nil
            lastRegisteredProviderPolls[providerID] = nil
            snapshot.providers[providerID] = nil
        }
    }

    private func pollRegisteredProviders(routerHost: String?) async -> [ProviderID: SourceState<ProviderSnapshot>] {
        var states: [ProviderID: SourceState<ProviderSnapshot>] = [:]
        let context = EnvironmentContext(routerHost: routerHost, settings: settings, routerPassword: routerPassword)
        let now = Date()
        for provider in providers {
            if Self.usesRouterLogin(provider.id),
               let backoff = routerBackoffUntil,
               backoff > Date() {
                states[provider.id] = SourceState(
                    value: providerStates[provider.id]?.value,
                    errorMessage: Self.routerBackoffMessage(until: backoff)
                )
                continue
            }
            if let lastPoll = lastRegisteredProviderPolls[provider.id],
               now.timeIntervalSince(lastPoll) < provider.pollInterval,
               let previous = providerStates[provider.id] {
                states[provider.id] = SourceState(value: previous.value, errorMessage: previous.errorMessage)
                continue
            }
            let started = Date()
            let providerSnapshot = await provider.poll(context: context)
            if Self.usesRouterLogin(provider.id),
               let wait = providerSnapshot.retryAfterSeconds {
                routerBackoffUntil = Date().addingTimeInterval(TimeInterval(wait))
            }
            states[provider.id] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
            lastRegisteredProviderPolls[provider.id] = Date()
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
        for (providerID, state) in registeredProviderStates {
            snapshot.providers[providerID] = state
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

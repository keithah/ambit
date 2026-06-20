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
    private let reachabilityProbe: ReachabilityProbeProtocol
    private let routerSpeedifyClient: any RouterSpeedifyClientProtocol
    private let routerClientFactory: RouterClientFactory
    private let providers: [any Provider]
    private let resetRouterClients: @Sendable () async -> Void
    private let starlinkStatusProvider: StarlinkStatusProvider
    private let ecoFlowClientFactory: EcoFlowClientFactory
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
        resetRouterClients: (@Sendable () async -> Void)? = nil,
        usageMeter: ModuleUsageMeter = ModuleUsageMeter(),
        starlinkStatusProvider: @escaping StarlinkStatusProvider = { path in
            await StarlinkClient(path: path).status()
        },
        ecoFlowClientFactory: @escaping EcoFlowClientFactory = { baseURL in
            EcoFlowHTTPClient(baseURL: baseURL)
        }
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
        self.reachabilityProbe = reachabilityProbe
        self.routerSpeedifyClient = routerSpeedifyClient
        self.providers = providers
        self.settings = loadedSettings
        self.routerPassword = routerPassword ?? ((try? credentialStore.password(account: loadedSettings.username)) ?? RouterDefaults.routerPassword)
        self.usageMeter = usageMeter
        if let routerClientFactory {
            self.routerClientFactory = routerClientFactory
        } else {
            let pool = GLiNetClientPool()
            self.routerClientFactory = { endpoint, username, passwordProvider in
                await pool.client(endpoint: endpoint, username: username, passwordProvider: passwordProvider)
            }
            self.resetRouterClients = {
                await pool.removeAll()
            }
            self.starlinkStatusProvider = starlinkStatusProvider
            self.ecoFlowClientFactory = ecoFlowClientFactory
            return
        }
        self.resetRouterClients = resetRouterClients ?? {}
        self.starlinkStatusProvider = starlinkStatusProvider
        self.ecoFlowClientFactory = ecoFlowClientFactory
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
        if !builtInCommands.isEmpty {
            return builtInCommands
        }
        return providers.first { $0.id == providerID }?.commands ?? []
    }

    public func refresh() async {
        snapshot.router.isLoading = true
        snapshot.vpn.isLoading = true
        snapshot.reachability.isLoading = true
        snapshot.speedify.isLoading = true
        snapshot.starlink.isLoading = true
        snapshot.ecoflow.isLoading = settings.ecoflowEnabled
        markRegisteredProvidersLoading()
        publish()

        async let endpointResult = resolveEndpoint()
        async let reachabilityResult = loadLegacyReachabilityStatusIfNeeded()
        async let starlinkResult = loadLegacyStarlinkStatusIfNeeded()

        let endpoint = await endpointResult
        selectedEndpoint = endpoint.value
        async let ecoflowResult = loadLegacyEcoFlowStatusIfNeeded(routerHost: endpoint.value?.host)

        if let selection = endpoint.value, let url = URL.routerRPC(host: selection.host) {
            async let speedifyResult = loadLegacySpeedifyStatusIfNeeded(host: selection.host)
            if let backoff = routerBackoffUntil, backoff > Date() {
                let message = "Router login paused for \(Self.formatRemaining(until: backoff))."
                await recordUsage(providerID: ProviderIDs.router, operation: .poll, started: Date(), error: message)
                await recordUsage(providerID: ProviderIDs.vpn, operation: .poll, started: Date(), error: message)
                snapshot.router = SourceState(value: snapshot.router.value, errorMessage: message)
                snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: message)
                if let reachability = await reachabilityResult {
                    snapshot.reachability = reachability
                }
                if let speedify = await speedifyResult {
                    snapshot.speedify = speedify
                }
                if let starlink = await starlinkResult {
                    snapshot.starlink = starlink
                }
                if let ecoflow = await ecoflowResult {
                    snapshot.ecoflow = ecoflow
                }
                providerStates = await pollRegisteredProviders(routerHost: endpoint.value?.host)
                snapshot.lastUpdated = Date()
                publish()
                return
            }

            let client = await routerClientFactory(url, settings.username, { [routerPassword] in routerPassword })
            if hasRegisteredProvider(ProviderIDs.router) {
                if !hasRegisteredProvider(ProviderIDs.vpn) {
                    snapshot.vpn = await loadVPNStatus(client: client)
                }
            } else {
                let router = await loadRouterStatus(client: client)
                snapshot.router = router
                if router.errorMessage?.localizedCaseInsensitiveContains("locked") == true {
                    if !hasRegisteredProvider(ProviderIDs.vpn) {
                        snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: router.errorMessage)
                    }
                } else {
                    if !hasRegisteredProvider(ProviderIDs.vpn) {
                        snapshot.vpn = await loadVPNStatus(client: client)
                    }
                }
            }
            if let speedify = await speedifyResult {
                snapshot.speedify = speedify
            }
        } else {
            snapshot.router = SourceState(value: snapshot.router.value, errorMessage: endpoint.errorMessage)
            snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: endpoint.errorMessage)
            await recordUsage(providerID: ProviderIDs.router, operation: .poll, started: Date(), error: endpoint.errorMessage)
            await recordUsage(providerID: ProviderIDs.vpn, operation: .poll, started: Date(), error: endpoint.errorMessage)
            if !hasRegisteredProvider(ProviderIDs.speedify) {
                snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: endpoint.errorMessage)
                await recordUsage(providerID: ProviderIDs.speedify, operation: .poll, started: Date(), error: endpoint.errorMessage)
            }
        }

        if let reachability = await reachabilityResult {
            snapshot.reachability = reachability
        }
        if let starlink = await starlinkResult {
            snapshot.starlink = starlink
        }
        if let ecoflow = await ecoflowResult {
            snapshot.ecoflow = ecoflow
        }
        providerStates = await pollRegisteredProviders(routerHost: selectedEndpoint?.host)
        snapshot.lastUpdated = Date()
        publish()
    }

    public func updateSettings(_ settings: AppSettings, routerPassword: String) {
        self.settings = settings
        self.routerPassword = routerPassword
    }

    public func saveSettings(_ settings: AppSettings, routerPassword: String) async -> String? {
        do {
            try settingsStore.save(settings)
            try credentialStore.setPassword(routerPassword.isEmpty ? nil : routerPassword, account: settings.username)
            self.settings = settings
            self.routerPassword = routerPassword
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
        switch (provider, commandID) {
        case (ProviderIDs.vpn, ProviderCommandIDs.vpnToggle):
            await toggleVPN()
        case (ProviderIDs.speedify, ProviderCommandIDs.speedifyToggle):
            await toggleSpeedify()
        case (ProviderIDs.speedify, ProviderCommandIDs.speedifySetBondingMode):
            let mode = try requireString("mode", in: arguments)
            await setSpeedifyBondingMode(SpeedifyBondingMode(code: mode))
        case (ProviderIDs.speedify, ProviderCommandIDs.speedifySetNetworkPriority):
            let priority = try requireInt("priority", in: arguments)
            let networkID = try requireString("networkID", in: arguments)
            await setSpeedifyNetworkPriority(SpeedifyNetworkPriority(value: priority), networkID: networkID)
        case (ProviderIDs.ecoflow, ProviderCommandIDs.ecoFlowSetOutput):
            let target = try requireEcoFlowOutputTarget(in: arguments)
            let state = try requireEcoFlowOutputState(in: arguments)
            _ = await setEcoFlowOutput(target, state: state)
        default:
            guard let registeredProvider = providers.first(where: { $0.id == provider }) else {
                throw JSONRPCClientError.commandFailed("Unsupported provider command \(provider).\(commandID).")
            }
            let started = Date()
            do {
                try await registeredProvider.execute(
                    commandID: commandID,
                    arguments: arguments,
                    context: EnvironmentContext(routerHost: selectedEndpoint?.host, settings: settings)
                )
                await recordUsage(providerID: provider, operation: .command, started: started)
            } catch {
                await recordUsage(providerID: provider, operation: .command, started: started, error: error.localizedDescription)
                throw error
            }
        }
    }

    private func requireString(_ key: String, in arguments: CommandArguments) throws -> String {
        guard let value = arguments.values[key]?.stringValue, !value.isEmpty else {
            throw JSONRPCClientError.commandFailed("Provider command argument \(key) must be a non-empty string.")
        }
        return value
    }

    private func requireInt(_ key: String, in arguments: CommandArguments) throws -> Int {
        guard let value = arguments.values[key]?.intValue else {
            throw JSONRPCClientError.commandFailed("Provider command argument \(key) must be a number.")
        }
        return value
    }

    private func requireEcoFlowOutputTarget(in arguments: CommandArguments) throws -> EcoFlowOutputTarget {
        let rawValue = try requireString("target", in: arguments)
        guard let target = EcoFlowOutputTarget(rawValue: rawValue) else {
            throw JSONRPCClientError.commandFailed("Provider command argument target is not a supported EcoFlow output.")
        }
        return target
    }

    private func requireEcoFlowOutputState(in arguments: CommandArguments) throws -> EcoFlowOutputState {
        let rawValue = try requireString("state", in: arguments)
        guard let state = EcoFlowOutputState(rawValue: rawValue), state != .unknown else {
            throw JSONRPCClientError.commandFailed("Provider command argument state must be on or off.")
        }
        return state
    }

    public func toggleVPN() async {
        let started = Date()
        guard
            let selection = selectedEndpoint,
            let url = URL.routerRPC(host: selection.host),
            let status = snapshot.vpn.value
        else {
            await recordUsage(providerID: ProviderIDs.vpn, operation: .command, started: started, error: "VPN command prerequisites unavailable.")
            return
        }
        let client = await routerClientFactory(url, settings.username, { [routerPassword] in routerPassword })
        do {
            try await client.setVPNEnabled(!status.isConnected, protocol: status.vpnProtocol)
            snapshot.vpn = await loadVPNStatus(client: client)
            await recordUsage(providerID: ProviderIDs.vpn, operation: .command, started: started)
            publish()
        } catch {
            snapshot.vpn.errorMessage = error.localizedDescription
            await recordUsage(providerID: ProviderIDs.vpn, operation: .command, started: started, error: error.localizedDescription)
            publish()
        }
    }

    public func toggleSpeedify() async {
        let started = Date()
        guard let selection = selectedEndpoint, let status = snapshot.speedify.value else {
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started, error: "Speedify command prerequisites unavailable.")
            return
        }
        snapshot.speedify.isLoading = true
        publish()
        do {
            if status.isConnected {
                try await routerSpeedifyClient.disconnect(host: selection.host)
            } else {
                try await routerSpeedifyClient.connect(host: selection.host)
            }
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started, error: error.localizedDescription)
        }
        publish()
    }

    public func setSpeedifyBondingMode(_ mode: SpeedifyBondingMode) async {
        let started = Date()
        guard let selection = selectedEndpoint else {
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started, error: "Speedify endpoint unavailable.")
            return
        }
        snapshot.speedify.isLoading = true
        publish()
        do {
            try await routerSpeedifyClient.setBondingMode(mode, host: selection.host)
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started, error: error.localizedDescription)
        }
        publish()
    }

    public func setSpeedifyNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String) async {
        let started = Date()
        guard let selection = selectedEndpoint else {
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started, error: "Speedify endpoint unavailable.")
            return
        }
        snapshot.speedify.isLoading = true
        publish()
        do {
            try await routerSpeedifyClient.setNetworkPriority(priority, networkID: networkID, host: selection.host)
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
            await recordUsage(providerID: ProviderIDs.speedify, operation: .command, started: started, error: error.localizedDescription)
        }
        publish()
    }

    public func setEcoFlowOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async -> EcoFlowControlResponse? {
        let started = Date()
        guard settings.ecoflowEnabled else {
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .command, started: started, error: "EcoFlow is disabled.")
            return nil
        }
        let host = settings.ecoflowHost == "auto" ? selectedEndpoint?.host : settings.ecoflowHost
        guard let host, !host.isEmpty, let baseURL = URL(string: "http://\(host):\(settings.ecoflowPort)") else {
            snapshot.ecoflow.errorMessage = "EcoFlow daemon endpoint unresolved."
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .command, started: started, error: snapshot.ecoflow.errorMessage)
            publish()
            return nil
        }

        let client = ecoFlowClientFactory(baseURL)
        do {
            let response = try await client.setOutput(target, state: state)
            snapshot.ecoflow = await loadEcoFlowStatus(routerHost: selectedEndpoint?.host)
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .command, started: started)
            publish()
            return response
        } catch {
            snapshot.ecoflow = SourceState(value: snapshot.ecoflow.value, errorMessage: error.localizedDescription)
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .command, started: started, error: error.localizedDescription)
            publish()
            return nil
        }
    }

    private func refreshSpeedifyOnly(markLoading: Bool) async {
        if markLoading {
            snapshot.speedify.isLoading = true
            publish()
        }
        let selection: EndpointSelection?
        if let selectedEndpoint {
            selection = selectedEndpoint
        } else {
            let endpoint = await resolveEndpoint()
            selectedEndpoint = endpoint.value
            selection = endpoint.value
            if endpoint.value == nil {
                snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: endpoint.errorMessage)
                publish()
                return
            }
        }
        guard let selection else { return }
        snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
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

    private func loadRouterStatus(client: any GLiNetClientProtocol) async -> SourceState<RouterStatus> {
        let started = Date()
        do {
            let state = SourceState(value: try await client.routerStatus())
            await recordUsage(providerID: ProviderIDs.router, operation: .poll, started: started)
            return state
        } catch {
            noteRouterError(error)
            let state = SourceState(value: snapshot.router.value, errorMessage: error.localizedDescription)
            await recordUsage(providerID: ProviderIDs.router, operation: .poll, started: started, error: error.localizedDescription)
            return state
        }
    }

    private func loadVPNStatus(client: any GLiNetClientProtocol) async -> SourceState<VPNStatus> {
        let started = Date()
        do {
            let state = SourceState(value: try await client.vpnStatus())
            await recordUsage(providerID: ProviderIDs.vpn, operation: .poll, started: started)
            return state
        } catch {
            noteRouterError(error)
            let state = SourceState(value: snapshot.vpn.value, errorMessage: error.localizedDescription)
            await recordUsage(providerID: ProviderIDs.vpn, operation: .poll, started: started, error: error.localizedDescription)
            return state
        }
    }

    private func loadReachabilityStatus() async -> SourceState<ReachabilityStatus> {
        let started = Date()
        let status = await reachabilityProbe.probe()
        await recordUsage(providerID: ProviderIDs.reachability, operation: .poll, started: started)
        return SourceState(value: status)
    }

    private func loadLegacyReachabilityStatusIfNeeded() async -> SourceState<ReachabilityStatus>? {
        guard !hasRegisteredProvider(ProviderIDs.reachability) else { return nil }
        return await loadReachabilityStatus()
    }

    private func loadSpeedifyStatus(host: String) async -> SourceState<SpeedifyStatus> {
        let started = Date()
        do {
            let status = try await routerSpeedifyClient.status(host: host)
                .mergingLiveSamples(from: snapshot.speedify.value)
            let state = SourceState(value: status)
            await recordUsage(providerID: ProviderIDs.speedify, operation: .poll, started: started)
            return state
        } catch {
            let state = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
            await recordUsage(providerID: ProviderIDs.speedify, operation: .poll, started: started, error: error.localizedDescription)
            return state
        }
    }

    private func loadLegacySpeedifyStatusIfNeeded(host: String) async -> SourceState<SpeedifyStatus>? {
        guard !hasRegisteredProvider(ProviderIDs.speedify) else { return nil }
        return await loadSpeedifyStatus(host: host)
    }

    private func loadStarlinkStatus() async -> SourceState<StarlinkStatus> {
        let started = Date()
        let status = await starlinkStatusProvider(settings.grpcurlPath)
        if status.isReachable {
            let state = SourceState(value: status)
            await recordUsage(providerID: ProviderIDs.starlink, operation: .poll, started: started)
            return state
        }
        let state = SourceState(value: snapshot.starlink.value, errorMessage: status.state)
        await recordUsage(providerID: ProviderIDs.starlink, operation: .poll, started: started, error: status.state)
        return state
    }

    private func loadLegacyStarlinkStatusIfNeeded() async -> SourceState<StarlinkStatus>? {
        guard !hasRegisteredProvider(ProviderIDs.starlink) else { return nil }
        return await loadStarlinkStatus()
    }

    private func loadEcoFlowStatus(routerHost: String?) async -> SourceState<EcoFlowSnapshot> {
        let started = Date()
        guard settings.ecoflowEnabled else {
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .poll, started: started)
            return SourceState()
        }
        let host = settings.ecoflowHost == "auto" ? routerHost : settings.ecoflowHost
        guard let host, !host.isEmpty else {
            let state = SourceState(value: snapshot.ecoflow.value, errorMessage: "EcoFlow daemon endpoint unresolved.")
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .poll, started: started, error: state.errorMessage)
            return state
        }
        guard let baseURL = URL(string: "http://\(host):\(settings.ecoflowPort)") else {
            let state = SourceState(value: snapshot.ecoflow.value, errorMessage: "EcoFlow daemon endpoint is invalid.")
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .poll, started: started, error: state.errorMessage)
            return state
        }

        let client = ecoFlowClientFactory(baseURL)
        do {
            async let device = try? client.device()
            async let status = client.status()
            async let outputs = try? client.outputs()
            async let stats = try? client.stats()
            let state = SourceState(value: try await EcoFlowSnapshot(
                device: await device,
                status: status,
                outputs: await outputs,
                stats: await stats
            ))
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .poll, started: started)
            return state
        } catch {
            let state = SourceState(value: snapshot.ecoflow.value, errorMessage: error.localizedDescription)
            await recordUsage(providerID: ProviderIDs.ecoflow, operation: .poll, started: started, error: error.localizedDescription)
            return state
        }
    }

    private func loadLegacyEcoFlowStatusIfNeeded(routerHost: String?) async -> SourceState<EcoFlowSnapshot>? {
        guard !hasRegisteredProvider(ProviderIDs.ecoflow) else { return nil }
        return await loadEcoFlowStatus(routerHost: routerHost)
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

    private func hasRegisteredProvider(_ providerID: ProviderID) -> Bool {
        providers.contains { $0.id == providerID }
    }

    private func pollRegisteredProviders(routerHost: String?) async -> [ProviderID: SourceState<ProviderSnapshot>] {
        var states: [ProviderID: SourceState<ProviderSnapshot>] = [:]
        let context = EnvironmentContext(routerHost: routerHost, settings: settings)
        let now = Date()
        for provider in providers {
            if let lastPoll = lastRegisteredProviderPolls[provider.id],
               now.timeIntervalSince(lastPoll) < provider.pollInterval,
               let previous = providerStates[provider.id] {
                states[provider.id] = SourceState(value: previous.value, errorMessage: previous.errorMessage)
                continue
            }
            let started = Date()
            let providerSnapshot = await provider.poll(context: context)
            states[provider.id] = SourceState(value: providerSnapshot, errorMessage: providerSnapshot.error)
            lastRegisteredProviderPolls[provider.id] = Date()
            await recordUsage(providerID: provider.id, operation: .poll, started: started, error: providerSnapshot.error)
        }
        return states
    }

    private func noteRouterError(_ error: Error) {
        guard
            let clientError = error as? JSONRPCClientError,
            let wait = clientError.retryAfterSeconds
        else { return }
        routerBackoffUntil = Date().addingTimeInterval(TimeInterval(wait))
    }

    private func publish() {
        let registeredProviderStates = providerStates
        snapshot.populateProviderSnapshots()
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
}

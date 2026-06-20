import Foundation

public typealias RouterClientFactory = @Sendable (URL, String, @escaping @Sendable () throws -> String?) async -> any GLiNetClientProtocol
public typealias StarlinkStatusProvider = @Sendable (String) async -> StarlinkStatus
public typealias EcoFlowClientFactory = @Sendable (URL) -> any EcoFlowClientProtocol

public actor Engine {
    public nonisolated let snapshots: AsyncStream<StatusSnapshot>

    private let snapshotContinuation: AsyncStream<StatusSnapshot>.Continuation
    private let settingsStore: SettingsStore
    private let credentialStore: CredentialStore
    private let endpointSelector: EndpointSelector
    private let reachabilityProbe: ReachabilityProbeProtocol
    private let routerSpeedifyClient: any RouterSpeedifyClientProtocol
    private let routerClientFactory: RouterClientFactory
    private let resetRouterClients: @Sendable () async -> Void
    private let starlinkStatusProvider: StarlinkStatusProvider
    private let ecoFlowClientFactory: EcoFlowClientFactory

    private var snapshot = StatusSnapshot()
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
        resetRouterClients: (@Sendable () async -> Void)? = nil,
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
        let loadedSettings = settings ?? ((try? settingsStore.load()) ?? AppSettings())
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.endpointSelector = endpointSelector
        self.reachabilityProbe = reachabilityProbe
        self.routerSpeedifyClient = routerSpeedifyClient
        self.settings = loadedSettings
        self.routerPassword = routerPassword ?? ((try? credentialStore.password(account: loadedSettings.username)) ?? RouterDefaults.routerPassword)
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

    public func refresh() async {
        snapshot.router.isLoading = true
        snapshot.vpn.isLoading = true
        snapshot.reachability.isLoading = true
        snapshot.speedify.isLoading = true
        snapshot.starlink.isLoading = true
        snapshot.ecoflow.isLoading = settings.ecoflowEnabled
        publish()

        async let endpointResult = resolveEndpoint()
        async let reachabilityResult = reachabilityProbe.probe()
        async let starlinkResult = loadStarlinkStatus()

        let endpoint = await endpointResult
        selectedEndpoint = endpoint.value
        async let ecoflowResult = loadEcoFlowStatus(routerHost: endpoint.value?.host)

        if let selection = endpoint.value, let url = URL.routerRPC(host: selection.host) {
            async let speedifyResult = loadSpeedifyStatus(host: selection.host)
            if let backoff = routerBackoffUntil, backoff > Date() {
                let message = "Router login paused for \(Self.formatRemaining(until: backoff))."
                snapshot.router = SourceState(value: snapshot.router.value, errorMessage: message)
                snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: message)
                snapshot.reachability = SourceState(value: await reachabilityResult)
                snapshot.speedify = await speedifyResult
                snapshot.starlink = await starlinkResult
                snapshot.ecoflow = await ecoflowResult
                snapshot.lastUpdated = Date()
                publish()
                return
            }

            let client = await routerClientFactory(url, settings.username, { [routerPassword] in routerPassword })
            let router = await loadRouterStatus(client: client)
            snapshot.router = router
            if router.errorMessage?.localizedCaseInsensitiveContains("locked") == true {
                snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: router.errorMessage)
            } else {
                snapshot.vpn = await loadVPNStatus(client: client)
            }
            snapshot.speedify = await speedifyResult
        } else {
            snapshot.router = SourceState(value: snapshot.router.value, errorMessage: endpoint.errorMessage)
            snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: endpoint.errorMessage)
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: endpoint.errorMessage)
        }

        snapshot.reachability = SourceState(value: await reachabilityResult)
        snapshot.starlink = await starlinkResult
        snapshot.ecoflow = await ecoflowResult
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

    public func toggleVPN() async {
        guard
            let selection = selectedEndpoint,
            let url = URL.routerRPC(host: selection.host),
            let status = snapshot.vpn.value
        else { return }
        let client = await routerClientFactory(url, settings.username, { [routerPassword] in routerPassword })
        do {
            try await client.setVPNEnabled(!status.isConnected, protocol: status.vpnProtocol)
            snapshot.vpn = await loadVPNStatus(client: client)
            publish()
        } catch {
            snapshot.vpn.errorMessage = error.localizedDescription
            publish()
        }
    }

    public func toggleSpeedify() async {
        guard let selection = selectedEndpoint, let status = snapshot.speedify.value else { return }
        snapshot.speedify.isLoading = true
        publish()
        do {
            if status.isConnected {
                try await routerSpeedifyClient.disconnect(host: selection.host)
            } else {
                try await routerSpeedifyClient.connect(host: selection.host)
            }
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
        }
        publish()
    }

    public func setSpeedifyBondingMode(_ mode: SpeedifyBondingMode) async {
        guard let selection = selectedEndpoint else { return }
        snapshot.speedify.isLoading = true
        publish()
        do {
            try await routerSpeedifyClient.setBondingMode(mode, host: selection.host)
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
        }
        publish()
    }

    public func setSpeedifyNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String) async {
        guard let selection = selectedEndpoint else { return }
        snapshot.speedify.isLoading = true
        publish()
        do {
            try await routerSpeedifyClient.setNetworkPriority(priority, networkID: networkID, host: selection.host)
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
        }
        publish()
    }

    public func setEcoFlowOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async -> EcoFlowControlResponse? {
        guard settings.ecoflowEnabled else { return nil }
        let host = settings.ecoflowHost == "auto" ? selectedEndpoint?.host : settings.ecoflowHost
        guard let host, !host.isEmpty, let baseURL = URL(string: "http://\(host):\(settings.ecoflowPort)") else {
            snapshot.ecoflow.errorMessage = "EcoFlow daemon endpoint unresolved."
            publish()
            return nil
        }

        let client = ecoFlowClientFactory(baseURL)
        do {
            let response = try await client.setOutput(target, state: state)
            snapshot.ecoflow = await loadEcoFlowStatus(routerHost: selectedEndpoint?.host)
            publish()
            return response
        } catch {
            snapshot.ecoflow = SourceState(value: snapshot.ecoflow.value, errorMessage: error.localizedDescription)
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
        do {
            return SourceState(value: try await client.routerStatus())
        } catch {
            noteRouterError(error)
            return SourceState(value: snapshot.router.value, errorMessage: error.localizedDescription)
        }
    }

    private func loadVPNStatus(client: any GLiNetClientProtocol) async -> SourceState<VPNStatus> {
        do {
            return SourceState(value: try await client.vpnStatus())
        } catch {
            noteRouterError(error)
            return SourceState(value: snapshot.vpn.value, errorMessage: error.localizedDescription)
        }
    }

    private func loadSpeedifyStatus(host: String) async -> SourceState<SpeedifyStatus> {
        do {
            let status = try await routerSpeedifyClient.status(host: host)
                .mergingLiveSamples(from: snapshot.speedify.value)
            return SourceState(value: status)
        } catch {
            return SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
        }
    }

    private func loadStarlinkStatus() async -> SourceState<StarlinkStatus> {
        let status = await starlinkStatusProvider(settings.grpcurlPath)
        if status.isReachable {
            return SourceState(value: status)
        }
        return SourceState(value: snapshot.starlink.value, errorMessage: status.state)
    }

    private func loadEcoFlowStatus(routerHost: String?) async -> SourceState<EcoFlowSnapshot> {
        guard settings.ecoflowEnabled else {
            return SourceState()
        }
        let host = settings.ecoflowHost == "auto" ? routerHost : settings.ecoflowHost
        guard let host, !host.isEmpty else {
            return SourceState(value: snapshot.ecoflow.value, errorMessage: "EcoFlow daemon endpoint unresolved.")
        }
        guard let baseURL = URL(string: "http://\(host):\(settings.ecoflowPort)") else {
            return SourceState(value: snapshot.ecoflow.value, errorMessage: "EcoFlow daemon endpoint is invalid.")
        }

        let client = ecoFlowClientFactory(baseURL)
        do {
            async let device = try? client.device()
            async let status = client.status()
            async let outputs = try? client.outputs()
            async let stats = try? client.stats()
            return SourceState(value: try await EcoFlowSnapshot(
                device: await device,
                status: status,
                outputs: await outputs,
                stats: await stats
            ))
        } catch {
            return SourceState(value: snapshot.ecoflow.value, errorMessage: error.localizedDescription)
        }
    }

    private func noteRouterError(_ error: Error) {
        guard
            let clientError = error as? JSONRPCClientError,
            let wait = clientError.retryAfterSeconds
        else { return }
        routerBackoffUntil = Date().addingTimeInterval(TimeInterval(wait))
    }

    private func publish() {
        snapshot.populateProviderSnapshots()
        snapshotContinuation.yield(snapshot)
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

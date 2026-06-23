import Foundation

public struct BuiltInProviderFactory: Sendable {
    private let routerClientFactory: RouterClientFactory
    private let reachabilityProbe: ReachabilityProbeProtocol
    private let routerSpeedifyClient: any RouterSpeedifyClientProtocol
    private let starlinkStatusProvider: StarlinkStatusProvider
    private let ecoFlowClientFactory: EcoFlowClientFactory
    private let activeMeasurementProcessRunner: (any ProcessRunner)?

    public init(
        routerClientFactory: @escaping RouterClientFactory,
        reachabilityProbe: ReachabilityProbeProtocol = ReachabilityProbe(),
        routerSpeedifyClient: any RouterSpeedifyClientProtocol = RouterSpeedifyClient(),
        starlinkStatusProvider: @escaping StarlinkStatusProvider = { path in
            await StarlinkClient(path: path).status()
        },
        ecoFlowClientFactory: @escaping EcoFlowClientFactory = { baseURL in
            EcoFlowHTTPClient(baseURL: baseURL)
        },
        activeMeasurementProcessRunner: (any ProcessRunner)? = nil
    ) {
        self.routerClientFactory = routerClientFactory
        self.reachabilityProbe = reachabilityProbe
        self.routerSpeedifyClient = routerSpeedifyClient
        self.starlinkStatusProvider = starlinkStatusProvider
        self.ecoFlowClientFactory = ecoFlowClientFactory
        self.activeMeasurementProcessRunner = activeMeasurementProcessRunner
    }

    public func providers(settings: AppSettings) -> [any Provider] {
        var providers: [any Provider] = [
            GLiNetRouterProvider(clientFactory: routerClientFactory),
            GLiNetVPNProvider(clientFactory: routerClientFactory),
            ReachabilityProvider(probe: reachabilityProbe),
            SpeedifyProvider(client: routerSpeedifyClient),
            StarlinkProvider(statusProvider: starlinkStatusProvider)
        ]
        if settings.ecoflowEnabled {
            providers.append(EcoFlowProvider(clientFactory: ecoFlowClientFactory))
        }
        if let activeMeasurementProcessRunner {
            providers.append(PingProvider(processRunner: activeMeasurementProcessRunner))
            providers.append(Iperf3Provider(processRunner: activeMeasurementProcessRunner))
        }
        return providers
    }

    public static let providerIDs: Set<ProviderID> = [
        ProviderIDs.router,
        ProviderIDs.vpn,
        ProviderIDs.reachability,
        ProviderIDs.speedify,
        ProviderIDs.starlink,
        ProviderIDs.ecoflow,
        ProviderIDs.ping,
        ProviderIDs.iperf3
    ]

    /// The built-ins as single-instance integrations (registry-driven assembly). Ping/iperf3
    /// exist only when a process runner is available (matching providers(settings:)).
    public func integrations() -> [any Integration] {
        var result: [any Integration] = [
            GLiNetIntegration(routerClientFactory: routerClientFactory),
            ReachabilityIntegration(probe: reachabilityProbe),
            SpeedifyIntegration(client: routerSpeedifyClient),
            StarlinkIntegration(statusProvider: starlinkStatusProvider),
            EcoFlowIntegration(clientFactory: ecoFlowClientFactory)
        ]
        if let activeMeasurementProcessRunner {
            result.append(PingIntegration(processRunner: activeMeasurementProcessRunner))
            result.append(Iperf3Integration(processRunner: activeMeasurementProcessRunner))
        }
        return result
    }

    /// Default instance seed reproducing providers(settings:) exactly: all built-ins enabled
    /// in canonical order, EcoFlow gated by settings, ping/iperf3 only when a runner exists.
    public func defaultInstanceSeed(settings: AppSettings) -> [IntegrationInstanceRecord] {
        BuiltInIntegrationSeed.records(
            ecoflowEnabled: settings.ecoflowEnabled,
            includeActiveMeasurement: activeMeasurementProcessRunner != nil
        )
    }
}

public struct GLiNetRouterProvider: Provider {
    public let id: ProviderID = ProviderIDs.router
    public let displayName = "Router"
    public let typeID: ProviderTypeID = ProviderIDs.router
    public let integrationID = IntegrationIDs.glinet
    public let integrationInstanceID = IntegrationInstanceIDs.glinet
    public let instanceID = ProviderInstanceIDs.router
    public let pollInterval: TimeInterval

    private let clientFactory: RouterClientFactory
    private let passwordProvider: @Sendable () throws -> String?

    public init(
        pollInterval: TimeInterval = 5,
        clientFactory: RouterClientFactory? = nil,
        passwordProvider: @escaping @Sendable () throws -> String? = { nil }
    ) {
        self.pollInterval = pollInterval
        self.clientFactory = Self.makeClientFactory(clientFactory)
        self.passwordProvider = passwordProvider
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        do {
            let client = try await GLiNetProviderClient.client(
                context: context,
                clientFactory: clientFactory,
                passwordProvider: passwordProvider
            )
            var status = try await client.routerStatus()
            // hostname/model are not in `system get_status`; fold in `system board`
            // (best-effort — a board failure must not fail the router poll).
            if let board = try? await client.boardInfo() {
                status.hostname = status.hostname ?? board.hostname
                status.model = status.model ?? board.model
            }
            return ProviderSnapshot.router(status)
        } catch {
            return ProviderSnapshot(
                health: .unknown,
                error: error.localizedDescription,
                retryAfterSeconds: (error as? JSONRPCClientError)?.retryAfterSeconds
            )
        }
    }
}

public struct GLiNetVPNProvider: Provider {
    public let id: ProviderID = ProviderIDs.vpn
    public let displayName = "VPN"
    public let typeID: ProviderTypeID = ProviderIDs.vpn
    public let integrationID = IntegrationIDs.glinet
    public let integrationInstanceID = IntegrationInstanceIDs.glinet
    public let instanceID = ProviderInstanceIDs.vpn
    public let pollInterval: TimeInterval
    public let commands = ProviderCommandCatalog.commands(for: ProviderIDs.vpn)

    private let clientFactory: RouterClientFactory
    private let passwordProvider: @Sendable () throws -> String?

    public init(
        pollInterval: TimeInterval = 5,
        clientFactory: RouterClientFactory? = nil,
        passwordProvider: @escaping @Sendable () throws -> String? = { nil }
    ) {
        self.pollInterval = pollInterval
        self.clientFactory = Self.makeClientFactory(clientFactory)
        self.passwordProvider = passwordProvider
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        do {
            let client = try await GLiNetProviderClient.client(
                context: context,
                clientFactory: clientFactory,
                passwordProvider: passwordProvider
            )
            return ProviderSnapshot.vpn(try await client.vpnStatus())
        } catch {
            return ProviderSnapshot(
                health: .unknown,
                error: error.localizedDescription,
                retryAfterSeconds: (error as? JSONRPCClientError)?.retryAfterSeconds
            )
        }
    }

    public func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        guard commandID == ProviderCommandIDs.vpnToggle else {
            throw JSONRPCClientError.commandFailed("Unsupported VPN command \(commandID).")
        }
        let client = try await GLiNetProviderClient.client(
            context: context,
            clientFactory: clientFactory,
            passwordProvider: passwordProvider
        )
        let status = try await client.vpnStatus()
        try await client.setVPNEnabled(!status.isConnected, protocol: status.vpnProtocol)
    }
}

public struct ReachabilityProvider: Provider {
    public let id: ProviderID = ProviderIDs.reachability
    public let displayName = "Internet"
    public let typeID: ProviderTypeID = ProviderIDs.reachability
    public let integrationID = IntegrationIDs.reachability
    public let integrationInstanceID = IntegrationInstanceIDs.reachability
    public let instanceID = ProviderInstanceIDs.reachability
    public let pollInterval: TimeInterval

    private let probe: ReachabilityProbeProtocol

    public init(probe: ReachabilityProbeProtocol = ReachabilityProbe(), pollInterval: TimeInterval = 5) {
        self.probe = probe
        self.pollInterval = pollInterval
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        ProviderSnapshot.reachability(await probe.probe())
    }
}

public struct StarlinkProvider: Provider {
    public let id: ProviderID = ProviderIDs.starlink
    public let displayName = "Starlink"
    public let typeID: ProviderTypeID = ProviderIDs.starlink
    public let integrationID = IntegrationIDs.starlink
    public let integrationInstanceID = IntegrationInstanceIDs.starlink
    public let instanceID = ProviderInstanceIDs.starlink
    public let pollInterval: TimeInterval

    private let statusProvider: StarlinkStatusProvider

    public init(
        pollInterval: TimeInterval = 5,
        statusProvider: @escaping StarlinkStatusProvider = { path in
            await StarlinkClient(path: path).status()
        }
    ) {
        self.pollInterval = pollInterval
        self.statusProvider = statusProvider
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        let status = await statusProvider(context.settings.grpcurlPath)
        var snapshot = ProviderSnapshot.starlink(status)
        if !status.isReachable {
            snapshot.error = status.state
        }
        return snapshot
    }
}

public struct SpeedifyProvider: Provider {
    public let id: ProviderID = ProviderIDs.speedify
    public let displayName = "Speedify"
    public let typeID: ProviderTypeID = ProviderIDs.speedify
    public let integrationID = IntegrationIDs.speedify
    public let integrationInstanceID = IntegrationInstanceIDs.speedify
    public let instanceID = ProviderInstanceIDs.speedify
    public let pollInterval: TimeInterval
    public let commands = ProviderCommandCatalog.commands(for: ProviderIDs.speedify)

    private let client: RouterSpeedifyClientProtocol

    public init(client: RouterSpeedifyClientProtocol = RouterSpeedifyClient(), pollInterval: TimeInterval = 5) {
        self.client = client
        self.pollInterval = pollInterval
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        guard let host = context.routerHost, !host.isEmpty else {
            return ProviderSnapshot(health: .unknown, error: "Speedify endpoint unavailable.")
        }
        do {
            return ProviderSnapshot.speedify(try await client.status(host: host))
        } catch {
            return ProviderSnapshot(health: .unknown, error: error.localizedDescription)
        }
    }

    public func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        guard let host = context.routerHost, !host.isEmpty else {
            throw JSONRPCClientError.commandFailed("Speedify endpoint unavailable.")
        }
        switch commandID {
        case ProviderCommandIDs.speedifyToggle:
            let status = try await client.status(host: host)
            if status.isConnected {
                try await client.disconnect(host: host)
            } else {
                try await client.connect(host: host)
            }
        case ProviderCommandIDs.speedifySetBondingMode:
            let mode = try Self.requireString("mode", in: arguments)
            try await client.setBondingMode(SpeedifyBondingMode(code: mode), host: host)
        case ProviderCommandIDs.speedifySetNetworkPriority:
            let priority = try Self.requireInt("priority", in: arguments)
            let networkID = try Self.requireString("networkID", in: arguments)
            try await client.setNetworkPriority(SpeedifyNetworkPriority(value: priority), networkID: networkID, host: host)
        default:
            throw JSONRPCClientError.commandFailed("Unsupported Speedify command \(commandID).")
        }
    }

    private static func requireString(_ key: String, in arguments: CommandArguments) throws -> String {
        guard let value = arguments.values[key]?.stringValue, !value.isEmpty else {
            throw JSONRPCClientError.commandFailed("Provider command argument \(key) must be a non-empty string.")
        }
        return value
    }

    private static func requireInt(_ key: String, in arguments: CommandArguments) throws -> Int {
        guard let value = arguments.values[key]?.intValue else {
            throw JSONRPCClientError.commandFailed("Provider command argument \(key) must be a number.")
        }
        return value
    }
}

public protocol EcoFlowOutputControllingProvider: Provider {
    func setOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState, context: EnvironmentContext) async throws -> EcoFlowControlResponse
}

public struct EcoFlowProvider: EcoFlowOutputControllingProvider {
    public let id: ProviderID = ProviderIDs.ecoflow
    public let displayName = "EcoFlow"
    public let typeID: ProviderTypeID = ProviderIDs.ecoflow
    public let integrationID = IntegrationIDs.ecoflow
    public let integrationInstanceID = IntegrationInstanceIDs.ecoflow
    public let instanceID = ProviderInstanceIDs.ecoflow
    public let pollInterval: TimeInterval
    public let commands = ProviderCommandCatalog.commands(for: ProviderIDs.ecoflow)

    private let clientFactory: EcoFlowClientFactory

    public init(
        pollInterval: TimeInterval = 5,
        clientFactory: @escaping EcoFlowClientFactory = { baseURL in EcoFlowHTTPClient(baseURL: baseURL) }
    ) {
        self.pollInterval = pollInterval
        self.clientFactory = clientFactory
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        guard context.settings.ecoflowEnabled else {
            return ProviderSnapshot()
        }
        guard let baseURL = Self.baseURL(context: context) else {
            return ProviderSnapshot(health: .unknown, error: Self.unresolvedEndpointMessage(context: context))
        }

        let client = clientFactory(baseURL)
        do {
            async let device = try? client.device()
            async let status = client.status()
            async let outputs = try? client.outputs()
            async let stats = try? client.stats()
            return try await ProviderSnapshot.ecoFlow(
                EcoFlowSnapshot(
                    device: await device,
                    status: status,
                    outputs: await outputs,
                    stats: await stats
                )
            )
        } catch {
            return ProviderSnapshot(health: .unknown, error: error.localizedDescription)
        }
    }

    public func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        guard commandID == ProviderCommandIDs.ecoFlowSetOutput else {
            throw JSONRPCClientError.commandFailed("Unsupported EcoFlow command \(commandID).")
        }
        let target = try Self.requireOutputTarget(in: arguments)
        let state = try Self.requireOutputState(in: arguments)
        _ = try await setOutput(target, state: state, context: context)
    }

    public func setOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState, context: EnvironmentContext) async throws -> EcoFlowControlResponse {
        guard context.settings.ecoflowEnabled else {
            throw JSONRPCClientError.commandFailed("EcoFlow is disabled.")
        }
        guard let baseURL = Self.baseURL(context: context) else {
            throw JSONRPCClientError.commandFailed(Self.unresolvedEndpointMessage(context: context))
        }
        return try await clientFactory(baseURL).setOutput(target, state: state)
    }

    private static func baseURL(context: EnvironmentContext) -> URL? {
        let host = context.settings.ecoflowHost == "auto" ? context.routerHost : context.settings.ecoflowHost
        guard let host, !host.isEmpty else { return nil }
        return URL(string: "http://\(host):\(context.settings.ecoflowPort)")
    }

    private static func unresolvedEndpointMessage(context: EnvironmentContext) -> String {
        let host = context.settings.ecoflowHost == "auto" ? context.routerHost : context.settings.ecoflowHost
        if host == nil || host?.isEmpty == true {
            return "EcoFlow daemon endpoint unresolved."
        }
        return "EcoFlow daemon endpoint is invalid."
    }

    private static func requireOutputTarget(in arguments: CommandArguments) throws -> EcoFlowOutputTarget {
        let rawValue = try requireString("target", in: arguments)
        guard let target = EcoFlowOutputTarget(rawValue: rawValue) else {
            throw JSONRPCClientError.commandFailed("Provider command argument target is not a supported EcoFlow output.")
        }
        return target
    }

    private static func requireOutputState(in arguments: CommandArguments) throws -> EcoFlowOutputState {
        let rawValue = try requireString("state", in: arguments)
        guard let state = EcoFlowOutputState(rawValue: rawValue), state != .unknown else {
            throw JSONRPCClientError.commandFailed("Provider command argument state must be on or off.")
        }
        return state
    }

    private static func requireString(_ key: String, in arguments: CommandArguments) throws -> String {
        guard let value = arguments.values[key]?.stringValue, !value.isEmpty else {
            throw JSONRPCClientError.commandFailed("Provider command argument \(key) must be a non-empty string.")
        }
        return value
    }
}

private enum GLiNetProviderClient {
    static func client(
        context: EnvironmentContext,
        clientFactory: RouterClientFactory,
        passwordProvider: @escaping @Sendable () throws -> String?
    ) async throws -> any GLiNetClientProtocol {
        guard let host = context.routerHost, !host.isEmpty, let endpoint = URL.routerRPC(host: host) else {
            throw JSONRPCClientError.commandFailed("Router endpoint unavailable.")
        }
        let contextPassword = context.routerPassword
        return await clientFactory(endpoint, context.settings.username) {
            if let password = try passwordProvider(), !password.isEmpty {
                return password
            }
            return contextPassword
        }
    }
}

private extension Provider {
    static func makeClientFactory(_ clientFactory: RouterClientFactory?) -> RouterClientFactory {
        if let clientFactory {
            return clientFactory
        }
        let pool = GLiNetClientPool()
        return { endpoint, username, passwordProvider in
            await pool.client(endpoint: endpoint, username: username, passwordProvider: passwordProvider)
        }
    }
}

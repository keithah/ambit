import Foundation

public struct ReachabilityProvider: Provider {
    public let id: ProviderID = ProviderIDs.reachability
    public let displayName = "Internet"
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

public struct EcoFlowProvider: Provider {
    public let id: ProviderID = ProviderIDs.ecoflow
    public let displayName = "EcoFlow"
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
        guard context.settings.ecoflowEnabled else {
            throw JSONRPCClientError.commandFailed("EcoFlow is disabled.")
        }
        guard let baseURL = Self.baseURL(context: context) else {
            throw JSONRPCClientError.commandFailed(Self.unresolvedEndpointMessage(context: context))
        }

        let target = try Self.requireOutputTarget(in: arguments)
        let state = try Self.requireOutputState(in: arguments)
        _ = try await clientFactory(baseURL).setOutput(target, state: state)
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

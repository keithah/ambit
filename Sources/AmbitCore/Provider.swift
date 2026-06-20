import Foundation

public typealias ProviderID = String

public enum ProviderIDs {
    public static let router: ProviderID = "router"
    public static let vpn: ProviderID = "vpn"
    public static let reachability: ProviderID = "reachability"
    public static let speedify: ProviderID = "speedify"
    public static let starlink: ProviderID = "starlink"
    public static let ecoflow: ProviderID = "ecoflow"
    public static let ping: ProviderID = "ping"
    public static let iperf3: ProviderID = "iperf3"
}

public protocol Provider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var pollInterval: TimeInterval { get }
    var commands: [CommandDescriptor] { get }
    func poll(context: EnvironmentContext) async -> ProviderSnapshot
    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws
}

public extension Provider {
    var commands: [CommandDescriptor] { [] }

    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        throw JSONRPCClientError.commandFailed("Provider command \(commandID) is not supported.")
    }
}

public struct EnvironmentContext: Sendable {
    public var routerHost: String?
    public var settings: AppSettings

    public init(routerHost: String?, settings: AppSettings) {
        self.routerHost = routerHost
        self.settings = settings
    }
}

public struct ProviderSnapshot: Equatable, Sendable {
    public var health: Health
    public var metrics: [Metric]
    public var detail: ProviderDetail?
    public var error: String?

    public init(health: Health = .unknown, metrics: [Metric] = [], detail: ProviderDetail? = nil, error: String? = nil) {
        self.health = health
        self.metrics = metrics
        self.detail = detail
        self.error = error
    }
}

public enum ProviderDetail: Equatable, Sendable {
    case router(RouterStatus)
    case vpn(VPNStatus)
    case reachability(ReachabilityStatus)
    case speedify(SpeedifyStatus)
    case starlink(StarlinkStatus)
    case ecoflow(EcoFlowSnapshot)
    case ping(PingSnapshot)
    case iperf3(Iperf3Snapshot)
}

public enum Health: Equatable, Sendable {
    case ok
    case degraded
    case down
    case unknown
}

public struct Metric: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var value: MetricValue

    public init(id: String, label: String, value: MetricValue) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public enum MetricValue: Equatable, Sendable {
    case throughput(bitsPerSecond: Int)
    case latency(ms: Double)
    case percent(Double)
    case level(Double)
    case bool(Bool)
    case text(String)
}

public struct CommandDescriptor: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var parameters: [CommandParameter]
    public var requiresConfirmation: Bool

    public init(id: String, label: String, parameters: [CommandParameter] = [], requiresConfirmation: Bool = false) {
        self.id = id
        self.label = label
        self.parameters = parameters
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct CommandParameter: Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var kind: CommandParameterKind

    public init(id: String, label: String, kind: CommandParameterKind) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public enum CommandParameterKind: Equatable, Sendable {
    case text
    case bool
    case option([String])
    case number
}

public struct CommandArguments: Equatable, Sendable {
    public var values: [String: JSONValue]

    public init(values: [String: JSONValue] = [:]) {
        self.values = values
    }
}

public struct EngineSnapshot: Equatable, Sendable {
    public var providers: [ProviderID: SourceState<ProviderSnapshot>]
    public var lastUpdated: Date?

    public init(providers: [ProviderID: SourceState<ProviderSnapshot>] = [:], lastUpdated: Date? = nil) {
        self.providers = providers
        self.lastUpdated = lastUpdated
    }
}

public extension SourceState where Value == ProviderSnapshot {
    init<DetailValue>(
        providerValue: DetailValue?,
        errorMessage: String?,
        detail: (DetailValue) -> ProviderDetail,
        snapshot: (DetailValue) -> ProviderSnapshot
    ) {
        if let providerValue {
            var providerSnapshot = snapshot(providerValue)
            providerSnapshot.detail = detail(providerValue)
            providerSnapshot.error = errorMessage
            self.init(value: providerSnapshot, errorMessage: errorMessage)
        } else {
            self.init(value: nil, errorMessage: errorMessage)
        }
    }
}

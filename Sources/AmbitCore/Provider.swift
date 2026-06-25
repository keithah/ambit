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
    public static let systemOverview: ProviderID = "system.overview"
    public static let systemStorage: ProviderID = "system.storage"
    public static let systemProcesses: ProviderID = "system.processes"
}

public enum ProviderCommandIDs {
    public static let vpnToggle = "vpn.toggle"
    public static let speedifyToggle = "speedify.toggle"
    public static let speedifySetBondingMode = "speedify.setBondingMode"
    public static let speedifySetNetworkPriority = "speedify.setNetworkPriority"
    public static let ecoFlowSetOutput = "ecoflow.setOutput"
    public static let iperf3Run = "iperf3.run"
}

public enum ProviderCommandCatalog {
    public static func commands(for providerID: ProviderID) -> [CommandDescriptor] {
        switch providerID {
        case ProviderIDs.vpn:
            return [
                CommandDescriptor(id: ProviderCommandIDs.vpnToggle, label: "Toggle VPN")
            ]
        case ProviderIDs.speedify:
            return [
                CommandDescriptor(id: ProviderCommandIDs.speedifyToggle, label: "Toggle Speedify"),
                CommandDescriptor(
                    id: ProviderCommandIDs.speedifySetBondingMode,
                    label: "Set Bonding Mode",
                    parameters: [
                        CommandParameter(id: "mode", label: "Mode", kind: .option(["SP", "RD", "STR"]))
                    ]
                ),
                CommandDescriptor(
                    id: ProviderCommandIDs.speedifySetNetworkPriority,
                    label: "Set Network Priority",
                    parameters: [
                        CommandParameter(id: "priority", label: "Priority", kind: .number),
                        CommandParameter(id: "networkID", label: "Network ID", kind: .text)
                    ]
                )
            ]
        case ProviderIDs.ecoflow:
            return [
                CommandDescriptor(
                    id: ProviderCommandIDs.ecoFlowSetOutput,
                    label: "Set Output",
                    parameters: [
                        CommandParameter(id: "target", label: "Output", kind: .option(["ac", "dc", "usb"])),
                        CommandParameter(id: "state", label: "State", kind: .option(["on", "off"]))
                    ]
                )
            ]
        case ProviderIDs.iperf3:
            return [
                CommandDescriptor(
                    id: ProviderCommandIDs.iperf3Run,
                    label: "Run iperf3",
                    parameters: [CommandParameter(id: "host", label: "Host", kind: .text)]
                )
            ]
        default:
            return []
        }
    }
}

public protocol Provider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var pollInterval: TimeInterval { get }
    var layout: ProviderManifest.Layout? { get }
    var commands: [CommandDescriptor] { get }

    /// Identity hierarchy (`integration-model.md`). Defaults keep every existing/manifest
    /// provider as a single-provider integration whose instance id is its bare `id`; the
    /// built-ins override these to express grouping (router + vpn => integration "glinet").
    var typeID: ProviderTypeID { get }
    var integrationID: IntegrationID { get }
    var integrationInstanceID: IntegrationInstanceID { get }
    var instanceID: ProviderInstanceID { get }

    /// STATIC entity descriptors for this instance (entity-model.md §5). Declared as a
    /// requirement (not just an extension) so author overrides dispatch through the witness
    /// table when held as `any Provider`. Default derives from commands + health.
    func entityDescriptors() -> [EntityDescriptor]

    func poll(context: EnvironmentContext) async -> ProviderSnapshot
    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws
}

public extension Provider {
    var layout: ProviderManifest.Layout? { nil }
    var commands: [CommandDescriptor] { [] }

    var typeID: ProviderTypeID { id }
    var integrationID: IntegrationID { IntegrationID(rawValue: id) }
    var integrationInstanceID: IntegrationInstanceID { IntegrationInstanceID(rawValue: id) }
    var instanceID: ProviderInstanceID { ProviderInstanceID(rawValue: id) }

    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        throw JSONRPCClientError.commandFailed("Provider command \(commandID) is not supported.")
    }
}

public struct EnvironmentContext: Sendable {
    public var routerHost: String?
    public var settings: AppSettings
    public var routerPassword: String?

    public init(routerHost: String?, settings: AppSettings, routerPassword: String? = nil) {
        self.routerHost = routerHost
        self.settings = settings
        self.routerPassword = routerPassword
    }
}

public struct ProviderSnapshot: Equatable, Sendable {
    public var health: Health
    public var metrics: [Metric]
    public var detail: ProviderDetail?
    public var error: String?
    public var retryAfterSeconds: Int?

    public init(
        health: Health = .unknown,
        metrics: [Metric] = [],
        detail: ProviderDetail? = nil,
        error: String? = nil,
        retryAfterSeconds: Int? = nil
    ) {
        self.health = health
        self.metrics = metrics
        self.detail = detail
        self.error = error
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public extension ProviderSnapshot {
    func metric(_ id: String) -> Metric? {
        metrics.first { $0.id == id }
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

    /// Optional authoring classification (entity-model.md §6). All default nil so existing
    /// metrics are unchanged; the entity projection and metric grouping read these instead
    /// of inferring from `value` or matching on `id`.
    public var deviceClass: DeviceClass?
    public var category: EntityCategory?
    public var capability: ProviderCapability?

    public init(
        id: String,
        label: String,
        value: MetricValue,
        deviceClass: DeviceClass? = nil,
        category: EntityCategory? = nil,
        capability: ProviderCapability? = nil
    ) {
        self.id = id
        self.label = label
        self.value = value
        self.deviceClass = deviceClass
        self.category = category
        self.capability = capability
    }
}

public enum MetricValue: Equatable, Sendable {
    case throughput(bitsPerSecond: Int)
    case latency(ms: Double)
    case percent(Double)
    case level(Double)
    case bool(Bool)
    case text(String)
    case table(TableValue)
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

public struct CommandPaletteItem: Equatable, Identifiable, Sendable {
    public var providerID: ProviderID
    public var providerName: String
    public var command: CommandDescriptor

    public var id: String {
        "\(providerID).\(command.id)"
    }

    public init(providerID: ProviderID, providerName: String, command: CommandDescriptor) {
        self.providerID = providerID
        self.providerName = providerName
        self.command = command
    }

    public func matches(_ query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return true }
        let searchableText = ([
            providerID,
            providerName,
            command.id,
            command.label
        ] + command.parameters.flatMap { [$0.id, $0.label] })
            .joined(separator: " ")
            .lowercased()
        return searchableText.contains(normalizedQuery)
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
    public var providers: [ProviderInstanceID: SourceState<ProviderSnapshot>]
    public var lastUpdated: Date?

    public init(providers: [ProviderInstanceID: SourceState<ProviderSnapshot>] = [:], lastUpdated: Date? = nil) {
        self.providers = providers
        self.lastUpdated = lastUpdated
    }
}

public extension SourceState where Value == ProviderSnapshot {
    init<DetailValue>(
        providerValue: DetailValue?,
        isLoading: Bool = false,
        errorMessage: String?,
        detail: (DetailValue) -> ProviderDetail,
        snapshot: (DetailValue) -> ProviderSnapshot
    ) {
        if let providerValue {
            var providerSnapshot = snapshot(providerValue)
            providerSnapshot.detail = detail(providerValue)
            providerSnapshot.error = errorMessage
            self.init(value: providerSnapshot, isLoading: isLoading, errorMessage: errorMessage)
        } else {
            self.init(value: nil, isLoading: isLoading, errorMessage: errorMessage)
        }
    }
}

public extension SourceState {
    var isEmpty: Bool {
        value == nil && !isLoading && errorMessage == nil
    }
}

import Foundation

public enum ConfigFieldKind: String, Equatable, Sendable, Codable {
    case text
    case number
    case toggle
    case select
}

public struct IntegrationConfigField: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var kind: ConfigFieldKind
    public var options: [EntityOption]?
    public var range: ValueRange?
    public var defaultValue: JSONValue?
    public var required: Bool

    public init(
        id: String,
        title: String,
        kind: ConfigFieldKind,
        options: [EntityOption]? = nil,
        range: ValueRange? = nil,
        defaultValue: JSONValue? = nil,
        required: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.options = options
        self.range = range
        self.defaultValue = defaultValue
        self.required = required
    }
}

public extension IntegrationConfigField {
    static func monitoringRole(id: String = "monitoringRole", title: String = "Network Role") -> IntegrationConfigField {
        IntegrationConfigField(
            id: id,
            title: title,
            kind: .select,
            options: [
                EntityOption(value: "auto", label: "Auto", description: "Infer the role from the target address or provider metadata."),
                EntityOption(value: MonitoringRole.localGateway.rawValue, label: "Local Gateway", description: "The local gateway or first-hop router."),
                EntityOption(value: MonitoringRole.accessNetwork.rawValue, label: "Access Network", description: "The access network between this device and the wider internet."),
                EntityOption(value: MonitoringRole.upstreamInternet.rawValue, label: "Upstream Internet", description: "A public internet dependency used to distinguish upstream reachability."),
                EntityOption(value: MonitoringRole.remoteService.rawValue, label: "Remote Service", description: "A remote service or endpoint outside the local path."),
                EntityOption(value: MonitoringRole.endpoint.rawValue, label: "Endpoint", description: "A monitored endpoint whose role is supplied by the provider.")
            ],
            defaultValue: .string("auto")
        )
    }
}

public struct IntegrationConfigSchema: Equatable, Sendable, Codable {
    public var fields: [IntegrationConfigField]

    public init(fields: [IntegrationConfigField]) {
        self.fields = fields
    }
}

public struct IntegrationPreset: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var systemImage: String?
    public var values: [String: JSONValue]

    public init(
        id: String,
        title: String,
        systemImage: String? = nil,
        values: [String: JSONValue]
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.values = values
    }
}

public struct IntegrationInstanceDraft: Equatable, Sendable {
    public var integrationID: IntegrationID
    public var replacing: IntegrationInstanceID?
    public var values: [String: JSONValue]

    public init(
        integrationID: IntegrationID,
        replacing: IntegrationInstanceID? = nil,
        values: [String: JSONValue] = [:]
    ) {
        self.integrationID = integrationID
        self.replacing = replacing
        self.values = values
    }
}

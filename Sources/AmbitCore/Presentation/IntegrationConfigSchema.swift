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

public struct IntegrationConfigSchema: Equatable, Sendable, Codable {
    public var fields: [IntegrationConfigField]

    public init(fields: [IntegrationConfigField]) {
        self.fields = fields
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

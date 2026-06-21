import Foundation

public struct ProviderManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: ProviderID
    public var displayName: String
    public var pollInterval: TimeInterval
    public var credentials: [Credential]
    public var layout: Layout?
    public var endpoint: Endpoint
    public var metrics: [MetricMapping]
    public var alerts: [Alert]
    public var commands: [Command]

    public init(
        schemaVersion: Int,
        id: ProviderID,
        displayName: String,
        pollInterval: TimeInterval,
        credentials: [Credential] = [],
        layout: Layout? = nil,
        endpoint: Endpoint,
        metrics: [MetricMapping],
        alerts: [Alert] = [],
        commands: [Command] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.pollInterval = pollInterval
        self.credentials = credentials
        self.layout = layout
        self.endpoint = endpoint
        self.metrics = metrics
        self.alerts = alerts
        self.commands = commands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.id = try container.decode(ProviderID.self, forKey: .id)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        self.pollInterval = try container.decode(TimeInterval.self, forKey: .pollInterval)
        self.credentials = try container.decodeIfPresent([Credential].self, forKey: .credentials) ?? []
        self.layout = try container.decodeIfPresent(Layout.self, forKey: .layout)
        self.endpoint = try container.decode(Endpoint.self, forKey: .endpoint)
        self.metrics = try container.decode([MetricMapping].self, forKey: .metrics)
        self.alerts = try container.decodeIfPresent([Alert].self, forKey: .alerts) ?? []
        self.commands = try container.decodeIfPresent([Command].self, forKey: .commands) ?? []
    }

    public static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> ProviderManifest {
        let manifest = try decoder.decode(ProviderManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard schemaVersion == 1 else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyID("provider")
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyDisplayName
        }
        guard pollInterval > 0 else {
            throw ValidationError.invalidPollInterval
        }
        guard Self.isValidHTTPURL(endpoint.url) else {
            throw ValidationError.invalidEndpointURL(endpoint.url)
        }
        let metricIDs = Set(metrics.map(\.id))
        if let primaryMetric = layout?.primaryMetric, !metricIDs.contains(primaryMetric) {
            throw ValidationError.invalidLayoutMetricID(primaryMetric)
        }
        try Self.validateUnique(credentials.map(\.id), duplicate: ValidationError.duplicateCredentialID)
        try Self.validateUnique(metrics.map(\.id), duplicate: ValidationError.duplicateMetricID)
        try Self.validateUnique(alerts.map(\.id), duplicate: ValidationError.duplicateAlertID)
        try Self.validateUnique(commands.map(\.id), duplicate: ValidationError.duplicateCommandID)
        try validateCredentialReferences()
        for credential in credentials {
            guard !credential.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyLabel(credential.id)
            }
        }
        for metric in metrics {
            guard !metric.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyLabel(metric.id)
            }
            guard !metric.value.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyMetricPath(metric.id)
            }
        }
        for command in commands {
            guard !command.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.emptyLabel(command.id)
            }
            if let endpoint = command.endpoint, !Self.isValidHTTPURL(endpoint.url) {
                throw ValidationError.invalidCommandEndpointURL(command.id, endpoint.url)
            }
            try Self.validateUnique(command.parameters.map(\.id), duplicate: { ValidationError.duplicateParameterID(command.id, $0) })
            for parameter in command.parameters {
                guard !parameter.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ValidationError.emptyLabel(parameter.id)
                }
            }
        }
        for alert in alerts where !metricIDs.contains(alert.metricID) {
            throw ValidationError.invalidAlertMetricID(alert.id, alert.metricID)
        }
    }

    private func validateCredentialReferences() throws {
        let declared = Set(credentials.map(\.id))
        for reference in credentialReferences() where !declared.contains(reference) {
            throw ValidationError.undeclaredCredentialReference(reference)
        }
    }

    private func credentialReferences() -> Set<String> {
        var references = Set<String>()
        let templates = [endpoint.url, endpoint.body].compactMap { $0 }
            + Array(endpoint.headers.values)
            + commands.flatMap { command -> [String] in
                guard let endpoint = command.endpoint else { return [] }
                return [endpoint.url, endpoint.body].compactMap { $0 } + Array(endpoint.headers.values)
            }
        for template in templates {
            references.formUnion(Self.credentialReferences(in: template))
        }
        return references
    }

    private static func credentialReferences(in template: String) -> [String] {
        let prefix = "{credential."
        var references: [String] = []
        var searchStart = template.startIndex
        while let prefixRange = template.range(of: prefix, range: searchStart..<template.endIndex) {
            let idStart = prefixRange.upperBound
            guard let end = template[idStart...].firstIndex(of: "}") else { break }
            let id = String(template[idStart..<end])
            if !id.isEmpty {
                references.append(id)
            }
            searchStart = template.index(after: end)
        }
        return references
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case displayName
        case pollInterval
        case credentials
        case layout
        case endpoint
        case metrics
        case alerts
        case commands
    }

    public var commandDescriptors: [CommandDescriptor] {
        commands.map { command in
            CommandDescriptor(
                id: command.id,
                label: command.label,
                parameters: command.parameters.map(\.descriptor),
                requiresConfirmation: command.requiresConfirmation
            )
        }
    }

    public var executableCommandDescriptors: [CommandDescriptor] {
        commands.compactMap { command in
            guard command.endpoint != nil else { return nil }
            return CommandDescriptor(
                id: command.id,
                label: command.label,
                parameters: command.parameters.map(\.descriptor),
                requiresConfirmation: command.requiresConfirmation
            )
        }
    }

    private static func validateUnique(
        _ ids: [String],
        duplicate: (String) -> ValidationError
    ) throws {
        var seen: Set<String> = []
        for id in ids {
            let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else {
                throw ValidationError.emptyID("item")
            }
            if !seen.insert(normalized).inserted {
                throw duplicate(normalized)
            }
        }
    }

    private static func isValidHTTPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else { return false }
        return true
    }
}

public struct ProviderManifestPackage: Equatable, Sendable {
    public var directory: URL
    public var manifest: ProviderManifest

    public init(directory: URL, manifest: ProviderManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    public static func load(from directory: URL, fileManager: FileManager = .default) throws -> ProviderManifestPackage {
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw LoadError.missingManifest(manifestURL.path)
        }
        let data = try Data(contentsOf: manifestURL)
        return ProviderManifestPackage(directory: directory, manifest: try ProviderManifest.decode(data))
    }

    public enum LoadError: Error, Equatable, LocalizedError, Sendable {
        case missingManifest(String)

        public var errorDescription: String? {
            switch self {
            case .missingManifest(let path):
                return "Manifest file is missing at \(path)."
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case displayName
        case pollInterval
        case credentials
        case endpoint
        case metrics
        case commands
    }
}

public extension ProviderManifest {
    struct Layout: Codable, Equatable, Sendable {
        public var icon: String?
        public var accent: String?
        public var primaryMetric: String?

        public init(icon: String? = nil, accent: String? = nil, primaryMetric: String? = nil) {
            self.icon = icon
            self.accent = accent
            self.primaryMetric = primaryMetric
        }
    }

    struct Endpoint: Codable, Equatable, Sendable {
        public var method: HTTPMethod
        public var url: String
        public var headers: [String: String]
        public var body: String?

        public init(method: HTTPMethod, url: String, headers: [String: String] = [:], body: String? = nil) {
            self.method = method
            self.url = url
            self.headers = headers
            self.body = body
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.method = try container.decode(HTTPMethod.self, forKey: .method)
            self.url = try container.decode(String.self, forKey: .url)
            self.headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
            self.body = try container.decodeIfPresent(String.self, forKey: .body)
        }

        private enum CodingKeys: String, CodingKey {
            case method
            case url
            case headers
            case body
        }
    }

    enum HTTPMethod: String, Codable, Equatable, Sendable {
        case get = "GET"
        case post = "POST"
    }

    struct Credential: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var kind: Kind
        public var required: Bool

        public init(id: String, label: String, kind: Kind, required: Bool = true) {
            self.id = id
            self.label = label
            self.kind = kind
            self.required = required
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.label = try container.decode(String.self, forKey: .label)
            self.kind = try container.decode(Kind.self, forKey: .kind)
            self.required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? true
        }

        public enum Kind: String, Codable, Equatable, Sendable {
            case password
            case apiKey
            case bearerToken
            case header
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case label
            case kind
            case required
        }
    }

    struct MetricMapping: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var value: ValueMapping

        public init(id: String, label: String, value: ValueMapping) {
            self.id = id
            self.label = label
            self.value = value
        }
    }

    struct ValueMapping: Codable, Equatable, Sendable {
        public var type: ValueType
        public var path: String
        public var transforms: [Transform]

        public init(type: ValueType, path: String, transforms: [Transform] = []) {
            self.type = type
            self.path = path
            self.transforms = transforms
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.type = try container.decode(ValueType.self, forKey: .type)
            self.path = try container.decode(String.self, forKey: .path)
            self.transforms = try container.decodeIfPresent([Transform].self, forKey: .transforms) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case path
            case transforms
        }
    }

    enum Transform: Codable, Equatable, Sendable {
        case multiply(Double)
        case divide(Double)
        case round
        case clamp(min: Double?, max: Double?)
        case defaultValue(JSONValue)

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "multiply":
                self = .multiply(try container.decode(Double.self, forKey: .value))
            case "divide":
                self = .divide(try container.decode(Double.self, forKey: .value))
            case "round":
                self = .round
            case "clamp":
                self = .clamp(
                    min: try container.decodeIfPresent(Double.self, forKey: .min),
                    max: try container.decodeIfPresent(Double.self, forKey: .max)
                )
            case "defaultValue":
                self = .defaultValue(try container.decode(JSONValue.self, forKey: .value))
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unsupported manifest transform \(type)."
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .multiply(let value):
                try container.encode("multiply", forKey: .type)
                try container.encode(value, forKey: .value)
            case .divide(let value):
                try container.encode("divide", forKey: .type)
                try container.encode(value, forKey: .value)
            case .round:
                try container.encode("round", forKey: .type)
            case .clamp(let min, let max):
                try container.encode("clamp", forKey: .type)
                try container.encodeIfPresent(min, forKey: .min)
                try container.encodeIfPresent(max, forKey: .max)
            case .defaultValue(let value):
                try container.encode("defaultValue", forKey: .type)
                try container.encode(value, forKey: .value)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case value
            case min
            case max
        }
    }

    enum ValueType: String, Codable, Equatable, Sendable {
        case throughput
        case latency
        case percent
        case level
        case bool
        case text
    }

    struct Command: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var parameters: [CommandParameter]
        public var requiresConfirmation: Bool
        public var endpoint: Endpoint?

        public init(
            id: String,
            label: String,
            parameters: [CommandParameter] = [],
            requiresConfirmation: Bool = false,
            endpoint: Endpoint? = nil
        ) {
            self.id = id
            self.label = label
            self.parameters = parameters
            self.requiresConfirmation = requiresConfirmation
            self.endpoint = endpoint
        }
    }

    struct Alert: Codable, Equatable, Sendable {
        public var id: String
        public var metricID: String
        public var kind: Kind
        public var title: String
        public var message: String
        public var severity: AlertSeverity

        public init(
            id: String,
            metricID: String,
            kind: Kind,
            title: String,
            message: String,
            severity: AlertSeverity = .warning
        ) {
            self.id = id
            self.metricID = metricID
            self.kind = kind
            self.title = title
            self.message = message
            self.severity = severity
        }

        public enum Kind: Codable, Equatable, Sendable {
            case threshold(comparison: AlertComparison, value: Double)
            case stateTransition(value: MetricValue)
            case sustained(comparison: AlertComparison, value: Double, duration: TimeInterval)

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let type = try container.decode(String.self, forKey: .type)
                switch type {
                case "threshold":
                    self = .threshold(
                        comparison: try container.decode(AlertComparison.self, forKey: .comparison),
                        value: try container.decode(Double.self, forKey: .value)
                    )
                case "stateTransition":
                    self = .stateTransition(value: try container.decode(JSONValue.self, forKey: .value).metricValue)
                case "sustained":
                    self = .sustained(
                        comparison: try container.decode(AlertComparison.self, forKey: .comparison),
                        value: try container.decode(Double.self, forKey: .value),
                        duration: try container.decode(TimeInterval.self, forKey: .duration)
                    )
                default:
                    throw DecodingError.dataCorruptedError(
                        forKey: .type,
                        in: container,
                        debugDescription: "Unsupported manifest alert kind \(type)."
                    )
                }
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .threshold(let comparison, let value):
                    try container.encode("threshold", forKey: .type)
                    try container.encode(comparison, forKey: .comparison)
                    try container.encode(value, forKey: .value)
                case .stateTransition(let value):
                    try container.encode("stateTransition", forKey: .type)
                    try container.encode(value.jsonValue, forKey: .value)
                case .sustained(let comparison, let value, let duration):
                    try container.encode("sustained", forKey: .type)
                    try container.encode(comparison, forKey: .comparison)
                    try container.encode(value, forKey: .value)
                    try container.encode(duration, forKey: .duration)
                }
            }

            private enum CodingKeys: String, CodingKey {
                case type
                case comparison
                case value
                case duration
            }
        }
    }

    struct CommandParameter: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var kind: Kind

        public init(id: String, label: String, kind: Kind) {
            self.id = id
            self.label = label
            self.kind = kind
        }

        var descriptor: AmbitCore.CommandParameter {
            AmbitCore.CommandParameter(id: id, label: label, kind: kind.descriptorKind)
        }
    }

    enum Kind: Codable, Equatable, Sendable {
        case text
        case bool
        case option([String])
        case number

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "text":
                self = .text
            case "bool":
                self = .bool
            case "number":
                self = .number
            case "option":
                self = .option(try container.decode([String].self, forKey: .options))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported command parameter kind \(type).")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text:
                try container.encode("text", forKey: .type)
            case .bool:
                try container.encode("bool", forKey: .type)
            case .number:
                try container.encode("number", forKey: .type)
            case .option(let options):
                try container.encode("option", forKey: .type)
                try container.encode(options, forKey: .options)
            }
        }

        var descriptorKind: CommandParameterKind {
            switch self {
            case .text:
                return .text
            case .bool:
                return .bool
            case .option(let options):
                return .option(options)
            case .number:
                return .number
            }
        }

        private enum CodingKeys: String, CodingKey {
            case type
            case options
        }
    }

    enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedSchemaVersion(Int)
        case emptyID(String)
        case emptyDisplayName
        case invalidPollInterval
        case invalidEndpointURL(String)
        case duplicateCredentialID(String)
        case duplicateMetricID(String)
        case duplicateAlertID(String)
        case duplicateCommandID(String)
        case duplicateParameterID(String, String)
        case emptyLabel(String)
        case emptyMetricPath(String)
        case invalidLayoutMetricID(String)
        case invalidAlertMetricID(String, String)
        case undeclaredCredentialReference(String)
        case invalidCommandEndpointURL(String, String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                return "Unsupported manifest schema version \(version)."
            case .emptyID(let owner):
                return "Manifest \(owner) id is empty."
            case .emptyDisplayName:
                return "Manifest display name is empty."
            case .invalidPollInterval:
                return "Manifest poll interval must be greater than zero."
            case .invalidEndpointURL(let url):
                return "Manifest endpoint URL is invalid: \(url)"
            case .duplicateCredentialID(let id):
                return "Manifest declares duplicate credential id \(id)."
            case .duplicateMetricID(let id):
                return "Manifest declares duplicate metric id \(id)."
            case .duplicateAlertID(let id):
                return "Manifest declares duplicate alert id \(id)."
            case .duplicateCommandID(let id):
                return "Manifest declares duplicate command id \(id)."
            case .duplicateParameterID(let commandID, let parameterID):
                return "Command \(commandID) declares duplicate parameter id \(parameterID)."
            case .emptyLabel(let id):
                return "Manifest item \(id) label is empty."
            case .emptyMetricPath(let id):
                return "Metric \(id) value path is empty."
            case .invalidLayoutMetricID(let id):
                return "Manifest layout references unknown metric id \(id)."
            case .invalidAlertMetricID(let alertID, let metricID):
                return "Manifest alert \(alertID) references unknown metric id \(metricID)."
            case .undeclaredCredentialReference(let id):
                return "Manifest references undeclared credential id \(id)."
            case .invalidCommandEndpointURL(let commandID, let url):
                return "Command \(commandID) endpoint URL is invalid: \(url)"
            }
        }
    }
}

private extension JSONValue {
    var metricValue: MetricValue {
        switch self {
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            return .level(value)
        case .string(let value):
            return .text(value)
        case .null:
            return .text("")
        case .array, .object:
            return .text("")
        }
    }
}

private extension MetricValue {
    var jsonValue: JSONValue {
        switch self {
        case .throughput(let bitsPerSecond):
            return .number(Double(bitsPerSecond))
        case .latency(let ms):
            return .number(ms)
        case .percent(let value), .level(let value):
            return .number(value)
        case .bool(let value):
            return .bool(value)
        case .text(let value):
            return .string(value)
        }
    }
}

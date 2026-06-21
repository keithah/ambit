import Foundation

public struct ProviderManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var id: ProviderID
    public var displayName: String
    public var pollInterval: TimeInterval
    public var endpoint: Endpoint
    public var metrics: [MetricMapping]
    public var commands: [Command]

    public init(
        schemaVersion: Int,
        id: ProviderID,
        displayName: String,
        pollInterval: TimeInterval,
        endpoint: Endpoint,
        metrics: [MetricMapping],
        commands: [Command] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.displayName = displayName
        self.pollInterval = pollInterval
        self.endpoint = endpoint
        self.metrics = metrics
        self.commands = commands
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
        try Self.validateUnique(metrics.map(\.id), duplicate: ValidationError.duplicateMetricID)
        try Self.validateUnique(commands.map(\.id), duplicate: ValidationError.duplicateCommandID)
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
}

public extension ProviderManifest {
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

        public init(type: ValueType, path: String) {
            self.type = type
            self.path = path
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
        case duplicateMetricID(String)
        case duplicateCommandID(String)
        case duplicateParameterID(String, String)
        case emptyLabel(String)
        case emptyMetricPath(String)
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
            case .duplicateMetricID(let id):
                return "Manifest declares duplicate metric id \(id)."
            case .duplicateCommandID(let id):
                return "Manifest declares duplicate command id \(id)."
            case .duplicateParameterID(let commandID, let parameterID):
                return "Command \(commandID) declares duplicate parameter id \(parameterID)."
            case .emptyLabel(let id):
                return "Manifest item \(id) label is empty."
            case .emptyMetricPath(let id):
                return "Metric \(id) value path is empty."
            case .invalidCommandEndpointURL(let commandID, let url):
                return "Command \(commandID) endpoint URL is invalid: \(url)"
            }
        }
    }
}

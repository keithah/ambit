import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ManifestHTTPRequest: Equatable, Sendable {
    public var method: ProviderManifest.HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: ProviderManifest.HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public protocol ManifestHTTPClient: Sendable {
    func send(_ request: ManifestHTTPRequest) async throws -> Data
}

public struct URLSessionManifestHTTPClient: ManifestHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: ManifestHTTPRequest) async throws -> Data {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        urlRequest.httpBody = request.body
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.nonHTTPResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Error.badStatus(httpResponse.statusCode)
        }
        return data
    }

    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case nonHTTPResponse
        case badStatus(Int)

        public var errorDescription: String? {
            switch self {
            case .nonHTTPResponse:
                return "Endpoint returned a non-HTTP response."
            case .badStatus(let statusCode):
                return "Endpoint returned HTTP \(statusCode)."
            }
        }
    }
}

public struct ManifestProvider: Provider {
    public let id: ProviderID
    public let displayName: String
    public let pollInterval: TimeInterval
    public let layout: ProviderManifest.Layout?
    public let commands: [CommandDescriptor]

    private let manifest: ProviderManifest
    private let httpClient: ManifestHTTPClient
    private let credentialStore: (any CredentialStore)?

    public init(
        manifest: ProviderManifest,
        httpClient: ManifestHTTPClient = URLSessionManifestHTTPClient(),
        credentialStore: (any CredentialStore)? = nil
    ) {
        self.manifest = manifest
        self.id = manifest.id
        self.displayName = manifest.displayName
        self.pollInterval = manifest.pollInterval
        self.layout = manifest.layout
        self.commands = manifest.executableCommandDescriptors
        self.httpClient = httpClient
        self.credentialStore = credentialStore
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        let urlString: String
        do {
            urlString = try Self.interpolate(manifest.endpoint.url, arguments: CommandArguments(), manifest: manifest, credentialStore: credentialStore)
        } catch {
            return ProviderSnapshot(health: .down, error: error.localizedDescription)
        }
        guard let url = URL(string: urlString) else {
            return ProviderSnapshot(health: .unknown, error: "Manifest endpoint URL is invalid.")
        }

        do {
            let data = try await httpClient.send(Self.request(endpoint: manifest.endpoint, url: url, manifest: manifest, credentialStore: credentialStore))
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return Self.snapshot(from: value, mappings: manifest.metrics)
        } catch {
            return ProviderSnapshot(health: .down, error: error.localizedDescription)
        }
    }

    public func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        guard let command = manifest.commands.first(where: { $0.id == commandID }) else {
            throw JSONRPCClientError.commandFailed("Manifest command \(commandID) is not declared.")
        }
        guard let endpoint = command.endpoint else {
            throw JSONRPCClientError.commandFailed("Manifest command \(commandID) does not declare an executable endpoint.")
        }
        let urlString = try Self.interpolate(endpoint.url, arguments: arguments, manifest: manifest, credentialStore: credentialStore)
        guard let url = URL(string: urlString) else {
            throw JSONRPCClientError.commandFailed("Manifest command \(commandID) endpoint URL is invalid.")
        }
        _ = try await httpClient.send(Self.request(endpoint: endpoint, url: url, arguments: arguments, manifest: manifest, credentialStore: credentialStore))
    }

    private static func request(
        endpoint: ProviderManifest.Endpoint,
        url: URL,
        arguments: CommandArguments = CommandArguments(),
        manifest: ProviderManifest,
        credentialStore: (any CredentialStore)?
    ) throws -> ManifestHTTPRequest {
        let headers = try endpoint.headers.reduce(into: [String: String]()) { result, header in
            result[header.key] = try interpolate(header.value, arguments: arguments, manifest: manifest, credentialStore: credentialStore)
        }
        let body: Data?
        if let template = endpoint.body {
            body = try Data(interpolate(template, arguments: arguments, manifest: manifest, credentialStore: credentialStore).utf8)
        } else {
            body = nil
        }
        return ManifestHTTPRequest(
            method: endpoint.method,
            url: url,
            headers: headers,
            body: body
        )
    }

    private static func snapshot(from value: JSONValue, mappings: [ProviderManifest.MetricMapping]) -> ProviderSnapshot {
        var metrics: [Metric] = []
        var failedIDs: [String] = []

        for mapping in mappings {
            let source = value.value(at: mapping.value.path) ?? .null
            let transformed = mapping.value.transforms.reduce(source) { current, transform in
                transform.apply(to: current)
            }
            guard let metricValue = transformed.metricValue(type: mapping.value.type) else {
                failedIDs.append(mapping.id)
                continue
            }
            metrics.append(Metric(id: mapping.id, label: mapping.label, value: metricValue))
        }

        if failedIDs.isEmpty {
            return ProviderSnapshot(health: .ok, metrics: metrics)
        }
        return ProviderSnapshot(
            health: .degraded,
            metrics: metrics,
            error: "Could not map metrics: \(failedIDs.joined(separator: ", "))"
        )
    }

    private static func interpolate(
        _ template: String,
        arguments: CommandArguments,
        manifest: ProviderManifest,
        credentialStore: (any CredentialStore)?
    ) throws -> String {
        let argumentInterpolated = arguments.values.reduce(template) { result, argument in
            result.replacingOccurrences(
                of: "{\(argument.key)}",
                with: argument.value.urlComponentValue
            )
        }
        return try manifest.credentials.reduce(argumentInterpolated) { result, credential in
            let placeholder = "{credential.\(credential.id)}"
            guard result.contains(placeholder) else { return result }
            let value = try credentialStore?.credential(CredentialKey(providerID: manifest.id, id: credential.id))
            guard let value, !value.isEmpty else {
                if credential.required {
                    throw ManifestProviderError.missingCredential(credential.id)
                }
                return result.replacingOccurrences(of: placeholder, with: "")
            }
            return result.replacingOccurrences(of: placeholder, with: value)
        }
    }
}

private extension ProviderManifest.Transform {
    func apply(to value: JSONValue) -> JSONValue {
        switch self {
        case .multiply(let factor):
            guard let number = value.numberValue else { return value }
            return .number(number * factor)
        case .divide(let divisor):
            guard let number = value.numberValue, divisor != 0 else { return value }
            return .number(number / divisor)
        case .round:
            guard let number = value.numberValue else { return value }
            return .number(number.rounded())
        case .clamp(let min, let max):
            guard let number = value.numberValue else { return value }
            var clamped = number
            if let min {
                clamped = Swift.max(clamped, min)
            }
            if let max {
                clamped = Swift.min(clamped, max)
            }
            return .number(clamped)
        case .defaultValue(let defaultValue):
            return value == .null ? defaultValue : value
        }
    }
}

private enum ManifestProviderError: Error, LocalizedError {
    case missingCredential(String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let id):
            return "Manifest credential \(id) is not configured."
        }
    }
}

private extension JSONValue {
    func value(at path: String) -> JSONValue? {
        let components = path.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return nil }
        return components.reduce(Optional(self)) { current, component in
            guard let current else { return nil }
            if let object = current.objectValue {
                return object[component]
            }
            if let array = current.arrayValue, let index = Int(component), array.indices.contains(index) {
                return array[index]
            }
            return nil
        }
    }

    func metricValue(type: ProviderManifest.ValueType) -> MetricValue? {
        switch type {
        case .throughput:
            guard let numberValue else { return nil }
            return .throughput(bitsPerSecond: Int(numberValue))
        case .latency:
            guard let numberValue else { return nil }
            return .latency(ms: numberValue)
        case .percent:
            guard let numberValue else { return nil }
            return .percent(numberValue)
        case .level:
            guard let numberValue else { return nil }
            return .level(numberValue)
        case .bool:
            guard let boolValue else { return nil }
            return .bool(boolValue)
        case .text:
            return textMetricValue.map(MetricValue.text)
        }
    }

    var textMetricValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            return String(value)
        case .null, .array, .object:
            return nil
        }
    }

    var urlComponentValue: String {
        let rawValue: String
        switch self {
        case .string(let value):
            rawValue = value
        case .number(let value):
            rawValue = value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            rawValue = String(value)
        case .null:
            rawValue = ""
        case .array, .object:
            rawValue = textMetricValue ?? ""
        }
        return rawValue.addingPercentEncoding(withAllowedCharacters: .manifestURLPathComponentAllowed) ?? rawValue
    }
}

private extension CharacterSet {
    static let manifestURLPathComponentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return allowed
    }()
}

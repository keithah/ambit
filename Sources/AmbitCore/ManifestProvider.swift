import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ManifestHTTPRequest: Equatable, Sendable {
    public var method: ProviderManifest.HTTPMethod
    public var url: URL

    public init(method: ProviderManifest.HTTPMethod, url: URL) {
        self.method = method
        self.url = url
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
    public let commands: [CommandDescriptor]

    private let manifest: ProviderManifest
    private let httpClient: ManifestHTTPClient

    public init(manifest: ProviderManifest, httpClient: ManifestHTTPClient = URLSessionManifestHTTPClient()) {
        self.manifest = manifest
        self.id = manifest.id
        self.displayName = manifest.displayName
        self.pollInterval = manifest.pollInterval
        self.commands = manifest.commandDescriptors
        self.httpClient = httpClient
    }

    public func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        guard manifest.endpoint.method == .get else {
            return ProviderSnapshot(health: .unknown, error: "Manifest endpoint method \(manifest.endpoint.method.rawValue) is not supported for polling.")
        }
        guard let url = URL(string: manifest.endpoint.url) else {
            return ProviderSnapshot(health: .unknown, error: "Manifest endpoint URL is invalid.")
        }

        do {
            let data = try await httpClient.send(ManifestHTTPRequest(method: manifest.endpoint.method, url: url))
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            return Self.snapshot(from: value, mappings: manifest.metrics)
        } catch {
            return ProviderSnapshot(health: .down, error: error.localizedDescription)
        }
    }

    private static func snapshot(from value: JSONValue, mappings: [ProviderManifest.MetricMapping]) -> ProviderSnapshot {
        var metrics: [Metric] = []
        var failedIDs: [String] = []

        for mapping in mappings {
            guard let source = value.value(at: mapping.value.path),
                  let metricValue = source.metricValue(type: mapping.value.type) else {
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
}

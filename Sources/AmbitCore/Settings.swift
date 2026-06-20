import Foundation

public enum EndpointMode: String, Codable, Equatable, Sendable, CaseIterable {
    case auto
    case forceLocal
    case forceRemote
}

public enum EndpointSelectionMode: Equatable, Sendable {
    case local
    case remote
}

public struct EndpointSelection: Equatable, Sendable {
    public var mode: EndpointSelectionMode
    public var host: String

    public init(mode: EndpointSelectionMode, host: String) {
        self.mode = mode
        self.host = host
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var localHost: String
    public var remoteHost: String
    public var username: String
    public var endpointMode: EndpointMode
    public var pollInterval: TimeInterval
    public var speedifyPath: String
    public var grpcurlPath: String
    public var ecoflowEnabled: Bool
    public var ecoflowHost: String
    public var ecoflowPort: Int

    private enum CodingKeys: String, CodingKey {
        case localHost
        case remoteHost
        case username
        case endpointMode
        case pollInterval
        case speedifyPath
        case grpcurlPath
        case ecoflowEnabled
        case ecoflowHost
        case ecoflowPort
    }

    public init(
        localHost: String = "auto",
        remoteHost: String = "",
        username: String = "root",
        endpointMode: EndpointMode = .auto,
        pollInterval: TimeInterval = 5,
        speedifyPath: String = "/Applications/Speedify.app/Contents/Resources/speedify_cli",
        grpcurlPath: String = "/opt/homebrew/bin/grpcurl",
        ecoflowEnabled: Bool = false,
        ecoflowHost: String = "auto",
        ecoflowPort: Int = 8787
    ) {
        self.localHost = localHost
        self.remoteHost = remoteHost
        self.username = username
        self.endpointMode = endpointMode
        self.pollInterval = pollInterval
        self.speedifyPath = speedifyPath
        self.grpcurlPath = grpcurlPath
        self.ecoflowEnabled = ecoflowEnabled
        self.ecoflowHost = ecoflowHost
        self.ecoflowPort = ecoflowPort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.localHost = try container.decodeIfPresent(String.self, forKey: .localHost) ?? "auto"
        self.remoteHost = try container.decodeIfPresent(String.self, forKey: .remoteHost) ?? ""
        self.username = try container.decodeIfPresent(String.self, forKey: .username) ?? "root"
        self.endpointMode = try container.decodeIfPresent(EndpointMode.self, forKey: .endpointMode) ?? .auto
        self.pollInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .pollInterval) ?? 5
        self.speedifyPath = try container.decodeIfPresent(String.self, forKey: .speedifyPath) ?? "/Applications/Speedify.app/Contents/Resources/speedify_cli"
        self.grpcurlPath = try container.decodeIfPresent(String.self, forKey: .grpcurlPath) ?? "/opt/homebrew/bin/grpcurl"
        self.ecoflowEnabled = try container.decodeIfPresent(Bool.self, forKey: .ecoflowEnabled) ?? false
        self.ecoflowHost = try container.decodeIfPresent(String.self, forKey: .ecoflowHost) ?? "auto"
        self.ecoflowPort = try container.decodeIfPresent(Int.self, forKey: .ecoflowPort) ?? 8787
    }
}

public protocol SettingsStore: Sendable {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

public struct UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "appSettings"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() throws -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            return AppSettings()
        }
        return try JSONDecoder().decode(AppSettings.self, from: data)
    }

    public func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: key)
    }
}

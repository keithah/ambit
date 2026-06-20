import Foundation

public struct SpeedifyStatus: Equatable, Sendable {
    public static let graphSampleLimit = 120

    public var isInstalled: Bool
    public var isAvailable: Bool
    public var isConnected: Bool
    public var state: String
    public var server: String?
    public var detail: String?
    public var bondingMode: SpeedifyBondingMode?
    public var networks: [SpeedifyNetwork]
    public var secondaryThresholdMbps: Int?
    public var startupConnect: Bool?
    public var sessionDownloadBytes: Int?
    public var sessionUploadBytes: Int?
    public var graphSamples: [SpeedifyGraphSample]

    public init(
        isInstalled: Bool,
        isAvailable: Bool,
        isConnected: Bool = false,
        state: String,
        server: String? = nil,
        detail: String? = nil,
        bondingMode: SpeedifyBondingMode? = nil,
        networks: [SpeedifyNetwork] = [],
        secondaryThresholdMbps: Int? = nil,
        startupConnect: Bool? = nil,
        sessionDownloadBytes: Int? = nil,
        sessionUploadBytes: Int? = nil,
        graphSamples: [SpeedifyGraphSample] = []
    ) {
        self.isInstalled = isInstalled
        self.isAvailable = isAvailable
        self.isConnected = isConnected
        self.state = state
        self.server = server
        self.detail = detail
        self.bondingMode = bondingMode
        self.networks = networks
        self.secondaryThresholdMbps = secondaryThresholdMbps
        self.startupConnect = startupConnect
        self.sessionDownloadBytes = sessionDownloadBytes
        self.sessionUploadBytes = sessionUploadBytes
        self.graphSamples = graphSamples
    }

    public func mergingLiveSamples(from previous: SpeedifyStatus?, limit: Int = Self.graphSampleLimit) -> SpeedifyStatus {
        guard let previous, !previous.graphSamples.isEmpty else { return limitedSamples(limit: limit) }
        var copy = self
        copy.graphSamples = Array((previous.graphSamples + graphSamples).suffix(max(1, limit)))
        return copy
    }

    private func limitedSamples(limit: Int) -> SpeedifyStatus {
        var copy = self
        copy.graphSamples = Array(graphSamples.suffix(max(1, limit)))
        return copy
    }
}

public struct SpeedifyGraphSample: Equatable, Sendable {
    public var timestamp: Date?
    public var totalBps: Int
    public var downloadBps: Int?
    public var uploadBps: Int?

    public init(timestamp: Date? = nil, totalBps: Int, downloadBps: Int? = nil, uploadBps: Int? = nil) {
        self.timestamp = timestamp
        self.totalBps = totalBps
        self.downloadBps = downloadBps
        self.uploadBps = uploadBps
    }
}

public enum SpeedifyBondingMode: String, Equatable, Sendable, CaseIterable {
    case speed = "SP"
    case redundant = "RD"
    case streaming = "STR"
    case unknown

    public init(code: String) {
        switch code.uppercased() {
        case "SP", "SPEED":
            self = .speed
        case "RD":
            self = .redundant
        case "STR":
            self = .streaming
        default:
            self = .unknown
        }
    }

    public var label: String {
        switch self {
        case .speed: return "Speed"
        case .redundant: return "Redundant"
        case .streaming: return "Streaming"
        case .unknown: return "Unknown"
        }
    }

    public var commandCode: String {
        switch self {
        case .speed: return "SP"
        case .redundant: return "RD"
        case .streaming: return "STR"
        case .unknown: return ""
        }
    }
}

public enum SpeedifyNetworkPriority: Int, Equatable, Sendable, CaseIterable {
    case always = 0
    case secondary = 1
    case backup = 2
    case never = 100
    case automatic = 200
    case unknown = -1

    public init(value: Int) {
        self = SpeedifyNetworkPriority(rawValue: value) ?? .unknown
    }

    public var label: String {
        switch self {
        case .always: return "Primary"
        case .secondary: return "Secondary"
        case .backup: return "Backup"
        case .never: return "Never"
        case .automatic: return "Automatic"
        case .unknown: return "Unknown"
        }
    }
}

public struct SpeedifyNetwork: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var type: String?
    public var isp: String?
    public var priority: SpeedifyNetworkPriority
    public var receiveBps: Int?
    public var sendBps: Int?
    public var statusMessage: String?
    public var isConnected: Bool

    public init(id: String, name: String, type: String? = nil, isp: String? = nil, priority: SpeedifyNetworkPriority = .unknown, receiveBps: Int? = nil, sendBps: Int? = nil, statusMessage: String? = nil, isConnected: Bool = true) {
        self.id = id
        self.name = name
        self.type = type
        self.isp = isp
        self.priority = priority
        self.receiveBps = receiveBps
        self.sendBps = sendBps
        self.statusMessage = statusMessage
        self.isConnected = isConnected
    }

    public var displayName: String {
        if let isp, !isp.isEmpty {
            return "\(name) (\(isp))"
        }
        return name
    }
}

public protocol SpeedifyClientProtocol: Sendable {
    func status() async -> SpeedifyStatus
}

public struct SpeedifyClient: SpeedifyClientProtocol {
    private let path: String
    private let processRunner: ProcessRunner

    public init(path: String, processRunner: ProcessRunner = SystemProcessRunner()) {
        self.path = path
        self.processRunner = processRunner
    }

    public func status() async -> SpeedifyStatus {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return SpeedifyStatus(isInstalled: false, isAvailable: false, state: "Not installed")
        }

        do {
            let stateResult = try await processRunner.run(executable: path, arguments: ["state"], timeout: 6)
            guard stateResult.exitCode == 0 else {
                return unavailableFromErrorJSON(stateResult.stdout, fallback: stateResult.stderr)
            }
            let stateObject = decodeObject(stateResult.stdout)
            let state = stateObject.firstString(keys: ["state", "connectionState", "status"]) ?? "Available"
            let connected = stateObject.firstBool(keys: ["connected"]) ?? state.localizedCaseInsensitiveContains("connect")

            let server = try? await processRunner.run(executable: path, arguments: ["show", "currentserver"], timeout: 4)
            return SpeedifyStatus(
                isInstalled: true,
                isAvailable: true,
                isConnected: connected,
                state: state,
                server: server.flatMap { parseServer($0.stdout) }
            )
        } catch {
            return SpeedifyStatus(isInstalled: true, isAvailable: false, state: "Unavailable", detail: error.localizedDescription)
        }
    }

    private func unavailableFromErrorJSON(_ stdout: String, fallback: String) -> SpeedifyStatus {
        let object = decodeObject(stdout)
        let message = object.firstString(keys: ["errorMessage", "errorType"]) ?? (fallback.isEmpty ? "Speedify CLI failed." : fallback)
        return SpeedifyStatus(isInstalled: true, isAvailable: false, state: "Daemon unavailable", detail: message)
    }

    private func parseServer(_ stdout: String) -> String? {
        let object = decodeObject(stdout)
        let country = object.firstString(keys: ["country", "countryName"])
        let city = object.firstString(keys: ["city", "cityName"])
        if let country, let city {
            return "\(country), \(city)"
        }
        return object.firstString(keys: ["server", "name", "displayName"])
    }

    private func decodeObject(_ string: String) -> JSONObject {
        guard let data = string.data(using: .utf8) else { return [:] }
        let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        return value?.objectValue ?? [:]
    }
}

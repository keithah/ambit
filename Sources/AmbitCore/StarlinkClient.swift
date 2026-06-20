import Foundation

public struct StarlinkStatus: Equatable, Sendable {
    public var isReachable: Bool
    public var state: String
    public var hardwareVersion: String?
    public var softwareVersion: String?
    public var uptimeSeconds: Int?
    public var downlinkThroughputBps: Int?
    public var uplinkThroughputBps: Int?
    public var popPingLatencyMs: Double?
    public var obstructionPercent: Double?
    public var gpsValid: Bool?
    public var gpsSats: Int?
    public var ethSpeedMbps: Int?
    public var disablementCode: String?
    public var softwareUpdateState: String?
    public var recentDropRate: Double?
    public var recentLatencyMs: Double?
    public var recentDownlinkThroughputBps: Int?
    public var recentUplinkThroughputBps: Int?
    public var outageCount: Int?

    public init(
        isReachable: Bool = false,
        state: String = "Unavailable",
        hardwareVersion: String? = nil,
        softwareVersion: String? = nil,
        uptimeSeconds: Int? = nil,
        downlinkThroughputBps: Int? = nil,
        uplinkThroughputBps: Int? = nil,
        popPingLatencyMs: Double? = nil,
        obstructionPercent: Double? = nil,
        gpsValid: Bool? = nil,
        gpsSats: Int? = nil,
        ethSpeedMbps: Int? = nil,
        disablementCode: String? = nil,
        softwareUpdateState: String? = nil,
        recentDropRate: Double? = nil,
        recentLatencyMs: Double? = nil,
        recentDownlinkThroughputBps: Int? = nil,
        recentUplinkThroughputBps: Int? = nil,
        outageCount: Int? = nil
    ) {
        self.isReachable = isReachable
        self.state = state
        self.hardwareVersion = hardwareVersion
        self.softwareVersion = softwareVersion
        self.uptimeSeconds = uptimeSeconds
        self.downlinkThroughputBps = downlinkThroughputBps
        self.uplinkThroughputBps = uplinkThroughputBps
        self.popPingLatencyMs = popPingLatencyMs
        self.obstructionPercent = obstructionPercent
        self.gpsValid = gpsValid
        self.gpsSats = gpsSats
        self.ethSpeedMbps = ethSpeedMbps
        self.disablementCode = disablementCode
        self.softwareUpdateState = softwareUpdateState
        self.recentDropRate = recentDropRate
        self.recentLatencyMs = recentLatencyMs
        self.recentDownlinkThroughputBps = recentDownlinkThroughputBps
        self.recentUplinkThroughputBps = recentUplinkThroughputBps
        self.outageCount = outageCount
    }
}

public protocol StarlinkClientProtocol: Sendable {
    func status() async -> StarlinkStatus
}

public struct StarlinkClient: StarlinkClientProtocol {
    private let path: String
    private let host: String
    private let processRunner: ProcessRunner

    public init(path: String = "/opt/homebrew/bin/grpcurl", host: String = "192.168.100.1", processRunner: ProcessRunner = SystemProcessRunner()) {
        self.path = path
        self.host = host
        self.processRunner = processRunner
    }

    public func status() async -> StarlinkStatus {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return StarlinkStatus(isReachable: false, state: "grpcurl not installed")
        }

        async let statusResult = run(request: "{\"get_status\":{}}")
        async let historyResult = run(request: "{\"get_history\":{}}")
        do {
            let statusJSON = try await statusResult
            let historyJSON = try? await historyResult
            return Self.parse(statusJSON: statusJSON, historyJSON: historyJSON)
        } catch {
            return StarlinkStatus(isReachable: false, state: error.localizedDescription)
        }
    }

    private func run(request: String) async throws -> String {
        let result = try await processRunner.run(
            executable: path,
            arguments: ["-plaintext", "-max-time", "5", "-d", request, "\(host):9200", "SpaceX.API.Device.Device/Handle"],
            timeout: 7
        )
        guard result.exitCode == 0 else {
            throw JSONRPCClientError.commandFailed(result.stderr.isEmpty ? "Starlink grpcurl failed." : result.stderr)
        }
        return result.stdout
    }

    public static func parse(statusJSON: String, historyJSON: String?) -> StarlinkStatus {
        let statusObject = decode(statusJSON)["dishGetStatus"]?.objectValue ?? [:]
        let historyObject = historyJSON.map(decode)?["dishGetHistory"]?.objectValue ?? [:]
        let deviceInfo = statusObject["deviceInfo"]?.objectValue ?? [:]
        let deviceState = statusObject["deviceState"]?.objectValue ?? [:]
        let obstruction = statusObject["obstructionStats"]?.objectValue ?? [:]
        let gps = statusObject["gpsStats"]?.objectValue ?? [:]
        let disablement = statusObject["disablementCode"]?.stringValue

        return StarlinkStatus(
            isReachable: true,
            state: disablement == "OKAY" || disablement == nil ? "Online" : disablement ?? "Online",
            hardwareVersion: deviceInfo["hardwareVersion"]?.stringValue,
            softwareVersion: deviceInfo["softwareVersion"]?.stringValue,
            uptimeSeconds: intValue(deviceState["uptimeS"]),
            downlinkThroughputBps: statusObject["downlinkThroughputBps"]?.intValue,
            uplinkThroughputBps: statusObject["uplinkThroughputBps"]?.intValue,
            popPingLatencyMs: statusObject["popPingLatencyMs"]?.numberValue,
            obstructionPercent: obstruction["fractionObstructed"]?.numberValue.map { $0 * 100 },
            gpsValid: gps["gpsValid"]?.boolValue,
            gpsSats: gps["gpsSats"]?.intValue,
            ethSpeedMbps: statusObject["ethSpeedMbps"]?.intValue,
            disablementCode: disablement,
            softwareUpdateState: statusObject["softwareUpdateState"]?.stringValue,
            recentDropRate: historyObject["popPingDropRate"]?.arrayValue?.last?.numberValue,
            recentLatencyMs: historyObject["popPingLatencyMs"]?.arrayValue?.last?.numberValue,
            recentDownlinkThroughputBps: historyObject["downlinkThroughputBps"]?.arrayValue?.last?.intValue,
            recentUplinkThroughputBps: historyObject["uplinkThroughputBps"]?.arrayValue?.last?.intValue,
            outageCount: historyObject["outages"]?.arrayValue?.count
        )
    }

    private static func intValue(_ value: JSONValue?) -> Int? {
        value?.intValue ?? value?.stringValue.flatMap(Int.init)
    }

    private static func decode(_ string: String) -> JSONObject {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue
        else { return [:] }
        return object
    }
}

import Foundation

/// Field numbers below are from the dish's `SpaceX.API.Device` protobuf schema
/// (`device.proto`, `dish.proto`, `common.proto`) as published by community clients.

public enum StarlinkOutageCause: Int, Sendable, Equatable {
    case unknown = 0, booting, stowed, thermalShutdown, noSchedule, noSatellites, obstructed, noDownlink,
         noPings, actuatorActivity, cableTest, sleeping
    case skySearch = 13, inhibitRF = 14

    public var text: String {
        switch self {
        case .unknown: "Offline"
        case .booting: "Starting up"
        case .stowed: "Stowed"
        case .thermalShutdown: "Too hot or too cold"
        case .noSchedule, .noSatellites, .skySearch: "Searching for satellites"
        case .obstructed: "Obstructed"
        case .noDownlink, .noPings: "No signal"
        case .actuatorActivity: "Moving"
        case .cableTest: "Testing cable"
        case .sleeping: "Sleeping"
        case .inhibitRF: "Transmit disabled"
        }
    }
}

public struct StarlinkStatus: Sendable, Equatable {
    public var deviceID: String?
    public var hardwareVersion: String?
    public var softwareVersion: String?
    public var uptimeSeconds: UInt64?
    public var latencyMs: Double?
    public var downlinkBps: Double?
    public var uplinkBps: Double?
    public var dropRate: Double?
    public var fractionObstructed: Double?
    public var currentlyObstructed = false
    public var stowRequested = false
    /// Set while the dish reports an ongoing outage; nil when it is passing traffic.
    public var outage: StarlinkOutageCause?

    public init() {}

    public var isOnline: Bool { outage == nil }

    /// Decodes a `Response` message carrying `dish_get_status`.
    public init(response: Data) throws {
        do {
            try self.init(decoding: response)
        } catch is ProtoError {
            throw StarlinkError.unexpectedResponse
        }
    }

    private init(decoding response: Data) throws {
        let top = try ProtoWire.fields(response)
        try StarlinkError.checkDeviceStatus(top)
        guard let body = top.last(where: { $0.number == 2004 })?.data else { throw StarlinkError.unexpectedResponse }
        // proto3 leaves a zero off the wire, so for these an absent field means 0, not unknown.
        // Latency stays nil when absent: the dish has none to report during an outage.
        dropRate = 0
        fractionObstructed = 0
        downlinkBps = 0
        uplinkBps = 0
        for field in try ProtoWire.fields(body) {
            switch field.number {
            case 1:
                for info in try ProtoWire.fields(field.data ?? Data()) {
                    switch info.number {
                    case 1: deviceID = info.string
                    case 2: hardwareVersion = info.string
                    case 3: softwareVersion = info.string
                    default: break
                    }
                }
            case 2:
                uptimeSeconds = try ProtoWire.fields(field.data ?? Data()).last(where: { $0.number == 1 })?.uint
            case 1003: dropRate = field.float
            case 1004:
                for stat in try ProtoWire.fields(field.data ?? Data()) {
                    switch stat.number {
                    case 1: fractionObstructed = stat.float
                    case 5: currentlyObstructed = stat.bool ?? false
                    default: break
                    }
                }
            case 1007: downlinkBps = field.float
            case 1008: uplinkBps = field.float
            case 1009: latencyMs = field.float
            case 1010: stowRequested = field.bool ?? false
            case 1014:
                let cause = try ProtoWire.fields(field.data ?? Data()).last(where: { $0.number == 1 })?.uint ?? 0
                outage = Int(exactly: cause).flatMap(StarlinkOutageCause.init(rawValue:)) ?? .unknown
            default: break
            }
        }
        // A number that is not finite is no reading; the views round these to whole numbers.
        for path in [\StarlinkStatus.dropRate, \.fractionObstructed, \.downlinkBps, \.uplinkBps, \.latencyMs] {
            if let value = self[keyPath: path], !value.isFinite { self[keyPath: path] = nil }
        }
    }
}

public enum StarlinkError: Error, Equatable, Sendable {
    case invalidHost
    case timedOut
    case http(Int)
    case grpc(status: Int, message: String)
    case device(code: Int, message: String)
    case unexpectedResponse

    /// Every `Response` carries a status (field 2); a non-zero code means the dish refused the
    /// request, even when HTTP and gRPC both report success.
    static func checkDeviceStatus(in response: Data) throws {
        do {
            try checkDeviceStatus(try ProtoWire.fields(response))
        } catch is ProtoError {
            throw StarlinkError.unexpectedResponse
        }
    }

    static func checkDeviceStatus(_ top: [ProtoField]) throws {
        guard let status = top.last(where: { $0.number == 2 })?.data else { return }
        let fields = try ProtoWire.fields(status)
        // The code is an int32; a negative one arrives as a ten-byte varint.
        let raw = fields.last(where: { $0.number == 1 })?.uint ?? 0
        // A value that is not a sign-extended int32 is malformed, not a success.
        guard let code = Int32(exactly: Int64(bitPattern: raw)).map(Int.init) else { throw StarlinkError.unexpectedResponse }
        if code != 0 {
            throw StarlinkError.device(code: code, message: fields.last(where: { $0.number == 2 })?.string ?? "")
        }
    }
}

enum StarlinkRequest {
    static let getStatus = ProtoWire.message(field: 1004, Data())
    static let reboot = ProtoWire.message(field: 1001, Data())
    static func stow(_ stowed: Bool) -> Data {
        ProtoWire.message(field: 2002, stowed ? Data() : ProtoWire.bool(field: 1, true))
    }
}

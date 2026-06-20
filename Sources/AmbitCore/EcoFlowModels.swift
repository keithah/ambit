import Foundation

public enum EcoFlowCapability: String, Codable, Equatable, Sendable {
    case supported
    case unsupported
    case unknown
}

public enum EcoFlowBatteryState: String, Codable, Equatable, Sendable {
    case charging
    case discharging
    case idle
    case full
    case unknown
}

public enum EcoFlowOutputState: String, Codable, Equatable, Sendable {
    case on
    case off
    case unknown
}

public enum EcoFlowOutputTarget: String, Codable, Equatable, Sendable, CaseIterable {
    case ac
    case dc
    case usb
}

public enum EcoFlowRequestedControlState: String, Codable, Equatable, Sendable {
    case on
    case off
    case shutdown
}

public enum EcoFlowCommandResult: String, Codable, Equatable, Sendable {
    case applied
    case rejected
    case unsupported
    case unknown
    case failed
}

public struct EcoFlowDeviceIdentity: Codable, Equatable, Sendable {
    public var name: String
    public var model: String
    public var ip: String
    public var serialNumber: String?
    public var firmwareVersion: String?
}

public struct EcoFlowDeviceCapabilities: Codable, Equatable, Sendable {
    public var outputs: EcoFlowOutputMap<EcoFlowCapability>
    public var shutdown: EcoFlowCapability
    public var diagnostics: EcoFlowCapability
}

public struct EcoFlowDeviceInfo: Codable, Equatable, Sendable {
    public var device: EcoFlowDeviceIdentity
    public var capabilities: EcoFlowDeviceCapabilities
}

public struct EcoFlowBatteryStatus: Codable, Equatable, Sendable {
    public var percent: Int?
    public var state: EcoFlowBatteryState
}

public struct EcoFlowPowerStatus: Codable, Equatable, Sendable {
    public var inputWatts: Int?
    public var outputWatts: Int?
    public var netWatts: Int?
}

public struct EcoFlowOutputStatus: Codable, Equatable, Sendable {
    public var state: EcoFlowOutputState
    public var watts: Int?
}

public struct EcoFlowOutputStatusWithControllability: Codable, Equatable, Sendable {
    public var state: EcoFlowOutputState
    public var watts: Int?
    public var controllable: EcoFlowCapability

    public init(state: EcoFlowOutputState, watts: Int?, controllable: EcoFlowCapability) {
        self.state = state
        self.watts = watts
        self.controllable = controllable
    }
}

public struct EcoFlowOutputMap<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var ac: Value
    public var dc: Value
    public var usb: Value

    public init(ac: Value, dc: Value, usb: Value) {
        self.ac = ac
        self.dc = dc
        self.usb = usb
    }

    public subscript(target: EcoFlowOutputTarget) -> Value {
        switch target {
        case .ac: return ac
        case .dc: return dc
        case .usb: return usb
        }
    }
}

public struct EcoFlowDeviceStatus: Codable, Equatable, Sendable {
    public var battery: EcoFlowBatteryStatus
    public var power: EcoFlowPowerStatus
    public var outputs: EcoFlowOutputMap<EcoFlowOutputStatus>
    public var updatedAt: String
}

public struct EcoFlowDeviceStats: Codable, Equatable, Sendable {
    public var batteryPercent: Int?
    public var inputWatts: Int?
    public var outputWatts: Int?
    public var netWatts: Int?
    public var estimatedMinutesRemaining: Int?
    public var estimatedMinutesToFull: Int?
    public var isEstimateDerived: Bool
    public var updatedAt: String
}

public struct EcoFlowOutputsSnapshot: Codable, Equatable, Sendable {
    public var outputs: EcoFlowOutputMap<EcoFlowOutputStatusWithControllability>
    public var updatedAt: String
}

public struct EcoFlowControlResponse: Codable, Equatable, Sendable {
    public var target: EcoFlowControlTarget
    public var requestedState: EcoFlowRequestedControlState
    public var result: EcoFlowCommandResult
    public var observedState: EcoFlowOutputState
    public var message: String?
}

public enum EcoFlowControlTarget: String, Codable, Equatable, Sendable {
    case ac
    case dc
    case usb
    case device
}

public struct EcoFlowDiagnosticsSnapshot: Codable, Equatable, Sendable {
    public var deviceIp: String
    public var observations: [EcoFlowDiagnosticObservation]
}

public struct EcoFlowDiagnosticObservation: Codable, Equatable, Sendable {
    public var timestamp: String
    public var transport: String
    public var direction: String
    public var raw: String
    public var notes: String
}

public struct EcoFlowSnapshot: Equatable, Sendable {
    public var device: EcoFlowDeviceInfo?
    public var status: EcoFlowDeviceStatus
    public var outputs: EcoFlowOutputsSnapshot?
    public var stats: EcoFlowDeviceStats?

    public init(
        device: EcoFlowDeviceInfo? = nil,
        status: EcoFlowDeviceStatus,
        outputs: EcoFlowOutputsSnapshot? = nil,
        stats: EcoFlowDeviceStats? = nil
    ) {
        self.device = device
        self.status = status
        self.outputs = outputs
        self.stats = stats
    }
}

public struct EcoFlowAPIErrorBody: Codable, Equatable, Sendable {
    public var error: EcoFlowAPIError
}

public struct EcoFlowAPIError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var details: [String: JSONValue]
}

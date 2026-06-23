import Foundation

// pingscope domain (rebuilt fresh in Ambit's model; pingscope is the behavior oracle).
// Starlink is intentionally excluded — it is its own future integration.

public enum ProbeMethod: String, Codable, Sendable, CaseIterable {
    case tcp, udp, icmp

    public var defaultPort: UInt16? {
        switch self {
        case .tcp: return 443
        case .udp: return 53
        case .icmp: return nil
        }
    }

    public var requiresPort: Bool { self == .tcp || self == .udp }
}

public enum ProbeFailureReason: String, Codable, Sendable, Equatable {
    case timeout
    case dnsFailure
    case connectionRefused
    case networkUnavailable
    case cancelled
    case icmpUnavailable
    case unknown
}

/// One probe measurement. `latencyMs` present ⇔ success; failures carry a reason.
public struct ProbeResult: Equatable, Sendable {
    public var timestamp: Date
    public var latencyMs: Double?
    public var failureReason: ProbeFailureReason?
    public var note: String?

    public init(timestamp: Date, latencyMs: Double? = nil, failureReason: ProbeFailureReason? = nil, note: String? = nil) {
        self.timestamp = timestamp
        self.latencyMs = latencyMs
        self.failureReason = failureReason
        self.note = note
    }

    public var isSuccess: Bool { latencyMs != nil && failureReason == nil }
}

/// Per-host configuration — the per-instance config carried in IntegrationInstanceRecord.
public struct PingScopeHostConfig: Codable, Equatable, Sendable {
    public var displayName: String
    public var address: String
    public var method: ProbeMethod
    public var port: UInt16?
    public var interval: TimeInterval      // seconds; min 0.25
    public var timeout: TimeInterval       // seconds; min 0.25
    public var thresholds: HealthThresholds

    public init(
        displayName: String,
        address: String,
        method: ProbeMethod = .tcp,
        port: UInt16? = nil,
        interval: TimeInterval = 2,
        timeout: TimeInterval = 2,
        thresholds: HealthThresholds = HealthThresholds()
    ) {
        self.displayName = displayName
        self.address = address
        self.method = method
        self.port = port
        self.interval = interval
        self.timeout = timeout
        self.thresholds = thresholds
    }

    public enum ValidationError: String, Sendable, Equatable {
        case missingDisplayName, missingAddress, invalidPort, intervalTooShort, timeoutTooShort, degradedThresholdTooLow
    }

    public static let minimumTiming: TimeInterval = 0.25

    public var validationErrors: [ValidationError] {
        var errors: [ValidationError] = []
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.missingDisplayName) }
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors.append(.missingAddress) }
        if method.requiresPort, (port == nil || port == 0) { errors.append(.invalidPort) }
        if interval < Self.minimumTiming { errors.append(.intervalTooShort) }
        if timeout < Self.minimumTiming { errors.append(.timeoutTooShort) }
        if thresholds.degradedAt < 1 { errors.append(.degradedThresholdTooLow) }
        return errors
    }

    public var isValid: Bool { validationErrors.isEmpty }

    /// Switch probe method and adopt its method-aware default port.
    public func applying(method: ProbeMethod) -> PingScopeHostConfig {
        var copy = self
        copy.method = method
        copy.port = method.defaultPort
        return copy
    }
}

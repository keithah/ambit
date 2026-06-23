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
    public var policy: AlertPolicy

    public init(
        displayName: String,
        address: String,
        method: ProbeMethod = .tcp,
        port: UInt16? = nil,
        interval: TimeInterval = 2,
        timeout: TimeInterval = 2,
        thresholds: HealthThresholds = HealthThresholds(),
        policy: AlertPolicy = .preset(.balanced)
    ) {
        self.displayName = displayName
        self.address = address
        self.method = method
        self.port = port
        self.interval = interval
        self.timeout = timeout
        self.thresholds = thresholds
        self.policy = policy
    }

    enum CodingKeys: String, CodingKey {
        case displayName, address, method, port, interval, timeout, thresholds, policy
    }

    // Lenient decode: tolerate configs persisted before optional fields existed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        address = try c.decode(String.self, forKey: .address)
        method = try c.decodeIfPresent(ProbeMethod.self, forKey: .method) ?? .tcp
        port = try c.decodeIfPresent(UInt16.self, forKey: .port)
        interval = try c.decodeIfPresent(TimeInterval.self, forKey: .interval) ?? 2
        timeout = try c.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? 2
        thresholds = try c.decodeIfPresent(HealthThresholds.self, forKey: .thresholds) ?? HealthThresholds()
        policy = try c.decodeIfPresent(AlertPolicy.self, forKey: .policy) ?? .preset(.balanced)
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

    /// Deterministic, engine-independent integration-instance id from the target (address +
    /// port). Two engines configured for the same host compute the same id.
    public var integrationInstanceID: IntegrationInstanceID {
        let suffix = port.map { ":\($0)" } ?? ""
        return IntegrationInstanceID(rawValue: "pingscope@\(address)\(suffix)")
    }

    /// Encode to / decode from an IntegrationInstanceRecord.config (JSONObject), round-tripped
    /// through JSONValue so the generic registry needn't know pingscope's shape.
    public func asConfigObject() -> JSONObject {
        guard let data = try? JSONEncoder().encode(self),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else { return [:] }
        return object
    }

    public init?(configObject: JSONObject) {
        guard let data = try? JSONEncoder().encode(JSONValue.object(configObject)),
              let host = try? JSONDecoder().decode(PingScopeHostConfig.self, from: data) else { return nil }
        self = host
    }
}

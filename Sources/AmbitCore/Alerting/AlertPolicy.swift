import Foundation

public enum AlertPreset: String, Codable, Sendable, CaseIterable {
    case quiet, balanced, verbose, custom
}

public struct AlertThreshold: Codable, Equatable, Sendable {
    public var comparison: AlertComparison
    public var value: Double

    public init(comparison: AlertComparison, value: Double) {
        self.comparison = comparison
        self.value = value
    }
}

/// Generic per-entity alerting policy. Threshold values are interpreted by the entity
/// descriptor's device class/unit; integrations translate this model into concrete alert rules.
public struct EntityAlertPolicy: Codable, Equatable, Sendable {
    public var preset: AlertPreset
    public var enabled: Bool
    public var threshold: AlertThreshold?
    public var consecutive: Int
    public var cooldown: TimeInterval
    public var notifyOnRecovery: Bool

    public init(
        preset: AlertPreset = .balanced,
        enabled: Bool = true,
        threshold: AlertThreshold? = AlertThreshold(comparison: .greaterThanOrEqual, value: 250),
        consecutive: Int = 5,
        cooldown: TimeInterval = 300,
        notifyOnRecovery: Bool = true
    ) {
        self.preset = preset
        self.enabled = enabled
        self.threshold = threshold
        self.consecutive = consecutive
        self.cooldown = cooldown
        self.notifyOnRecovery = notifyOnRecovery
    }

    private enum CodingKeys: String, CodingKey {
        case preset
        case enabled
        case threshold
        case consecutive
        case cooldown
        case notifyOnRecovery
        case highLatencyMs
        case highLatencyConsecutive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EntityAlertPolicy.preset(.balanced)
        preset = try c.decodeIfPresent(AlertPreset.self, forKey: .preset) ?? .custom
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        cooldown = try c.decodeIfPresent(TimeInterval.self, forKey: .cooldown) ?? defaults.cooldown
        notifyOnRecovery = try c.decodeIfPresent(Bool.self, forKey: .notifyOnRecovery) ?? defaults.notifyOnRecovery

        if let threshold = try c.decodeIfPresent(AlertThreshold.self, forKey: .threshold) {
            self.threshold = threshold
        } else if let legacyLatency = try c.decodeIfPresent(Double.self, forKey: .highLatencyMs) {
            self.threshold = AlertThreshold(comparison: .greaterThanOrEqual, value: legacyLatency)
        } else {
            self.threshold = defaults.threshold
        }

        consecutive = try c.decodeIfPresent(Int.self, forKey: .consecutive)
            ?? c.decodeIfPresent(Int.self, forKey: .highLatencyConsecutive)
            ?? defaults.consecutive
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(preset, forKey: .preset)
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(threshold, forKey: .threshold)
        try c.encode(consecutive, forKey: .consecutive)
        try c.encode(cooldown, forKey: .cooldown)
        try c.encode(notifyOnRecovery, forKey: .notifyOnRecovery)
    }

    public static func preset(_ preset: AlertPreset) -> EntityAlertPolicy {
        switch preset {
        case .quiet:
            return EntityAlertPolicy(preset: .quiet, threshold: AlertThreshold(comparison: .greaterThanOrEqual, value: 250), consecutive: 10, cooldown: 300, notifyOnRecovery: false)
        case .balanced:
            return EntityAlertPolicy(preset: .balanced, threshold: AlertThreshold(comparison: .greaterThanOrEqual, value: 250), consecutive: 5, cooldown: 300, notifyOnRecovery: true)
        case .verbose:
            return EntityAlertPolicy(preset: .verbose, threshold: AlertThreshold(comparison: .greaterThanOrEqual, value: 250), consecutive: 3, cooldown: 300, notifyOnRecovery: true)
        case .custom:
            return EntityAlertPolicy(preset: .custom)
        }
    }

    /// Compatibility for existing Ping rule translation. New callers should use `threshold`.
    public var highLatencyMs: Double {
        get { threshold?.value ?? 250 }
        set { threshold = AlertThreshold(comparison: .greaterThanOrEqual, value: newValue) }
    }

    /// Compatibility for existing Ping rule translation. New callers should use `consecutive`.
    public var highLatencyConsecutive: Int {
        get { consecutive }
        set { consecutive = newValue }
    }
}

public typealias AlertPolicy = EntityAlertPolicy

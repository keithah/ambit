import Foundation

// Generic alerting policy (shaped by pingscope's NotificationRuleSet, reusable per "thing").
// Verbosity presets set cooldown, recovery, and high-latency sensitivity; integrations turn
// a policy into concrete AlertRules. The network-diagnosis-specific knobs (loss ratio,
// diagnosis sensitivity) stay in the pingscope integration (M6).

public enum AlertPreset: String, Codable, Sendable, CaseIterable {
    case quiet, balanced, verbose, custom
}

public struct AlertPolicy: Codable, Equatable, Sendable {
    public var preset: AlertPreset
    public var enabled: Bool
    public var cooldown: TimeInterval          // min seconds between repeats of the same alert
    public var notifyOnRecovery: Bool
    public var highLatencyMs: Double           // latency at/above which (when sustained) is high
    public var highLatencyConsecutive: Int     // consecutive elevated samples before alerting

    public init(
        preset: AlertPreset = .balanced,
        enabled: Bool = true,
        cooldown: TimeInterval = 300,
        notifyOnRecovery: Bool = true,
        highLatencyMs: Double = 250,
        highLatencyConsecutive: Int = 5
    ) {
        self.preset = preset
        self.enabled = enabled
        self.cooldown = cooldown
        self.notifyOnRecovery = notifyOnRecovery
        self.highLatencyMs = highLatencyMs
        self.highLatencyConsecutive = highLatencyConsecutive
    }

    /// Preset → policy (numbers ported from the oracle: quiet 10 / balanced 5 / verbose 3
    /// consecutive high-latency samples; 300s cooldown; recovery off only for quiet).
    public static func preset(_ preset: AlertPreset) -> AlertPolicy {
        switch preset {
        case .quiet:
            return AlertPolicy(preset: .quiet, cooldown: 300, notifyOnRecovery: false, highLatencyMs: 250, highLatencyConsecutive: 10)
        case .balanced:
            return AlertPolicy(preset: .balanced, cooldown: 300, notifyOnRecovery: true, highLatencyMs: 250, highLatencyConsecutive: 5)
        case .verbose:
            return AlertPolicy(preset: .verbose, cooldown: 300, notifyOnRecovery: true, highLatencyMs: 250, highLatencyConsecutive: 3)
        case .custom:
            return AlertPolicy(preset: .custom)
        }
    }
}

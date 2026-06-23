import Foundation

// Generic health model (shaped by pingscope, validated against it as oracle). The rich
// HealthState is the eventual source of truth; the flat `Health` enum is a derived
// projection (`legacyHealth`), so the later full migration is "delete the flat path", not
// "reconcile two truths". Built-ins keep emitting flat Health for now.

public enum HealthStatus: String, Sendable, Codable, Equatable {
    case noData    // no sample yet
    case healthy
    case degraded
    case down
}

public extension HealthStatus {
    /// Projection onto the legacy flat `Health` enum (bridge during migration).
    var legacyHealth: Health {
        switch self {
        case .noData: return .unknown
        case .healthy: return .ok
        case .degraded: return .degraded
        case .down: return .down
        }
    }

    /// Lift a flat `Health` (e.g. from a snapshot) back to a status for presentation.
    init(legacy: Health) {
        switch legacy {
        case .unknown: self = .noData
        case .ok: self = .healthy
        case .degraded: self = .degraded
        case .down: self = .down
        }
    }
}

public struct HealthThresholds: Equatable, Sendable, Codable {
    /// Measurement value (in the metric's unit, e.g. latency ms) at or above which a
    /// successful sample is treated as degraded.
    public var degradedAt: Double
    /// Consecutive failing samples required to declare `.down`; clamped to ≥ 1.
    public var downAfterFailures: Int

    public init(degradedAt: Double = 100, downAfterFailures: Int = 3) {
        self.degradedAt = degradedAt
        self.downAfterFailures = max(1, downAfterFailures)
    }
}

/// Stateful evaluator: ingest a stream of samples to track status, consecutive failures, and
/// the most recent down/recovery transition timestamps. Pure value type — callers hold it
/// across polls (e.g. in an actor) to retain the failure count.
public struct HealthState: Equatable, Sendable {
    public private(set) var status: HealthStatus
    public private(set) var consecutiveFailures: Int
    public private(set) var lastFailureTransition: Date?
    public private(set) var lastRecoveryTransition: Date?

    public init() {
        status = .noData
        consecutiveFailures = 0
    }

    public var legacyHealth: Health { status.legacyHealth }

    /// Ingest one sample. `ok` is the success flag; `value` is the measurement when present
    /// (used for the degraded threshold on successes).
    public mutating func ingest(value: Double?, ok: Bool, thresholds: HealthThresholds, at timestamp: Date) {
        let previous = status
        if ok {
            consecutiveFailures = 0
            if let value, value >= thresholds.degradedAt {
                status = .degraded
            } else {
                status = .healthy
            }
        } else {
            consecutiveFailures += 1
            status = consecutiveFailures >= thresholds.downAfterFailures ? .down : .degraded
        }
        if previous != .down, status == .down {
            lastFailureTransition = timestamp
        }
        if previous == .down, status == .healthy || status == .degraded {
            lastRecoveryTransition = timestamp
        }
    }
}

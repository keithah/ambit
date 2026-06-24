import Foundation

// Pure, UI-free. Folds freshness + health + the display threshold into a raw EntityState,
// producing the .stale availability and the per-entity Severity that every surface reads
// (presentation-model.md §4; P4 design §3a). No temporal state — staleness is a function of
// (lastUpdate, interval, now); the sustained-samples debounce for the display threshold lives
// in the AttentionEngine, not here.
//
// The severity rule is deterministic and documented (on-thesis: "never a black box"):
//   .unavailable → .down            genuinely offline; a strong, surfaceable signal
//   .stale       → .elevated        calm "paused"; SUPPRESS deeper fault inferred from old data
//   .online      → max(healthSeverity, displaySeverity, alertActive ? .alerting : .normal)
// Stale-suppression is load-bearing: a stale entity is capped at .elevated and never reports
// .degraded/.down/.alerting from data we did not collect (the per-entity analogue of the
// diagnoser's stale-suppression shipped in the hardening task).

public enum EntityEnricher {
    public struct Inputs: Sendable {
        public var descriptor: EntityDescriptor
        public var state: EntityState                  // raw, from EntityProjection
        public var interval: TimeInterval
        public var lastSampleAt: Date?                 // newest history sample for this entity
        public var displayThreshold: DisplayThreshold? // effective (override ?? descriptor.displayThreshold)
        public var health: HealthStatus?               // backing provider's health, when known
        public var alertActive: Bool                   // default false; true only via the caller overlay

        public init(
            descriptor: EntityDescriptor,
            state: EntityState,
            interval: TimeInterval,
            lastSampleAt: Date? = nil,
            displayThreshold: DisplayThreshold? = nil,
            health: HealthStatus? = nil,
            alertActive: Bool = false
        ) {
            self.descriptor = descriptor
            self.state = state
            self.interval = interval
            self.lastSampleAt = lastSampleAt
            self.displayThreshold = displayThreshold
            self.health = health
            self.alertActive = alertActive
        }
    }

    /// Enrich a raw state: downgrade `.online → .stale` past the freshness window and compute the
    /// per-entity severity. `value`/`lastUpdated`/`error` pass through unchanged.
    public static func enrich(_ input: Inputs, now: Date) -> EntityState {
        let availability = Staleness.availability(
            input.state.availability,
            lastUpdate: input.lastSampleAt,
            interval: input.interval,
            now: now
        )

        let severity = severity(for: input, availability: availability)

        var enriched = input.state
        enriched.availability = availability
        enriched.severity = severity
        return enriched
    }

    private static func severity(for input: Inputs, availability: Availability) -> Severity {
        switch availability {
        case .unavailable:
            return .down
        case .stale:
            // Stale-suppression: never infer a deeper fault from data we didn't collect.
            return .elevated
        case .online:
            return Swift.max(
                healthSeverity(input.health),
                displaySeverity(value: input.state.value, threshold: input.displayThreshold),
                input.alertActive ? .alerting : .normal
            )
        }
    }

    private static func healthSeverity(_ health: HealthStatus?) -> Severity {
        switch health {
        case .degraded: return .degraded
        case .down: return .down
        case .healthy, .noData, .none: return .normal
        }
    }

    /// `.elevated` when the entity's numeric value crosses its display threshold. No consecutive
    /// debounce here — that is the AttentionEngine's temporal concern (P4.4).
    private static func displaySeverity(value: EntityValue?, threshold: DisplayThreshold?) -> Severity {
        guard let threshold, case .number(let n)? = value else { return .normal }
        return threshold.comparison.matches(n, threshold: threshold.value) ? .elevated : .normal
    }
}

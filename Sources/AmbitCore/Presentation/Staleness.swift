import Foundation

// Pure, UI-free data-freshness primitive. Staleness is a function of (lastUpdate, interval, now)
// recomputed against wall-clock `now` — NOT a value stamped once at poll time — so a stalled poll
// loop (which produces no new snapshots) still flips entities to `.stale` when a time-driven tick
// re-evaluates. The tick + the diagnoser live elsewhere; this file is just the rule.

public enum Staleness {
    /// Grace before missing data counts as stale: `max(interval × factor, floor)`.
    public static func window(interval: TimeInterval, factor: Int = 3, floor: TimeInterval = 10) -> TimeInterval {
        Swift.max(interval * Double(factor), floor)
    }

    /// True when there has been no fresh update within the window. A `nil` lastUpdate (never
    /// updated) is stale; a future timestamp (clock skew) is treated as fresh.
    public static func isStale(lastUpdate: Date?, interval: TimeInterval, now: Date,
                               factor: Int = 3, floor: TimeInterval = 10) -> Bool {
        guard let lastUpdate else { return true }
        return now.timeIntervalSince(lastUpdate) > window(interval: interval, factor: factor, floor: floor)
    }

    /// Downgrades `.online → .stale` when the backing data is stale. `.unavailable` (genuinely
    /// offline) and `.stale` pass through unchanged.
    public static func availability(_ base: Availability, lastUpdate: Date?, interval: TimeInterval, now: Date,
                                    factor: Int = 3, floor: TimeInterval = 10) -> Availability {
        guard base == .online else { return base }
        return isStale(lastUpdate: lastUpdate, interval: interval, now: now, factor: factor, floor: floor) ? .stale : .online
    }
}

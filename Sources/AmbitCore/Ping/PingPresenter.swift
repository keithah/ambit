import Foundation

// Pure presentation logic for the pingscope UI (no SwiftUI/AppKit). The SwiftUI views and the
// menu-bar/overlay AppKit code render from these; this is the part that stays unit-tested.

public enum TimeRange: String, CaseIterable, Sendable, Codable {
    case oneMinute, fiveMinutes, tenMinutes, oneHour

    public var seconds: TimeInterval {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .tenMinutes: return 600
        case .oneHour: return 3600
        }
    }

    public var label: String {
        switch self {
        case .oneMinute: return "1m"
        case .fiveMinutes: return "5m"
        case .tenMinutes: return "10m"
        case .oneHour: return "1h"
        }
    }
}

public enum LatencyTone: String, Sendable, Equatable {
    case neutral   // no/stale data → grey
    case good      // healthy → green
    case warn      // degraded → amber
    case bad       // down → red
}

public extension LatencyTone {
    init(_ status: HealthStatus) {
        switch status {
        case .noData: self = .neutral
        case .healthy: self = .good
        case .degraded: self = .warn
        case .down: self = .bad
        }
    }
}

/// The big-number readout + status line (popover header and per-host rows).
public struct LatencyReadout: Equatable, Sendable {
    public var text: String        // "15ms" or "--ms"
    public var tone: LatencyTone
    public var statusLabel: String // "Healthy" / "Degraded" / "Down" / "No Recent Data" / "No Data"
}

/// Menu-bar glyph: a status dot stacked over the latency text (matches the oracle).
public struct MenuBarGlyph: Equatable, Sendable {
    public var latencyText: String
    public var tone: LatencyTone
    public var itemWidth: Double
    public var fontSize: Double
    public var dotDiameter: Double

    public init(latencyText: String, tone: LatencyTone, itemWidth: Double = 34, fontSize: Double = 9.5, dotDiameter: Double = 8) {
        self.latencyText = latencyText
        self.tone = tone
        self.itemWidth = itemWidth
        self.fontSize = fontSize
        self.dotDiameter = dotDiameter
    }
}

public enum PingPresenter {
    /// Format milliseconds as a compact, rounded label; nil → "--ms".
    public static func format(ms: Double?) -> String {
        guard let ms else { return "--ms" }
        return "\(Int(ms.rounded()))ms"
    }

    /// Readout for a host given its latest sample and health, ageing out a stale latest result
    /// past the freshness window.
    public static func readout(latest: Sample?, health: HealthStatus, now: Date, freshness: TimeInterval) -> LatencyReadout {
        guard let latest else {
            return LatencyReadout(text: "--ms", tone: .neutral, statusLabel: "No Data")
        }
        if now.timeIntervalSince(latest.timestamp) > freshness {
            return LatencyReadout(text: "--ms", tone: .neutral, statusLabel: "No Recent Data")
        }
        let tone = LatencyTone(health)
        let status: String
        switch health {
        case .noData: status = "No Data"
        case .healthy: status = "Healthy"
        case .degraded: status = "Degraded"
        case .down: status = "Down"
        }
        return LatencyReadout(text: format(ms: latest.value), tone: tone, statusLabel: status)
    }

    public static func glyph(latest: Sample?, health: HealthStatus, now: Date, freshness: TimeInterval) -> MenuBarGlyph {
        let r = readout(latest: latest, health: health, now: now, freshness: freshness)
        return MenuBarGlyph(latencyText: r.text, tone: r.tone)
    }

    /// A readable axis maximum at or above the data max (rounded up to a clean 25ms step, so the
    /// midpoint is clean too); e.g. 107 → 125. Floors at 25ms for tiny series.
    public static func niceMax(_ values: [Double]) -> Double {
        let peak = values.max() ?? 0
        let step = 25.0
        return Swift.max(step, (peak / step).rounded(.up) * step)
    }

    /// Axis ticks (top, mid, baseline) for a graph maximum.
    public static func ticks(max: Double) -> [Double] { [max, max / 2, 0] }

    /// Samples within `range` of `now`, oldest→newest.
    public static func windowed(_ samples: [Sample], range: TimeRange, now: Date) -> [Sample] {
        let cutoff = now.addingTimeInterval(-range.seconds)
        return samples.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
    }
}

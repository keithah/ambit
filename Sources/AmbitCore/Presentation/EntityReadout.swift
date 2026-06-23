import Foundation

// Pure, UI-free formatting of an entity's current value into display text, an optional 0…1
// fraction (for gauges/progress), and a generic tone. AmbitUI maps DisplayTone to a Color.
// This replaces the ad-hoc per-metric formatting in the retired display models.

public struct EntityReadout: Equatable, Sendable {
    public var text: String
    public var fraction: Double?
    public var tone: DisplayTone

    public init(text: String, fraction: Double? = nil, tone: DisplayTone = .neutral) {
        self.text = text
        self.fraction = fraction
        self.tone = tone
    }

    public static func make(descriptor: EntityDescriptor, state: EntityState?) -> EntityReadout {
        guard let state else { return EntityReadout(text: "—", tone: .neutral) }

        let tone = displayTone(for: state)
        guard let value = state.value else {
            return EntityReadout(text: "—", tone: tone)
        }

        switch value {
        case .number(let n):
            return EntityReadout(text: format(n, descriptor: descriptor),
                                 fraction: fraction(n, descriptor: descriptor),
                                 tone: tone)
        case .bool(let b):
            return EntityReadout(text: b ? "Yes" : "No", tone: tone)
        case .text(let s):
            return EntityReadout(text: s, tone: tone)
        }
    }

    private static func displayTone(for state: EntityState) -> DisplayTone {
        if let severity = state.severity, severity >= .elevated { return tone(for: severity) }
        return toneFor(availability: state.availability)
    }

    private static func tone(for severity: Severity) -> DisplayTone {
        switch severity {
        case .normal: return .neutral
        case .elevated, .degraded: return .warn
        case .alerting, .down: return .bad
        }
    }

    private static func toneFor(availability: Availability) -> DisplayTone {
        switch availability {
        case .unavailable: return .bad
        case .stale: return .warn
        case .online: return .good
        }
    }

    public static func format(_ n: Double, deviceClass: DeviceClass?, unit: String?) -> String {
        switch deviceClass {
        case .latency: return "\(Int(n.rounded()))ms"
        case .percent, .battery: return "\(Int(n.rounded()))%"
        case .throughput: return formatThroughput(bitsPerSecond: n)
        case .count: return "\(Int(n.rounded()))"
        case .duration: return "\(Int(n.rounded()))s"
        case .power: return "\(Int(n.rounded()))W"
        case .connectivity, .none:
            if let unit { return "\(trim(n)) \(unit)" }
            return trim(n)
        }
    }

    private static func format(_ n: Double, descriptor: EntityDescriptor) -> String {
        format(n, deviceClass: descriptor.deviceClass, unit: descriptor.unit)
    }

    private static func fraction(_ n: Double, descriptor: EntityDescriptor) -> Double? {
        switch descriptor.deviceClass {
        case .percent, .battery:
            let maxV = descriptor.range?.max ?? 100
            guard maxV > 0 else { return nil }
            return Swift.min(Swift.max(n / maxV, 0), 1)
        default:
            return nil
        }
    }

    private static func trim(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
    }

    private static func formatThroughput(bitsPerSecond bps: Double) -> String {
        let mbps = bps / 1_000_000
        if mbps >= 1 { return String(format: "%.1f Mbps", mbps) }
        return String(format: "%.0f Kbps", bps / 1_000)
    }
}

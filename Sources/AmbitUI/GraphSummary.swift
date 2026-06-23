import Foundation
import AmbitCore

/// One labeled summary value (Min/Avg/Max) for a graph's windowed series.
public struct GraphSummaryItem: Equatable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}

/// Value-side windowed summary for a single measurement series — generic, not pingscope-specific.
public enum GraphSummary {
    public static func minAvgMax(samples: [Sample], deviceClass: DeviceClass?, unit: String?) -> [GraphSummaryItem] {
        let stats = SampleStats.from(samples)
        guard let min = stats.min, let avg = stats.avg, let max = stats.max else { return [] }
        func f(_ v: Double) -> String { EntityReadout.format(v, deviceClass: deviceClass, unit: unit) }
        return [
            GraphSummaryItem(label: "Min", value: f(min)),
            GraphSummaryItem(label: "Avg", value: f(avg)),
            GraphSummaryItem(label: "Max", value: f(max))
        ]
    }
}

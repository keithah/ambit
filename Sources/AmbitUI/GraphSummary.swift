import Foundation
import AmbitCore

/// One labeled summary value for a graph's windowed series.
public struct GraphSummaryItem: Equatable, Sendable {
    public let label: String
    public let value: String
    public init(label: String, value: String) { self.label = label; self.value = value }
}

/// Value-side windowed summary for a single measurement series.
public enum GraphSummary {
    public static func summary(samples: [Sample], deviceClass: DeviceClass?, unit: String?) -> [GraphSummaryItem] {
        guard !samples.isEmpty else { return [] }
        let stats = SampleStats.from(samples)
        func value(_ v: Double?) -> String { v.map { EntityReadout.format($0, deviceClass: deviceClass, unit: unit) } ?? "—" }

        if deviceClass == .latency {
            return [
                GraphSummaryItem(label: "TX", value: "\(stats.transmitted)"),
                GraphSummaryItem(label: "RX", value: "\(stats.received)"),
                GraphSummaryItem(label: "Loss", value: "\(Int(stats.lossPercent.rounded()))%"),
                GraphSummaryItem(label: "Min", value: value(stats.min)),
                GraphSummaryItem(label: "Avg", value: value(stats.avg)),
                GraphSummaryItem(label: "Max", value: value(stats.max))
            ]
        }

        guard let current = samples.last(where: { $0.value != nil })?.value else { return [] }
        return [
            GraphSummaryItem(label: "Min", value: value(stats.min)),
            GraphSummaryItem(label: "Avg", value: value(stats.avg)),
            GraphSummaryItem(label: "Max", value: value(stats.max)),
            GraphSummaryItem(label: "Current", value: value(current))
        ]
    }
}

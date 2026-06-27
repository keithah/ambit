import SwiftUI
import AmbitCore

/// Two related series (up/down throughput, user/system %). Thin specialization of the
/// history graph that always shows a legend for the two lines.
public struct DualLineGraphCard: View {
    let title: String
    let lines: [GraphLine]
    let axis: GraphAxis?
    let deviceClass: DeviceClass?
    let unit: String?
    var hasDrawableSeries: Bool {
        lines.contains { line in
            line.samples.filter { $0.ok && $0.value != nil }.count > 1
        }
    }

    public init(title: String, lines: [GraphLine], axis: GraphAxis? = nil, deviceClass: DeviceClass? = nil, unit: String? = nil) {
        self.title = title
        self.lines = Array(lines.prefix(2))
        self.axis = axis
        self.deviceClass = deviceClass
        self.unit = unit
    }

    public var body: some View {
        HistoryGraphCard(title: title, lines: lines, axis: axis, deviceClass: deviceClass, unit: unit, showLegend: true)
    }
}

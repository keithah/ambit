import SwiftUI

/// Two related series (up/down throughput, user/system %). Thin specialization of the
/// history graph that always shows a legend for the two lines.
public struct DualLineGraphCard: View {
    let title: String
    let lines: [GraphLine]
    public init(title: String, lines: [GraphLine]) {
        self.title = title
        self.lines = Array(lines.prefix(2))
    }
    public var body: some View {
        HistoryGraphCard(title: title, lines: lines, showLegend: true)
    }
}

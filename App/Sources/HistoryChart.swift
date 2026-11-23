import AmbitKit
import Charts
import SwiftUI

/// A latency graph with a choice of the last 30 minutes or the last 24 hours. Probes that got no
/// reply are red rules. Time with no samples, such as while Ambit was not running, is left empty.
struct HistoryChart: View {
    let model: AppModel
    /// Nil for the connection itself.
    let device: UUID?
    /// What is being measured, for VoiceOver: "Internet latency".
    let label: String
    /// The last half hour, oldest first.
    let recent: [ProbeSample]

    @State private var showsDay = false
    @State private var day: [ProbeSample] = []

    var body: some View {
        let end = Date()
        let start = end.addingTimeInterval(showsDay ? -86_400 : -AppModel.graphSpan)
        let samples = (showsDay ? day : recent).filter { $0.date >= start && $0.date <= end }
        // A pause of more than a few samples is a gap, not a line.
        let runs = samples.runs(brokenBy: showsDay ? 900 : 60)
        VStack(alignment: .trailing, spacing: 4) {
            Chart {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    if let ms = sample.latencyMs {
                        LineMark(x: .value("Time", sample.date), y: .value("Latency", ms), series: .value("Run", runs[index]))
                            .foregroundStyle(.green)
                            .interpolationMethod(.monotone)
                    } else {
                        RuleMark(x: .value("Time", sample.date))
                            .foregroundStyle(.red.opacity(0.6))
                    }
                }
            }
            .chartXScale(domain: start...end)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let ms = value.as(Double.self) { Text("\(Int(ms)) ms").font(.system(size: 9)) }
                    }
                }
            }
            .frame(height: 56)
            .accessibilityLabel("\(label), last \(showsDay ? "24 hours" : "30 minutes")")
            Picker("Graph covers", selection: $showsDay) {
                Text("30 min").tag(false)
                Text("24 h").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .labelsHidden()
            .fixedSize()
        }
        // Read again each time the 24-hour graph is chosen and each time the popover opens.
        .task(id: [showsDay ? 1 : 0, model.popoverClosures]) {
            if showsDay { day = await model.dayHistory(device: device) }
        }
    }
}

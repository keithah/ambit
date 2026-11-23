import AmbitKit
import SwiftUI

struct PingRow: View {
    let device: SavedDevice
    let reading: PingReading

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .frame(width: 22)
                .foregroundStyle(DeviceText.color(reading.condition))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                Text(PingText.summary(reading)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if let ms = PingText.latency(reading) {
                Text("\(ms) ms")
                    .font(.system(size: 13).monospacedDigit())
                    .accessibilityLabel("\(ms) milliseconds")
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PingDetail: View {
    let model: AppModel
    let device: SavedDevice
    let close: () -> Void
    @State private var failure: String?

    var body: some View {
        let reading = model.pings[device.id] ?? PingReading()
        let stats = HopStats(samples: reading.samples)
        VStack(alignment: .leading, spacing: 10) {
            if let problem = PingText.problem(reading.condition) {
                Text(problem).font(.system(size: 13)).foregroundStyle(DeviceText.color(reading.condition))
            }
            HistoryChart(model: model, device: device.id, label: "Latency to \(device.name)", recent: reading.samples)
            DetailLine(label: "Latency", value: PingText.latency(reading).map { "\($0) ms" } ?? "–")
            DetailLine(
                label: "No reply",
                value: stats.sampleCount == 0 ? "–" : "\(Int((stats.lossFraction * Double(stats.sampleCount)).rounded())) of the last \(stats.sampleCount)"
            )
            DetailLine(label: "Address", value: device.host)
            Text("A ping target is shown here only. It does not change what Ambit says about your connection.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.red)
            }
            Divider()
            ConfirmedButton(title: "Remove ping target", question: "Remove \(device.name) from Ambit?") {
                failure = model.remove(device.id)
                if failure == nil { close() }
            }
        }
    }
}

private enum PingText {
    /// The latest latency, while the target is answering.
    static func latency(_ reading: PingReading) -> String? {
        guard reading.condition == .online else { return nil }
        return DeviceText.whole(reading.samples.last?.latencyMs)
    }

    static func problem(_ condition: DeviceCondition) -> String? {
        switch condition {
        case .unreachable: "No reply. The address may be wrong, or it may not answer pings."
        default: DeviceText.problem(condition, noun: "ping target")
        }
    }

    static func summary(_ reading: PingReading) -> String {
        problem(reading.condition) ?? "Answering"
    }
}

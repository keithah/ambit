import AmbitKit
import SwiftUI

struct StarlinkRow: View {
    let device: SavedDevice
    let reading: StarlinkReading

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .frame(width: 22)
                .foregroundStyle(DeviceText.color(reading.condition))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.system(size: 13))
                Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if showsReadings, let status = reading.status, status.isOnline {
                Text("↓ \(DeviceText.megabits(status.downlinkBps)) Mbps")
                    .font(.system(size: 13).monospacedDigit())
                    .accessibilityLabel("Download \(DeviceText.megabits(status.downlinkBps)) megabits per second")
            }
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var showsReadings: Bool {
        if case .stale = reading.condition { return true }
        return reading.condition == .online
    }

    private var summary: String {
        if let problem = DeviceText.problem(reading.condition, noun: "dish") { return problem }
        guard let status = reading.status else { return "Online" }
        if let outage = status.outage { return outage.text }
        return DeviceText.whole(status.latencyMs).map { "Online · \($0) ms" } ?? "Online"
    }
}

struct StarlinkDetail: View {
    let model: AppModel
    let device: SavedDevice
    let close: () -> Void
    @State private var failure: String?

    var body: some View {
        let reading = model.dishes[device.id] ?? StarlinkReading()
        let status = reading.status
        VStack(alignment: .leading, spacing: 10) {
            if let problem = DeviceText.problem(reading.condition, noun: "dish") {
                Text(problem).font(.system(size: 13)).foregroundStyle(DeviceText.color(reading.condition))
            }
            HStack(spacing: 8) {
                tile("Down", DeviceText.megabits(status?.downlinkBps), "Mbps")
                tile("Up", DeviceText.megabits(status?.uplinkBps), "Mbps")
                tile("Ping", DeviceText.whole(status?.latencyMs) ?? "–", "ms")
            }
            DetailLine(label: "State", value: status.map { $0.outage?.text ?? "Online" } ?? "–")
            DetailLine(label: "Obstructed", value: status?.fractionObstructed.map { String(format: "%.1f%% of the time", $0 * 100) } ?? "–")
            DetailLine(label: "Running for", value: DeviceText.uptime(status?.uptimeSeconds.map(Double.init)))
            DetailLine(label: "Software", value: status?.softwareVersion ?? "–")
            DetailLine(label: "Address", value: device.host)
            Divider()
            ConfirmedButton(title: "Reboot", question: "Reboot the dish? You'll be offline for a few minutes.") {
                failure = await model.rebootDish(device.id)
            }
            .disabled(model.busy.contains(device.id))
            let stowed = status?.stowRequested ?? false
            ConfirmedButton(
                title: stowed ? "Unstow" : "Stow",
                question: stowed ? "Unstow the dish?" : "Stow the dish? It goes offline until you unstow it."
            ) {
                failure = await model.setDishStowed(!stowed, device.id)
            }
            // If the dish changes state while the question is open, the question goes away.
            .id(stowed)
            .disabled(model.busy.contains(device.id))
            if let failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(.red)
            }
            Divider()
            ConfirmedButton(title: "Remove device", question: "Remove \(device.name) from Ambit?") {
                failure = model.remove(device.id)
                if failure == nil { close() }
            }
        }
    }

    private func tile(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .medium).monospacedDigit())
            Text("\(label) · \(unit)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value) \(unit)")
    }
}

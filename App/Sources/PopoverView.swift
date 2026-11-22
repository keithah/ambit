import AmbitKit
import Charts
import SwiftUI

struct PopoverView: View {
    let model: AppModel
    let checkForUpdates: () -> Void

    private enum Page: Equatable {
        case main, device(UUID), add
    }

    @State private var page = Page.main

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch page {
            case .main:
                main
            case .device(let id):
                if let device = model.devices.first(where: { $0.id == id }) {
                    titleBar(device.name)
                    switch device.kind {
                    case .starlink: StarlinkDetail(model: model, device: device) { page = .main }
                    case .glinet: RouterDetail(model: model, device: device) { page = .main }
                    }
                } else {
                    main
                }
            case .add:
                titleBar("Add device")
                AddDeviceView(model: model) { page = .main }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onChange(of: model.popoverClosures) { page = .main }
    }

    @ViewBuilder
    private var main: some View {
        let snapshot = model.snapshot
        header(snapshot)
        Text(hopLine(snapshot))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        LatencyChart(samples: snapshot.internetHistory)
            .frame(height: 56)
        Divider()
        // The popover grows to fit its content, so a long list would push the footer off the screen.
        // A short list is laid out as before; a scroll view has no height of its own to grow to.
        if model.devices.count > Self.rowsBeforeScrolling {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) { deviceRows }
            }
            .frame(height: 300)
            Divider()
        } else {
            deviceRows
        }
        footer(snapshot)
    }

    private static let rowsBeforeScrolling = 6

    @ViewBuilder
    private var deviceRows: some View {
        ForEach(model.devices) { device in
            Button {
                page = .device(device.id)
            } label: {
                switch device.kind {
                case .starlink: StarlinkRow(device: device, reading: model.dishes[device.id] ?? StarlinkReading())
                case .glinet: RouterRow(device: device, reading: model.routers[device.id] ?? RouterReading())
                }
            }
            .buttonStyle(.plain)
            Divider()
        }
    }

    private func titleBar(_ title: String) -> some View {
        HStack(spacing: 6) {
            Button {
                page = .main
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Back")
            Text(title).font(.system(size: 15, weight: .semibold))
        }
    }

    @ViewBuilder
    private func header(_ snapshot: DiagnosisSnapshot) -> some View {
        let health = snapshot.verdict.health
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(health.color).frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                Text(snapshot.verdict.title).font(.system(size: 15, weight: .semibold))
            }
            Text(detailLine(snapshot))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(health == .offline || health == .degraded ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (health == .offline || health == .degraded ? health.color.opacity(0.12) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .accessibilityElement(children: .combine)
    }

    private func footer(_ snapshot: DiagnosisSnapshot) -> some View {
        HStack {
            Button("Add device") { page = .add }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            if let updated = snapshot.updated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Check for updates…", action: checkForUpdates)
                Divider()
                Button("Quit Ambit") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Settings")
        }
    }

    private func detailLine(_ snapshot: DiagnosisSnapshot) -> String {
        guard snapshot.verdict.health == .offline || snapshot.verdict.health == .degraded else {
            return snapshot.verdict.detail
        }
        let since = snapshot.since.formatted(date: .omitted, time: .shortened)
        return "\(snapshot.verdict.detail) Since \(since)."
    }

    private func hopLine(_ snapshot: DiagnosisSnapshot) -> String {
        func reading(_ name: String, _ stats: HopStats) -> String {
            guard stats.sampleCount > 0 else { return "\(name) –" }
            guard let ms = stats.lastMs else { return "\(name) no reply" }
            return "\(name) \(Int(ms.rounded())) ms"
        }
        return [reading("Router", snapshot.router), reading("Internet", snapshot.internet), reading("DNS", snapshot.dns)]
            .joined(separator: " · ")
    }
}

/// Internet latency over the retained window; failed probes are drawn as red rules.
private struct LatencyChart: View {
    let samples: [ProbeSample]

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                if let ms = sample.latencyMs {
                    LineMark(x: .value("Time", sample.date), y: .value("Latency", ms))
                        .foregroundStyle(.green)
                        .interpolationMethod(.monotone)
                } else {
                    RuleMark(x: .value("Time", sample.date))
                        .foregroundStyle(.red.opacity(0.6))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let ms = value.as(Double.self) { Text("\(Int(ms)) ms").font(.system(size: 9)) }
                }
            }
        }
        .accessibilityLabel("Internet latency, last 30 minutes")
    }
}

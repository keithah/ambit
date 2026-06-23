import AppKit
import AmbitCore
import SwiftUI

// MARK: - Display model

struct PingHostDisplay: Identifiable, Equatable {
    var id: String { instanceID.rawValue }
    let instanceID: IntegrationInstanceID
    let providerInstanceID: ProviderInstanceID
    let latencyEntityID: EntityID
    let name: String
    let detail: String
    var samples: [Sample]
    var readout: LatencyReadout
    var stats: SampleStats
    var isPrimary: Bool
    var colorIndex: Int

    var color: Color { PingScopeColors.line(colorIndex) }
}

enum PingScopeColors {
    static let palette: [Color] = [
        Color(red: 0.23, green: 0.51, blue: 0.96),  // blue
        Color(red: 0.20, green: 0.78, blue: 0.35),  // green
        Color(red: 1.00, green: 0.62, blue: 0.26),  // orange
        Color(red: 0.69, green: 0.45, blue: 0.95),  // purple
        Color(red: 0.30, green: 0.78, blue: 0.85)   // teal
    ]
    static func line(_ index: Int) -> Color { palette[index % palette.count] }

    static func tone(_ tone: LatencyTone) -> Color {
        switch tone {
        case .neutral: return .secondary
        case .good: return Color(red: 0.20, green: 0.78, blue: 0.35)
        case .warn: return Color(red: 0.90, green: 0.70, blue: 0.29)
        case .bad: return Color(red: 1.0, green: 0.32, blue: 0.28)
        }
    }
}

// MARK: - Menu-bar glyph (stacked dot over latency)

enum PingScopeGlyphRenderer {
    static func image(_ glyph: MenuBarGlyph) -> NSImage {
        let width = glyph.itemWidth, height = 22.0
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let dot = NSBezierPath(ovalIn: NSRect(x: (width - glyph.dotDiameter) / 2, y: height - glyph.dotDiameter - 1, width: glyph.dotDiameter, height: glyph.dotDiameter))
        nsColor(glyph.tone).setFill()
        dot.fill()
        let text = NSAttributedString(string: glyph.latencyText, attributes: [
            .font: NSFont.systemFont(ofSize: glyph.fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (width - size.width) / 2, y: 0))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func nsColor(_ tone: LatencyTone) -> NSColor {
        switch tone {
        case .neutral: return .secondaryLabelColor
        case .good: return .systemGreen
        case .warn: return .systemYellow
        case .bad: return .systemRed
        }
    }
}

// MARK: - Popover

struct PingScopePopover: View {
    @EnvironmentObject private var viewModel: StatusViewModel

    private var gearIcon: some View {
        Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
    }

    private var hosts: [PingHostDisplay] { viewModel.pingHosts }
    private var isAllHosts: Bool { viewModel.pingScopeSelection == nil }
    private var focus: PingHostDisplay? {
        if let id = viewModel.pingScopeSelection { return hosts.first { $0.instanceID == id } }
        return hosts.first { $0.isPrimary } ?? hosts.first
    }
    private var axisMax: Double {
        let values = (isAllHosts ? hosts : focus.map { [$0] } ?? []).flatMap { $0.samples.compactMap(\.value) }
        return PingScopePresenter.niceMax(values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rangePicker
            graph
            diagnosisBanner
            stats
            recentSamples
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 420, height: 640, alignment: .topLeading)
        .background(Color(red: 0.055, green: 0.055, blue: 0.07))
    }

    // header: selector + big ms + health + gear
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    Button("All Hosts") { viewModel.selectPingScopeHost(nil) }
                    Divider()
                    ForEach(hosts) { host in
                        Button(host.name) { viewModel.selectPingScopeHost(host.instanceID) }
                    }
                } label: {
                    Text(isAllHosts ? "All Hosts" : (focus?.name ?? "—"))
                        .font(.system(size: 14, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Text(isAllHosts ? "\(hosts.count) enabled hosts" : (focus?.detail ?? ""))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(focus?.readout.text ?? "--ms")
                    .font(.system(size: 25, weight: .bold))
                HStack(spacing: 6) {
                    Circle().fill(PingScopeColors.tone(focus?.readout.tone ?? .neutral)).frame(width: 9, height: 9)
                    Text(focus?.readout.statusLabel ?? "No Data")
                        .font(.system(size: 13))
                        .foregroundStyle(PingScopeColors.tone(focus?.readout.tone ?? .neutral))
                }
            }
            Button {
                viewModel.toggleOverlay?()
            } label: {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .help("Toggle floating overlay")
            Button { viewModel.openSettings?() } label: { gearIcon }
                .buttonStyle(.plain)
                .padding(.leading, 4)
        }
    }

    @ViewBuilder private var diagnosisBanner: some View {
        if let d = viewModel.pingDiagnosis, d.scope != .allReachable, d.scope != .noData {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(bannerTone(d))
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.title).font(.system(size: 12.5, weight: .semibold))
                    Text(d.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if d.confidence == .tentative {
                    Text("tentative").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(bannerTone(d).opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private func bannerTone(_ d: NetworkPerspectiveDiagnosis) -> Color {
        switch d.verdict {
        case .partialDegradation, .remoteServiceDown: return Color(red: 0.90, green: 0.70, blue: 0.29)
        default: return Color(red: 1.0, green: 0.32, blue: 0.28)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 14) {
            Text("Range").font(.system(size: 14, weight: .semibold))
            Picker("", selection: Binding(get: { viewModel.pingScopeRange }, set: { viewModel.setPingScopeRange($0) })) {
                ForEach(TimeRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
    }

    private var graphSeries: [(color: Color, samples: [Sample])] {
        if isAllHosts { return hosts.map { ($0.color, $0.samples) } }
        return focus.map { [($0.color, $0.samples)] } ?? []
    }

    private var graph: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing) {
                Text("\(Int(axisMax))ms"); Spacer(); Text("\(Int(axisMax / 2))ms"); Spacer(); Text("0ms")
            }
            .font(.system(size: 10.5)).foregroundStyle(Color.secondary.opacity(0.6))
            .frame(width: 40, height: 130)
            LatencyGraph(series: graphSeries, axisMax: axisMax).frame(height: 130)
        }
        .overlay(alignment: .bottom) {
            if isAllHosts, !hosts.isEmpty { legend }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(hosts) { host in
                HStack(spacing: 5) {
                    Circle().fill(host.color).frame(width: 8, height: 8)
                    Text(host.name).font(.system(size: 11.5)).foregroundStyle(Color(white: 0.82))
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Color(white: 0.18).opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 8)
    }

    private var stats: some View {
        let s = focus?.stats ?? SampleStats()
        return Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 12) {
            GridRow {
                stat("TX", "\(s.transmitted)"); stat("RX", "\(s.received)"); stat("Loss", "\(Int(s.lossPercent))%")
            }
            GridRow {
                stat("Min", PingScopePresenter.format(ms: s.min)); stat("Avg", PingScopePresenter.format(ms: s.avg)); stat("Max", PingScopePresenter.format(ms: s.max))
            }
        }
    }

    private func stat(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentSamples: some View {
        let rows = Array((focus?.samples.reversed() ?? []).prefix(6))
        return VStack(spacing: 0) {
            HStack {
                Text("Time").frame(maxWidth: .infinity, alignment: .leading)
                Text("Result").frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider() }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, sample in
                HStack {
                    Text(Self.time.string(from: sample.timestamp)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(PingScopePresenter.format(ms: sample.value)).font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(sample.ok ? "OK" : "FAIL").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 13))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(index.isMultiple(of: 2) ? Color.clear : Color(white: 0.11))
            }
        }
        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08)))
    }

    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}

struct LatencyGraph: View {
    let series: [(color: Color, samples: [Sample])]
    let axisMax: Double

    var body: some View {
        Canvas { context, size in
            for fraction in [0.0, 0.5, 1.0] {
                let y = size.height * (1 - fraction)
                var line = Path(); line.move(to: CGPoint(x: 0, y: y)); line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.white.opacity(0.07)), lineWidth: 1)
            }
            guard axisMax > 0 else { return }
            for entry in series where entry.samples.count > 1 {
                var path = Path()
                for (index, sample) in entry.samples.enumerated() {
                    let x = size.width * Double(index) / Double(entry.samples.count - 1)
                    let value = sample.value ?? 0
                    let y = size.height * (1 - min(value / axisMax, 1))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(entry.color), lineWidth: 1.5)
            }
        }
    }
}

import AppKit
import AmbitCore
import AmbitUI
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

    private var hostOptions: [InstanceSelectorCard.Option] {
        viewModel.pingHosts.map { .init(id: $0.instanceID.rawValue, label: $0.name) }
    }
    private var focus: PingHostDisplay? {
        if let id = viewModel.pingScopeSelection { return viewModel.pingHosts.first { $0.instanceID == id } }
        return viewModel.pingHosts.first { $0.isPrimary } ?? viewModel.pingHosts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            rangePicker
            SurfaceView(plan: viewModel.surfacePlan, data: viewModel.surfaceData)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 420, height: 640, alignment: .topLeading)
        .background(Color(red: 0.055, green: 0.055, blue: 0.07))
    }

    private var header: some View {
        HStack(alignment: .top) {
            InstanceSelectorCard(
                options: hostOptions,
                selectedID: viewModel.pingScopeSelection?.rawValue,
                onSelect: { viewModel.selectPingScopeHost($0.map { IntegrationInstanceID(rawValue: $0) }) },
                allLabel: "All Hosts"
            )
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(focus?.readout.text ?? "--ms").font(.system(size: 25, weight: .bold))
                HStack(spacing: 6) {
                    Circle().fill(PingScopeColors.tone(focus?.readout.tone ?? .neutral)).frame(width: 9, height: 9)
                    Text(focus?.readout.statusLabel ?? "No Data")
                        .font(.system(size: 13)).foregroundStyle(PingScopeColors.tone(focus?.readout.tone ?? .neutral))
                }
            }
            Button { viewModel.toggleOverlay?() } label: {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 6).help("Toggle floating overlay")
            Button { viewModel.openSettings?() } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 4)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 14) {
            Text("Range").font(.system(size: 14, weight: .semibold))
            Picker("", selection: Binding(get: { viewModel.pingScopeRange }, set: { viewModel.setPingScopeRange($0) })) {
                ForEach(TimeRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Spacer()
        }
    }
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

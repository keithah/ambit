import AppKit
import AmbitCore
import AmbitUI
import SwiftUI

// MARK: - Generic menu-bar glyph renderer

/// Renders a stacked "dot over latency text" NSImage for any slot's bar readout.
/// Renamed from PingGlyphRenderer — this type does generic chrome, not Ping-specific UI.
enum StatusGlyphRenderer {
    static func image(_ glyph: MenuBarGlyph) -> NSImage {
        let width = glyph.itemWidth, height = 22.0
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let dot = NSBezierPath(ovalIn: NSRect(
            x: (width - glyph.dotDiameter) / 2,
            y: height - glyph.dotDiameter - 1,
            width: glyph.dotDiameter, height: glyph.dotDiameter))
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

// MARK: - Generic slot popover

/// One popover per slot. Reads SlotSurface from viewModel.slotSurfaces[slotID].
/// Layout is identical to the retired PingPopover (420x640, dark bg).
struct SlotPopover: View {
    let slotID: SlotID
    @EnvironmentObject private var viewModel: StatusViewModel

    private var surface: SlotSurface {
        viewModel.slotSurfaces[slotID] ?? .empty
    }
    private var focus: IntegrationInstanceID? {
        viewModel.slotFocus[slotID]
    }
    /// The range picker drives the global ping window (P3). Show it only on the ping slot so a
    /// future non-ping slot's popover never binds/mutates ping state. Per-slot range is P5.
    private var isPingSlot: Bool {
        if case .integrationType(IntegrationIDs.ping)? = viewModel.slots.first(where: { $0.id == slotID })?.selection {
            return true
        }
        return false
    }
    private var focusReadout: (text: String, tone: LatencyTone, statusLabel: String) {
        // Derive readout from the glyph (glyph already holds primary-entity data).
        // When focused on a specific host, the glyph is already recomputed for that host.
        let g = surface.glyph
        let label: String
        switch g.tone {
        case .neutral: label = "No Data"
        case .good: label = "Healthy"
        case .warn: label = "Degraded"
        case .bad: label = "Down"
        }
        return (g.latencyText, g.tone, label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isPingSlot { rangePicker }
            SurfaceView(plan: surface.plan, data: surface.data)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 420, height: 640, alignment: .topLeading)
        .background(Color(red: 0.055, green: 0.055, blue: 0.07))
    }

    private var header: some View {
        HStack(alignment: .top) {
            if surface.hostOptions.count > 1 {
                InstanceSelectorCard(
                    options: surface.hostOptions,
                    selectedID: focus?.rawValue,
                    onSelect: { rawID in
                        viewModel.selectInstance(slotID, rawID.map { IntegrationInstanceID(rawValue: $0) })
                    },
                    allLabel: "All Hosts"
                )
            } else {
                // Single host or no options: show the slot title as plain text.
                Text(viewModel.slots.first(where: { $0.id == slotID })?.title ?? "Ping")
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(focusReadout.text).font(.system(size: 25, weight: .bold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(DisplayTone(latencyTone: focusReadout.tone).color)
                        .frame(width: 9, height: 9)
                    Text(focusReadout.statusLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(DisplayTone(latencyTone: focusReadout.tone).color)
                }
            }
            Button { viewModel.toggleOverlay?() } label: {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 6).help("Toggle floating overlay")
            Button { viewModel.openSettings?() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).padding(.leading, 4)
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 14) {
            Text("Range").font(.system(size: 14, weight: .semibold))
            Picker("", selection: Binding(
                get: { viewModel.pingRange },
                set: { viewModel.setPingRange($0) }
            )) {
                ForEach(TimeRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Spacer()
        }
    }
}

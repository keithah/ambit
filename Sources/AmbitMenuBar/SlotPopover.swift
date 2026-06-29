import AppKit
import AmbitCore
import AmbitUI
import SwiftUI

// MARK: - Generic menu-bar glyph renderer

/// Renders a stacked "dot over latency text" NSImage for any slot's bar readout.
/// Renamed from PingGlyphRenderer — this type does generic chrome, not Ping-specific UI.
enum StatusGlyphRenderer {
    struct Layout: Equatable {
        var dotX: Double
        var dotY: Double
        var dotDiameter: Double
        var textBaselineY: Double
        var fontSize: Double
    }

    static func layout(for glyph: MenuBarGlyph, height: Double) -> Layout {
        Layout(
            dotX: (glyph.itemWidth - glyph.dotDiameter) / 2,
            dotY: height - glyph.dotDiameter - 2,
            dotDiameter: glyph.dotDiameter,
            textBaselineY: 0,
            fontSize: glyph.fontSize
        )
    }

    static func image(_ glyph: MenuBarGlyph, palette: StatusStylePalette = StatusStylePalette()) -> NSImage {
        let width = glyph.itemWidth, height = 22.0
        let layout = layout(for: glyph, height: height)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let dot = NSBezierPath(ovalIn: NSRect(
            x: layout.dotX,
            y: layout.dotY,
            width: layout.dotDiameter, height: layout.dotDiameter))
        nsColor(glyph.tone, palette: palette).setFill()
        dot.fill()
        let text = NSAttributedString(string: glyph.primaryText, attributes: [
            .font: NSFont.systemFont(ofSize: layout.fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (width - size.width) / 2, y: layout.textBaselineY))
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func nsColor(_ tone: LatencyTone, palette: StatusStylePalette) -> NSColor {
        NSColor(hex: palette.colorHex(for: DisplayTone(latencyTone: tone))) ?? {
            switch tone {
            case .neutral: return .secondaryLabelColor
            case .good: return .systemGreen
            case .warn: return .systemYellow
            case .bad: return .systemRed
            }
        }()
    }
}

private extension NSColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((number >> 16) & 0xff) / 255,
            green: CGFloat((number >> 8) & 0xff) / 255,
            blue: CGFloat(number & 0xff) / 255,
            alpha: 1
        )
    }
}

// MARK: - Generic slot popover

/// One popover per slot. Reads SlotSurface from viewModel.slotSurfaces[slotID].
/// Layout is identical to the retired PingPopover (420x640, dark bg).
struct SlotPopover: View {
    let slotID: SlotID
    @EnvironmentObject private var viewModel: StatusViewModel

    nonisolated static func scrollContentIdentity(for slotID: SlotID) -> String {
        "slot-scroll-\(slotID.rawValue)"
    }

    nonisolated static func hostSubtitle(selectedID: String?, options: [InstanceSelectorCard.Option]) -> String {
        guard let selectedID else { return "\(options.count) enabled hosts" }
        return options.first(where: { $0.id == selectedID })?.subtitle ?? ""
    }

    private var surface: SlotSurface {
        viewModel.slotSurfaces[slotID] ?? .empty
    }
    private var focus: IntegrationInstanceID? {
        surface.selectedInstanceID
    }
    private var selectedGraphRange: GraphRange? { surface.graphRange }
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
        return (g.primaryText, g.tone, label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if selectedGraphRange != nil { rangePicker }
            ScrollView(.vertical) {
                SurfaceView(plan: surface.plan, data: surface.data)
                    .environment(\.statusStylePalette, viewModel.statusStylePalette)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .id(Self.scrollContentIdentity(for: slotID))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(18)
        .frame(width: 420, height: 640, alignment: .topLeading)
        .background(Color(red: 0.055, green: 0.055, blue: 0.07))
    }

    private var header: some View {
        HStack(alignment: .top) {
            if surface.hostOptions.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    InstanceSelectorCard(
                        options: surface.hostOptions,
                        selectedID: focus?.rawValue,
                        primaryID: surface.primaryInstanceID?.rawValue,
                        onSelect: { rawID in
                            viewModel.selectInstance(slotID, rawID.map { IntegrationInstanceID(rawValue: $0) })
                        },
                        onSetPrimary: { rawID in
                            viewModel.setSlotPrimaryInstance(slotID, IntegrationInstanceID(rawValue: rawID))
                        },
                        allLabel: "All Hosts"
                    )
                    Text(Self.hostSubtitle(selectedID: focus?.rawValue, options: surface.hostOptions))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                // Single host or no options: show the slot title as plain text.
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.slots.first(where: { $0.id == slotID })?.title ?? "Ping")
                        .font(.system(size: 14, weight: .semibold))
                    if let subtitle = surface.hostOptions.first?.subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Text(focusReadout.text).font(.system(size: 25, weight: .bold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(DisplayTone(latencyTone: focusReadout.tone).color(using: viewModel.statusStylePalette))
                        .frame(width: 9, height: 9)
                    Text(focusReadout.statusLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(DisplayTone(latencyTone: focusReadout.tone).color(using: viewModel.statusStylePalette))
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
                get: { selectedGraphRange ?? .m5 },
                set: { viewModel.setSlotGraphRange(slotID, $0) }
            )) {
                ForEach(GraphRange.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Spacer()
        }
    }
}

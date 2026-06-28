import AppKit
import AmbitCore
import AmbitUI
import SwiftUI

enum OverlaySlotSelection {
    static func reconciled(_ selected: SlotID?, slots: [Slot]) -> SlotID? {
        guard !slots.isEmpty else { return nil }
        if let selected, slots.contains(where: { $0.id == selected }) {
            return selected
        }
        return slots.first?.id
    }
}

enum OverlaySurfaceCards {
    static func compactCards(from plan: SurfacePlan) -> [CardSpec] {
        let flattened = flatten(plan.cards)
        let graphs = flattened.filter { $0.kind == .historyGraph || $0.kind == .dualLineGraph }
        if !graphs.isEmpty { return graphs }
        if let bounded = flattened.first(where: isBoundedFallback) {
            return [bounded]
        }
        return flattened.first(where: isSecondaryFallback).map { [$0] } ?? []
    }

    private static func flatten(_ cards: [CardSpec]) -> [CardSpec] {
        cards.flatMap { card -> [CardSpec] in
            card.kind == .section ? flatten(card.children) : [card]
        }
    }

    private static func isBoundedFallback(_ card: CardSpec) -> Bool {
        switch card.kind {
        case .gauge, .progress, .segmentedRing, .coreGrid:
            return true
        case .statusRow, .historyGraph, .dualLineGraph, .breakdownLegend, .statTable, .sampleHistory, .control, .instanceSelector, .section, .statusBanner, .cardRow:
            return false
        }
    }

    private static func isSecondaryFallback(_ card: CardSpec) -> Bool {
        switch card.kind {
        case .statusRow, .breakdownLegend, .statTable, .sampleHistory:
            return true
        case .gauge, .progress, .segmentedRing, .coreGrid, .historyGraph, .dualLineGraph, .control, .instanceSelector, .section, .statusBanner, .cardRow:
            return false
        }
    }
}

/// The floating, always-on-top compact multi-host graph.
struct OverlayView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    let openPopover: (SlotID?) -> Void
    let close: () -> Void

    private var selectedSlotID: SlotID? {
        OverlaySlotSelection.reconciled(viewModel.overlaySlotID, slots: viewModel.slots)
    }
    private var surface: SlotSurface {
        selectedSlotID.flatMap { viewModel.slotSurfaces[$0] } ?? .empty
    }
    private var selectedSlotTitle: String {
        guard let selectedSlotID else { return "Slot" }
        return viewModel.slots.first(where: { $0.id == selectedSlotID })?.title ?? selectedSlotID.rawValue
    }

    var body: some View {
        let compactCards = OverlaySurfaceCards.compactCards(from: surface.plan)
        VStack(spacing: 5) {
            SurfaceView(plan: SurfacePlan(cards: compactCards), data: surface.data)
        }
        .padding(8)
        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 64, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .contextMenu {
            Menu("Slot") {
                ForEach(viewModel.slots) { slot in
                    Button(slot.title ?? slot.id.rawValue) {
                        viewModel.selectOverlaySlot(slot.id)
                    }
                }
            }
            if let selectedSlotID, !surface.hostOptions.isEmpty {
                Menu("Focus") {
                Button("All Items") { viewModel.selectInstance(selectedSlotID, nil) }
                ForEach(surface.hostOptions) { option in
                    Button(option.label) {
                        viewModel.selectInstance(selectedSlotID, IntegrationInstanceID(rawValue: option.id))
                    }
                }
                }
            }
            Button("Open \(selectedSlotTitle) Popover") {
                if let selectedSlotID {
                    openPopover(selectedSlotID)
                } else {
                    openPopover(nil)
                }
            }
            Button("Settings…") { viewModel.openSettings?() }
            Divider()
            Button("Close Overlay", action: close)
        }
    }
}

@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private let viewModel: StatusViewModel
    private let onOpenPopover: (SlotID?) -> Void

    init(viewModel: StatusViewModel, onOpenPopover: @escaping (SlotID?) -> Void) {
        self.viewModel = viewModel
        self.onOpenPopover = onOpenPopover
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        // Titled + resizable (with the title bar hidden/transparent) so macOS shows the
        // edge resize cursors; borderless windows don't get them.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 284, height: 108),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = NSSize(width: 180, height: 64)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = OverlayView(openPopover: onOpenPopover, close: { [weak self] in self?.hide() })
            .environmentObject(viewModel)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 284, height: 108)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}

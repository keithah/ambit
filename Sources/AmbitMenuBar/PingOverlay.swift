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
        .padding(viewModel.overlayConfig.compactMode ? 5 : 8)
        .frame(
            minWidth: viewModel.overlayConfig.compactMode ? 160 : 180,
            maxWidth: .infinity,
            minHeight: viewModel.overlayConfig.compactMode ? 52 : 64,
            maxHeight: .infinity
        )
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
final class OverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let viewModel: StatusViewModel
    private let onOpenPopover: (SlotID?) -> Void
    private var applyingConfig = false

    init(viewModel: StatusViewModel, onOpenPopover: @escaping (SlotID?) -> Void) {
        self.viewModel = viewModel
        self.onOpenPopover = onOpenPopover
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        viewModel.setOverlayVisible(!isVisible)
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if let frame = viewModel.overlayConfig.frame {
            panel.setFrame(NSRect(overlayFrame: frame), display: true)
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.minY + 24))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func apply(_ config: OverlayPresentationConfig) {
        applyingConfig = true
        defer { applyingConfig = false }
        let panel = panel ?? (config.isVisible ? makePanel() : nil)
        if let panel {
            self.panel = panel
            panel.level = config.alwaysOnTop ? .floating : .normal
            panel.alphaValue = config.opacity
            if let frame = config.frame {
                panel.setFrame(NSRect(overlayFrame: frame), display: true)
            }
            config.isVisible ? show() : hide()
        }
    }

    func windowDidMove(_ notification: Notification) {
        persistCurrentFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistCurrentFrame()
    }

    private func persistCurrentFrame() {
        guard !applyingConfig, let panel else { return }
        viewModel.setOverlayFrame(OverlayFrame(frame: panel.frame))
    }

    private func makePanel() -> NSPanel {
        // Titled + resizable (with the title bar hidden/transparent) so macOS shows the
        // edge resize cursors; borderless windows don't get them.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 284, height: 108),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = viewModel.overlayConfig.alwaysOnTop ? .floating : .normal
        panel.alphaValue = viewModel.overlayConfig.opacity
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
        panel.delegate = self
        let content = OverlayView(openPopover: onOpenPopover, close: { [weak self] in self?.viewModel.setOverlayVisible(false) })
            .environmentObject(viewModel)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 284, height: 108)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}

private extension NSRect {
    init(overlayFrame: OverlayFrame) {
        self.init(x: overlayFrame.x, y: overlayFrame.y, width: overlayFrame.width, height: overlayFrame.height)
    }
}

private extension OverlayFrame {
    init(frame: NSRect) {
        self.init(x: frame.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height)
    }
}

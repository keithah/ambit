import AppKit
import AmbitCore
import SwiftUI

final class OverlayModel: ObservableObject {
    @Published var showLegend = false
}

/// The floating, always-on-top compact multi-host graph.
struct OverlayView: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @ObservedObject var model: OverlayModel
    let openPopover: () -> Void
    let close: () -> Void

    var body: some View {
        let hosts = viewModel.pingHosts
        let series = hosts.map { (color: $0.color, samples: $0.samples) }
        let axisMax = PingScopePresenter.niceMax(hosts.flatMap { $0.samples.compactMap(\.value) })
        VStack(spacing: 5) {
            LatencyGraph(series: series, axisMax: axisMax)
            if model.showLegend {
                HStack(spacing: 9) {
                    ForEach(hosts) { host in
                        HStack(spacing: 3) {
                            Circle().fill(host.color).frame(width: 6, height: 6)
                            Text(host.name).font(.system(size: 8.5)).lineLimit(1).fixedSize()
                        }
                    }
                }
                .foregroundStyle(Color(white: 0.85))
            }
        }
        .padding(8)
        .frame(minWidth: 180, maxWidth: .infinity, minHeight: 64, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12)))
        .contextMenu {
            Button(model.showLegend ? "Hide Legend" : "Show Legend") { model.showLegend.toggle() }
            Menu("Host") {
                Button("All Hosts") { viewModel.selectPingScopeHost(nil) }
                ForEach(hosts) { host in Button(host.name) { viewModel.selectPingScopeHost(host.instanceID) } }
            }
            Button("Open Popover", action: openPopover)
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
    private let model = OverlayModel()
    private let onOpenPopover: () -> Void

    init(viewModel: StatusViewModel, onOpenPopover: @escaping () -> Void) {
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
        let content = OverlayView(model: model, openPopover: onOpenPopover, close: { [weak self] in self?.hide() })
            .environmentObject(viewModel)
        let hosting = NSHostingView(rootView: content)
        hosting.frame = panel.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 284, height: 108)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }
}

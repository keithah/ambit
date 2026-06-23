import AppKit
import Combine
import AmbitCore
import SwiftUI

@main
struct AmbitApp: App {
    @StateObject private var appModel = MenuBarAppModel()

    var body: some Scene {
        // Settings are shown via a self-managed AppKit window (SettingsWindowController),
        // not this scene — the SwiftUI Settings scene / showSettingsWindow: is unreliable in
        // an .accessory menu-bar app. This placeholder just satisfies the Scene requirement.
        Settings { EmptyView() }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let viewModel: StatusViewModel

    init(viewModel: StatusViewModel) { self.viewModel = viewModel }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PingScope Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PingScopeSettings().environmentObject(viewModel))
        window.center()
        return window
    }
}

@MainActor
private final class MenuBarAppModel: ObservableObject {
    let viewModel: StatusViewModel
    private let statusBarController: StatusBarController
    private let overlayController: OverlayController
    private let settingsController: SettingsWindowController

    init() {
        let viewModel = StatusViewModel()
        self.viewModel = viewModel
        let statusBarController = StatusBarController(viewModel: viewModel)
        self.statusBarController = statusBarController
        let overlayController = OverlayController(
            viewModel: viewModel,
            onOpenPopover: { [weak statusBarController] in statusBarController?.showPopover() }
        )
        self.overlayController = overlayController
        let settingsController = SettingsWindowController(viewModel: viewModel)
        self.settingsController = settingsController
        viewModel.toggleOverlay = { [weak overlayController] in overlayController?.toggle() }
        viewModel.showPopover = { [weak statusBarController] in statusBarController?.showPopover() }
        viewModel.openSettings = { [weak settingsController] in settingsController?.show() }
        viewModel.start()
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Owns the status-bar item (stacked latency glyph) and the popover.
@MainActor
private final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 34)
    private let popover = NSPopover()
    private let viewModel: StatusViewModel
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: StatusViewModel) {
        self.viewModel = viewModel
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: PingScopePopover().environmentObject(viewModel)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }

        updateGlyph(viewModel.menuGlyph)
        viewModel.$menuGlyph
            .receive(on: RunLoop.main)
            .sink { [weak self] glyph in self?.updateGlyph(glyph) }
            .store(in: &cancellables)
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func updateGlyph(_ glyph: MenuBarGlyph) {
        statusItem.button?.image = PingScopeGlyphRenderer.image(glyph)
        statusItem.button?.toolTip = "PingScope · \(glyph.latencyText)"
    }
}

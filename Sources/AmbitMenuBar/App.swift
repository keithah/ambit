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
        window.title = "Ambit Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AmbitSettings().environmentObject(viewModel))
        window.center()
        return window
    }
}

@MainActor
private final class MenuBarAppModel: ObservableObject {
    let viewModel: StatusViewModel
    private var statusBarControllers: [StatusBarController] = []
    private let overlayController: OverlayController
    private let settingsController: SettingsWindowController

    init() {
        let viewModel = StatusViewModel()
        self.viewModel = viewModel

        // Create one StatusBarController per slot. Today there is exactly one (Ping).
        let controllers = viewModel.slots.map { slot in
            StatusBarController(slotID: slot.id, viewModel: viewModel)
        }
        self.statusBarControllers = controllers

        // Overlay and settings always target the first (ping) slot's popover.
        let firstController = controllers.first
        let overlayController = OverlayController(
            viewModel: viewModel,
            onOpenPopover: { [weak firstController] in firstController?.showPopover() }
        )
        self.overlayController = overlayController
        let settingsController = SettingsWindowController(viewModel: viewModel)
        self.settingsController = settingsController
        viewModel.toggleOverlay = { [weak overlayController] in overlayController?.toggle() }
        viewModel.showPopover = { [weak firstController] in firstController?.showPopover() }
        viewModel.openSettings = { [weak settingsController] in settingsController?.show() }
        viewModel.start()
        // On system wake, kick a fresh poll cycle — a probe in flight at sleep is wedged and the
        // inter-cycle sleep won't have advanced. (Core stays UI-free; NSWorkspace lives here.)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak viewModel] _ in MainActor.assumeIsolated { viewModel?.kickPoll() } }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Owns one NSStatusItem + one NSPopover for a single slot.
@MainActor
private final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 34)
    private let popover = NSPopover()
    private let viewModel: StatusViewModel
    private let slotID: SlotID
    private var cancellables: Set<AnyCancellable> = []

    init(slotID: SlotID, viewModel: StatusViewModel) {
        self.slotID = slotID
        self.viewModel = viewModel
        super.init()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 420, height: 640)
        popover.contentViewController = NSHostingController(
            rootView: SlotPopover(slotID: slotID).environmentObject(viewModel)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
        }

        // Initial glyph from current slotSurfaces (may be .empty on first tick).
        updateGlyph(viewModel.slotSurfaces[slotID]?.glyph ?? MenuBarGlyph(latencyText: "--ms", tone: .neutral))
        viewModel.$slotSurfaces
            .receive(on: RunLoop.main)
            .sink { [weak self] surfaces in
                guard let self else { return }
                self.updateGlyph(surfaces[self.slotID]?.glyph ?? MenuBarGlyph(latencyText: "--ms", tone: .neutral))
            }
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
        let slot = viewModel.slots.first(where: { $0.id == slotID })
        let title = slot?.title ?? slotID.rawValue
        statusItem.button?.image = StatusGlyphRenderer.image(glyph)
        statusItem.button?.toolTip = "\(title) · \(glyph.latencyText)"
    }
}

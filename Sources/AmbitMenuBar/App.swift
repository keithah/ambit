import AppKit
import Combine
import AmbitCore
import SwiftUI

private let ambitSingleInstanceLock = FileAppInstanceLock()

@main
struct AmbitApp: App {
    @StateObject private var appModel = MenuBarAppModel()

    init() {
        if ambitSingleInstanceLock.acquire() == false {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    var body: some Scene {
        // Settings are shown via a self-managed AppKit window (SettingsWindowController);
        // the SwiftUI Settings scene is unreliable in an .accessory menu-bar app.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        appModel.viewModel.openSettings?()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
        }
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
    private let statusItemCoordinator: MenuBarStatusItemCoordinator
    private let overlayController: OverlayController
    private let settingsController: SettingsWindowController
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let viewModel = StatusViewModel()
        self.viewModel = viewModel

        let statusItemCoordinator = MenuBarStatusItemCoordinator(viewModel: viewModel)
        self.statusItemCoordinator = statusItemCoordinator

        let overlayController = OverlayController(
            viewModel: viewModel,
            onOpenPopover: { [weak statusItemCoordinator] slotID in
                statusItemCoordinator?.controller(for: slotID)?.showPopover()
            }
        )
        self.overlayController = overlayController
        let settingsController = SettingsWindowController(viewModel: viewModel)
        self.settingsController = settingsController
        viewModel.toggleOverlay = { [weak overlayController] in overlayController?.toggle() }
        viewModel.$overlayConfig
            .sink { [weak overlayController] config in
                overlayController?.apply(config)
            }
            .store(in: &cancellables)
        viewModel.showPopover = { [weak statusItemCoordinator] in statusItemCoordinator?.firstController?.showPopover() }
        viewModel.openSettings = { [weak viewModel, weak settingsController] in
            viewModel?.refreshPresentationSettingsFromRegistry()
            settingsController?.show()
        }
        viewModel.start()
        // On sleep, cancel any in-flight bounded cycle; on wake, re-detect the gateway before
        // kicking a fresh poll. Core stays UI-free; NSWorkspace lives here.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak viewModel] _ in MainActor.assumeIsolated { viewModel?.handleSystemWillSleep() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak viewModel] _ in
            Task { @MainActor in
                await viewModel?.handleSystemDidWake()
            }
        }
        NSApp.setActivationPolicy(.accessory)
    }
}

struct MenuBarStatusItemReconciliationPlan: Equatable {
    var idsToCreate: [SlotID]
    var idsToRemove: [SlotID]
    var orderedIDs: [SlotID]
}

enum MenuBarStatusItemReconciler {
    static func plan(existing: [SlotID], desired: [Slot]) -> MenuBarStatusItemReconciliationPlan {
        let desiredIDs = desired.map(\.id)
        let existingSet = Set(existing)
        let desiredSet = Set(desiredIDs)
        return MenuBarStatusItemReconciliationPlan(
            idsToCreate: desiredIDs.filter { !existingSet.contains($0) },
            idsToRemove: existing.filter { !desiredSet.contains($0) },
            orderedIDs: desiredIDs
        )
    }
}

@MainActor
private final class MenuBarStatusItemCoordinator {
    private let viewModel: StatusViewModel
    private var controllersByID: [SlotID: StatusBarController] = [:]
    private var orderedIDs: [SlotID] = []
    private var cancellables: Set<AnyCancellable> = []

    init(viewModel: StatusViewModel) {
        self.viewModel = viewModel
        reconcile(slots: viewModel.slots)
        viewModel.$slots
            .receive(on: RunLoop.main)
            .sink { [weak self] slots in self?.reconcile(slots: slots) }
            .store(in: &cancellables)
    }

    var firstController: StatusBarController? {
        orderedIDs.compactMap { controllersByID[$0] }.first
    }

    func controller(for slotID: SlotID?) -> StatusBarController? {
        if let slotID, let controller = controllersByID[slotID] {
            return controller
        }
        return firstController
    }

    private func reconcile(slots: [Slot]) {
        let plan = MenuBarStatusItemReconciler.plan(existing: orderedIDs, desired: slots)
        for id in plan.idsToRemove {
            controllersByID.removeValue(forKey: id)?.removeFromStatusBar()
        }
        for id in plan.idsToCreate {
            controllersByID[id] = StatusBarController(slotID: id, viewModel: viewModel)
        }
        orderedIDs = plan.orderedIDs
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
        updateGlyph(viewModel.slotSurfaces[slotID]?.glyph ?? SlotSurface.empty.glyph)
        viewModel.$slotSurfaces
            .receive(on: RunLoop.main)
            .sink { [weak self] surfaces in
                guard let self else { return }
                self.updateGlyph(surfaces[self.slotID]?.glyph ?? SlotSurface.empty.glyph)
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

    func removeFromStatusBar() {
        popover.performClose(nil)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func updateGlyph(_ glyph: MenuBarGlyph) {
        let slot = viewModel.slots.first(where: { $0.id == slotID })
        let title = slot?.title ?? slotID.rawValue
        statusItem.button?.image = StatusGlyphRenderer.image(glyph, palette: viewModel.statusStylePalette)
        statusItem.button?.toolTip = "\(title) · \(glyph.primaryText)"
    }
}

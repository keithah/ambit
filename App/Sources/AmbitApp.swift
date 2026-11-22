import AppKit
import SwiftUI

@main
struct AmbitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let updater = Updater()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        popover.behavior = .transient
        popover.delegate = self
        let content = NSHostingController(
            rootView: PopoverView(model: model, checkForUpdates: { [updater] in updater.checkForUpdates() })
        )
        // The popover follows the content's height as pages and device rows change.
        content.sizingOptions = [.preferredContentSize]
        popover.contentViewController = content

        model.onChange = { [weak self] in self?.renderStatusItem() }
        renderStatusItem()
        model.start()
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverDidClose()
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        let snapshot = model.snapshot
        let title = NSMutableAttributedString(
            string: "● ",
            attributes: [.foregroundColor: snapshot.verdict.health.nsColor, .font: NSFont.systemFont(ofSize: 9)]
        )
        title.append(NSAttributedString(
            string: model.menuBarText,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                         .baselineOffset: -0.5]
        ))
        button.attributedTitle = title
        button.toolTip = snapshot.verdict.title
        button.setAccessibilityLabel("Ambit: \(snapshot.verdict.title), \(model.menuBarText)")
    }
}

import AppKit
import Sparkle

/// Sparkle wrapper. The updater only starts when the build carries a public key, so local
/// development builds (no key) launch without an updater error.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        controller = key.isEmpty
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Updates aren't set up in this build"
            alert.informativeText = "This is a development build without an update key."
            alert.runModal()
        }
    }
}

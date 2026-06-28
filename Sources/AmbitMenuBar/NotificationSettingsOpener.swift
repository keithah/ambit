import AppKit
import Foundation

@MainActor
protocol NotificationSettingsOpening: Sendable {
    func openNotificationSettings()
}

@MainActor
struct MacNotificationSettingsOpener: NotificationSettingsOpening {
    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

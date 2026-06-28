import AmbitCore
import Foundation
import UserNotifications

struct MacNotificationDeliverer: NotificationDelivering {
    func authorizationStatus() async -> NotificationAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .authorized
        @unknown default:
            return .unknown(String(describing: settings.authorizationStatus.rawValue))
        }
    }

    func requestAuthorization() async -> NotificationAuthorizationStatus {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        return granted ? .authorized : .denied
    }

    func deliver(_ intent: NotificationIntent) async throws {
        let content = UNMutableNotificationContent()
        content.title = intent.title
        content.body = intent.body
        content.sound = intent.severity >= .down ? .defaultCritical : .default
        let request = UNNotificationRequest(identifier: intent.id, content: content, trigger: nil)
        try await UNUserNotificationCenter.current().add(request)
    }
}

import AmbitKit
import AppKit
import Observation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppModel {
    private(set) var snapshot = DiagnosisSnapshot()
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private let monitor = DiagnosisMonitor()
    @ObservationIgnored private var alerts = ConnectionAlerts()
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// Short readout for the menu bar: latency when online, otherwise the failing hop.
    var menuBarText: String {
        switch snapshot.verdict {
        case .checking: "…"
        case .online, .internetSlow, .wifiSlow:
            snapshot.internet.lastMs.map { "\(Int($0.rounded())) ms" } ?? "…"
        case .noNetwork: "No network"
        case .routerUnreachable: "Router"
        case .internetDown: "Offline"
        case .dnsFailing: "DNS"
        }
    }

    func start() {
        // Without an activity assertion App Nap throttles the timer of a UI-less app.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Monitoring the connection"
        )
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [monitor] _ in
            Task { await monitor.runCycle() }
        }
        Task { [weak self, monitor] in
            await monitor.start()
            for await next in await monitor.snapshots() {
                self?.apply(next)
            }
        }
    }

    private func apply(_ next: DiagnosisSnapshot) {
        snapshot = next
        onChange?()
        if let message = alerts.evaluate(verdict: next.verdict) {
            Notifier.deliver(message)
        }
    }
}

enum Notifier {
    static func deliver(_ message: AlertMessage) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = message.title
            content.body = message.body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

extension Health {
    var color: Color {
        switch self {
        case .unknown: .secondary
        case .online: .green
        case .degraded: .orange
        case .offline: .red
        }
    }

    var nsColor: NSColor {
        switch self {
        case .unknown: .secondaryLabelColor
        case .online: .systemGreen
        case .degraded: .systemOrange
        case .offline: .systemRed
        }
    }
}

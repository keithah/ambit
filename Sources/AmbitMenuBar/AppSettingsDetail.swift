import AmbitCore
import SwiftUI

struct AppSettingsDetail: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var notificationStatus: NotificationAuthorizationStatus = .unavailable
    @State private var notificationMessage: String?
    @State private var isRequestingNotifications = false
    @State private var isSendingTestNotification = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("App").font(.system(size: 22, weight: .bold))
                Text("Launch behavior and system integration.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Start Ambit at login", isOn: startAtLoginBinding)
                    .toggleStyle(.switch)

                if let message = viewModel.startAtLoginMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            notificationControls

            localNetworkHints

            Spacer()
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { refreshNotificationStatus() }
    }

    private var notificationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notifications")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Status: \(notificationStatus.label)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Allow Notifications") { requestNotifications() }
                    .disabled(isRequestingNotifications || notificationStatus == .authorized || notificationStatus == .provisional)
                Button("Send Test") { sendTestNotification() }
                    .disabled(isSendingTestNotification)
                Button("Open Notification Settings") {
                    viewModel.openNotificationSettings()
                }
            }
            if let notificationMessage {
                Text(notificationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var localNetworkHints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Network Access")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            let hints = viewModel.localNetworkPermissionHints()
            if hints.isEmpty {
                Text("No local-network targets are configured.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hints) { hint in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hint.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(hint.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func refreshNotificationStatus() {
        Task { @MainActor in
            notificationStatus = await viewModel.notificationAuthorizationStatus()
        }
    }

    private func requestNotifications() {
        isRequestingNotifications = true
        Task { @MainActor in
            notificationStatus = await viewModel.requestNotificationAuthorization()
            isRequestingNotifications = false
        }
    }

    private func sendTestNotification() {
        isSendingTestNotification = true
        notificationMessage = nil
        Task { @MainActor in
            let results = await viewModel.sendTestNotification()
            isSendingTestNotification = false
            notificationMessage = results.contains { result in
                if case .delivered = result { return true }
                return false
            } ? "Test notification sent." : "Test notification was not delivered."
            notificationStatus = await viewModel.notificationAuthorizationStatus()
        }
    }

    private var startAtLoginBinding: Binding<Bool> {
        Binding {
            viewModel.startAtLoginEnabled
        } set: { enabled in
            Task { @MainActor in
                await viewModel.setStartAtLoginEnabled(enabled)
            }
        }
    }
}

private extension NotificationAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: return "Not requested"
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .provisional: return "Provisional"
        case .unavailable: return "Unavailable"
        case .unknown(let value): return value
        }
    }
}

import AmbitCore
import AppKit
import SwiftUI

struct AppSettingsDetail: View {
    @EnvironmentObject private var viewModel: StatusViewModel
    @State private var notificationStatus: NotificationAuthorizationStatus = .unavailable
    @State private var notificationMessage: String?
    @State private var isRequestingNotifications = false
    @State private var isSendingTestNotification = false
    @State private var softwareUpdateStatus: SoftwareUpdateStatus = .idle
    @State private var softwareUpdateMessage: String?
    @State private var isCheckingForUpdates = false
    @State private var showingResetConfirmation = false
    @State private var resetMessage: String?

    var body: some View {
        ScrollView {
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

            overlayControls

            notificationControls

            localNetworkHints

            appAboutControls

            softwareUpdateControls

            resetAndQuitControls

            Spacer()
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            refreshNotificationStatus()
            refreshSoftwareUpdateStatus()
        }
        .confirmationDialog(
            "Reset Ambit to defaults?",
            isPresented: $showingResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears presentation settings and integration records, then reseeds the default integrations.")
        }
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

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Overlay")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Toggle("Show floating overlay", isOn: Binding {
                viewModel.overlayConfig.isVisible
            } set: { value in
                viewModel.setOverlayVisible(value)
            })
            .toggleStyle(.switch)

            Picker("Slot", selection: Binding {
                viewModel.overlayConfig.selectedSlotID
            } set: { value in
                viewModel.selectOverlaySlot(value)
            }) {
                ForEach(viewModel.slots) { slot in
                    Text(slot.title ?? slot.id.rawValue).tag(Optional(slot.id))
                }
            }
            .frame(width: 260)

            Toggle("Always on top", isOn: Binding {
                viewModel.overlayConfig.alwaysOnTop
            } set: { value in
                viewModel.setOverlayAlwaysOnTop(value)
            })
            .toggleStyle(.checkbox)

            Toggle("Compact mode", isOn: Binding {
                viewModel.overlayConfig.compactMode
            } set: { value in
                viewModel.setOverlayCompactMode(value)
            })
            .toggleStyle(.checkbox)

            HStack(spacing: 8) {
                Text("Opacity")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(value: Binding {
                    viewModel.overlayConfig.opacity
                } set: { value in
                    viewModel.setOverlayOpacity(value)
                }, in: 0.25...1)
                .frame(width: 180)
                Text("\(Int(viewModel.overlayConfig.opacity * 100))%")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }

            Button("Reset Overlay Position") {
                viewModel.resetOverlayPosition()
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

    private var appAboutControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            let build = viewModel.appBuildInfo
            Text("\(build.name) \(build.version) (\(build.build)) · \(build.flavor)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("ICMP: \(viewModel.icmpAvailabilityText)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Local network monitor: \(viewModel.networkMonitorStatusText)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("About Ambit") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }
    }

    private var softwareUpdateControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Software Updates")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Status: \(softwareUpdateStatus.label)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Feed URL: \(viewModel.softwareUpdateFeedURLStatus.label)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Public key: \(viewModel.softwareUpdatePublicKeyStatus.label)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Check for Updates") {
                checkForUpdates()
            }
            .disabled(isCheckingForUpdates)
            if let softwareUpdateMessage {
                Text(softwareUpdateMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var resetAndQuitControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Maintenance")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Reset to Defaults", role: .destructive) {
                    showingResetConfirmation = true
                }
                Button("Quit Ambit") {
                    NSApp.terminate(nil)
                }
            }
            if let resetMessage {
                Text(resetMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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

    private func refreshSoftwareUpdateStatus() {
        Task { @MainActor in
            softwareUpdateStatus = await viewModel.softwareUpdateStatus()
        }
    }

    private func checkForUpdates() {
        isCheckingForUpdates = true
        softwareUpdateMessage = nil
        Task { @MainActor in
            let result = await viewModel.checkForSoftwareUpdates()
            isCheckingForUpdates = false
            switch result {
            case .unavailable(let reason):
                softwareUpdateStatus = .unavailable(reason: reason)
                softwareUpdateMessage = reason
            case .checked(let status):
                softwareUpdateStatus = status
                softwareUpdateMessage = status.label
            }
        }
    }

    private func resetToDefaults() {
        Task { @MainActor in
            await viewModel.resetToDefaults()
            resetMessage = "Defaults restored."
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

private extension SoftwareUpdateStatus {
    var label: String {
        switch self {
        case .unavailable(let reason): return "Unavailable - \(reason)"
        case .idle: return "Idle"
        case .checking: return "Checking"
        case .updateAvailable(let version): return "Update available: \(version)"
        case .upToDate: return "Up to date"
        case .failed(let reason): return "Failed - \(reason)"
        }
    }
}

private extension SoftwareUpdateConfigurationStatus {
    var label: String {
        switch self {
        case .configured: return "Configured"
        case .unavailable(let reason): return "Unavailable - \(reason)"
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

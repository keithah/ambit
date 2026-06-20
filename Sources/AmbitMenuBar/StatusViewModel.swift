import AmbitCore
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class StatusViewModel: ObservableObject {
    @Published var snapshot = StatusSnapshot()
    @Published var settings: AppSettings
    @Published var routerPassword: String
    @Published var selectedEndpoint: EndpointSelection?

    private let engine: Engine
    private let alertEngine = AlertEngine()
    private let alertNotifier: AlertNotifier
    private var subscriptionTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        endpointSelector: EndpointSelector = EndpointSelector(),
        reachabilityProbe: ReachabilityProbeProtocol = ReachabilityProbe()
    ) {
        let settings = (try? settingsStore.load()) ?? AppSettings()
        let routerPassword = (try? credentialStore.password(account: settings.username)) ?? RouterDefaults.routerPassword
        self.settings = settings
        self.routerPassword = routerPassword
        self.alertNotifier = AlertNotifier()
        self.engine = Engine(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            endpointSelector: endpointSelector,
            reachabilityProbe: reachabilityProbe,
            settings: settings,
            routerPassword: routerPassword,
            registerBuiltInProviders: true,
            activeMeasurementProcessRunner: SystemProcessRunner()
        )
    }

    deinit {
        subscriptionTask?.cancel()
    }

    func start() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.engine.snapshots {
                self.snapshot = snapshot
                self.selectedEndpoint = await self.engine.currentSelectedEndpoint()
                let events = await self.alertEngine.evaluate(snapshot.engineSnapshot)
                await self.alertNotifier.deliver(events)
            }
        }
        Task { await engine.start() }
    }

    func refresh() async {
        await engine.updateSettings(settings, routerPassword: routerPassword)
        await engine.refresh()
        selectedEndpoint = await engine.currentSelectedEndpoint()
    }

    func saveSettings() {
        Task {
            let error = await engine.saveSettings(settings, routerPassword: routerPassword)
            if let error {
                snapshot.router.errorMessage = error
            }
        }
    }

    func setSpeedifyFocused(_ isFocused: Bool) {
        Task { await engine.setSpeedifyFocused(isFocused) }
    }

    func refreshSpeedifyNow() async {
        await engine.refreshSpeedifyNow()
    }

    func toggleVPN() async {
        try? await engine.dispatch(provider: ProviderIDs.vpn, commandID: ProviderCommandIDs.vpnToggle)
    }

    func toggleSpeedify() async {
        try? await engine.dispatch(provider: ProviderIDs.speedify, commandID: ProviderCommandIDs.speedifyToggle)
    }

    func setSpeedifyBondingMode(_ mode: SpeedifyBondingMode) async {
        try? await engine.dispatch(
            provider: ProviderIDs.speedify,
            commandID: ProviderCommandIDs.speedifySetBondingMode,
            arguments: CommandArguments(values: ["mode": .string(mode.commandCode)])
        )
    }

    func setSpeedifyNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String) async {
        try? await engine.dispatch(
            provider: ProviderIDs.speedify,
            commandID: ProviderCommandIDs.speedifySetNetworkPriority,
            arguments: CommandArguments(values: ["priority": .number(Double(priority.rawValue)), "networkID": .string(networkID)])
        )
    }

    func setEcoFlowOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async -> EcoFlowControlResponse? {
        await engine.setEcoFlowOutput(target, state: state)
    }
}

private struct AlertNotifier: Sendable {
    func deliver(_ events: [AlertEvent]) async {
        guard !events.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.message
            content.sound = event.severity == .critical ? .defaultCritical : .default
            let request = UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}

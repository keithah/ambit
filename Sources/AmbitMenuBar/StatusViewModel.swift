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
    @Published var commandPalette: [CommandPaletteItem] = []
    @Published var providerDisplayNames: [ProviderID: String] = [:]
    @Published var moduleUsageSnapshots: [ModuleUsageSnapshot] = []
    @Published var lastCommandResult: CommandExecutionResult?
    @Published var executingCommandID: String?
    @Published var installedProviders: [InstalledProviderRecord] = []
    @Published var providerSetupSummaries: [ProviderSetupSummary] = []
    @Published var providerSetupError: String?
    @Published var providerCredentialValues: [ProviderID: [String: String]] = [:]
    @Published var providerLayouts: [ProviderID: ProviderManifest.Layout] = [:]
    @Published var providerAlertRuleCounts: [ProviderID: Int] = [:]

    private let engine: Engine
    private let installedProviderStore: any InstalledProviderStore
    private let credentialStore: any CredentialStore
    private var alertEngine = AlertEngine()
    private let alertNotifier: AlertNotifier
    private var subscriptionTask: Task<Void, Never>?

    init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        installedProviderStore: any InstalledProviderStore = UserDefaultsInstalledProviderStore(),
        endpointSelector: EndpointSelector = EndpointSelector(),
        reachabilityProbe: ReachabilityProbeProtocol = ReachabilityProbe()
    ) {
        let settings = (try? settingsStore.load()) ?? AppSettings()
        let routerPassword = (try? credentialStore.password(account: settings.username)) ?? RouterDefaults.routerPassword
        self.settings = settings
        self.routerPassword = routerPassword
        self.alertNotifier = AlertNotifier()
        self.installedProviderStore = installedProviderStore
        self.credentialStore = credentialStore
        let integrationRegistry = UserDefaultsIntegrationRegistry()
        Self.seedIntegrationRegistryIfNeeded(integrationRegistry, settings: settings)
        self.engine = Engine(
            settingsStore: settingsStore,
            credentialStore: credentialStore,
            endpointSelector: endpointSelector,
            reachabilityProbe: reachabilityProbe,
            settings: settings,
            routerPassword: routerPassword,
            integrationRegistry: integrationRegistry,
            installedProviderStore: installedProviderStore,
            activeMeasurementProcessRunner: SystemProcessRunner()
        )
    }

    deinit {
        subscriptionTask?.cancel()
    }

    /// First-run seed: the built-in integrations are listed (so they remain toggleable) but
    /// disabled at the integration-type level, leaving only pingscope active (pingscope hosts
    /// are seeded in M1). Existing installs keep their saved state.
    private static func seedIntegrationRegistryIfNeeded(_ registry: any IntegrationRegistry, settings: AppSettings) {
        guard ((try? registry.instances()) ?? []).isEmpty else { return }
        let builtIns = BuiltInIntegrationSeed.records(ecoflowEnabled: settings.ecoflowEnabled, includeActiveMeasurement: true)
        try? registry.save(builtIns)
        try? registry.setDisabledIntegrationIDs(BuiltInIntegrationSeed.integrationIDs)
    }

    func start() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in self.engine.snapshots {
                self.snapshot = snapshot
                self.selectedEndpoint = await self.engine.currentSelectedEndpoint()
                self.providerDisplayNames = await self.engine.providerDisplayNames()
                await self.refreshModuleUsage()
                let events = await self.alertEngine.evaluate(snapshot.engineSnapshot)
                await self.alertNotifier.deliver(events)
            }
        }
        Task { await engine.start() }
        Task { await refreshAlertRules() }
        refreshInstalledProviders()
        refreshCommandPalette()
    }

    func refresh() async {
        await engine.updateSettings(settings, routerPassword: routerPassword)
        await engine.refresh()
        selectedEndpoint = await engine.currentSelectedEndpoint()
        await refreshModuleUsage()
        refreshCommandPalette()
    }

    func saveSettings() {
        Task {
            let error = await engine.saveSettings(settings, routerPassword: routerPassword)
            if let error {
                snapshot.router.errorMessage = error
            }
            await refreshModuleUsage()
            refreshCommandPalette()
        }
    }

    func refreshCommandPalette() {
        Task {
            commandPalette = await engine.commandPalette()
            providerDisplayNames = await engine.providerDisplayNames()
            providerLayouts = await engine.providerLayouts()
            providerAlertRuleCounts = await engine.alertRules().reduce(into: [ProviderID: Int]()) { counts, rule in
                counts[rule.providerID, default: 0] += 1
            }
        }
    }

    func refreshInstalledProviders() {
        installedProviders = (try? installedProviderStore.load()) ?? []
        providerSetupSummaries = installedProviders.map {
            ProviderSetupSummary.make(record: $0, credentialStore: credentialStore)
        }
        loadProviderCredentialValues()
    }

    func credentialRequirements(for provider: InstalledProviderRecord) -> [ProviderManifest.Credential] {
        (try? ProviderManifestPackage.load(from: URL(fileURLWithPath: provider.packagePath, isDirectory: true)).manifest.credentials) ?? []
    }

    func credentialBinding(providerID: ProviderID, credentialID: String) -> Binding<String> {
        Binding(
            get: { self.providerCredentialValues[providerID]?[credentialID] ?? "" },
            set: { self.providerCredentialValues[providerID, default: [:]][credentialID] = $0 }
        )
    }

    func saveInstalledProviderCredentials(_ provider: InstalledProviderRecord) {
        do {
            for credential in credentialRequirements(for: provider) {
                let value = providerCredentialValues[provider.id]?[credential.id]
                try credentialStore.setCredential(
                    value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value,
                    for: CredentialKey(providerID: provider.id, id: credential.id)
                )
            }
            providerSetupError = nil
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    func installManifestProvider(from directory: URL) {
        do {
            _ = try installedProviderStore.installManifestPackage(at: directory)
            providerSetupError = nil
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    func refreshInstalledProviderValidation(_ providerID: ProviderID) {
        do {
            switch try installedProviderStore.refreshManifestPackageValidation(providerID: providerID) {
            case .valid, .missing:
                providerSetupError = nil
            case .invalid(_, let message):
                providerSetupError = message
            }
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    func setInstalledProvider(_ providerID: ProviderID, enabled: Bool) {
        do {
            try installedProviderStore.setEnabled(enabled, providerID: providerID)
            providerSetupError = nil
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    func removeInstalledProvider(_ providerID: ProviderID) {
        do {
            try installedProviderStore.remove(providerID: providerID)
            providerSetupError = nil
            reloadInstalledProviders()
        } catch {
            providerSetupError = error.localizedDescription
        }
    }

    private func reloadInstalledProviders() {
        refreshInstalledProviders()
        Task {
            await engine.reloadInstalledProviders()
            await refreshAlertRules()
            await refresh()
            refreshCommandPalette()
        }
    }

    private func refreshAlertRules() async {
        alertEngine = AlertEngine(rules: await engine.alertRules())
    }

    private func loadProviderCredentialValues() {
        var values = providerCredentialValues
        for provider in installedProviders {
            for credential in credentialRequirements(for: provider) {
                values[provider.id, default: [:]][credential.id] = (try? credentialStore.credential(
                    CredentialKey(providerID: provider.id, id: credential.id)
                )) ?? values[provider.id]?[credential.id] ?? ""
            }
        }
        providerCredentialValues = values
    }

    func executeCommand(_ item: CommandPaletteItem, arguments: CommandArguments = CommandArguments()) async {
        _ = await runProviderCommand(
            providerID: item.providerID,
            providerName: item.providerName,
            commandID: item.command.id,
            commandLabel: item.command.label,
            arguments: arguments
        )
    }

    @discardableResult
    private func runProviderCommand(
        providerID: ProviderID,
        providerName: String,
        commandID: String,
        commandLabel: String,
        arguments: CommandArguments = CommandArguments()
    ) async -> CommandExecutionResult {
        let itemID = "\(providerID).\(commandID)"
        executingCommandID = itemID
        lastCommandResult = nil
        let result = await engine.runCommand(
            provider: providerID,
            providerName: providerName,
            commandID: commandID,
            commandLabel: commandLabel,
            arguments: arguments
        )
        lastCommandResult = result
        switch result.status {
        case .succeeded:
            snapshot = await engine.currentSnapshot()
            selectedEndpoint = await engine.currentSelectedEndpoint()
            await refreshModuleUsage()
        case .failed:
            await refreshModuleUsage()
        }
        refreshCommandPalette()
        executingCommandID = nil
        return result
    }

    func refreshModuleUsage() async {
        moduleUsageSnapshots = Array(await engine.usageSnapshots().values)
    }

    func setSpeedifyFocused(_ isFocused: Bool) {
        Task { await engine.setSpeedifyFocused(isFocused) }
    }

    func refreshSpeedifyNow() async {
        await engine.refreshSpeedifyNow()
    }

    func toggleVPN() async {
        await runProviderCommand(
            providerID: ProviderIDs.vpn,
            providerName: providerDisplayNames[ProviderIDs.vpn] ?? "VPN",
            commandID: ProviderCommandIDs.vpnToggle,
            commandLabel: "Toggle VPN"
        )
    }

    func toggleSpeedify() async {
        await runProviderCommand(
            providerID: ProviderIDs.speedify,
            providerName: providerDisplayNames[ProviderIDs.speedify] ?? "Speedify",
            commandID: ProviderCommandIDs.speedifyToggle,
            commandLabel: "Toggle Speedify"
        )
    }

    func setSpeedifyBondingMode(_ mode: SpeedifyBondingMode) async {
        await runProviderCommand(
            providerID: ProviderIDs.speedify,
            providerName: providerDisplayNames[ProviderIDs.speedify] ?? "Speedify",
            commandID: ProviderCommandIDs.speedifySetBondingMode,
            commandLabel: "Set Bonding Mode",
            arguments: CommandArguments(values: ["mode": .string(mode.commandCode)])
        )
    }

    func setSpeedifyNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String) async {
        await runProviderCommand(
            providerID: ProviderIDs.speedify,
            providerName: providerDisplayNames[ProviderIDs.speedify] ?? "Speedify",
            commandID: ProviderCommandIDs.speedifySetNetworkPriority,
            commandLabel: "Set Network Priority",
            arguments: CommandArguments(values: ["priority": .number(Double(priority.rawValue)), "networkID": .string(networkID)])
        )
    }

    func setEcoFlowOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async -> EcoFlowControlResponse? {
        executingCommandID = "\(ProviderIDs.ecoflow).\(ProviderCommandIDs.ecoFlowSetOutput)"
        lastCommandResult = nil
        let response = await engine.setEcoFlowOutput(target, state: state)
        if response == nil {
            lastCommandResult = .failure(
                providerID: ProviderIDs.ecoflow,
                providerName: providerDisplayNames[ProviderIDs.ecoflow] ?? "EcoFlow",
                commandID: ProviderCommandIDs.ecoFlowSetOutput,
                commandLabel: "Set Output",
                errorMessage: "EcoFlow output command did not return a control response."
            )
        } else {
            lastCommandResult = .success(
                providerID: ProviderIDs.ecoflow,
                providerName: providerDisplayNames[ProviderIDs.ecoflow] ?? "EcoFlow",
                commandID: ProviderCommandIDs.ecoFlowSetOutput,
                commandLabel: "Set Output"
            )
        }
        snapshot = await engine.currentSnapshot()
        selectedEndpoint = await engine.currentSelectedEndpoint()
        await refreshModuleUsage()
        refreshCommandPalette()
        executingCommandID = nil
        return response
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

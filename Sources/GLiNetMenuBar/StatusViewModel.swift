import Foundation
import GLiNetCore
import SwiftUI

@MainActor
final class StatusViewModel: ObservableObject {
    @Published var snapshot = StatusSnapshot()
    @Published var settings: AppSettings
    @Published var routerPassword = ""
    @Published var selectedEndpoint: EndpointSelection?

    private let settingsStore: SettingsStore
    private let credentialStore: CredentialStore
    private let endpointSelector: EndpointSelector
    private let reachabilityProbe: ReachabilityProbeProtocol
    private let routerSpeedifyClient = RouterSpeedifyClient()
    private let clientPool = GLiNetClientPool()
    private var pollTask: Task<Void, Never>?
    private var speedifyFocusTask: Task<Void, Never>?
    private var routerBackoffUntil: Date?

    init(
        settingsStore: SettingsStore = UserDefaultsSettingsStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        endpointSelector: EndpointSelector = EndpointSelector(),
        reachabilityProbe: ReachabilityProbeProtocol = ReachabilityProbe()
    ) {
        self.settingsStore = settingsStore
        self.credentialStore = credentialStore
        self.endpointSelector = endpointSelector
        self.reachabilityProbe = reachabilityProbe
        self.settings = (try? settingsStore.load()) ?? AppSettings()
        self.routerPassword = (try? credentialStore.password(account: self.settings.username)) ?? RouterDefaults.routerPassword
    }

    deinit {
        pollTask?.cancel()
        speedifyFocusTask?.cancel()
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let interval = max(self.settings.pollInterval, 2)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func refresh() async {
        snapshot.router.isLoading = true
        snapshot.vpn.isLoading = true
        snapshot.reachability.isLoading = true
        snapshot.speedify.isLoading = true
        snapshot.starlink.isLoading = true
        snapshot.ecoflow.isLoading = settings.ecoflowEnabled

        async let endpointResult = resolveEndpoint()
        async let reachabilityResult = reachabilityProbe.probe()
        async let starlinkResult = loadStarlinkStatus()

        let endpoint = await endpointResult
        selectedEndpoint = endpoint.value
        async let ecoflowResult = loadEcoFlowStatus(routerHost: endpoint.value?.host)

        if let selection = endpoint.value, let url = URL.routerRPC(host: selection.host) {
            async let speedifyResult = loadSpeedifyStatus(host: selection.host)
            if let backoff = routerBackoffUntil, backoff > Date() {
                let message = "Router login paused for \(Self.formatRemaining(until: backoff))."
                snapshot.router = SourceState(value: snapshot.router.value, errorMessage: message)
                snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: message)
                snapshot.reachability = SourceState(value: await reachabilityResult)
                snapshot.speedify = await speedifyResult
                snapshot.starlink = await starlinkResult
                snapshot.ecoflow = await ecoflowResult
                snapshot.lastUpdated = Date()
                return
            }

            let client = await clientPool.client(endpoint: url, username: settings.username, passwordProvider: { [routerPassword] in routerPassword })
            let router = await loadRouterStatus(client: client)
            snapshot.router = router
            if router.errorMessage?.localizedCaseInsensitiveContains("locked") == true {
                snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: router.errorMessage)
            } else {
                snapshot.vpn = await loadVPNStatus(client: client)
            }
            snapshot.speedify = await speedifyResult
        } else {
            snapshot.router = SourceState(value: snapshot.router.value, errorMessage: endpoint.errorMessage)
            snapshot.vpn = SourceState(value: snapshot.vpn.value, errorMessage: endpoint.errorMessage)
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: endpoint.errorMessage)
        }

        snapshot.reachability = SourceState(value: await reachabilityResult)
        snapshot.starlink = await starlinkResult
        snapshot.ecoflow = await ecoflowResult
        snapshot.lastUpdated = Date()
    }

    func saveSettings() {
        do {
            try settingsStore.save(settings)
            try credentialStore.setPassword(routerPassword.isEmpty ? nil : routerPassword, account: settings.username)
            Task { await clientPool.removeAll() }
        } catch {
            snapshot.router.errorMessage = error.localizedDescription
        }
    }

    func setSpeedifyFocused(_ isFocused: Bool) {
        if isFocused {
            guard speedifyFocusTask == nil else { return }
            speedifyFocusTask = Task { [weak self] in
                guard let self else { return }
                await self.refreshSpeedifyOnly(markLoading: false)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await self.refreshSpeedifyOnly(markLoading: false)
                }
            }
        } else {
            speedifyFocusTask?.cancel()
            speedifyFocusTask = nil
        }
    }

    func refreshSpeedifyNow() async {
        await refreshSpeedifyOnly(markLoading: true)
    }

    func toggleVPN() async {
        guard
            let selection = selectedEndpoint,
            let url = URL.routerRPC(host: selection.host),
            let status = snapshot.vpn.value
        else { return }
        let client = await clientPool.client(endpoint: url, username: settings.username, passwordProvider: { [routerPassword] in routerPassword })
        do {
            try await client.setVPNEnabled(!status.isConnected, protocol: status.vpnProtocol)
            snapshot.vpn = await loadVPNStatus(client: client)
        } catch {
            snapshot.vpn.errorMessage = error.localizedDescription
        }
    }

    func toggleSpeedify() async {
        guard let selection = selectedEndpoint, let status = snapshot.speedify.value else { return }
        snapshot.speedify.isLoading = true
        do {
            if status.isConnected {
                try await routerSpeedifyClient.disconnect(host: selection.host)
            } else {
                try await routerSpeedifyClient.connect(host: selection.host)
            }
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
        }
    }

    func setSpeedifyBondingMode(_ mode: SpeedifyBondingMode) async {
        guard let selection = selectedEndpoint else { return }
        snapshot.speedify.isLoading = true
        do {
            try await routerSpeedifyClient.setBondingMode(mode, host: selection.host)
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
        }
    }

    func setSpeedifyNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String) async {
        guard let selection = selectedEndpoint else { return }
        snapshot.speedify.isLoading = true
        do {
            try await routerSpeedifyClient.setNetworkPriority(priority, networkID: networkID, host: selection.host)
            snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
        } catch {
            snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
        }
    }

    func setEcoFlowOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async -> EcoFlowControlResponse? {
        guard settings.ecoflowEnabled else { return nil }
        let host = settings.ecoflowHost == "auto" ? selectedEndpoint?.host : settings.ecoflowHost
        guard let host, !host.isEmpty, let baseURL = URL(string: "http://\(host):\(settings.ecoflowPort)") else {
            snapshot.ecoflow.errorMessage = "EcoFlow daemon endpoint unresolved."
            return nil
        }

        let client = EcoFlowHTTPClient(baseURL: baseURL)
        do {
            let response = try await client.setOutput(target, state: state)
            snapshot.ecoflow = await loadEcoFlowStatus(routerHost: selectedEndpoint?.host)
            return response
        } catch {
            snapshot.ecoflow = SourceState(value: snapshot.ecoflow.value, errorMessage: error.localizedDescription)
            return nil
        }
    }

    private func refreshSpeedifyOnly(markLoading: Bool) async {
        if markLoading {
            snapshot.speedify.isLoading = true
        }
        let selection: EndpointSelection?
        if let selectedEndpoint {
            selection = selectedEndpoint
        } else {
            let endpoint = await resolveEndpoint()
            selectedEndpoint = endpoint.value
            selection = endpoint.value
            if endpoint.value == nil {
                snapshot.speedify = SourceState(value: snapshot.speedify.value, errorMessage: endpoint.errorMessage)
                return
            }
        }
        guard let selection else { return }
        snapshot.speedify = await loadSpeedifyStatus(host: selection.host)
        snapshot.lastUpdated = Date()
    }

    private func resolveEndpoint() async -> SourceState<EndpointSelection> {
        do {
            let endpoint = try await endpointSelector.select(settings: settings)
            return SourceState(value: endpoint)
        } catch {
            return SourceState(errorMessage: error.localizedDescription)
        }
    }

    private func loadRouterStatus(client: GLiNetClient) async -> SourceState<RouterStatus> {
        do {
            return SourceState(value: try await client.routerStatus())
        } catch {
            noteRouterError(error)
            return SourceState(value: snapshot.router.value, errorMessage: error.localizedDescription)
        }
    }

    private func loadVPNStatus(client: GLiNetClient) async -> SourceState<VPNStatus> {
        do {
            return SourceState(value: try await client.vpnStatus())
        } catch {
            noteRouterError(error)
            return SourceState(value: snapshot.vpn.value, errorMessage: error.localizedDescription)
        }
    }

    private func loadSpeedifyStatus(host: String) async -> SourceState<SpeedifyStatus> {
        do {
            let status = try await routerSpeedifyClient.status(host: host)
                .mergingLiveSamples(from: snapshot.speedify.value)
            return SourceState(value: status)
        } catch {
            return SourceState(value: snapshot.speedify.value, errorMessage: error.localizedDescription)
        }
    }

    private func loadStarlinkStatus() async -> SourceState<StarlinkStatus> {
        let client = StarlinkClient(path: settings.grpcurlPath)
        let status = await client.status()
        if status.isReachable {
            return SourceState(value: status)
        }
        return SourceState(value: snapshot.starlink.value, errorMessage: status.state)
    }

    private func loadEcoFlowStatus(routerHost: String?) async -> SourceState<EcoFlowSnapshot> {
        guard settings.ecoflowEnabled else {
            return SourceState()
        }
        let host = settings.ecoflowHost == "auto" ? routerHost : settings.ecoflowHost
        guard let host, !host.isEmpty else {
            return SourceState(value: snapshot.ecoflow.value, errorMessage: "EcoFlow daemon endpoint unresolved.")
        }
        guard let baseURL = URL(string: "http://\(host):\(settings.ecoflowPort)") else {
            return SourceState(value: snapshot.ecoflow.value, errorMessage: "EcoFlow daemon endpoint is invalid.")
        }

        let client = EcoFlowHTTPClient(baseURL: baseURL)
        do {
            async let device = try? client.device()
            async let status = client.status()
            async let outputs = try? client.outputs()
            async let stats = try? client.stats()
            return SourceState(value: try await EcoFlowSnapshot(
                device: await device,
                status: status,
                outputs: await outputs,
                stats: await stats
            ))
        } catch {
            return SourceState(value: snapshot.ecoflow.value, errorMessage: error.localizedDescription)
        }
    }

    private func noteRouterError(_ error: Error) {
        guard
            let clientError = error as? JSONRPCClientError,
            let wait = clientError.retryAfterSeconds
        else { return }
        routerBackoffUntil = Date().addingTimeInterval(TimeInterval(wait))
    }

    private static func formatRemaining(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded(.up)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 {
            return "\(remainder)s"
        }
        if remainder == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(remainder)s"
    }
}

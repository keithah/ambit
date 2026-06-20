import Foundation
import XCTest
@testable import AmbitCore

final class EngineTests: XCTestCase {
    func testRefreshPublishesPollCycleThroughCoreEngine() async {
        let routerClient = StubRouterClient(
            routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem, publicIP: "203.0.113.10"),
            vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true, server: "sjc")
        )
        let speedify = SpeedifyStatus(
            isInstalled: true,
            isAvailable: true,
            isConnected: true,
            state: "Connected",
            server: "Auto",
            bondingMode: .speed,
            graphSamples: [SpeedifyGraphSample(totalBps: 12_000, downloadBps: 8_000, uploadBps: 4_000)]
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.042))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: speedify),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in routerClient },
            starlinkStatusProvider: { _ in
                StarlinkStatus(isReachable: true, state: "Online", downlinkThroughputBps: 100_000, popPingLatencyMs: 31)
            }
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        let selectedEndpoint = await engine.currentSelectedEndpoint()
        XCTAssertEqual(selectedEndpoint?.host, "router.local")
        XCTAssertEqual(snapshot.router.value?.hostname, "GL-X3000")
        XCTAssertEqual(snapshot.vpn.value?.isConnected, true)
        XCTAssertEqual(snapshot.reachability.value?.state, .online(latency: 0.042))
        XCTAssertEqual(snapshot.speedify.value?.server, "Auto")
        XCTAssertEqual(snapshot.starlink.value?.state, "Online")
        XCTAssertEqual(snapshot.providers[ProviderIDs.router]?.value?.health, .ok)
        XCTAssertEqual(snapshot.providers[ProviderIDs.vpn]?.value?.metricValue("connected"), .bool(true))
        XCTAssertEqual(snapshot.providers[ProviderIDs.speedify]?.value?.metricValue("throughput_bps"), .throughput(bitsPerSecond: 12_000))
        XCTAssertEqual(snapshot.providers[ProviderIDs.starlink]?.value?.metricValue("pop_latency_ms"), .latency(ms: 31))

        let usage = await engine.usageSnapshots()
        XCTAssertEqual(usage[ProviderIDs.router]?.pollCount, 1)
        XCTAssertEqual(usage[ProviderIDs.vpn]?.pollCount, 1)
        XCTAssertEqual(usage[ProviderIDs.reachability]?.pollCount, 1)
        XCTAssertEqual(usage[ProviderIDs.speedify]?.pollCount, 1)
        XCTAssertEqual(usage[ProviderIDs.starlink]?.pollCount, 1)
    }

    func testCommandUsageIsRecorded() async {
        let routerClient = StubRouterClient(
            routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
            vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Disconnected")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in routerClient },
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()
        await engine.toggleVPN()

        let usage = await engine.usageSnapshots()
        XCTAssertEqual(usage[ProviderIDs.vpn]?.commandCount, 1)
        XCTAssertEqual(usage[ProviderIDs.vpn]?.failureCount, 0)
        XCTAssertEqual(routerClient.vpnEnabledRequests, [false])
    }

    func testDispatchRoutesProviderCommandToExistingCommandPath() async throws {
        let routerClient = StubRouterClient(
            routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
            vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Disconnected")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in routerClient },
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()
        try await engine.dispatch(provider: ProviderIDs.vpn, commandID: ProviderCommandIDs.vpnToggle)

        XCTAssertEqual(routerClient.vpnEnabledRequests, [false])
    }

    func testDispatchRoutesSpeedifyToggleCommand() async throws {
        let speedifyClient = StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Disconnected"))
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: speedifyClient,
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()
        try await engine.dispatch(provider: ProviderIDs.speedify, commandID: ProviderCommandIDs.speedifyToggle)

        XCTAssertEqual(speedifyClient.connectHosts, ["router.local"])
    }


    func testDispatchRejectsUnsupportedProviderCommand() async {
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret"
        )

        do {
            try await engine.dispatch(provider: "unknown", commandID: "unknown.command")
            XCTFail("Expected unsupported dispatch to throw.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Unsupported provider command unknown.unknown.command"))
        }
    }

    func testEcoFlowMetricExtraction() {
        let snapshot = EcoFlowSnapshot(
            status: EcoFlowDeviceStatus(
                battery: EcoFlowBatteryStatus(percent: 18, state: .discharging),
                power: EcoFlowPowerStatus(inputWatts: 10, outputWatts: 42, netWatts: -32),
                outputs: EcoFlowOutputMap(
                    ac: EcoFlowOutputStatus(state: .on, watts: 40),
                    dc: EcoFlowOutputStatus(state: .off, watts: 0),
                    usb: EcoFlowOutputStatus(state: .off, watts: 2)
                ),
                updatedAt: "2026-06-19T00:00:00Z"
            )
        )

        let provider = ProviderSnapshot.ecoFlow(snapshot)

        XCTAssertEqual(provider.health, .degraded)
        XCTAssertEqual(provider.metricValue("battery_percent"), .level(18))
        XCTAssertEqual(provider.metricValue("output_watts"), .level(42))
        XCTAssertEqual(provider.metricValue("ac_output"), .bool(true))
    }
}

private extension ProviderSnapshot {
    func metricValue(_ id: String) -> MetricValue? {
        metrics.first { $0.id == id }?.value
    }
}

private struct InMemorySettingsStore: SettingsStore {
    var settings: AppSettings

    func load() throws -> AppSettings {
        settings
    }

    func save(_ settings: AppSettings) throws {}
}

private final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    var password: String?

    init(password: String?) {
        self.password = password
    }

    func password(account: String) throws -> String? {
        password
    }

    func setPassword(_ password: String?, account: String) throws {
        self.password = password
    }
}

private struct StubReachabilityProbe: ReachabilityProbeProtocol {
    var status: ReachabilityStatus

    func probe() async -> ReachabilityStatus {
        status
    }
}

private final class StubRouterClient: GLiNetClientProtocol, @unchecked Sendable {
    var routerStatusResult: RouterStatus
    var vpnStatusResult: VPNStatus
    private(set) var vpnEnabledRequests: [Bool] = []

    init(routerStatus: RouterStatus, vpnStatus: VPNStatus) {
        self.routerStatusResult = routerStatus
        self.vpnStatusResult = vpnStatus
    }

    func call(service: String, method: String, args: JSONObject) async throws -> JSONObject {
        [:]
    }

    func routerStatus() async throws -> RouterStatus {
        routerStatusResult
    }

    func vpnStatus() async throws -> VPNStatus {
        vpnStatusResult
    }

    func setVPNEnabled(_ enabled: Bool, protocol vpnProtocol: VPNProtocol) async throws {
        vpnEnabledRequests.append(enabled)
    }
}

private final class StubRouterSpeedifyClient: RouterSpeedifyClientProtocol, @unchecked Sendable {
    var status: SpeedifyStatus
    private(set) var connectHosts: [String] = []

    init(status: SpeedifyStatus) {
        self.status = status
    }

    func status(host: String) async throws -> SpeedifyStatus {
        status
    }

    func connect(host: String, server: String) async throws {
        connectHosts.append(host)
    }
    func disconnect(host: String) async throws {}
    func setBondingMode(_ mode: SpeedifyBondingMode, host: String) async throws {}
    func setNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String, host: String) async throws {}
}

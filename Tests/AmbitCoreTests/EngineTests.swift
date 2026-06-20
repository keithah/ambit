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

private struct StubRouterSpeedifyClient: RouterSpeedifyClientProtocol {
    var status: SpeedifyStatus

    func status(host: String) async throws -> SpeedifyStatus {
        status
    }

    func connect(host: String, server: String) async throws {}
    func disconnect(host: String) async throws {}
    func setBondingMode(_ mode: SpeedifyBondingMode, host: String) async throws {}
    func setNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String, host: String) async throws {}
}

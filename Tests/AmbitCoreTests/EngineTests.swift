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

    func testRefreshPublishesNormalizedEngineSnapshotStream() async {
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
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in routerClient },
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        let streamTask = Task<EngineSnapshot?, Never> {
            var iterator = engine.engineSnapshots.makeAsyncIterator()
            while let snapshot = await iterator.next() {
                if snapshot.providers[ProviderIDs.router]?.value != nil {
                    return snapshot
                }
            }
            return nil
        }

        await engine.refresh()

        let snapshot = await streamTask.value
        XCTAssertEqual(snapshot?.providers[ProviderIDs.router]?.value?.health, .ok)
        XCTAssertEqual(snapshot?.providers[ProviderIDs.vpn]?.value?.metricValue("connected"), .bool(true))
    }

    func testRefreshPollsRegisteredProviderIntoProviderSnapshotMap() async {
        let provider = StubProvider(
            id: "demo",
            snapshot: ProviderSnapshot(
                health: .ok,
                metrics: [Metric(id: "sample", label: "Sample", value: .level(1))]
            )
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            providers: [provider],
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providers["demo"]?.value?.health, .ok)
        XCTAssertEqual(snapshot.providers["demo"]?.value?.metricValue("sample"), .level(1))
        let pollCount = await provider.currentPollCount()
        XCTAssertEqual(pollCount, 1)
    }

    func testRefreshSkipsRegisteredProviderUntilPollIntervalElapses() async {
        let provider = StubProvider(
            id: "slow",
            snapshot: ProviderSnapshot(
                health: .ok,
                metrics: [Metric(id: "sample", label: "Sample", value: .level(1))]
            ),
            pollInterval: 3_600
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            providers: [provider],
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()
        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providers["slow"]?.value?.metricValue("sample"), .level(1))
        let pollCount = await provider.currentPollCount()
        XCTAssertEqual(pollCount, 1)
    }

    func testRefreshCanRegisterBuiltInProvidersByDefault() async {
        let routerClient = StubRouterClient(
            routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
            vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
        )
        let reachabilityProbe = StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01)))
        let speedifyClient = StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected"))
        let starlinkCounter = CallCounter()
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: reachabilityProbe,
            routerSpeedifyClient: speedifyClient,
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in routerClient },
            registerBuiltInProviders: true,
            starlinkStatusProvider: { _ in
                starlinkCounter.increment()
                return StarlinkStatus(isReachable: true, state: "Online")
            }
        )

        await engine.refresh()
        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providerRouterStatus?.hostname, "GL-X3000")
        XCTAssertEqual(snapshot.providerVPNStatus?.isConnected, true)
        XCTAssertEqual(snapshot.providerSpeedifyStatus?.isConnected, true)
        XCTAssertEqual(snapshot.providerReachabilityStatus?.state, .online(latency: 0.01))
        XCTAssertEqual(snapshot.providerStarlinkStatus?.state, "Online")
        XCTAssertEqual(routerClient.routerStatusCallCount, 1)
        XCTAssertEqual(routerClient.vpnStatusCallCount, 1)
        XCTAssertEqual(speedifyClient.statusCallCount, 1)
        XCTAssertEqual(reachabilityProbe.callCount, 1)
        XCTAssertEqual(starlinkCounter.count, 1)
    }

    func testRefreshUsesRegisteredSpeedifyProviderInsteadOfLegacyPoller() async {
        let provider = StubProvider(
            id: ProviderIDs.speedify,
            snapshot: ProviderSnapshot.speedify(
                SpeedifyStatus(
                    isInstalled: true,
                    isAvailable: true,
                    isConnected: true,
                    state: "Connected",
                    server: "Provider"
                )
            )
        )
        let speedifyClient = StubRouterSpeedifyClient(
            status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Legacy")
        )
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
            providers: [provider],
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providerSpeedifyStatus?.server, "Provider")
        XCTAssertEqual(speedifyClient.statusCallCount, 0)
        let pollCount = await provider.currentPollCount()
        XCTAssertEqual(pollCount, 1)
    }

    func testRefreshUsesRegisteredReachabilityProviderInsteadOfLegacyProbe() async {
        let provider = StubProvider(
            id: ProviderIDs.reachability,
            snapshot: ProviderSnapshot.reachability(
                ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.123))
            )
        )
        let reachabilityProbe = StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: false, state: .offline))
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: reachabilityProbe,
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Legacy")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            providers: [provider],
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providerReachabilityStatus?.state, .online(latency: 0.123))
        XCTAssertEqual(reachabilityProbe.callCount, 0)
        let pollCount = await provider.currentPollCount()
        XCTAssertEqual(pollCount, 1)
    }

    func testRefreshUsesRegisteredStarlinkProviderInsteadOfLegacyStatusProvider() async {
        let provider = StubProvider(
            id: ProviderIDs.starlink,
            snapshot: ProviderSnapshot.starlink(
                StarlinkStatus(isReachable: true, state: "Online", downlinkThroughputBps: 123_000)
            )
        )
        let starlinkCounter = CallCounter()
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Legacy")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            providers: [provider],
            starlinkStatusProvider: { _ in
                starlinkCounter.increment()
                return StarlinkStatus(isReachable: false, state: "Legacy")
            }
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providerStarlinkStatus?.state, "Online")
        XCTAssertEqual(starlinkCounter.count, 0)
        let pollCount = await provider.currentPollCount()
        XCTAssertEqual(pollCount, 1)
    }

    func testRefreshUsesRegisteredEcoFlowProviderInsteadOfLegacyClientFactory() async {
        let provider = StubProvider(
            id: ProviderIDs.ecoflow,
            snapshot: ProviderSnapshot.ecoFlow(
                EcoFlowSnapshot(
                    status: EcoFlowDeviceStatus(
                        battery: EcoFlowBatteryStatus(percent: 88, state: .discharging),
                        power: EcoFlowPowerStatus(inputWatts: 0, outputWatts: 9, netWatts: -9),
                        outputs: EcoFlowOutputMap(
                            ac: EcoFlowOutputStatus(state: .off, watts: 0),
                            dc: EcoFlowOutputStatus(state: .off, watts: 0),
                            usb: EcoFlowOutputStatus(state: .on, watts: 9)
                        ),
                        updatedAt: "2026-06-20T00:00:00Z"
                    )
                )
            )
        )
        let ecoFlowFactoryCounter = CallCounter()
        let settings = AppSettings(localHost: "router.local", ecoflowEnabled: true)
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: settings),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Legacy")),
            settings: settings,
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            providers: [provider],
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") },
            ecoFlowClientFactory: { _ in
                ecoFlowFactoryCounter.increment()
                return StubEcoFlowClient()
            }
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providerEcoFlowSnapshot?.status.battery.percent, 88)
        XCTAssertEqual(ecoFlowFactoryCounter.count, 0)
        let pollCount = await provider.currentPollCount()
        XCTAssertEqual(pollCount, 1)
    }

    func testBuiltInEcoFlowProviderFollowsSettingsToggle() async {
        let factoryCounter = CallCounter()
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local", ecoflowEnabled: false)),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Disconnected")),
            settings: AppSettings(localHost: "router.local", ecoflowEnabled: false),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            registerBuiltInProviders: true,
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") },
            ecoFlowClientFactory: { _ in
                factoryCounter.increment()
                return StubEcoFlowClient()
            }
        )

        await engine.refresh()

        var snapshot = await engine.currentSnapshot()
        XCTAssertNil(snapshot.providers[ProviderIDs.ecoflow])
        XCTAssertEqual(factoryCounter.count, 0)

        await engine.updateSettings(AppSettings(localHost: "router.local", ecoflowEnabled: true), routerPassword: "secret")
        await engine.refresh()

        snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providerEcoFlowSnapshot?.status.battery.percent, 75)
        XCTAssertEqual(factoryCounter.count, 1)

        await engine.updateSettings(AppSettings(localHost: "router.local", ecoflowEnabled: false), routerPassword: "secret")
        await engine.refresh()

        snapshot = await engine.currentSnapshot()
        XCTAssertNil(snapshot.providers[ProviderIDs.ecoflow])
        XCTAssertEqual(factoryCounter.count, 1)
    }

    func testRefreshCanRegisterActiveMeasurementProvidersByDefault() async {
        let pingOutput = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=58 time=10.000 ms

        --- 1.1.1.1 ping statistics ---
        3 packets transmitted, 3 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 10.000/10.000/10.000/0.000 ms
        """
        let processRunner = StubProcessRunner(results: [
            "-c 3 -W 1000 1.1.1.1": ProcessResult(exitCode: 0, stdout: pingOutput, stderr: "")
        ])
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
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            registerBuiltInProviders: true,
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") },
            activeMeasurementProcessRunner: processRunner
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providers[ProviderIDs.ping]?.value?.metricValue("latency_ms"), .latency(ms: 10))
        XCTAssertEqual(snapshot.providers[ProviderIDs.iperf3]?.value?.detail, .iperf3(Iperf3Snapshot(host: "")))
        let commands = await engine.commands(provider: ProviderIDs.iperf3)
        XCTAssertEqual(commands.map(\.id), [ProviderCommandIDs.iperf3Run])
    }

    func testDispatchRunsBuiltInIperf3ProviderAndPublishesMetrics() async throws {
        let iperfOutput = """
        {
          "end": {
            "sum_sent": { "bits_per_second": 12000000 },
            "sum_received": { "bits_per_second": 11000000 }
          }
        }
        """
        let processRunner = StubProcessRunner(results: [
            "-c 3 -W 1000 1.1.1.1": ProcessResult(exitCode: 127, stdout: "", stderr: "not run"),
            "-J -t 5 -c iperf.example": ProcessResult(exitCode: 0, stdout: iperfOutput, stderr: "")
        ])
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
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            registerBuiltInProviders: true,
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") },
            activeMeasurementProcessRunner: processRunner
        )
        await engine.refresh()

        try await engine.dispatch(
            provider: ProviderIDs.iperf3,
            commandID: ProviderCommandIDs.iperf3Run,
            arguments: CommandArguments(values: ["host": .string("iperf.example")])
        )

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providers[ProviderIDs.iperf3]?.value?.metricValue("download_bps"), .throughput(bitsPerSecond: 11_000_000))
        XCTAssertEqual(snapshot.providers[ProviderIDs.iperf3]?.value?.metricValue("upload_bps"), .throughput(bitsPerSecond: 12_000_000))
        XCTAssertEqual(snapshot.providers[ProviderIDs.iperf3]?.errorMessage, nil)
    }

    func testRefreshUsesRegisteredRouterProviderInsteadOfLegacyRouterPoll() async {
        let provider = StubProvider(
            id: ProviderIDs.router,
            snapshot: ProviderSnapshot.router(
                RouterStatus(reachable: true, hostname: "Provider Router", activeWAN: .wired)
            )
        )
        let routerClient = StubRouterClient(
            routerStatus: RouterStatus(reachable: true, hostname: "Legacy Router", activeWAN: .modem),
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
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Legacy")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in routerClient },
            providers: [provider],
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providerRouterStatus?.hostname, "Provider Router")
        XCTAssertEqual(routerClient.routerStatusCallCount, 0)
        XCTAssertEqual(routerClient.vpnStatusCallCount, 1)
        let pollCount = await provider.currentPollCount()
        XCTAssertEqual(pollCount, 1)
    }

    func testRefreshUsesRegisteredVPNProviderInsteadOfLegacyVPNPoll() async {
        let provider = StubProvider(
            id: ProviderIDs.vpn,
            snapshot: ProviderSnapshot.vpn(VPNStatus(protocol: .wireGuard, isConnected: true, server: "Provider VPN"))
        )
        let routerClient = StubRouterClient(
            routerStatus: RouterStatus(reachable: true, hostname: "Legacy Router", activeWAN: .modem),
            vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: false, server: "Legacy VPN")
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: false, state: "Legacy")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in routerClient },
            providers: [provider],
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(snapshot.providerVPNStatus?.server, "Provider VPN")
        XCTAssertEqual(routerClient.routerStatusCallCount, 1)
        XCTAssertEqual(routerClient.vpnStatusCallCount, 0)
        let pollCount = await provider.currentPollCount()
        XCTAssertEqual(pollCount, 1)
    }

    func testRegisteredRouterProviderLoginLimitActivatesBackoff() async {
        let routerClient = StubRouterClient(
            routerStatus: RouterStatus(reachable: true, hostname: "Legacy Router", activeWAN: .modem),
            vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
        )
        routerClient.routerStatusError = JSONRPCClientError.rpc(
            JSONRPCError(
                code: -32003,
                message: "Login fail number over limit",
                data: .object(["wait": .number(5)])
            )
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected")),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in routerClient },
            registerBuiltInProviders: true,
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()
        await engine.refresh()

        let snapshot = await engine.currentSnapshot()
        XCTAssertEqual(routerClient.routerStatusCallCount, 1)
        XCTAssertEqual(snapshot.providerErrorMessage(ProviderIDs.router)?.hasPrefix("Router login paused for "), true)
    }

    func testDispatchRoutesRegisteredProviderCommand() async throws {
        let provider = StubProvider(
            id: "demo",
            snapshot: ProviderSnapshot(health: .ok),
            commands: [CommandDescriptor(id: "demo.run", label: "Run Demo")]
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            providers: [provider]
        )

        try await engine.dispatch(
            provider: "demo",
            commandID: "demo.run",
            arguments: CommandArguments(values: ["sample": .string("value")])
        )

        let command = await provider.lastCommand()
        XCTAssertEqual(command?.id, "demo.run")
        XCTAssertEqual(command?.arguments, CommandArguments(values: ["sample": .string("value")]))
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

    func testDispatchRoutesBuiltInCommandToRegisteredProviderWhenRegistered() async throws {
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
            registerBuiltInProviders: true,
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") }
        )

        await engine.refresh()
        try await engine.dispatch(provider: ProviderIDs.speedify, commandID: ProviderCommandIDs.speedifyToggle)

        XCTAssertEqual(speedifyClient.connectHosts, ["router.local"])
    }

    func testDispatchRoutesSpeedifyBondingModeCommandWithArguments() async throws {
        let speedifyClient = StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected"))
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
        try await engine.dispatch(
            provider: ProviderIDs.speedify,
            commandID: ProviderCommandIDs.speedifySetBondingMode,
            arguments: CommandArguments(values: ["mode": .string("RD")])
        )

        XCTAssertEqual(speedifyClient.bondingModeRequests, [.init(mode: .redundant, host: "router.local")])
    }

    func testDispatchRoutesSpeedifyNetworkPriorityCommandWithArguments() async throws {
        let speedifyClient = StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected"))
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
        try await engine.dispatch(
            provider: ProviderIDs.speedify,
            commandID: ProviderCommandIDs.speedifySetNetworkPriority,
            arguments: CommandArguments(values: ["priority": .number(2), "networkID": .string("cellular-1")])
        )

        XCTAssertEqual(speedifyClient.networkPriorityRequests, [.init(priority: .backup, networkID: "cellular-1", host: "router.local")])
    }

    func testDispatchRoutesEcoFlowOutputCommandWithArguments() async throws {
        let ecoFlowClient = StubEcoFlowClient()
        let settings = AppSettings(localHost: "router.local", ecoflowEnabled: true)
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: settings),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            endpointSelector: EndpointSelector(
                prober: StubEndpointProber(results: ["router.local": .success(afterNanoseconds: 0)]),
                addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)
            ),
            reachabilityProbe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.01))),
            routerSpeedifyClient: StubRouterSpeedifyClient(status: SpeedifyStatus(isInstalled: true, isAvailable: true, isConnected: true, state: "Connected")),
            settings: settings,
            routerPassword: "secret",
            routerClientFactory: { _, _, _ in StubRouterClient(
                routerStatus: RouterStatus(reachable: true, hostname: "GL-X3000", activeWAN: .modem),
                vpnStatus: VPNStatus(protocol: .wireGuard, isConnected: true)
            ) },
            starlinkStatusProvider: { _ in StarlinkStatus(isReachable: false, state: "Unavailable") },
            ecoFlowClientFactory: { _ in ecoFlowClient }
        )

        await engine.refresh()
        try await engine.dispatch(
            provider: ProviderIDs.ecoflow,
            commandID: ProviderCommandIDs.ecoFlowSetOutput,
            arguments: CommandArguments(values: ["target": .string("ac"), "state": .string("off")])
        )

        XCTAssertEqual(ecoFlowClient.outputRequests, [.init(target: .ac, state: .off)])
    }

    func testExposesProviderCommandMetadata() async {
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret"
        )

        let vpnCommands = await engine.commands(provider: ProviderIDs.vpn)
        let speedifyCommands = await engine.commands(provider: ProviderIDs.speedify)
        let ecoFlowCommands = await engine.commands(provider: ProviderIDs.ecoflow)

        XCTAssertEqual(vpnCommands.map(\.id), [ProviderCommandIDs.vpnToggle])
        XCTAssertEqual(speedifyCommands.map(\.id), [
            ProviderCommandIDs.speedifyToggle,
            ProviderCommandIDs.speedifySetBondingMode,
            ProviderCommandIDs.speedifySetNetworkPriority
        ])
        XCTAssertEqual(
            speedifyCommands.first { $0.id == ProviderCommandIDs.speedifySetBondingMode }?.parameters,
            [CommandParameter(id: "mode", label: "Mode", kind: .option(["SP", "RD", "STR"]))]
        )
        XCTAssertEqual(ecoFlowCommands.map(\.id), [ProviderCommandIDs.ecoFlowSetOutput])
        XCTAssertEqual(
            ecoFlowCommands.first?.parameters,
            [
                CommandParameter(id: "target", label: "Output", kind: .option(["ac", "dc", "usb"])),
                CommandParameter(id: "state", label: "State", kind: .option(["on", "off"]))
            ]
        )
    }

    func testExposesRegisteredProviderCommandMetadata() async {
        let provider = StubProvider(
            id: "demo",
            snapshot: ProviderSnapshot(health: .ok),
            commands: [
                CommandDescriptor(
                    id: "demo.run",
                    label: "Run Demo",
                    parameters: [CommandParameter(id: "sample", label: "Sample", kind: .text)]
                )
            ]
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            providers: [provider]
        )

        let commands = await engine.commands(provider: "demo")

        XCTAssertEqual(commands, provider.commands)
    }

    func testExposesRegisteredCommandsForBuiltInProviderID() async {
        let provider = StubProvider(
            id: ProviderIDs.speedify,
            snapshot: ProviderSnapshot(health: .ok),
            commands: [
                CommandDescriptor(id: ProviderCommandIDs.speedifyToggle, label: "Custom Toggle"),
                CommandDescriptor(id: "speedify.custom", label: "Custom Speedify Command")
            ]
        )
        let engine = Engine(
            settingsStore: InMemorySettingsStore(settings: AppSettings(localHost: "router.local")),
            credentialStore: InMemoryCredentialStore(password: "secret"),
            settings: AppSettings(localHost: "router.local"),
            routerPassword: "secret",
            providers: [provider]
        )

        let commands = await engine.commands(provider: ProviderIDs.speedify)

        XCTAssertEqual(commands.map(\.id), [
            ProviderCommandIDs.speedifyToggle,
            ProviderCommandIDs.speedifySetBondingMode,
            ProviderCommandIDs.speedifySetNetworkPriority,
            "speedify.custom"
        ])
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

private actor StubProvider: Provider {
    let id: ProviderID
    let displayName: String
    let pollInterval: TimeInterval
    let commands: [CommandDescriptor]
    private let snapshot: ProviderSnapshot
    private(set) var pollCount = 0
    private var executedCommands: [(id: String, arguments: CommandArguments)] = []

    init(id: ProviderID, snapshot: ProviderSnapshot, pollInterval: TimeInterval = 10, commands: [CommandDescriptor] = []) {
        self.id = id
        self.displayName = id
        self.pollInterval = pollInterval
        self.snapshot = snapshot
        self.commands = commands
    }

    func poll(context: EnvironmentContext) async -> ProviderSnapshot {
        pollCount += 1
        return snapshot
    }

    func currentPollCount() -> Int {
        pollCount
    }

    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws {
        executedCommands.append((id: commandID, arguments: arguments))
    }

    func lastCommand() -> (id: String, arguments: CommandArguments)? {
        executedCommands.last
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

private final class StubReachabilityProbe: ReachabilityProbeProtocol, @unchecked Sendable {
    var status: ReachabilityStatus
    private(set) var callCount = 0

    init(status: ReachabilityStatus) {
        self.status = status
    }

    func probe() async -> ReachabilityStatus {
        callCount += 1
        return status
    }
}

private final class CallCounter: @unchecked Sendable {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private final class StubRouterClient: GLiNetClientProtocol, @unchecked Sendable {
    var routerStatusResult: RouterStatus
    var vpnStatusResult: VPNStatus
    var routerStatusError: Error?
    var vpnStatusError: Error?
    private(set) var routerStatusCallCount = 0
    private(set) var vpnStatusCallCount = 0
    private(set) var vpnEnabledRequests: [Bool] = []

    init(routerStatus: RouterStatus, vpnStatus: VPNStatus) {
        self.routerStatusResult = routerStatus
        self.vpnStatusResult = vpnStatus
    }

    func call(service: String, method: String, args: JSONObject) async throws -> JSONObject {
        [:]
    }

    func routerStatus() async throws -> RouterStatus {
        routerStatusCallCount += 1
        if let routerStatusError {
            throw routerStatusError
        }
        return routerStatusResult
    }

    func vpnStatus() async throws -> VPNStatus {
        vpnStatusCallCount += 1
        if let vpnStatusError {
            throw vpnStatusError
        }
        return vpnStatusResult
    }

    func setVPNEnabled(_ enabled: Bool, protocol vpnProtocol: VPNProtocol) async throws {
        vpnEnabledRequests.append(enabled)
    }
}

private final class StubRouterSpeedifyClient: RouterSpeedifyClientProtocol, @unchecked Sendable {
    struct BondingModeRequest: Equatable {
        var mode: SpeedifyBondingMode
        var host: String
    }

    struct NetworkPriorityRequest: Equatable {
        var priority: SpeedifyNetworkPriority
        var networkID: String
        var host: String
    }

    var status: SpeedifyStatus
    private(set) var statusCallCount = 0
    private(set) var connectHosts: [String] = []
    private(set) var bondingModeRequests: [BondingModeRequest] = []
    private(set) var networkPriorityRequests: [NetworkPriorityRequest] = []

    init(status: SpeedifyStatus) {
        self.status = status
    }

    func status(host: String) async throws -> SpeedifyStatus {
        statusCallCount += 1
        return status
    }

    func connect(host: String, server: String) async throws {
        connectHosts.append(host)
    }
    func disconnect(host: String) async throws {}

    func setBondingMode(_ mode: SpeedifyBondingMode, host: String) async throws {
        bondingModeRequests.append(BondingModeRequest(mode: mode, host: host))
    }

    func setNetworkPriority(_ priority: SpeedifyNetworkPriority, networkID: String, host: String) async throws {
        networkPriorityRequests.append(NetworkPriorityRequest(priority: priority, networkID: networkID, host: host))
    }
}

private final class StubEcoFlowClient: EcoFlowClientProtocol, @unchecked Sendable {
    struct OutputRequest: Equatable {
        var target: EcoFlowOutputTarget
        var state: EcoFlowOutputState
    }

    private(set) var outputRequests: [OutputRequest] = []

    func device() async throws -> EcoFlowDeviceInfo {
        throw JSONRPCClientError.commandFailed("device unavailable")
    }

    func status() async throws -> EcoFlowDeviceStatus {
        EcoFlowDeviceStatus(
            battery: EcoFlowBatteryStatus(percent: 75, state: .discharging),
            power: EcoFlowPowerStatus(inputWatts: 0, outputWatts: 10, netWatts: -10),
            outputs: EcoFlowOutputMap(
                ac: EcoFlowOutputStatus(state: .off, watts: 0),
                dc: EcoFlowOutputStatus(state: .off, watts: 0),
                usb: EcoFlowOutputStatus(state: .on, watts: 10)
            ),
            updatedAt: "2026-06-19T00:00:00Z"
        )
    }

    func stats() async throws -> EcoFlowDeviceStats {
        throw JSONRPCClientError.commandFailed("stats unavailable")
    }

    func outputs() async throws -> EcoFlowOutputsSnapshot {
        throw JSONRPCClientError.commandFailed("outputs unavailable")
    }

    func setOutput(_ target: EcoFlowOutputTarget, state: EcoFlowOutputState) async throws -> EcoFlowControlResponse {
        outputRequests.append(OutputRequest(target: target, state: state))
        return EcoFlowControlResponse(target: .ac, requestedState: .off, result: .applied, observedState: .off, message: nil)
    }

    func diagnostics() async throws -> EcoFlowDiagnosticsSnapshot {
        throw JSONRPCClientError.commandFailed("diagnostics unavailable")
    }
}

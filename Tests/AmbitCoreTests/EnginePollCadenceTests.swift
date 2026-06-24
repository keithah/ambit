import XCTest
@testable import AmbitCore

/// Regression: a ping-only setup was polled ~once/63s because every refresh() blocked on
/// router endpoint resolution (a ~60s URLSession probe on a router-less network). Resolution
/// must be skipped when no active provider consumes the router host, so fast probes poll at
/// their own interval (dense history graphs).
final class EnginePollCadenceTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }
    private final class SpyProber: EndpointProber {
        let counter = Counter()
        func challenge(host: String, username: String) async -> Bool {
            await counter.bump()
            return false
        }
    }

    private struct FixedProbe: PingProbe {
        let result: ProbeResult
        func measure(_ host: PingScopeHostConfig) async -> ProbeResult { result }
    }

    private func engine(providers: [any Provider], prober: SpyProber) -> Engine {
        Engine(
            endpointSelector: EndpointSelector(prober: prober, addressDiscovery: StubRouterAddressDiscovery(defaultGateway: nil)),
            settings: AppSettings(remoteHost: "1.2.3.4", endpointMode: .auto),
            providers: providers,
            registerBuiltInProviders: false
        )
    }

    func testPingOnlySetupSkipsEndpointResolution() async {
        let spy = SpyProber()
        let host = PingScopeHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443)
        let provider = PingScopeProvider(host: host, integrationInstanceID: host.integrationInstanceID,
                                         probe: FixedProbe(result: ProbeResult(timestamp: Date(), latencyMs: 20)))
        let engine = engine(providers: [provider], prober: spy)
        await engine.refresh()
        let count = await spy.counter.value
        XCTAssertEqual(count, 0, "ping-only refresh must not probe the router endpoint")
    }

    func testRouterHostFamilyIsResolved() {
        XCTAssertTrue(Engine.consumesRouterHost(ProviderIDs.router))
        XCTAssertTrue(Engine.consumesRouterHost(ProviderIDs.vpn))
        XCTAssertTrue(Engine.consumesRouterHost(ProviderIDs.speedify))
        XCTAssertTrue(Engine.consumesRouterHost(ProviderIDs.ecoflow))
        XCTAssertFalse(Engine.consumesRouterHost(ProviderIDs.ping))
        XCTAssertFalse(Engine.consumesRouterHost(ProviderIDs.starlink))
        XCTAssertFalse(Engine.consumesRouterHost(ProviderIDs.reachability))
        XCTAssertFalse(Engine.consumesRouterHost(ProviderIDs.iperf3))
    }
}

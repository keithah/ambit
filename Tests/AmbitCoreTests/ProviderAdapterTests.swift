import XCTest
@testable import AmbitCore

final class ProviderAdapterTests: XCTestCase {
    func testReachabilityProviderWrapsProbeStatus() async {
        let provider = ReachabilityProvider(
            probe: StubReachabilityProbe(status: ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.042)))
        )

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(provider.id, ProviderIDs.reachability)
        XCTAssertEqual(provider.displayName, "Internet")
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("latency_ms"), .latency(ms: 42))
        XCTAssertEqual(snapshot.detail, .reachability(ReachabilityStatus(hasNetworkPath: true, state: .online(latency: 0.042))))
    }

    func testStarlinkProviderWrapsReachableStatus() async {
        let provider = StarlinkProvider { path in
            XCTAssertEqual(path, "/usr/local/bin/grpcurl")
            return StarlinkStatus(isReachable: true, state: "Online", downlinkThroughputBps: 100_000, popPingLatencyMs: 31)
        }

        let snapshot = await provider.poll(
            context: EnvironmentContext(routerHost: nil, settings: AppSettings(grpcurlPath: "/usr/local/bin/grpcurl"))
        )

        XCTAssertEqual(provider.id, ProviderIDs.starlink)
        XCTAssertEqual(provider.displayName, "Starlink")
        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("pop_latency_ms"), .latency(ms: 31))
        XCTAssertEqual(snapshot.metricValue("downlink_bps"), .throughput(bitsPerSecond: 100_000))
    }

    func testStarlinkProviderPreservesUnavailableStatusAsErrorDetail() async {
        let provider = StarlinkProvider { _ in
            StarlinkStatus(isReachable: false, state: "grpc unavailable")
        }

        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .down)
        XCTAssertEqual(snapshot.error, "grpc unavailable")
        XCTAssertEqual(snapshot.detail, .starlink(StarlinkStatus(isReachable: false, state: "grpc unavailable")))
    }
}

private extension ProviderSnapshot {
    func metricValue(_ id: String) -> MetricValue? {
        metrics.first { $0.id == id }?.value
    }
}

private struct StubReachabilityProbe: ReachabilityProbeProtocol {
    var status: ReachabilityStatus

    func probe() async -> ReachabilityStatus {
        status
    }
}

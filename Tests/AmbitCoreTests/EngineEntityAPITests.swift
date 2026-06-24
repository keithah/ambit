import XCTest
@testable import AmbitCore

final class EngineEntityAPITests: XCTestCase {
    private struct FixedProbe: PingProbe {
        let result: ProbeResult
        func measure(_ host: PingHostConfig) async -> ProbeResult { result }
    }
    private let latencyID = EntityID(rawValue: "ping@1.1.1.1:443/probe.latency_ms")
    private let providerInstance = ProviderInstanceID(rawValue: "ping@1.1.1.1:443/probe")

    private func engine(latencyMs: Double?) -> Engine {
        let host = PingHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443)
        let provider = PingProvider(host: host, integrationInstanceID: host.integrationInstanceID,
                                         probe: FixedProbe(result: ProbeResult(timestamp: Date(), latencyMs: latencyMs)))
        return Engine(settings: AppSettings(remoteHost: "", endpointMode: .forceRemote),
                      providers: [provider], registerBuiltInProviders: false)
    }

    func testExposesDescriptors() async {
        let engine = engine(latencyMs: 20)
        let descriptors = await engine.entityDescriptors()
        XCTAssertTrue(descriptors[providerInstance]?.contains { $0.id == latencyID } ?? false)
    }

    func testExposesProjectedStatesAfterPoll() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()
        let states = await engine.entityStates()
        XCTAssertEqual(states[latencyID]?.value, .number(20))
        XCTAssertEqual(states[latencyID]?.availability, .online)
    }

    // P4.2: entityStates(now:) enriches against wall-clock `now`, so a stalled loop (no fresh poll)
    // surfaces as .stale rather than a frozen-online value — recomputed at read time, not poll time.
    func testEntityStatesGoStaleAgainstWallClockNow() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()
        let states = await engine.entityStates(now: Date().addingTimeInterval(3600)) // far past any freshness window
        XCTAssertEqual(states[latencyID]?.availability, .stale)
        XCTAssertEqual(states[latencyID]?.severity, .elevated) // stale-suppression caps at .elevated
    }

    func testEntityStatesFreshHealthyHasNormalSeverity() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()
        let states = await engine.entityStates(now: Date())
        XCTAssertEqual(states[latencyID]?.availability, .online)
        XCTAssertEqual(states[latencyID]?.severity, .normal)
    }

    func testEntityStatesDegradedProviderYieldsDegradedSeverity() async {
        let engine = engine(latencyMs: 999) // success but above the degraded threshold
        await engine.refresh()
        let states = await engine.entityStates(now: Date())
        XCTAssertEqual(states[latencyID]?.availability, .online)
        XCTAssertEqual(states[latencyID]?.severity, .degraded)
    }
}

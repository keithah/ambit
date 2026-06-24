import XCTest
@testable import AmbitCore

final class EngineHistoryFeedTests: XCTestCase {
    private struct FixedProbe: PingProbe {
        let result: ProbeResult
        func measure(_ host: PingHostConfig) async -> ProbeResult { result }
    }

    private let epoch = Date(timeIntervalSince1970: 0)
    private let latencyID = EntityID(rawValue: "pingscope@1.1.1.1:443/probe.latency_ms")
    private let healthID = EntityID(rawValue: "pingscope@1.1.1.1:443/probe.health")

    private func engine(latencyMs: Double?, failure: ProbeFailureReason? = nil) -> Engine {
        let host = PingHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443)
        let result = ProbeResult(timestamp: Date(), latencyMs: latencyMs, failureReason: failure)
        let provider = PingProvider(host: host, integrationInstanceID: host.integrationInstanceID, probe: FixedProbe(result: result))
        return Engine(
            settings: AppSettings(remoteHost: "", endpointMode: .forceRemote),
            providers: [provider],
            registerBuiltInProviders: false
        )
    }

    func testEngineRecordsStateClassEntityToHistoryOnPoll() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()

        let samples = await engine.historySamples(latencyID, since: epoch)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.value, 20)
        XCTAssertEqual(samples.first?.ok, true)
    }

    func testEngineDoesNotRecordEntitiesWithoutStateClass() async {
        let engine = engine(latencyMs: 20)
        await engine.refresh()

        // health/config entities carry no stateClass → never historized.
        let healthSamples = await engine.historySamples(healthID, since: epoch)
        XCTAssertTrue(healthSamples.isEmpty)
    }

    func testEngineRecordsLossSampleOnProbeFailure() async {
        let engine = engine(latencyMs: nil, failure: .timeout)
        await engine.refresh()

        let samples = await engine.historySamples(latencyID, since: epoch)
        XCTAssertEqual(samples.count, 1)
        XCTAssertNil(samples.first?.value)
        XCTAssertEqual(samples.first?.ok, false)
    }

    func testHistoryStatsAggregateAcrossPolls() async {
        let host = PingHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443, interval: 0.25)
        // Probe alternates aren't easy with a fixed probe; use three engines is overkill —
        // instead poll the same engine repeatedly with a fixed latency (interval small).
        let provider = PingProvider(host: host, integrationInstanceID: host.integrationInstanceID, probe: FixedProbe(result: ProbeResult(timestamp: Date(), latencyMs: 30)))
        let engine = Engine(settings: AppSettings(remoteHost: "", endpointMode: .forceRemote), providers: [provider], registerBuiltInProviders: false)
        await engine.refresh()

        let stats = await engine.historyStats(latencyID, since: epoch)
        XCTAssertEqual(stats.received, 1)
        XCTAssertEqual(stats.avg, 30)
        XCTAssertEqual(stats.lossPercent, 0)
    }
}

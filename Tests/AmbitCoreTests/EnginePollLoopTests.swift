import XCTest
@testable import AmbitCore

/// Poll-loop resilience (Task 4): a wedged probe must not freeze the loop, and pollNow() must
/// kick a fresh cycle. No sleeping for the durations-under-test (the 10s watchdog window); only
/// short bounded polls observe the live async loop.
final class EnginePollLoopTests: XCTestCase {
    /// Counts how many times it's invoked, then hangs (until cancelled) — a probe stuck like an
    /// NWConnection across system sleep. Wrapped in TimeoutProbe in the tests.
    private actor CountingHungProbe: PingProbe {
        private(set) var count = 0
        func measure(_ host: PingHostConfig) async -> ProbeResult {
            count += 1
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return ProbeResult(timestamp: Date(), failureReason: .timeout)
        }
    }

    private func engine(probe: any PingProbe, interval: TimeInterval) -> Engine {
        let host = PingHostConfig(displayName: "H", address: "1.1.1.1", method: .tcp, port: 443, interval: interval, timeout: 0.05)
        let provider = PingProvider(host: host, integrationInstanceID: host.integrationInstanceID, probe: probe)
        return Engine(settings: AppSettings(remoteHost: "", endpointMode: .forceRemote), providers: [provider], registerBuiltInProviders: false)
    }

    private func pollUntil(_ timeout: TimeInterval, _ cond: @escaping () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await cond()) && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func testLoopKeepsCyclingDespiteAHungProbe() async {
        let probe = CountingHungProbe()
        let engine = engine(probe: TimeoutProbe(wrapping: probe), interval: 0.05)   // loopInterval floors to 1s
        await engine.start()
        await pollUntil(5) { await probe.count >= 2 }   // a wedged probe didn't freeze the loop
        let count = await probe.count
        await engine.stop()
        XCTAssertGreaterThanOrEqual(count, 2, "loop should keep cycling; the hung probe is bounded by TimeoutProbe, never awaited")
    }

    func testPollNowKicksAFreshCycle() async {
        // interval 5s ⇒ the loop sleeps 5s between cycles. We observe snapshot publication
        // (refresh() always stamps lastUpdated, regardless of the per-provider poll throttle),
        // so a fresh cycle within ~2s can only be pollNow() cutting the 5s sleep.
        let engine = engine(probe: TimeoutProbe(wrapping: CountingHungProbe()), interval: 5)
        await engine.start()
        await pollUntil(2) { await engine.currentSnapshot().lastUpdated != nil }   // first cycle published
        let before = await engine.currentSnapshot().lastUpdated
        await engine.pollNow()
        await pollUntil(2) { await engine.currentSnapshot().lastUpdated != before }
        let after = await engine.currentSnapshot().lastUpdated
        await engine.stop()
        XCTAssertNotNil(after)
        XCTAssertNotEqual(after, before, "pollNow() should publish a fresh cycle without waiting out the 5s interval")
    }
}

import XCTest
@testable import AmbitCore

final class PingProbesTests: XCTestCase {
    private func host(_ method: ProbeMethod, address: String = "1.1.1.1", port: UInt16? = 443, timeout: TimeInterval = 2) -> PingHostConfig {
        PingHostConfig(displayName: "H", address: address, method: method, port: method.requiresPort ? port : nil, timeout: timeout)
    }

    // MARK: ProbeFactory selection

    func testFactorySelectsProbePerMethod() {
        let factory = DefaultProbeFactory(allowsICMP: true)
        XCTAssertTrue(factory.makeProbe(for: host(.tcp)) is TimeoutProbe)
        XCTAssertTrue(factory.makeProbe(for: host(.udp)) is TimeoutProbe)
        XCTAssertTrue(factory.makeProbe(for: host(.icmp)) is ICMPProbe)
    }

    func testFactorySubstitutesUnavailableProbeWhenICMPDisallowed() async {
        let factory = DefaultProbeFactory(allowsICMP: false)
        let probe = factory.makeProbe(for: host(.icmp))
        XCTAssertTrue(probe is UnavailableProbe)
        let result = await probe.measure(host(.icmp))
        XCTAssertEqual(result.failureReason, .icmpUnavailable)
        XCTAssertNil(result.latencyMs)
    }

    // MARK: ICMP parsing (via StubProcessRunner, like the oracle)

    private func icmp(_ stub: [String: ProcessResult]) -> ICMPProbe {
        ICMPProbe(executable: "/sbin/ping", processRunner: StubProcessRunner(results: stub))
    }

    func testICMPParsesLatencyFromPingOutput() async {
        let output = """
        PING 1.1.1.1 (1.1.1.1): 56 data bytes
        64 bytes from 1.1.1.1: icmp_seq=0 ttl=58 time=12.100 ms

        --- 1.1.1.1 ping statistics ---
        1 packets transmitted, 1 packets received, 0.0% packet loss
        round-trip min/avg/max/stddev = 12.100/12.100/12.100/0.000 ms
        """
        let probe = icmp(["-c 1 -W 2000 1.1.1.1": ProcessResult(exitCode: 0, stdout: output, stderr: "")])
        let result = await probe.measure(host(.icmp, address: "1.1.1.1"))
        XCTAssertEqual(result.latencyMs, 12.1)
        XCTAssertNil(result.failureReason)
    }

    func testICMPNoReplyMapsToTimeout() async {
        let output = """
        PING 10.0.0.9 (10.0.0.9): 56 data bytes
        Request timeout for icmp_seq 0

        --- 10.0.0.9 ping statistics ---
        1 packets transmitted, 0 packets received, 100.0% packet loss
        """
        let probe = icmp(["-c 1 -W 2000 10.0.0.9": ProcessResult(exitCode: 2, stdout: output, stderr: "")])
        let result = await probe.measure(host(.icmp, address: "10.0.0.9"))
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertNil(result.latencyMs)
    }

    func testICMPUnresolvableHostMapsToDNSFailure() async {
        let probe = icmp(["-c 1 -W 2000 bad.host": ProcessResult(exitCode: 68, stdout: "", stderr: "ping: cannot resolve bad.host: Unknown host")])
        let result = await probe.measure(host(.icmp, address: "bad.host"))
        XCTAssertEqual(result.failureReason, .dnsFailure)
    }

    func testICMPHostUnreachableMapsToHostUnreachable() async {
        let output = """
        PING 10.0.0.9 (10.0.0.9): 56 data bytes
        ping: sendto: Host is down
        ping: sendto: Host is down
        """
        let probe = icmp(["-c 1 -W 2000 10.0.0.9": ProcessResult(exitCode: 2, stdout: output, stderr: "")])
        let result = await probe.measure(host(.icmp, address: "10.0.0.9"))
        XCTAssertEqual(result.failureReason, .hostUnreachable)
    }

    func testICMPNoRouteMapsToNoRoute() async {
        let probe = icmp(["-c 1 -W 2000 10.0.0.9": ProcessResult(exitCode: 2, stdout: "", stderr: "ping: sendto: No route to host")])
        let result = await probe.measure(host(.icmp, address: "10.0.0.9"))
        XCTAssertEqual(result.failureReason, .noRoute)
    }

    func testICMPTTLExpiredMapsToTTLExpired() async {
        let output = """
        36 bytes from 192.0.2.1: Time to live exceeded
        Vr HL TOS  Len   ID Flg  off TTL Pro  cks      Src      Dst
        """
        let probe = icmp(["-c 1 -W 2000 10.0.0.9": ProcessResult(exitCode: 2, stdout: output, stderr: "")])
        let result = await probe.measure(host(.icmp, address: "10.0.0.9"))
        XCTAssertEqual(result.failureReason, .ttlExpired)
    }

    func testICMPRespectsTimeoutInWaitArgument() async {
        // host.timeout 0.5s ⇒ -W 500
        let probe = icmp(["-c 1 -W 500 1.1.1.1": ProcessResult(exitCode: 0, stdout: "time=8.0 ms", stderr: "")])
        let result = await probe.measure(host(.icmp, address: "1.1.1.1", timeout: 0.5))
        XCTAssertEqual(result.latencyMs, 8.0)
    }

    // MARK: Provider through ICMP

    func testProviderProbesViaICMPAndReportsHealthy() async {
        let host = host(.icmp, address: "192.168.8.1")
        let probe = icmp(["-c 1 -W 2000 192.168.8.1": ProcessResult(exitCode: 0, stdout: "time=4.5 ms", stderr: "")])
        let provider = PingProvider(host: host, integrationInstanceID: host.integrationInstanceID, probe: probe)
        let snap = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        XCTAssertEqual(snap.health, .ok)
        XCTAssertEqual(snap.metric("latency_ms")?.value, .latency(ms: 4.5))
    }

    // MARK: TimeoutProbe abandon-the-loser

    /// A probe that never returns on its own (sleeps far past any test window) but observes
    /// cancellation — stands in for a socket wedged across system sleep.
    private final class NeverResolvingProbe: PingProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        var wasCancelled: Bool { lock.withLock { _cancelled } }
        func measure(_ host: PingHostConfig) async -> ProbeResult {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                lock.withLock { _cancelled = true }
            }
            return ProbeResult(timestamp: Date(), failureReason: .timeout)
        }
    }

    private struct ImmediateStubProbe: PingProbe {
        let result: ProbeResult
        func measure(_ host: PingHostConfig) async -> ProbeResult { result }
    }

    private func pollUntil(_ timeout: TimeInterval, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testTimeoutProbeAbandonsAHungProbeAndReportsTimeout() async {
        let result = await TimeoutProbe(wrapping: NeverResolvingProbe()).measure(host(.tcp, timeout: 0.05))
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertNil(result.latencyMs)
    }

    func testTimeoutProbeReturnsTheRealResultWhenProbeWins() async {
        let stub = ImmediateStubProbe(result: ProbeResult(timestamp: Date(), latencyMs: 12))
        let result = await TimeoutProbe(wrapping: stub).measure(host(.tcp, timeout: 2))
        XCTAssertEqual(result.latencyMs, 12)
        XCTAssertNil(result.failureReason)
    }

    func testTimeoutProbeCancelsTheLosingProbe() async {
        let probe = NeverResolvingProbe()
        _ = await TimeoutProbe(wrapping: probe).measure(host(.tcp, timeout: 0.05))
        await pollUntil(1.0) { probe.wasCancelled }   // cancellation propagates asynchronously
        XCTAssertTrue(probe.wasCancelled)
    }
}

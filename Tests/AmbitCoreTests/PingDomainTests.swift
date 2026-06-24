import XCTest
@testable import AmbitCore

final class PingDomainTests: XCTestCase {
    func testValidationRequiresUsableNameAndAddress() {
        let host = PingHostConfig(displayName: "  ", address: "  ", method: .icmp)
        XCTAssertEqual(host.validationErrors, [.missingDisplayName, .missingAddress])
    }

    func testValidationRejectsInvalidTimingAndThresholds() {
        let host = PingHostConfig(
            displayName: "Host", address: "example.com", method: .tcp, port: 0,
            interval: 0.1, timeout: 0.05, thresholds: HealthThresholds(degradedAt: 0)
        )
        XCTAssertEqual(host.validationErrors, [.invalidPort, .intervalTooShort, .timeoutTooShort, .degradedThresholdTooLow])
    }

    func testTCPAndUDPRequirePortButICMPDoesNot() {
        XCTAssertTrue(PingHostConfig(displayName: "a", address: "h", method: .tcp, port: nil).validationErrors.contains(.invalidPort))
        XCTAssertTrue(PingHostConfig(displayName: "a", address: "h", method: .udp, port: nil).validationErrors.contains(.invalidPort))
        XCTAssertFalse(PingHostConfig(displayName: "a", address: "h", method: .icmp, port: nil).validationErrors.contains(.invalidPort))
    }

    func testApplyingMethodSetsMethodAwarePort() {
        var host = PingHostConfig(displayName: "a", address: "h", method: .tcp, port: 443)
        host = host.applying(method: .udp); XCTAssertEqual(host.port, 53)
        host = host.applying(method: .icmp); XCTAssertNil(host.port)
        host = host.applying(method: .tcp); XCTAssertEqual(host.port, 443)
    }

    // MARK: TimeoutProbe

    private struct DelayProbe: PingProbe {
        let delay: TimeInterval
        let result: ProbeResult
        func measure(_ host: PingHostConfig) async -> ProbeResult {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return result
        }
    }

    func testTimeoutProbeReturnsProbeResultWhenProbeWins() async {
        let probe = TimeoutProbe(wrapping: DelayProbe(delay: 0.001, result: ProbeResult(timestamp: Date(), latencyMs: 12)))
        let host = PingHostConfig(displayName: "a", address: "h", method: .tcp, port: 443, timeout: 1)
        let result = await probe.measure(host)
        XCTAssertEqual(result.latencyMs, 12)
        XCTAssertNil(result.failureReason)
    }

    func testTimeoutProbeReturnsTimeoutWhenProbeIsLate() async {
        let probe = TimeoutProbe(wrapping: DelayProbe(delay: 5, result: ProbeResult(timestamp: Date(), latencyMs: 12)))
        let host = PingHostConfig(displayName: "a", address: "h", method: .tcp, port: 443, timeout: 0.25)
        let result = await probe.measure(host)
        XCTAssertEqual(result.failureReason, .timeout)
        XCTAssertNil(result.latencyMs)
    }
}

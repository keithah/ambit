import XCTest
@testable import AmbitCore

final class PingAlertMonitorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ o: TimeInterval) -> Date { t0.addingTimeInterval(o) }

    private func host(_ status: HealthStatus, recovery: Bool = true, cooldown: TimeInterval = 60) -> AlertHost {
        AlertHost(id: "cf", name: "Cloudflare", status: status, notifyOnRecovery: recovery, cooldown: cooldown)
    }
    private func diag(_ verdict: NetworkPerspectiveDiagnosis.Verdict, _ confidence: NetworkPerspectiveDiagnosis.Confidence) -> NetworkPerspectiveDiagnosis {
        NetworkPerspectiveDiagnosis(scope: .upstream, verdict: verdict, confidence: confidence, faultTier: .upstream, affectedHostIDs: [], title: "t", detail: "d", tierEvidence: [])
    }
    private let healthy = NetworkPerspectiveDiagnosis(scope: .allReachable, verdict: .allReachable, confidence: .high, faultTier: nil, affectedHostIDs: [], title: "", detail: "", tierEvidence: [])

    func testHostDownThenRecoveryWithCooldown() {
        var monitor = PingAlertMonitor()
        _ = monitor.evaluate(hosts: [host(.healthy)], diagnosis: healthy, now: at(0))   // prime
        let down = monitor.evaluate(hosts: [host(.down)], diagnosis: healthy, now: at(1))
        let stillDown = monitor.evaluate(hosts: [host(.down)], diagnosis: healthy, now: at(2))
        let recovered = monitor.evaluate(hosts: [host(.healthy)], diagnosis: healthy, now: at(70))

        XCTAssertEqual(down.map(\.ruleID), ["pingscope.hostDown.cf"])
        XCTAssertTrue(stillDown.isEmpty)                                   // no re-fire while down
        XCTAssertEqual(recovered.map(\.ruleID), ["pingscope.recovered.cf"])
        XCTAssertEqual(recovered.first?.severity, .info)
    }

    func testNoRecoveryWhenDisabled() {
        var monitor = PingAlertMonitor()
        _ = monitor.evaluate(hosts: [host(.down, recovery: false)], diagnosis: healthy, now: at(0))
        let recovered = monitor.evaluate(hosts: [host(.healthy, recovery: false)], diagnosis: healthy, now: at(5))
        XCTAssertTrue(recovered.filter { $0.ruleID.contains("recovered") }.isEmpty)
    }

    func testHighConfidenceEmitsSpecificNetworkAlert() {
        var monitor = PingAlertMonitor(sensitivity: .balanced)
        let events = monitor.evaluate(hosts: [], diagnosis: diag(.upstreamDown, .high), now: at(0))
        XCTAssertEqual(events.map(\.ruleID), ["pingscope.upstreamDown"])
    }

    func testTentativeBalancedFallsBackToInternetLoss() {
        var monitor = PingAlertMonitor(sensitivity: .balanced)
        let events = monitor.evaluate(hosts: [], diagnosis: diag(.upstreamDown, .tentative), now: at(0))
        XCTAssertEqual(events.map(\.ruleID), ["pingscope.internetLoss"])
    }

    func testTentativeSensitiveUsesSpecificType() {
        var monitor = PingAlertMonitor(sensitivity: .sensitive)
        let events = monitor.evaluate(hosts: [], diagnosis: diag(.upstreamDown, .tentative), now: at(0))
        XCTAssertEqual(events.map(\.ruleID), ["pingscope.upstreamDown"])
    }

    func testTentativeConservativeEmitsNothing() {
        var monitor = PingAlertMonitor(sensitivity: .conservative)
        let events = monitor.evaluate(hosts: [], diagnosis: diag(.upstreamDown, .tentative), now: at(0))
        XCTAssertTrue(events.isEmpty)
    }

    func testPathDegradedRequiresStreak() {
        var monitor = PingAlertMonitor(sensitivity: .balanced, pathDegradedConsecutive: 3)
        let d = diag(.partialDegradation(tier: .upstream), .tentative)
        XCTAssertTrue(monitor.evaluate(hosts: [], diagnosis: d, now: at(0)).isEmpty)
        XCTAssertTrue(monitor.evaluate(hosts: [], diagnosis: d, now: at(1)).isEmpty)
        let third = monitor.evaluate(hosts: [], diagnosis: d, now: at(2))
        XCTAssertEqual(third.map(\.ruleID), ["pingscope.pathDegraded"])
    }

    func testNetworkAlertCooldownSuppressesRepeat() {
        var monitor = PingAlertMonitor(sensitivity: .balanced, networkCooldown: 300)
        let first = monitor.evaluate(hosts: [], diagnosis: diag(.upstreamDown, .high), now: at(0))
        let soon = monitor.evaluate(hosts: [], diagnosis: diag(.upstreamDown, .high), now: at(30))
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(soon.isEmpty)
    }
}

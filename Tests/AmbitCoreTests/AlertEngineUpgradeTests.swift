import XCTest
@testable import AmbitCore

final class AlertEngineUpgradeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)
    private func at(_ o: TimeInterval) -> Date { t0.addingTimeInterval(o) }

    private func snapshot(_ value: Double?) -> EngineSnapshot {
        let metrics = value.map { [Metric(id: "m", label: "M", value: .level($0))] } ?? []
        return EngineSnapshot(providers: ["x": SourceState(value: ProviderSnapshot(health: .ok, metrics: metrics))])
    }

    // MARK: Presets

    func testPresetsMapToExpectedPolicies() {
        XCTAssertEqual(AlertPolicy.preset(.quiet).highLatencyConsecutive, 10)
        XCTAssertFalse(AlertPolicy.preset(.quiet).notifyOnRecovery)
        XCTAssertEqual(AlertPolicy.preset(.balanced).highLatencyConsecutive, 5)
        XCTAssertTrue(AlertPolicy.preset(.balanced).notifyOnRecovery)
        XCTAssertEqual(AlertPolicy.preset(.verbose).highLatencyConsecutive, 3)
        XCTAssertEqual(AlertPolicy.preset(.balanced).cooldown, 300)
    }

    // MARK: Cooldown

    func testCooldownSuppressesRepeatWithinWindow() async {
        let rule = ThresholdAlertRule(id: "r", providerID: "x", metricID: "m", comparison: .greaterThan, threshold: 100, title: "High", message: "hi", cooldown: 60)
        let engine = AlertEngine(rules: [.threshold(rule)])

        let first = await engine.evaluate(snapshot(150), now: at(0))
        let drop = await engine.evaluate(snapshot(10), now: at(10))
        let reArmedTooSoon = await engine.evaluate(snapshot(150), now: at(30))   // rising edge within cooldown
        _ = await engine.evaluate(snapshot(10), now: at(40))
        let reArmedAfter = await engine.evaluate(snapshot(150), now: at(90))      // cooldown elapsed

        XCTAssertEqual(first.map(\.ruleID), ["r"])
        XCTAssertTrue(drop.isEmpty)
        XCTAssertTrue(reArmedTooSoon.isEmpty, "should be suppressed within cooldown")
        XCTAssertEqual(reArmedAfter.map(\.ruleID), ["r"])
    }

    // MARK: Recovery

    func testRecoveryEmitsOnFallingEdgeWhenEnabled() async {
        let rule = ThresholdAlertRule(id: "r", providerID: "x", metricID: "m", comparison: .greaterThan, threshold: 100, title: "High", message: "hi", notifyOnRecovery: true, recoveryMessage: "All good")
        let engine = AlertEngine(rules: [.threshold(rule)])

        let fired = await engine.evaluate(snapshot(150), now: at(0))
        let recovered = await engine.evaluate(snapshot(10), now: at(10))

        XCTAssertEqual(fired.map(\.severity), [.warning])
        XCTAssertEqual(recovered.map(\.ruleID), ["r.recovered"])
        XCTAssertEqual(recovered.first?.severity, .info)
        XCTAssertEqual(recovered.first?.message, "All good")
    }

    func testNoRecoveryWhenDisabled() async {
        let rule = ThresholdAlertRule(id: "r", providerID: "x", metricID: "m", comparison: .greaterThan, threshold: 100, title: "High", message: "hi")
        let engine = AlertEngine(rules: [.threshold(rule)])
        _ = await engine.evaluate(snapshot(150), now: at(0))
        let recovered = await engine.evaluate(snapshot(10), now: at(10))
        XCTAssertTrue(recovered.isEmpty)
    }
}

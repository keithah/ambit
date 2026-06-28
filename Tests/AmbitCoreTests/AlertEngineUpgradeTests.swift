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
        XCTAssertEqual(AlertPolicy.preset(.quiet).consecutive, 10)
        XCTAssertFalse(AlertPolicy.preset(.quiet).notifyOnRecovery)
        XCTAssertEqual(AlertPolicy.preset(.balanced).consecutive, 5)
        XCTAssertTrue(AlertPolicy.preset(.balanced).notifyOnRecovery)
        XCTAssertEqual(AlertPolicy.preset(.verbose).consecutive, 3)
        XCTAssertEqual(AlertPolicy.preset(.balanced).cooldown, 300)
    }

    func testLegacyLatencyPolicyJSONDecodesToGenericThresholdPolicy() throws {
        let data = """
        {
          "preset": "custom",
          "enabled": true,
          "cooldown": 90,
          "notifyOnRecovery": false,
          "highLatencyMs": 500,
          "highLatencyConsecutive": 3
        }
        """.data(using: .utf8)!

        let policy = try JSONDecoder().decode(EntityAlertPolicy.self, from: data)

        XCTAssertEqual(policy.threshold, AlertThreshold(comparison: .greaterThanOrEqual, value: 500))
        XCTAssertEqual(policy.consecutive, 3)
        XCTAssertEqual(policy.cooldown, 90)
        XCTAssertFalse(policy.notifyOnRecovery)
    }

    func testGenericPolicyEncodesWithoutLatencyFieldNames() throws {
        let policy = EntityAlertPolicy(
            preset: .custom,
            enabled: true,
            threshold: AlertThreshold(comparison: .lessThan, value: 20),
            consecutive: 4,
            cooldown: 120,
            notifyOnRecovery: true
        )

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as? [String: Any]

        XCTAssertNotNil(object?["threshold"])
        XCTAssertNil(object?["highLatencyMs"])
        XCTAssertNil(object?["highLatencyConsecutive"])
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
        XCTAssertEqual(recovered.first?.phase, .recovered)
    }

    func testRecoveryDoesNotEmitAfterCooldownSuppressedActiveAlert() async {
        let rule = ThresholdAlertRule(id: "r", providerID: "x", metricID: "m", comparison: .greaterThan, threshold: 100, title: "High", message: "hi", cooldown: 60, notifyOnRecovery: true)
        let engine = AlertEngine(rules: [.threshold(rule)])

        _ = await engine.evaluate(snapshot(150), now: at(0))
        _ = await engine.evaluate(snapshot(10), now: at(10))
        let suppressed = await engine.evaluate(snapshot(150), now: at(30))
        let recoveryAfterSuppressed = await engine.evaluate(snapshot(10), now: at(40))

        XCTAssertTrue(suppressed.isEmpty)
        XCTAssertTrue(recoveryAfterSuppressed.isEmpty)
    }

    func testNoRecoveryWhenDisabled() async {
        let rule = ThresholdAlertRule(id: "r", providerID: "x", metricID: "m", comparison: .greaterThan, threshold: 100, title: "High", message: "hi")
        let engine = AlertEngine(rules: [.threshold(rule)])
        _ = await engine.evaluate(snapshot(150), now: at(0))
        let recovered = await engine.evaluate(snapshot(10), now: at(10))
        XCTAssertTrue(recovered.isEmpty)
    }
}

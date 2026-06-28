import Foundation
import XCTest
@testable import AmbitCore

final class AlertEngineTests: XCTestCase {
    func testThresholdRuleFiresOnRisingEdgeOnly() async {
        let engine = AlertEngine(rules: [
            .threshold(ThresholdAlertRule(
                id: "starlink.obstruction",
                providerID: ProviderIDs.starlink,
                metricID: "obstruction_percent",
                comparison: .greaterThan,
                threshold: 5,
                title: "Obstruction",
                message: "Too high"
            ))
        ])

        let below = snapshot(providerID: ProviderIDs.starlink, metric: Metric(id: "obstruction_percent", label: "Obstruction", value: .percent(2)))
        let above = snapshot(providerID: ProviderIDs.starlink, metric: Metric(id: "obstruction_percent", label: "Obstruction", value: .percent(7)))

        let first = await engine.evaluate(below)
        let second = await engine.evaluate(above)
        let third = await engine.evaluate(above)
        let fourth = await engine.evaluate(below)
        let fifth = await engine.evaluate(above)
        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.map { $0.ruleID }, ["starlink.obstruction"])
        XCTAssertEqual(third.count, 0)
        XCTAssertEqual(fourth.count, 0)
        XCTAssertEqual(fifth.map { $0.ruleID }, ["starlink.obstruction"])
    }

    func testStateTransitionRuleFiresWhenMetricMovesToExpectedValue() async {
        let engine = AlertEngine(rules: [
            .stateTransition(StateTransitionAlertRule(
                id: "vpn.down",
                providerID: ProviderIDs.vpn,
                metricID: "connected",
                expectedValue: .bool(false),
                title: "VPN Down",
                message: "Disconnected"
            ))
        ])

        let connected = snapshot(providerID: ProviderIDs.vpn, metric: Metric(id: "connected", label: "Connected", value: .bool(true)))
        let disconnected = snapshot(providerID: ProviderIDs.vpn, metric: Metric(id: "connected", label: "Connected", value: .bool(false)))

        let first = await engine.evaluate(connected)
        let second = await engine.evaluate(disconnected)
        let third = await engine.evaluate(disconnected)
        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.map { $0.ruleID }, ["vpn.down"])
        XCTAssertEqual(third.count, 0)
    }

    func testSustainedRuleWaitsForDuration() async {
        let engine = AlertEngine(rules: [
            .sustained(SustainedAlertRule(
                id: "battery.low",
                providerID: ProviderIDs.ecoflow,
                metricID: "battery_percent",
                comparison: .lessThan,
                threshold: 20,
                duration: 60,
                title: "Battery Low",
                message: "Low"
            ))
        ])
        let base = Date(timeIntervalSince1970: 1_000)
        let low = snapshot(providerID: ProviderIDs.ecoflow, metric: Metric(id: "battery_percent", label: "Battery", value: .level(18)))

        let first = await engine.evaluate(low, now: base)
        let second = await engine.evaluate(low, now: base.addingTimeInterval(59))
        let third = await engine.evaluate(low, now: base.addingTimeInterval(60))
        let fourth = await engine.evaluate(low, now: base.addingTimeInterval(120))
        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.count, 0)
        XCTAssertEqual(third.map { $0.ruleID }, ["battery.low"])
        XCTAssertEqual(fourth.count, 0)
    }

    func testDefaultRulesDoNotIncludeLegacyDisabledProviderAlerts() async {
        let engine = AlertEngine()
        let snapshot = EngineSnapshot(providers: [
            ProviderInstanceIDs.starlink: Self.providerSnapshot(metric: Metric(id: "obstruction_percent", label: "Obstruction", value: .percent(8))),
            ProviderInstanceIDs.vpn: Self.providerSnapshot(metric: Metric(id: "connected", label: "Connected", value: .bool(true))),
            ProviderInstanceIDs.ecoflow: Self.providerSnapshot(metric: Metric(id: "battery_percent", label: "Battery", value: .level(18)))
        ])

        let first = await engine.evaluate(snapshot, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(AlertRule.defaultRules.isEmpty)
        XCTAssertTrue(first.isEmpty)
    }

    private func snapshot(providerID: ProviderID, metric: Metric) -> EngineSnapshot {
        EngineSnapshot(providers: [ProviderInstanceIDs.resolve(providerID): Self.providerSnapshot(metric: metric)])
    }

    private static func providerSnapshot(metric: Metric) -> SourceState<ProviderSnapshot> {
        SourceState(value: ProviderSnapshot(health: .ok, metrics: [metric]))
    }
}

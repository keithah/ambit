import XCTest
@testable import AmbitCore

final class PingScopeAlertRulesTests: XCTestCase {
    private func record(policy: AlertPolicy, interval: TimeInterval = 2) -> IntegrationInstanceRecord {
        let host = PingScopeHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443, interval: interval, policy: policy)
        return .pingscope(host)
    }

    func testBuildsHighLatencyRuleFromPolicy() {
        let rules = PingScopeIntegration().alertRules(instance: record(policy: .preset(.verbose)))
        guard case .sustained(let rule)? = rules.first else { return XCTFail("expected sustained rule") }
        XCTAssertEqual(rule.id, "pingscope@1.1.1.1:443.highLatency")
        XCTAssertEqual(rule.providerID, "pingscope@1.1.1.1:443/probe")  // matches the provider instance id
        XCTAssertEqual(rule.metricID, "latency_ms")
        XCTAssertEqual(rule.threshold, 250)
        XCTAssertEqual(rule.duration, 3 * 2)                           // verbose: 3 consecutive × 2s interval
        XCTAssertEqual(rule.cooldown, 300)
        XCTAssertTrue(rule.notifyOnRecovery)
    }

    func testNoRulesWhenPolicyDisabled() {
        var policy = AlertPolicy.preset(.balanced); policy.enabled = false
        XCTAssertTrue(PingScopeIntegration().alertRules(instance: record(policy: policy)).isEmpty)
    }

    func testEngineAggregatesPingscopeRulesForActiveInstances() {
        let registry = InMemoryIntegrationRegistry(records: [record(policy: .preset(.balanced))])
        let engine = Engine(settings: AppSettings(), integrationRegistry: registry)
        // Engine.alertRules() is nonisolated? It's actor-isolated — call via Task in a sync test.
        let expectation = expectation(description: "rules")
        Task {
            let rules = await engine.alertRules()
            XCTAssertTrue(rules.contains { $0.id == "pingscope@1.1.1.1:443.highLatency" })
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testConfigWithoutPolicyDecodesToBalancedDefault() {
        var config = PingScopeHostConfig(displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443).asConfigObject()
        config["policy"] = nil   // simulate a config persisted before policy existed
        let decoded = PingScopeHostConfig(configObject: config)
        XCTAssertEqual(decoded?.policy, .preset(.balanced))
    }
}

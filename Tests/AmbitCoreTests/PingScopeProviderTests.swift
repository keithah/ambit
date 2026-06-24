import XCTest
@testable import AmbitCore

final class PingProviderTests: XCTestCase {
    private struct FixedProbe: PingProbe {
        let result: ProbeResult
        func measure(_ host: PingHostConfig) async -> ProbeResult { result }
    }

    private let ctx = EnvironmentContext(routerHost: nil, settings: AppSettings())

    private func host(_ address: String = "1.1.1.1", degradedAt: Double = 100, downAfter: Int = 3) -> PingHostConfig {
        PingHostConfig(
            displayName: "CF", address: address, method: .tcp, port: 443,
            interval: 2, timeout: 2, thresholds: HealthThresholds(degradedAt: degradedAt, downAfterFailures: downAfter)
        )
    }

    private func provider(_ host: PingHostConfig, _ result: ProbeResult) -> PingProvider {
        PingProvider(host: host, integrationInstanceID: host.integrationInstanceID, probe: FixedProbe(result: result))
    }

    func testIdentityIsScopedUnderIntegrationInstance() {
        let p = provider(host(), ProbeResult(timestamp: Date(), latencyMs: 10))
        XCTAssertEqual(p.integrationID, IntegrationIDs.pingscope)
        XCTAssertEqual(p.integrationInstanceID, IntegrationInstanceID(rawValue: "pingscope@1.1.1.1:443"))
        XCTAssertEqual(p.instanceID, ProviderInstanceID(rawValue: "pingscope@1.1.1.1:443/probe"))
        XCTAssertEqual(p.id, "pingscope@1.1.1.1:443/probe")
        XCTAssertEqual(p.instanceID.rawValue, "\(p.integrationInstanceID.rawValue)/\(p.typeID)")
    }

    func testPollEmitsLatencyAndHealthyHealthOnSuccess() async {
        let p = provider(host(), ProbeResult(timestamp: Date(), latencyMs: 20))
        let snap = await p.poll(context: ctx)
        XCTAssertEqual(snap.health, .ok)
        XCTAssertEqual(snap.metric("latency_ms")?.value, .latency(ms: 20))
        XCTAssertEqual(snap.metric("latency_ms")?.deviceClass, .latency)
    }

    func testSlowSuccessIsDegraded() async {
        let p = provider(host(degradedAt: 100), ProbeResult(timestamp: Date(), latencyMs: 140))
        let snap = await p.poll(context: ctx)
        XCTAssertEqual(snap.health, .degraded)
    }

    func testConsecutiveFailuresReachDownAndCarryError() async {
        let p = provider(host(downAfter: 3), ProbeResult(timestamp: Date(), failureReason: .timeout))
        let first = await p.poll(context: ctx)
        let second = await p.poll(context: ctx)
        let third = await p.poll(context: ctx)
        XCTAssertEqual(first.health, .degraded)
        XCTAssertEqual(second.health, .degraded)
        XCTAssertEqual(third.health, .down)
        XCTAssertEqual(third.metrics, [])
        XCTAssertEqual(third.error, "Probe failed: timeout")
    }

    func testDescriptorsExposeLatencyHealthAndConfigEntities() {
        let descriptors = provider(host(), ProbeResult(timestamp: Date(), latencyMs: 10)).entityDescriptors()
        let byKey = Dictionary(uniqueKeysWithValues: descriptors.map { (String($0.id.rawValue.split(separator: ".").last ?? ""), $0) })
        XCTAssertEqual(byKey["latency_ms"]?.deviceClass, .latency)
        XCTAssertEqual(byKey["health"]?.deviceClass, .connectivity)
        XCTAssertEqual(byKey["address"]?.category, .config)
        XCTAssertEqual(byKey["down_after_failures"]?.category, .config)
    }

    // MARK: Integration + config bridge

    func testHostConfigRoundTripsThroughRecordConfig() {
        let original = PingHostConfig(
            displayName: "CF", address: "1.1.1.1", method: .tcp, port: 443,
            interval: 3, timeout: 1, thresholds: HealthThresholds(degradedAt: 150, downAfterFailures: 4)
        )
        XCTAssertEqual(PingHostConfig(configObject: original.asConfigObject()), original)
    }

    func testIntegrationBuildsOneProviderPerHostRecord() {
        let integration = PingIntegration(probeFactory: { _ in FixedProbe(result: ProbeResult(timestamp: Date(), latencyMs: 5)) })
        func record(_ address: String) -> IntegrationInstanceRecord {
            let h = host(address)
            return IntegrationInstanceRecord(id: h.integrationInstanceID, integrationID: IntegrationIDs.pingscope, displayName: h.displayName, origin: .user, config: h.asConfigObject())
        }
        let a = integration.makeProviders(instance: record("1.1.1.1"))
        let b = integration.makeProviders(instance: record("8.8.8.8"))
        XCTAssertEqual(a.first?.instanceID, ProviderInstanceID(rawValue: "pingscope@1.1.1.1:443/probe"))
        XCTAssertEqual(b.first?.instanceID, ProviderInstanceID(rawValue: "pingscope@8.8.8.8:443/probe"))
        XCTAssertNotEqual(a.first?.id, b.first?.id)
    }

    func testIntegrationReturnsNothingForUndecodableConfig() {
        let integration = PingIntegration()
        let record = IntegrationInstanceRecord(id: "pingscope@bad", integrationID: IntegrationIDs.pingscope, displayName: "bad", origin: .user, config: ["nonsense": .bool(true)])
        XCTAssertTrue(integration.makeProviders(instance: record).isEmpty)
    }
}

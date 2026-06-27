import XCTest
@testable import AmbitCore

final class AlertTargetResolverTests: XCTestCase {
    func testProviderMetricTargetResolvesMatchingEntity() {
        let descriptor = descriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            metricID: "cpu_usage_percent",
            capability: "system.cpu",
            isPrimary: true
        )
        let event = AlertEvent(
            ruleID: "cpu.high",
            providerID: ProviderInstanceIDs.systemOverview.rawValue,
            target: .providerMetric(providerID: ProviderInstanceIDs.systemOverview.rawValue, metricID: "cpu_usage_percent"),
            title: "CPU high",
            message: "CPU crossed threshold",
            severity: .elevated
        )

        let ids = AlertTargetResolver().resolve(event, descriptors: [descriptor])

        XCTAssertEqual(ids, [descriptor.id])
    }

    func testCapabilityTargetPrefersPrimaryMatchingDescriptors() {
        let primary = descriptor(
            id: "system@local/overview.cpu_usage_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            metricID: "cpu_usage_percent",
            capability: "system.cpu",
            isPrimary: true
        )
        let secondary = descriptor(
            id: "system@local/overview.cpu_user_percent",
            instanceID: ProviderInstanceIDs.systemOverview,
            metricID: "cpu_user_percent",
            capability: "system.cpu"
        )
        let event = AlertEvent(
            ruleID: "cpu.capability",
            providerID: ProviderInstanceIDs.systemOverview.rawValue,
            target: .capability("system.cpu"),
            title: "CPU",
            message: "CPU issue",
            severity: .elevated
        )

        let ids = AlertTargetResolver().resolve(event, descriptors: [secondary, primary])

        XCTAssertEqual(ids, [primary.id])
    }

    func testMissingTargetResolvesEmptySet() {
        let event = AlertEvent(
            ruleID: "missing",
            providerID: "missing/provider",
            target: .entity("missing.provider.value"),
            title: "Missing",
            message: "Missing",
            severity: .elevated
        )

        XCTAssertEqual(AlertTargetResolver().resolve(event, descriptors: []), [])
    }

    func testLegacyPingNetworkEventResolvesDiagnosisEntity() {
        let diagnosis = descriptor(
            id: DiagnosisEntity.entityID,
            instanceID: ProviderInstanceID(rawValue: "ping/network"),
            metricID: "diagnosis",
            capability: "connectivity"
        )
        let event = AlertEvent(
            ruleID: "ping.localNetworkDown",
            providerID: "ping.network",
            title: "Local network down",
            message: "Gateway unreachable",
            severity: .down
        )

        let ids = AlertTargetResolver().resolve(event, descriptors: [diagnosis])

        XCTAssertEqual(ids, [DiagnosisEntity.entityID])
    }

    private func descriptor(
        id: EntityID,
        instanceID: ProviderInstanceID,
        metricID: String,
        capability: ProviderCapability?,
        isPrimary: Bool = false
    ) -> EntityDescriptor {
        EntityDescriptor(
            id: id,
            instanceID: instanceID,
            name: id.rawValue,
            kind: .sensor,
            deviceClass: .percent,
            capability: capability,
            stateClass: .measurement,
            metricID: metricID,
            isPrimary: isPrimary
        )
    }
}

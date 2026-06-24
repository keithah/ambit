import XCTest
@testable import AmbitCore

final class SlotResolverTests: XCTestCase {
    // Two ping hosts (latency carries capability "uplink") + a glinet single-instance provider.
    private func latency(_ providerInstance: String) -> EntityDescriptor {
        EntityDescriptor(id: EntityID(rawValue: "\(providerInstance).latency_ms"),
                         instanceID: ProviderInstanceID(rawValue: providerInstance),
                         name: "Latency", kind: .sensor, deviceClass: .latency,
                         capability: "uplink", stateClass: .measurement)
    }
    private let cf = "ping@1.1.1.1/probe"
    private let goog = "ping@8.8.8.8/probe"
    private let gw = "ping@192.168.8.1/probe"

    private lazy var descriptors = [latency(cf), latency(goog),
                                    EntityDescriptor(id: "glinet/router.online", instanceID: "glinet/router",
                                                     name: "Online", kind: .binarySensor, deviceClass: .connectivity)]
    private let records = [
        IntegrationInstanceRecord(id: "ping@1.1.1.1", integrationID: "ping", displayName: "Cloudflare"),
        IntegrationInstanceRecord(id: "ping@8.8.8.8", integrationID: "ping", displayName: "Google"),
        IntegrationInstanceRecord(id: "glinet", integrationID: "glinet", displayName: "GL.iNet")
    ]

    private func ids(_ ds: [EntityDescriptor]) -> [String] { ds.map(\.id.rawValue).sorted() }

    func testIntegrationTypeExpandsToAllInstancesOfThatIntegration() {
        let resolved = SlotResolver.resolve(.integrationType("ping"), descriptors: descriptors, records: records)
        XCTAssertEqual(ids(resolved), ["ping@1.1.1.1/probe.latency_ms", "ping@8.8.8.8/probe.latency_ms"])
        // And the combined set composes to ONE multi-line history graph (the P2 collapse).
        let plan = SurfaceComposer.detailPlan(descriptors: resolved, states: [:])
        let graphs = plan.cards.flatMap(\.children).filter { $0.kind == .historyGraph }
        XCTAssertEqual(graphs.count, 1)
        XCTAssertEqual(graphs.first?.entities.count, 2)
    }

    func testIntegrationTypeExcludesDisabledInstance() {
        // A disabled Google host (with a live descriptor still present) must NOT resolve in.
        let recs = [
            IntegrationInstanceRecord(id: "ping@1.1.1.1", integrationID: "ping", displayName: "Cloudflare", enabled: true),
            IntegrationInstanceRecord(id: "ping@8.8.8.8", integrationID: "ping", displayName: "Google", enabled: false)
        ]
        let resolved = SlotResolver.resolve(.integrationType("ping"), descriptors: descriptors, records: recs)
        XCTAssertEqual(ids(resolved), ["ping@1.1.1.1/probe.latency_ms"])
    }

    func testIntegrationsResolvesExplicitInstanceSet() {
        let resolved = SlotResolver.resolve(.integrations(["ping@1.1.1.1", "ping@8.8.8.8"]), descriptors: descriptors, records: records)
        XCTAssertEqual(ids(resolved), ["ping@1.1.1.1/probe.latency_ms", "ping@8.8.8.8/probe.latency_ms"])
    }

    func testIntegrationResolvesSingleInstance() {
        let resolved = SlotResolver.resolve(.integration("ping@1.1.1.1"), descriptors: descriptors, records: records)
        XCTAssertEqual(ids(resolved), ["ping@1.1.1.1/probe.latency_ms"])
    }

    func testCapabilityResolvesAcrossInstances() {
        let resolved = SlotResolver.resolve(.capability("uplink"), descriptors: descriptors, records: records)
        XCTAssertEqual(ids(resolved), ["ping@1.1.1.1/probe.latency_ms", "ping@8.8.8.8/probe.latency_ms"])
    }

    func testEntitiesResolvesExact() {
        let resolved = SlotResolver.resolve(.entities(["glinet/router.online"]), descriptors: descriptors, records: records)
        XCTAssertEqual(ids(resolved), ["glinet/router.online"])
    }

    func testProviderInstanceIDDerivesIntegrationInstance() {
        XCTAssertEqual(ProviderInstanceID(rawValue: "ping@1.1.1.1/probe").integrationInstanceID, "ping@1.1.1.1")
        XCTAssertEqual(ProviderInstanceID(rawValue: "glinet/router").integrationInstanceID, "glinet")
        XCTAssertEqual(ProviderInstanceID(rawValue: "bare").integrationInstanceID, "bare")
    }
}

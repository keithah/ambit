import XCTest
@testable import AmbitCore

final class SurfaceComposerTests: XCTestCase {
    private func sensor(_ key: String, _ deviceClass: DeviceClass?, kind: EntityKind = .sensor,
                        stateClass: StateClass? = nil, graphStyle: GraphStyle? = nil,
                        isPrimary: Bool = false, priority: Int? = nil, category: EntityCategory = .primary) -> EntityDescriptor {
        EntityDescriptor(id: EntityID(rawValue: "i/p.\(key)"), instanceID: "i/p", name: key, kind: kind,
                         deviceClass: deviceClass, category: category, stateClass: stateClass,
                         graphStyle: graphStyle, isPrimary: isPrimary, priority: priority)
    }

    // Ported from ProviderMetricSectionTests: grouping by classification, deviceClass wins.
    func testGroupsEntitiesByClassificationInOrder() {
        let descriptors = [
            sensor("latency", .latency, stateClass: .measurement),
            sensor("download", .throughput, stateClass: .measurement),
            sensor("battery", .battery),
            sensor("online", .connectivity, kind: .binarySensor),
            sensor("note", nil, kind: .text)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        // online is connectivity → Network; note (text, no class) → State.
        XCTAssertEqual(plan.cards.map { $0.title }, ["Network", "Power", "State"])
        let network = plan.cards[0]
        XCTAssertEqual(network.children.map { $0.entities.first?.rawValue }, ["i/p.latency", "i/p.download", "i/p.online"])
    }

    func testDeviceClassWinsOverValueShape() {
        // A battery sensor whose value is a percentage still groups under Power.
        let descriptors = [
            sensor("soc", .battery),
            sensor("load", .power),
            sensor("note", nil, kind: .text)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        XCTAssertEqual(plan.cards.map { $0.title }, ["Power", "State"])
        XCTAssertEqual(plan.cards[0].children.map { $0.entities.first?.rawValue }, ["i/p.soc", "i/p.load"])
    }

    func testSensorGraphStyleSelectsCardKind() {
        let descriptors = [
            sensor("g", .percent, graphStyle: .gauge),
            sensor("p", .battery, graphStyle: .progress),
            sensor("s", .latency, graphStyle: .sparkline),
            sensor("r", .latency, graphStyle: GraphStyle.none)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        let kinds = plan.cards.flatMap { $0.children }.reduce(into: [String: CardKind]()) { $0[$1.entities.first!.rawValue] = $1.kind }
        XCTAssertEqual(kinds["i/p.g"], .gauge)
        XCTAssertEqual(kinds["i/p.p"], .progress)
        XCTAssertEqual(kinds["i/p.s"], .historyGraph)
        XCTAssertEqual(kinds["i/p.r"], .statusRow)
    }

    func testUnsetGraphStyleMeasurementBecomesHistoryGraph() {
        let plan = SurfaceComposer.detailPlan(descriptors: [sensor("m", .latency, stateClass: .measurement)], states: [:])
        XCTAssertEqual(plan.cards.first?.children.first?.kind, .historyGraph)
        XCTAssertEqual(plan.cards.first?.children.first?.graphRange, .m5)  // layer default
    }

    func testControlsGroupSeparately() {
        let toggle = EntityDescriptor(id: "i/p.vpn", instanceID: "i/p", name: "VPN", kind: .toggle,
                                      command: CommandRef(commandID: "vpn.toggle"))
        let plan = SurfaceComposer.detailPlan(descriptors: [toggle], states: [:])
        XCTAssertEqual(plan.cards.map { $0.title }, ["Controls"])
        XCTAssertEqual(plan.cards.first?.children.first?.kind, .control)
    }

    func testPrimarySortsFirstWithinSection() {
        let descriptors = [
            sensor("a", .latency, priority: 1),
            sensor("b", .latency, isPrimary: true)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        XCTAssertEqual(plan.cards[0].children.first?.entities.first?.rawValue, "i/p.b")
        XCTAssertEqual(plan.cards[0].role, .primary)
    }

    func testConfigEntitiesExcludedFromDetail() {
        let cfg = sensor("host", nil, kind: .text, category: .config)
        let plan = SurfaceComposer.detailPlan(descriptors: [cfg], states: [:])
        XCTAssertTrue(plan.cards.isEmpty)
    }

    func testSameClassMeasurementSeriesCombineIntoOneGraph() {
        let descriptors = [
            sensor("lat_a", .latency, stateClass: .measurement),
            sensor("lat_b", .latency, stateClass: .measurement)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        let network = plan.cards.first { $0.title == "Network" }
        XCTAssertEqual(network?.children.count, 1)
        XCTAssertEqual(network?.children.first?.kind, .historyGraph)
        XCTAssertEqual(network?.children.first?.entities.map(\.rawValue), ["i/p.lat_a", "i/p.lat_b"])
        XCTAssertNil(network?.children.first?.title)
    }

    func testSingleMeasurementSeriesStaysSingleLineWithName() {
        let plan = SurfaceComposer.detailPlan(descriptors: [sensor("lat", .latency, stateClass: .measurement)], states: [:])
        let card = plan.cards.first?.children.first
        XCTAssertEqual(card?.entities.map(\.rawValue), ["i/p.lat"])
        XCTAssertEqual(card?.title, "lat")
    }

    func testDisabledOverrideDropsEntity() {
        var config = PresentationConfig.empty
        config.entityOverrides["i/p.latency"] = EntityPresentationOverride(enabled: false)
        let plan = SurfaceComposer.detailPlan(descriptors: [sensor("latency", .latency)], states: [:], config: config)
        XCTAssertTrue(plan.cards.isEmpty)
    }

    func testGraphRangeOnlyOnHistoryGraph() {
        let descriptors = [
            sensor("g", .percent, graphStyle: .gauge),
            sensor("p", .battery, graphStyle: .progress),
            sensor("s", .latency, graphStyle: .sparkline)
        ]
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        let byID = plan.cards.flatMap { $0.children }.reduce(into: [String: CardSpec]()) { $0[$1.entities.first!.rawValue] = $1 }
        XCTAssertNil(byID["i/p.g"]?.graphRange)
        XCTAssertNil(byID["i/p.p"]?.graphRange)
        XCTAssertEqual(byID["i/p.s"]?.graphRange, .m5)
    }
}

import XCTest
@testable import AmbitCore

final class SurfaceComposerTests: XCTestCase {
    private func sensor(_ key: String, _ deviceClass: DeviceClass?, kind: EntityKind = .sensor,
                        stateClass: StateClass? = nil, graphStyle: GraphStyle? = nil,
                        isPrimary: Bool = false, priority: Int? = nil, category: EntityCategory = .primary,
                        capability: ProviderCapability? = nil,
                        compositionRole: EntityCompositionRole? = nil,
                        unit: String? = nil) -> EntityDescriptor {
        EntityDescriptor(id: EntityID(rawValue: "i/p.\(key)"), instanceID: "i/p", name: key, kind: kind,
                         deviceClass: deviceClass, category: category, capability: capability, unit: unit,
                         stateClass: stateClass, graphStyle: graphStyle, isPrimary: isPrimary, priority: priority,
                         compositionRole: compositionRole)
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

    func testDiagnosticTextWithElevatedSeverityRendersAsStatusBanner() {
        let diagnosis = sensor("diagnosis", nil, kind: .text, category: .diagnostic)
        let plan = SurfaceComposer.detailPlan(
            descriptors: [diagnosis],
            states: [diagnosis.id: EntityState(id: diagnosis.id, value: .text("Monitoring paused"), availability: .online, severity: .elevated)]
        )
        let card = plan.cards.flatMap(\.children).first
        XCTAssertEqual(card?.kind, .statusBanner)
        XCTAssertEqual(card?.entities, [diagnosis.id])
    }

    func testDiagnosticTextWithoutElevatedSeverityStaysStatusRow() {
        let diagnosis = sensor("diagnosis", nil, kind: .text, category: .diagnostic)
        let plan = SurfaceComposer.detailPlan(
            descriptors: [diagnosis],
            states: [diagnosis.id: EntityState(id: diagnosis.id, value: .text("All reachable"), availability: .online, severity: .normal)]
        )
        let card = plan.cards.flatMap(\.children).first
        XCTAssertEqual(card?.kind, .statusRow)
        XCTAssertEqual(card?.role, .secondary)
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

    func testTableEntityProducesStatTableCard() {
        let table = sensor("volumes", nil, kind: .table)

        let plan = SurfaceComposer.detailPlan(descriptors: [table], states: [:])

        let card = plan.cards.flatMap(\.children).first
        XCTAssertEqual(card?.kind, .statTable)
        XCTAssertEqual(card?.entities, [table.id])
    }

    func testSystemCapabilitiesProduceGenericSectionsInOrder() {
        let descriptors = [
            sensor("fan", nil, capability: "system.fans"),
            sensor("disk", nil, kind: .table, capability: "system.disk"),
            sensor("mem", .percent, capability: "system.memory"),
            sensor("cpu", .percent, capability: "system.cpu"),
            sensor("net", .throughput, capability: "system.network"),
            sensor("temp", .percent, capability: "system.sensors")
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["CPU", "Memory", "Disk", "Network", "Sensors", "Fans"])
        XCTAssertEqual(plan.cards.flatMap(\.children).map { $0.entities.first?.rawValue }, [
            "i/p.cpu", "i/p.mem", "i/p.disk", "i/p.net", "i/p.temp", "i/p.fan"
        ])
    }

    func testPowerBatteryCapabilityProducesPowerSectionBeforeDeviceClassFallback() {
        let descriptor = sensor("battery", .percent, capability: "power.battery")

        let plan = SurfaceComposer.detailPlan(descriptors: [descriptor], states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["Power"])
        XCTAssertEqual(plan.cards.first?.children.first?.entities, [descriptor.id])
    }

    func testPingNetworkAndDiagnosticSectionsStayStable() {
        let descriptors = [
            sensor("latency", .latency, stateClass: .measurement, capability: "uplink"),
            sensor("diagnosis", nil, kind: .text, category: .diagnostic)
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["Network", "State"])
        XCTAssertEqual(plan.cards[0].children.first?.entities, [descriptors[0].id])
        XCTAssertEqual(plan.cards[1].children.first?.entities, [descriptors[1].id])
    }

    func testProgressSiblingComponentsProduceSegmentedRing() {
        let descriptors = [
            sensor("App", .dataSize, stateClass: .measurement, graphStyle: .progress, priority: 30, capability: "system.memory"),
            sensor("Wired", .dataSize, stateClass: .measurement, graphStyle: .progress, priority: 20, capability: "system.memory"),
            sensor("Compressed", .dataSize, stateClass: .measurement, graphStyle: .progress, priority: 10, capability: "system.memory"),
            sensor("Free", .dataSize, stateClass: .measurement, graphStyle: .progress, priority: 0, capability: "system.memory")
        ]
        let states = Dictionary(uniqueKeysWithValues: descriptors.enumerated().map { index, descriptor in
            (descriptor.id, EntityState(id: descriptor.id, value: .number(Double(index + 1)), availability: .online))
        })

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)

        let memory = plan.cards.first { $0.title == "Memory" }
        XCTAssertEqual(memory?.children.count, 1)
        XCTAssertEqual(memory?.children.first?.kind, .segmentedRing)
        XCTAssertEqual(memory?.children.first?.id, "group:system.memory:dataSize:none:segments")
        XCTAssertEqual(memory?.children.first?.entities.map(\.rawValue), [
            "i/p.App", "i/p.Wired", "i/p.Compressed", "i/p.Free"
        ])
    }

    func testSegmentedRingRequiresAllWholeMembersAvailable() {
        let descriptors = [
            sensor("App", .dataSize, stateClass: .measurement, graphStyle: .progress, capability: "system.memory"),
            sensor("Wired", .dataSize, stateClass: .measurement, graphStyle: .progress, capability: "system.memory"),
            sensor("Compressed", .dataSize, stateClass: .measurement, graphStyle: .progress, capability: "system.memory")
        ]
        let states: [EntityID: EntityState] = [
            descriptors[0].id: EntityState(id: descriptors[0].id, value: .number(4), availability: .online),
            descriptors[1].id: EntityState(id: descriptors[1].id, value: nil, availability: .online),
            descriptors[2].id: EntityState(id: descriptors[2].id, value: .number(1), availability: .unavailable)
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)

        let kinds = plan.cards.flatMap(\.children).map(\.kind)
        XCTAssertFalse(kinds.contains(.segmentedRing))
        XCTAssertEqual(kinds, [.progress, .progress, .progress])
    }

    func testSegmentedRingIDIncludesGroupingDiscriminators() {
        let descriptors = [
            sensor("MemoryApp", .dataSize, stateClass: .measurement, graphStyle: .progress, capability: "system.memory", unit: "bytes"),
            sensor("MemoryWired", .dataSize, stateClass: .measurement, graphStyle: .progress, capability: "system.memory", unit: "bytes"),
            sensor("MemoryFree", .dataSize, stateClass: .measurement, graphStyle: .progress, capability: "system.memory", unit: "bytes"),
            sensor("PressureApp", .percent, stateClass: .measurement, graphStyle: .progress, capability: "system.memory", unit: "%"),
            sensor("PressureWired", .percent, stateClass: .measurement, graphStyle: .progress, capability: "system.memory", unit: "%"),
            sensor("PressureFree", .percent, stateClass: .measurement, graphStyle: .progress, capability: "system.memory", unit: "%")
        ]
        let states = Dictionary(uniqueKeysWithValues: descriptors.map {
            ($0.id, EntityState(id: $0.id, value: .number(1), availability: .online))
        })

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)

        let ids = plan.cards.flatMap(\.children).filter { $0.kind == .segmentedRing }.map(\.id)
        XCTAssertEqual(ids, [
            "group:system.memory:dataSize:bytes:segments",
            "group:system.memory:percent:%:segments"
        ])
    }

    func testControlsAndConfigExclusionSurviveCapabilitySections() {
        let control = EntityDescriptor(
            id: "i/p.toggle",
            instanceID: "i/p",
            name: "Toggle",
            kind: .toggle,
            capability: "system.cpu",
            command: CommandRef(commandID: "toggle")
        )
        let config = sensor("config", nil, kind: .text, category: .config, capability: "system.memory")

        let plan = SurfaceComposer.detailPlan(descriptors: [config, control], states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["Controls"])
        XCTAssertEqual(plan.cards.first?.children.first?.entities, [control.id])
    }
}

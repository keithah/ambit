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

    func testComplementaryMeasurementPairProducesDualLineGraph() {
        let descriptors = [
            sensor("User", .percent, stateClass: .measurement, capability: "system.cpu"),
            sensor("System", .percent, stateClass: .measurement, capability: "system.cpu")
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.children.count, 1)
        XCTAssertEqual(cpu?.children.first?.kind, .dualLineGraph)
        XCTAssertEqual(cpu?.children.first?.id, "group:system.cpu:percent:none:user-system")
        XCTAssertEqual(cpu?.children.first?.entities.map(\.rawValue), ["i/p.User", "i/p.System"])
    }

    func testSingleMeasurementSeriesStaysSingleLineWithName() {
        let plan = SurfaceComposer.detailPlan(descriptors: [sensor("lat", .latency, stateClass: .measurement)], states: [:])
        let card = plan.cards.first?.children.first
        XCTAssertEqual(card?.entities.map(\.rawValue), ["i/p.lat"])
        XCTAssertEqual(card?.title, "lat")
    }

    func testPrimaryLatencyMeasurementAutoIncludesSampleHistoryCard() {
        let descriptors = [
            sensor("primary", .latency, stateClass: .measurement, isPrimary: true),
            sensor("secondary", .latency, stateClass: .measurement, isPrimary: true)
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        let leaves = renderedLeaves(in: plan)

        XCTAssertEqual(leaves.map(\.kind), [.historyGraph, .sampleHistory])
        XCTAssertEqual(leaves.first { $0.kind == .sampleHistory }?.id, "history:i/p.primary")
        XCTAssertEqual(leaves.first { $0.kind == .sampleHistory }?.entities, ["i/p.primary"])
    }

    func testSampleHistoryFollowsFocusedLatencyDescriptorInput() {
        let focused = sensor("focused", .latency, stateClass: .measurement, isPrimary: true)

        let plan = SurfaceComposer.detailPlan(descriptors: [focused], states: [:])
        let history = renderedLeaves(in: plan).first { $0.kind == .sampleHistory }

        XCTAssertEqual(history?.id, "history:i/p.focused")
        XCTAssertEqual(history?.entities, ["i/p.focused"])
    }

    func testNonLatencyMeasurementsExposeSampleHistoryAsAvailableButNotAutoShown() {
        let slotID = SlotID(rawValue: "slot.system")
        let descriptors = [
            sensor("CPU", .percent, stateClass: .measurement, graphStyle: .gauge, isPrimary: true, capability: "system.cpu")
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:], slotID: slotID)
        let items = SurfaceComposer.surfaceItems(descriptors: descriptors, states: [:], slotID: slotID)

        XCTAssertFalse(renderedLeaves(in: plan).contains { $0.kind == .sampleHistory })
        XCTAssertEqual(items.map(\.id.rawValue), ["entity:i/p.CPU", "history:i/p.CPU"])
        XCTAssertEqual(items.map(\.isShown), [true, false])
        XCTAssertEqual(items.map(\.label), ["CPU", "CPU history"])
    }

    func testPreferredSampleHistoryUsesSameIdentityInPlanAndAvailableItems() {
        let slotID = SlotID(rawValue: "slot.ping")
        let primary = sensor("primary", .latency, stateClass: .measurement, isPrimary: true)
        let selected = sensor("selected", .latency, stateClass: .measurement)

        let plan = SurfaceComposer.detailPlan(
            descriptors: [primary, selected],
            states: [:],
            slotID: slotID,
            preferredSampleHistoryEntityID: selected.id
        )
        let items = SurfaceComposer.surfaceItems(
            descriptors: [primary, selected],
            states: [:],
            slotID: slotID,
            preferredSampleHistoryEntityID: selected.id
        )

        let history = renderedLeaves(in: plan).first { $0.kind == .sampleHistory }
        XCTAssertEqual(history?.id, "history:i/p.selected")
        XCTAssertEqual(history?.entities, [selected.id])
        XCTAssertEqual(items.filter { $0.id.rawValue.hasPrefix("history:") }.map(\.id.rawValue), [
            "history:i/p.primary",
            "history:i/p.selected"
        ])
        XCTAssertEqual(items.first { $0.id.rawValue == "history:i/p.selected" }?.isShown, true)
        XCTAssertEqual(items.first { $0.id.rawValue == "history:i/p.primary" }?.isShown, false)
    }

    func testSingleEponymousChildOmitsRepeatedSectionTitle() {
        let plan = SurfaceComposer.detailPlan(descriptors: [
            sensor("CPU", .percent, graphStyle: .gauge, capability: "system.cpu")
        ], states: [:])

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.children.count, 1)
        XCTAssertNil(cpu?.children.first?.title)
    }

    func testEponymousChildTitleIsOmittedInMultiChildSection() {
        let descriptors = [
            sensor("User", .percent, stateClass: .measurement, capability: "system.cpu"),
            sensor("System", .percent, stateClass: .measurement, capability: "system.cpu"),
            sensor("CPU", .percent, graphStyle: .gauge, capability: "system.cpu"),
            sensor("Top CPU", nil, kind: .table, capability: "system.cpu")
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.title, "CPU")
        XCTAssertEqual(cpu?.children.map(\.kind), [.dualLineGraph, .gauge, .statTable])
        XCTAssertNil(cpu?.children[1].title)
        XCTAssertEqual(cpu?.children[2].title, "Top CPU")
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

    func testSlotTableRowLimitFlowsToStatTableCards() {
        let slotID = SlotID(rawValue: "slot.system")
        let table = sensor("Top CPU", nil, kind: .table, capability: "system.cpu")
        var config = PresentationConfig.empty
        config.slotOverrides[slotID] = SlotPresentationOverride(tableRowLimit: 7)

        let plan = SurfaceComposer.detailPlan(descriptors: [table], states: [:], config: config, slotID: slotID)

        let card = plan.cards.flatMap(\.children).first
        XCTAssertEqual(card?.kind, .statTable)
        XCTAssertEqual(card?.tableRowLimit, 7)
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
        XCTAssertEqual(memory?.children.count, 2)
        XCTAssertEqual(memory?.children.map(\.kind), [.segmentedRing, .breakdownLegend])
        XCTAssertEqual(memory?.children[0].id, "group:system.memory:dataSize:none:segments")
        XCTAssertEqual(memory?.children[1].id, "group:system.memory:dataSize:none:breakdown")
        XCTAssertEqual(memory?.children[1].entities.map(\.rawValue), [
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
        XCTAssertFalse(kinds.contains(.breakdownLegend))
        XCTAssertEqual(kinds, [.cardRow])
        XCTAssertEqual(plan.cards.flatMap(\.children).first?.children.map(\.kind), [.progress, .progress, .progress])
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

    func testHomogeneousCoreMetricsProduceCoreGrid() {
        let descriptors = [
            sensor("Core 1", .percent, stateClass: .measurement, graphStyle: .gauge, priority: 4, capability: "system.cpu", compositionRole: .channel, unit: "%"),
            sensor("Core 2", .percent, stateClass: .measurement, graphStyle: .gauge, priority: 3, capability: "system.cpu", compositionRole: .channel, unit: "%"),
            sensor("Core 3", .percent, stateClass: .measurement, graphStyle: .gauge, priority: 2, capability: "system.cpu", compositionRole: .channel, unit: "%"),
            sensor("Core 4", .percent, stateClass: .measurement, graphStyle: .gauge, priority: 1, capability: "system.cpu", compositionRole: .channel, unit: "%")
        ]
        let states = Dictionary(uniqueKeysWithValues: descriptors.map {
            ($0.id, EntityState(id: $0.id, value: .number(42), availability: .online))
        })

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.children.count, 1)
        XCTAssertEqual(cpu?.children.first?.kind, .coreGrid)
        XCTAssertEqual(cpu?.children.first?.id, "group:system.cpu:percent:%:cores")
        XCTAssertEqual(cpu?.children.first?.entities.map(\.rawValue), [
            "i/p.Core 1", "i/p.Core 2", "i/p.Core 3", "i/p.Core 4"
        ])
    }

    func testNonPercentChannelsStayIndependentUntilGenericAxisModelLands() {
        let descriptors = [
            sensor("Fan 1", .fan, stateClass: .measurement, graphStyle: .gauge, capability: "system.fans", compositionRole: .channel),
            sensor("Fan 2", .fan, stateClass: .measurement, graphStyle: .gauge, capability: "system.fans", compositionRole: .channel),
            sensor("Fan 3", .fan, stateClass: .measurement, graphStyle: .gauge, capability: "system.fans", compositionRole: .channel)
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        let kinds = plan.cards.flatMap(\.children).map(\.kind)
        XCTAssertEqual(kinds, [.cardRow])
        XCTAssertEqual(plan.cards.flatMap(\.children).first?.children.map(\.kind), [.gauge, .gauge, .gauge])
    }

    func testCoreGridRendersEvenWhenSomeMembersUnavailable() {
        let descriptors = [
            sensor("Core 1", .percent, stateClass: .measurement, graphStyle: .gauge, capability: "system.cpu", compositionRole: .channel, unit: "%"),
            sensor("Core 2", .percent, stateClass: .measurement, graphStyle: .gauge, capability: "system.cpu", compositionRole: .channel, unit: "%"),
            sensor("Core 3", .percent, stateClass: .measurement, graphStyle: .gauge, capability: "system.cpu", compositionRole: .channel, unit: "%")
        ]
        let states: [EntityID: EntityState] = [
            descriptors[0].id: EntityState(id: descriptors[0].id, value: .number(25), availability: .online),
            descriptors[1].id: EntityState(id: descriptors[1].id, value: nil, availability: .unavailable),
            descriptors[2].id: EntityState(id: descriptors[2].id, value: .number(75), availability: .online)
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)

        let card = plan.cards.flatMap(\.children).first
        XCTAssertEqual(card?.kind, .coreGrid)
        XCTAssertEqual(card?.entities.count, 3)
    }

    func testSmallBoundedSiblingsGroupIntoCardRowsWithinSection() {
        let descriptors = [
            sensor("CPU", .percent, graphStyle: .gauge, isPrimary: true, priority: 4, capability: "system.cpu"),
            sensor("Pressure", .percent, graphStyle: .gauge, priority: 3, capability: "system.cpu"),
            sensor("Load", .percent, graphStyle: .progress, priority: 2, capability: "system.cpu"),
            sensor("Memory", .percent, graphStyle: .gauge, priority: 1, capability: "system.memory")
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.children.map(\.kind), [.cardRow])
        XCTAssertEqual(cpu?.children.first?.id, "row:CPU:0")
        XCTAssertEqual(cpu?.children.first?.entities, [])
        XCTAssertEqual(cpu?.children.first?.children.map(\.id), [
            "card.i/p.CPU", "card.i/p.Pressure", "card.i/p.Load"
        ])
        XCTAssertEqual(cpu?.children.first?.children.map(\.kind), [.gauge, .gauge, .progress])

        let memory = plan.cards.first { $0.title == "Memory" }
        XCTAssertEqual(memory?.children.map(\.kind), [.gauge])
    }

    func testCardRowLeavesIneligibleCardsFullWidthAndPreservesOrder() {
        let descriptors = [
            sensor("Gauge 1", .percent, stateClass: .measurement, graphStyle: .gauge, priority: 5, capability: "system.cpu"),
            sensor("History", .latency, stateClass: .measurement, graphStyle: .sparkline, priority: 4, capability: "system.cpu"),
            sensor("Gauge 2", .percent, stateClass: .measurement, graphStyle: .gauge, priority: 3, capability: "system.cpu"),
            sensor("Gauge 3", .percent, stateClass: .measurement, graphStyle: .gauge, priority: 2, capability: "system.cpu")
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.children.map(\.kind), [.gauge, .historyGraph, .cardRow])
        XCTAssertEqual(cpu?.children[0].entities, [descriptors[0].id])
        XCTAssertEqual(cpu?.children[1].entities, [descriptors[1].id])
        XCTAssertEqual(cpu?.children[2].children.map(\.id), [
            "card.i/p.Gauge 2", "card.i/p.Gauge 3"
        ])
    }

    func testCardRowCapsAtThreeAndLeavesSingleRemainderFullWidth() {
        let descriptors = [
            sensor("A", .percent, graphStyle: .gauge, priority: 5, capability: "system.cpu"),
            sensor("B", .percent, graphStyle: .gauge, priority: 4, capability: "system.cpu"),
            sensor("C", .percent, graphStyle: .gauge, priority: 3, capability: "system.cpu"),
            sensor("D", .percent, graphStyle: .gauge, priority: 2, capability: "system.cpu")
        ]

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.children.map(\.kind), [.cardRow, .gauge])
        XCTAssertEqual(cpu?.children[0].children.count, 3)
        XCTAssertEqual(cpu?.children[1].entities, [descriptors[3].id])
    }

    func testSlotCustomizationAutoMinusHiddenFiltersLeafCardsAndRegroupsRows() {
        let slotID = SlotID(rawValue: "slot.system")
        let descriptors = [
            sensor("A", .percent, graphStyle: .gauge, priority: 5, capability: "system.cpu"),
            sensor("B", .percent, graphStyle: .gauge, priority: 4, capability: "system.cpu"),
            sensor("C", .percent, graphStyle: .gauge, priority: 3, capability: "system.cpu")
        ]
        var config = PresentationConfig.empty
        config.slotOverrides[slotID] = SlotPresentationOverride(
            hiddenItems: [SurfaceItemID(rawValue: "entity:i/p.B")]
        )

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:], config: config, slotID: slotID)

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.children.map(\.kind), [.cardRow])
        XCTAssertEqual(cpu?.children.first?.id, "row:CPU:0")
        XCTAssertEqual(cpu?.children.first?.children.map(\.id), ["card.i/p.A", "card.i/p.C"])
    }

    func testSlotCustomizationExplicitShownItemsOrdersLeavesAndSkipsMissingIDs() {
        let slotID = SlotID(rawValue: "slot.system")
        let descriptors = [
            sensor("A", .percent, graphStyle: .gauge, priority: 5, capability: "system.cpu"),
            sensor("B", .percent, graphStyle: .gauge, priority: 4, capability: "system.cpu"),
            sensor("C", .percent, graphStyle: .gauge, priority: 3, capability: "system.cpu")
        ]
        var config = PresentationConfig.empty
        config.slotOverrides[slotID] = SlotPresentationOverride(
            shownItems: [
                SurfaceItemID(rawValue: "entity:i/p.C"),
                SurfaceItemID(rawValue: "entity:missing"),
                SurfaceItemID(rawValue: "entity:i/p.A")
            ],
            hiddenItems: [SurfaceItemID(rawValue: "entity:i/p.A")]
        )

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:], config: config, slotID: slotID)

        let cpu = plan.cards.first { $0.title == "CPU" }
        XCTAssertEqual(cpu?.children.map(\.kind), [.cardRow])
        XCTAssertEqual(cpu?.children.first?.children.map(\.id), ["card.i/p.C", "card.i/p.A"])
    }

    func testSlotCustomizationPureAutoMatchesUncustomizedPlan() {
        let slotID = SlotID(rawValue: "slot.system")
        let descriptors = [
            sensor("A", .percent, graphStyle: .gauge, priority: 5, capability: "system.cpu"),
            sensor("B", .percent, graphStyle: .gauge, priority: 4, capability: "system.cpu"),
            sensor("latency", .latency, stateClass: .measurement, capability: "uplink")
        ]
        let auto = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:])
        var config = PresentationConfig.empty
        config.slotOverrides[slotID] = SlotPresentationOverride()

        let customizedAuto = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:], config: config, slotID: slotID)

        XCTAssertEqual(customizedAuto, auto)
    }

    func testSlotCustomizationCanHideWholeSection() {
        let slotID = SlotID(rawValue: "slot.system")
        let descriptors = [
            sensor("A", .percent, graphStyle: .gauge, capability: "system.cpu"),
            sensor("B", .percent, graphStyle: .gauge, capability: "system.memory")
        ]
        var config = PresentationConfig.empty
        config.slotOverrides[slotID] = SlotPresentationOverride(
            hiddenItems: [SurfaceItemID(rawValue: "section:Memory")]
        )

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:], config: config, slotID: slotID)

        XCTAssertEqual(plan.cards.map(\.title), ["CPU"])
    }

    func testSurfaceItemsExposeCanonicalIDsLabelsSectionsAndShownState() {
        let slotID = SlotID(rawValue: "slot.system")
        let descriptors = [
            sensor("CPU", .percent, stateClass: .measurement, graphStyle: .gauge, priority: 50, capability: "system.cpu"),
            sensor("User", .percent, stateClass: .measurement, graphStyle: .sparkline, priority: 40, capability: "system.cpu"),
            sensor("System", .percent, stateClass: .measurement, graphStyle: .sparkline, priority: 30, capability: "system.cpu"),
            sensor("Core 1", .percent, graphStyle: .gauge, priority: 20, capability: "system.cpu", compositionRole: .channel),
            sensor("Core 2", .percent, graphStyle: .gauge, priority: 19, capability: "system.cpu", compositionRole: .channel),
            sensor("Core 3", .percent, graphStyle: .gauge, priority: 18, capability: "system.cpu", compositionRole: .channel),
            sensor("App/Active", .dataSize, graphStyle: .progress, priority: 30, capability: "system.memory", compositionRole: .segment, unit: "B"),
            sensor("Wired", .dataSize, graphStyle: .progress, priority: 20, capability: "system.memory", compositionRole: .segment, unit: "B"),
            sensor("Compressed", .dataSize, graphStyle: .progress, priority: 10, capability: "system.memory", compositionRole: .segment, unit: "B"),
            sensor("Free", .dataSize, graphStyle: .progress, priority: 0, capability: "system.memory", compositionRole: .remainder, unit: "B")
        ]
        let states = Dictionary(uniqueKeysWithValues: descriptors.map {
            ($0.id, EntityState(id: $0.id, value: .number(1), availability: .online))
        })
        var config = PresentationConfig.empty
        config.slotOverrides[slotID] = SlotPresentationOverride(
            hiddenItems: [SurfaceItemID(rawValue: "group:system.memory:dataSize:B:breakdown")]
        )

        let items = SurfaceComposer.surfaceItems(descriptors: descriptors, states: states, config: config, slotID: slotID)

        XCTAssertEqual(items.map(\.id.rawValue), [
            "group:system.cpu:percent:none:cores",
            "group:system.cpu:percent:none:user-system",
            "entity:i/p.CPU",
            "history:i/p.CPU",
            "history:i/p.User",
            "history:i/p.System",
            "group:system.memory:dataSize:B:segments",
            "group:system.memory:dataSize:B:breakdown"
        ])
        XCTAssertEqual(items.map(\.label), ["CPU Cores", "CPU User/System", "CPU", "CPU history", "User history", "System history", "Memory breakdown", "Memory breakdown details"])
        XCTAssertEqual(items.map(\.section), ["CPU", "CPU", "CPU", "CPU", "CPU", "CPU", "Memory", "Memory"])
        XCTAssertEqual(items.map(\.isShown), [true, true, true, false, false, false, true, false])
        XCTAssertEqual(items.map(\.isHidden), [false, false, false, false, false, false, false, true])
    }

    func testSurfaceItemsMatchRenderedLeafIDs() {
        let slotID = SlotID(rawValue: "slot.system")
        let descriptors = [
            sensor("A", .percent, graphStyle: .gauge, priority: 5, capability: "system.cpu"),
            sensor("B", .percent, graphStyle: .gauge, priority: 4, capability: "system.cpu"),
            sensor("C", .percent, graphStyle: .gauge, priority: 3, capability: "system.cpu")
        ]
        var config = PresentationConfig.empty
        config.slotOverrides[slotID] = SlotPresentationOverride(
            shownItems: [SurfaceItemID(rawValue: "entity:i/p.C"), SurfaceItemID(rawValue: "entity:i/p.A")]
        )

        let items = SurfaceComposer.surfaceItems(descriptors: descriptors, states: [:], config: config, slotID: slotID)
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: [:], config: config, slotID: slotID)
        let renderedIDs = plan.cards.flatMap(\.children).flatMap { card in
            card.kind == .cardRow ? card.children.map(\.id) : [card.id]
        }

        XCTAssertEqual(items.filter(\.isShown).map(\.card.id), renderedIDs)
        XCTAssertEqual(renderedIDs, ["card.i/p.C", "card.i/p.A"])
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

    private func renderedLeaves(in plan: SurfacePlan) -> [CardSpec] {
        plan.cards.flatMap(\.children).flatMap { card in
            card.kind == .cardRow ? card.children : [card]
        }
    }
}

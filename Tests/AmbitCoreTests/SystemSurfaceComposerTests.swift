import XCTest
@testable import AmbitCore

final class SystemSurfaceComposerTests: XCTestCase {
    func testFullSystemSurfaceUsesOnlyGenericCardVocabulary() {
        let descriptors = fullSystemDescriptors()
        let states = fullSystemStates(for: descriptors)

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)
        let childCards = plan.cards.flatMap(\.children)

        XCTAssertEqual(plan.cards.map(\.title), ["CPU", "Memory", "Disk", "Network", "Power", "Sensors", "Fans"])
        XCTAssertTrue(Set(childCards.map(\.kind)).isSubset(of: [
            .gauge,
            .progress,
            .historyGraph,
            .statTable,
            .statusRow
        ]))
    }

    func testFullSystemSurfaceDoesNotBindCardsToProviderOrIntegrationIDs() {
        let descriptors = fullSystemDescriptors()
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: fullSystemStates(for: descriptors))
        let allCards = plan.cards + plan.cards.flatMap(\.children)
        let forbiddenIDs: Set<String> = [
            IntegrationIDs.system.rawValue,
            ProviderIDs.systemOverview,
            ProviderIDs.systemStorage,
            ProviderIDs.systemProcesses,
            ProviderIDs.systemNetwork,
            ProviderIDs.systemSensors,
            ProviderIDs.systemFans
        ]

        for card in allCards {
            XCTAssertFalse(forbiddenIDs.contains(card.id), "Card id should not be a provider/integration id: \(card.id)")
            if let title = card.title {
                XCTAssertFalse(forbiddenIDs.contains(title), "Card title should not be a provider/integration id: \(title)")
            }
            XCTAssertTrue(card.entities.allSatisfy { !forbiddenIDs.contains($0.rawValue) })
        }
    }

    func testUnavailableSensorsAndFansRemainStableGenericCards() {
        let descriptors = fullSystemDescriptors()
        let states = fullSystemStates(for: descriptors)
        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)

        let sensors = plan.cards.first { $0.title == "Sensors" }
        let fans = plan.cards.first { $0.title == "Fans" }

        XCTAssertEqual(sensors?.children.map(\.kind), [.statusRow])
        XCTAssertEqual(fans?.children.map(\.kind), [.statTable])
        XCTAssertEqual(sensors?.children.first?.entities, [systemID("sensors.temperature")])
        XCTAssertEqual(fans?.children.first?.entities, [systemID("fans.fans")])
        XCTAssertEqual(states[systemID("sensors.temperature")]?.availability, .unavailable)
        XCTAssertEqual(states[systemID("fans.fans")]?.availability, .unavailable)
    }

    private func fullSystemDescriptors() -> [EntityDescriptor] {
        [
            descriptor("overview.cpu_usage_percent", instanceID: ProviderInstanceIDs.systemOverview, name: "CPU", deviceClass: .percent, capability: "system.cpu", stateClass: .measurement, graphStyle: .gauge, isPrimary: true),
            descriptor("overview.cpu_user_percent", instanceID: ProviderInstanceIDs.systemOverview, name: "User", deviceClass: .percent, capability: "system.cpu", stateClass: .measurement),
            descriptor("overview.memory_used_percent", instanceID: ProviderInstanceIDs.systemOverview, name: "Memory", deviceClass: .percent, capability: "system.memory", stateClass: .measurement, graphStyle: .progress),
            descriptor("overview.memory_used_bytes", instanceID: ProviderInstanceIDs.systemOverview, name: "Used", deviceClass: .dataSize, capability: "system.memory", stateClass: .measurement),
            descriptor("overview.battery_percent", instanceID: ProviderInstanceIDs.systemOverview, name: "Battery", deviceClass: .battery, capability: "power.battery", stateClass: .measurement, graphStyle: .progress),
            descriptor("overview.battery_charging", instanceID: ProviderInstanceIDs.systemOverview, name: "Battery Charging", kind: .binarySensor, deviceClass: .battery, capability: "power.battery"),
            descriptor("storage.volumes", instanceID: ProviderInstanceIDs.systemStorage, name: "Volumes", kind: .table, capability: "system.disk"),
            descriptor("processes.top_cpu", instanceID: ProviderInstanceIDs.systemProcesses, name: "Top CPU", kind: .table, capability: "system.cpu"),
            descriptor("processes.top_memory", instanceID: ProviderInstanceIDs.systemProcesses, name: "Top Memory", kind: .table, capability: "system.memory"),
            descriptor("network.throughput_in", instanceID: ProviderInstanceIDs.systemNetwork, name: "In", deviceClass: .throughput, capability: "system.network", stateClass: .measurement, graphStyle: .sparkline, isPrimary: true),
            descriptor("network.throughput_out", instanceID: ProviderInstanceIDs.systemNetwork, name: "Out", deviceClass: .throughput, capability: "system.network", stateClass: .measurement, graphStyle: .sparkline),
            descriptor("network.interfaces", instanceID: ProviderInstanceIDs.systemNetwork, name: "Interfaces", kind: .table, capability: "system.network"),
            descriptor("sensors.temperature", instanceID: ProviderInstanceIDs.systemSensors, name: "Temperature", deviceClass: .temperature, capability: "system.sensors"),
            descriptor("fans.fans", instanceID: ProviderInstanceIDs.systemFans, name: "Fans", kind: .table, deviceClass: .fan, capability: "system.fans")
        ]
    }

    private func fullSystemStates(for descriptors: [EntityDescriptor]) -> [EntityID: EntityState] {
        Dictionary(uniqueKeysWithValues: descriptors.map { descriptor in
            let state: EntityState
            switch descriptor.kind {
            case .table:
                if descriptor.capability == "system.fans" {
                    state = EntityState(id: descriptor.id, availability: .unavailable, severity: .normal)
                } else {
                    state = EntityState(id: descriptor.id, value: .table(table(for: descriptor)), availability: .online, severity: .normal)
                }
            case .binarySensor:
                state = EntityState(id: descriptor.id, value: .bool(true), availability: .online, severity: .normal)
            default:
                if descriptor.capability == "system.sensors" {
                    state = EntityState(id: descriptor.id, availability: .unavailable, severity: .normal)
                } else {
                    state = EntityState(id: descriptor.id, value: .number(42), availability: .online, severity: .normal)
                }
            }
            return (descriptor.id, state)
        })
    }

    private func table(for descriptor: EntityDescriptor) -> TableValue {
        switch descriptor.capability {
        case "system.disk":
            return TableValue(
                columns: [
                    TableColumn(id: "volume", title: "Volume"),
                    TableColumn(id: "mount", title: "Mount"),
                    TableColumn(id: "used", title: "Used", alignment: .trailing, valueStyle: .number)
                ],
                rows: [TableRow(id: "/", cells: ["volume": .text("Macintosh HD"), "mount": .text("/"), "used": .number(128, unit: "GB")])]
            )
        case "system.cpu", "system.memory":
            return TableValue(
                columns: [
                    TableColumn(id: "pid", title: "PID", alignment: .trailing, valueStyle: .number),
                    TableColumn(id: "name", title: "Name"),
                    TableColumn(id: "value", title: "Value", alignment: .trailing, valueStyle: .number)
                ],
                rows: [TableRow(id: "123:WindowServer", cells: ["pid": .number(123, unit: nil), "name": .text("WindowServer"), "value": .number(12.5, unit: "%")])]
            )
        case "system.network":
            return TableValue(
                columns: [
                    TableColumn(id: "interface", title: "Interface"),
                    TableColumn(id: "in", title: "In", alignment: .trailing, valueStyle: .number),
                    TableColumn(id: "out", title: "Out", alignment: .trailing, valueStyle: .number)
                ],
                rows: [TableRow(id: "en0", cells: ["interface": .text("en0"), "in": .number(1_024, unit: "bps"), "out": .number(2_048, unit: "bps")])]
            )
        default:
            return TableValue(columns: [], rows: [])
        }
    }

    private func descriptor(
        _ key: String,
        instanceID: ProviderInstanceID,
        name: String,
        kind: EntityKind = .sensor,
        deviceClass: DeviceClass? = nil,
        capability: ProviderCapability? = nil,
        stateClass: StateClass? = nil,
        graphStyle: GraphStyle? = nil,
        isPrimary: Bool = false
    ) -> EntityDescriptor {
        EntityDescriptor(
            id: systemID(key),
            instanceID: instanceID,
            name: name,
            kind: kind,
            deviceClass: deviceClass,
            category: .primary,
            capability: capability,
            stateClass: stateClass,
            graphStyle: graphStyle,
            isPrimary: isPrimary
        )
    }

    private func systemID(_ key: String) -> EntityID {
        EntityID(rawValue: "system@local/\(key)")
    }
}

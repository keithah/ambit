import XCTest
@testable import AmbitCore

final class EntityProjectionTests: XCTestCase {
    private struct DemoProvider: Provider {
        let id: ProviderID = "demo"
        let displayName = "Demo"
        let pollInterval: TimeInterval = 5
        let commands: [CommandDescriptor]
        func poll(context: EnvironmentContext) async -> ProviderSnapshot { ProviderSnapshot() }
    }

    func testDefaultDescriptorsMapCommandsToControlsAndAddHealthSensor() {
        let provider = DemoProvider(commands: [
            CommandDescriptor(id: "demo.toggle", label: "Toggle", parameters: [CommandParameter(id: "on", label: "On", kind: .bool)]),
            CommandDescriptor(id: "demo.mode", label: "Mode", parameters: [CommandParameter(id: "mode", label: "Mode", kind: .option(["A", "B"]))]),
            CommandDescriptor(id: "demo.level", label: "Level", parameters: [CommandParameter(id: "level", label: "Level", kind: .number)]),
            CommandDescriptor(id: "demo.run", label: "Run"),
            CommandDescriptor(id: "demo.multi", label: "Multi", parameters: [
                CommandParameter(id: "a", label: "A", kind: .text),
                CommandParameter(id: "b", label: "B", kind: .text)
            ])
        ])

        let descriptors = provider.entityDescriptors()
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id.rawValue, $0) })

        // Health connectivity sensor is always present and diagnostic.
        let health = byID["demo.health"]
        XCTAssertEqual(health?.kind, .binarySensor)
        XCTAssertEqual(health?.deviceClass, .connectivity)
        XCTAssertEqual(health?.category, .diagnostic)

        XCTAssertEqual(byID["demo.demo.toggle"]?.kind, .toggle)
        XCTAssertEqual(byID["demo.demo.toggle"]?.command?.argumentKey, "on")
        XCTAssertEqual(byID["demo.demo.mode"]?.kind, .select)
        XCTAssertEqual(byID["demo.demo.mode"]?.options, [EntityOption(value: "A", label: "A"), EntityOption(value: "B", label: "B")])
        XCTAssertEqual(byID["demo.demo.level"]?.kind, .number)
        XCTAssertEqual(byID["demo.demo.run"]?.kind, .button)        // no params → momentary button
        XCTAssertEqual(byID["demo.demo.multi"]?.kind, .button)      // multi-param → opens detail
        XCTAssertEqual(byID["demo.demo.run"]?.access, .write)
        XCTAssertEqual(byID["demo.demo.toggle"]?.access, .readWrite)
    }

    func testSnapshotDescriptorsInferSensorsFromMetrics() {
        let provider = DemoProvider(commands: [])
        let snapshot = ProviderSnapshot(health: .ok, metrics: [
            Metric(id: "download_bps", label: "Download", value: .throughput(bitsPerSecond: 12_000_000)),
            Metric(id: "latency_ms", label: "Latency", value: .latency(ms: 24)),
            Metric(id: "connected", label: "Connected", value: .bool(true))
        ])

        let descriptors = EntityProjection.descriptors(provider: provider, snapshot: snapshot)
        let byID = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id.rawValue, $0) })

        XCTAssertEqual(byID["demo.download_bps"]?.kind, .sensor)
        XCTAssertEqual(byID["demo.download_bps"]?.deviceClass, .throughput)
        XCTAssertEqual(byID["demo.download_bps"]?.unit, "bps")
        XCTAssertEqual(byID["demo.latency_ms"]?.deviceClass, .latency)
        XCTAssertEqual(byID["demo.connected"]?.kind, .binarySensor)
        XCTAssertEqual(byID["demo.connected"]?.metricID, "connected")
    }

    func testStatesOverlayMetricValuesAndHealthWhenOnline() {
        let provider = DemoProvider(commands: [])
        let snapshot = ProviderSnapshot(health: .ok, metrics: [
            Metric(id: "latency_ms", label: "Latency", value: .latency(ms: 24)),
            Metric(id: "connected", label: "Connected", value: .bool(true))
        ])
        let descriptors = EntityProjection.descriptors(provider: provider, snapshot: snapshot)

        let states = EntityProjection.states(snapshot: snapshot, descriptors: descriptors)

        XCTAssertEqual(states[EntityID(rawValue: "demo.latency_ms")]?.value, .number(24))
        XCTAssertEqual(states[EntityID(rawValue: "demo.latency_ms")]?.availability, .online)
        XCTAssertEqual(states[EntityID(rawValue: "demo.connected")]?.value, .bool(true))
        XCTAssertEqual(states[EntityID(rawValue: "demo.health")]?.value, .bool(true))
        XCTAssertEqual(states[EntityID(rawValue: "demo.health")]?.availability, .online)
    }

    func testStatesOverlayTableMetricValues() {
        let table = TableValue(
            columns: [
                TableColumn(id: "name", title: "Name", alignment: .leading, valueStyle: .text),
                TableColumn(id: "cpu", title: "CPU", alignment: .trailing, valueStyle: .number)
            ],
            rows: [
                TableRow(id: "123:WindowServer", cells: [
                    "name": .text("WindowServer"),
                    "cpu": .number(18.4, unit: "%")
                ])
            ]
        )
        let descriptor = EntityDescriptor(
            id: "demo.processes",
            instanceID: "demo",
            name: "Top Processes",
            kind: .table,
            metricID: "processes"
        )
        let snapshot = ProviderSnapshot(health: .ok, metrics: [
            Metric(id: "processes", label: "Top Processes", value: .table(table))
        ])

        let states = EntityProjection.states(snapshot: snapshot, descriptors: [descriptor])

        XCTAssertEqual(states["demo.processes"]?.value, .table(table))
        XCTAssertEqual(states["demo.processes"]?.availability, .online)
    }

    func testOfflineDescriptorsPersistAndStatesAreUnavailable() {
        let provider = DemoProvider(commands: [
            CommandDescriptor(id: "demo.run", label: "Run")
        ])
        // Descriptors derived while online stay valid; states are computed from a later
        // (failed/offline) poll where the snapshot has no data.
        let onlineSnapshot = ProviderSnapshot(health: .ok, metrics: [
            Metric(id: "latency_ms", label: "Latency", value: .latency(ms: 24))
        ])
        let descriptors = EntityProjection.descriptors(provider: provider, snapshot: onlineSnapshot)

        let states = EntityProjection.states(snapshot: nil, descriptors: descriptors)

        // Descriptors persist (identity stable offline).
        XCTAssertTrue(descriptors.contains { $0.id.rawValue == "demo.latency_ms" })
        XCTAssertTrue(descriptors.contains { $0.id.rawValue == "demo.health" })
        // ...but every state is unavailable.
        XCTAssertEqual(states.count, descriptors.count)
        XCTAssertTrue(states.values.allSatisfy { $0.availability == .unavailable })
        XCTAssertTrue(states.values.allSatisfy { $0.value == nil })
    }
}

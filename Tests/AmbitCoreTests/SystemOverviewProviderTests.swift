import XCTest
@testable import AmbitCore

final class SystemOverviewProviderTests: XCTestCase {
    func testSystemOverviewProviderDeclaresExpectedDescriptors() {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()))
        let descriptors = byKey(provider.entityDescriptors())

        let cpu = descriptors["cpu_usage_percent"]
        XCTAssertEqual(cpu?.kind, .sensor)
        XCTAssertEqual(cpu?.deviceClass, .percent)
        XCTAssertEqual(cpu?.capability, "system.cpu")
        XCTAssertEqual(cpu?.graphStyle, .gauge)
        XCTAssertEqual(cpu?.isPrimary, true)
        XCTAssertEqual(cpu?.defaultVisibility, .auto)
        XCTAssertEqual(cpu?.displayThreshold, DisplayThreshold(comparison: .greaterThan, value: 85, consecutive: 3))

        XCTAssertEqual(descriptors["cpu_user_percent"]?.capability, "system.cpu")
        XCTAssertEqual(descriptors["cpu_system_percent"]?.capability, "system.cpu")
        XCTAssertEqual(descriptors["memory_used_percent"]?.deviceClass, .percent)
        XCTAssertEqual(descriptors["memory_used_percent"]?.capability, "system.memory")
        XCTAssertEqual(descriptors["memory_used_percent"]?.graphStyle, .progress)
        XCTAssertEqual(descriptors["memory_used_bytes"]?.deviceClass, .dataSize)
        XCTAssertEqual(descriptors["memory_used_bytes"]?.capability, "system.memory")
        XCTAssertEqual(descriptors["battery_percent"]?.deviceClass, .battery)
        XCTAssertEqual(descriptors["battery_percent"]?.capability, "power.battery")
        XCTAssertEqual(descriptors["battery_percent"]?.graphStyle, .progress)
        XCTAssertEqual(descriptors["battery_charging"]?.kind, .binarySensor)
        XCTAssertEqual(descriptors["battery_charging"]?.capability, "power.battery")
        XCTAssertEqual(descriptors["battery_charging"]?.defaultVisibility, .auto)
        XCTAssertEqual(descriptors["load_1m"]?.capability, "system.cpu")
        XCTAssertEqual(descriptors["load_1m"]?.deviceClass, .count)
    }

    func testSystemOverviewProviderMapsSnapshotToMetricsAndStates() async {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()))
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("cpu_usage_percent"), .percent(20))
        XCTAssertEqual(snapshot.metricValue("cpu_user_percent"), .percent(12.5))
        XCTAssertEqual(snapshot.metricValue("cpu_system_percent"), .percent(7.5))
        XCTAssertEqual(snapshot.metricValue("memory_used_percent"), .percent(50))
        XCTAssertEqual(snapshot.metricValue("memory_used_bytes"), .level(8_000_000_000))
        XCTAssertEqual(snapshot.metricValue("battery_percent"), .level(88))
        XCTAssertEqual(snapshot.metricValue("battery_charging"), .bool(true))
        XCTAssertEqual(snapshot.metricValue("load_1m"), .level(1.2))

        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())
        XCTAssertEqual(states[ProviderInstanceIDs.systemOverview.appending("cpu_usage_percent")]?.value, .number(20))
        XCTAssertEqual(states[ProviderInstanceIDs.systemOverview.appending("memory_used_bytes")]?.value, .number(8_000_000_000))
        XCTAssertEqual(states[ProviderInstanceIDs.systemOverview.appending("battery_percent")]?.value, .number(88))
        XCTAssertEqual(states[ProviderInstanceIDs.systemOverview.appending("battery_charging")]?.value, .bool(true))
    }

    func testSystemOverviewOmitsBatteryMetricsWhenBatteryNotPresent() async {
        let snapshot = SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 12.5, systemPercent: 7.5, idlePercent: 80, coreCount: 10),
            memory: MemoryMetrics(usedBytes: 8_000_000_000, wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000, totalBytes: 16_000_000_000),
            battery: BatteryMetrics(percent: 0, isCharging: false, isPresent: false)
        )
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: snapshot))

        let result = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertNil(result.metricValue("battery_percent"))
        XCTAssertNil(result.metricValue("battery_charging"))
    }

    func testSystemOverviewDescriptorsRouteThroughGenericSections() {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()))
        let metricDescriptors = provider.entityDescriptors().filter { $0.metricID != nil }

        let plan = SurfaceComposer.detailPlan(descriptors: metricDescriptors, states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["CPU", "Memory", "Power"])
    }

    private func byKey(_ descriptors: [EntityDescriptor]) -> [String: EntityDescriptor] {
        Dictionary(uniqueKeysWithValues: descriptors.map { (String($0.id.rawValue.split(separator: ".").last ?? ""), $0) })
    }

    private static func snapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 12.5, systemPercent: 7.5, idlePercent: 80, coreCount: 10, loadAverages: [1.2, 1.4, 1.6]),
            memory: MemoryMetrics(usedBytes: 8_000_000_000, wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000, totalBytes: 16_000_000_000),
            battery: BatteryMetrics(percent: 88, isCharging: true, isPresent: true)
        )
    }
}

private struct FakeOverviewReader: SystemMetricsReading {
    var snapshot: SystemMetricsSnapshot
    func snapshot() async throws -> SystemMetricsSnapshot { snapshot }
}

private extension ProviderSnapshot {
    func metricValue(_ id: String) -> MetricValue? {
        metrics.first { $0.id == id }?.value
    }
}

private extension ProviderInstanceID {
    func appending(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}

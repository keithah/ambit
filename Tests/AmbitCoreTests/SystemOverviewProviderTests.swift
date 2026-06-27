import XCTest
@testable import AmbitCore

final class SystemOverviewProviderTests: XCTestCase {
    func testSystemOverviewProviderDeclaresExpectedDescriptors() {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()), coreCountHint: 4)
        let descriptors = byKey(provider.entityDescriptors())

        let cpu = descriptors["cpu_usage_percent"]
        XCTAssertEqual(cpu?.kind, .sensor)
        XCTAssertEqual(cpu?.deviceClass, .percent)
        XCTAssertEqual(cpu?.capability, "system.cpu")
        XCTAssertEqual(cpu?.graphStyle, .gauge)
        XCTAssertEqual(cpu?.isPrimary, true)
        XCTAssertEqual(cpu?.priority, 100)
        XCTAssertEqual(cpu?.defaultVisibility, .auto)
        XCTAssertEqual(cpu?.displayThreshold, DisplayThreshold(comparison: .greaterThan, value: 85, consecutive: 3))

        XCTAssertEqual(descriptors["cpu_user_percent"]?.capability, "system.cpu")
        XCTAssertEqual(descriptors["cpu_system_percent"]?.capability, "system.cpu")
        XCTAssertEqual(descriptors["cpu_core_0_percent"]?.deviceClass, .percent)
        XCTAssertEqual(descriptors["cpu_core_0_percent"]?.capability, "system.cpu")
        XCTAssertEqual(descriptors["cpu_core_0_percent"]?.graphStyle, .gauge)
        XCTAssertEqual(descriptors["cpu_core_0_percent"]?.compositionRole, .channel)
        XCTAssertEqual(descriptors["cpu_core_3_percent"]?.compositionRole, .channel)
        XCTAssertEqual(descriptors["memory_used_percent"]?.deviceClass, .percent)
        XCTAssertEqual(descriptors["memory_used_percent"]?.capability, "system.memory")
        XCTAssertEqual(descriptors["memory_used_percent"]?.graphStyle, .progress)
        XCTAssertEqual(descriptors["memory_pressure_percent"]?.deviceClass, .percent)
        XCTAssertEqual(descriptors["memory_pressure_percent"]?.capability, "system.memory")
        XCTAssertEqual(descriptors["memory_pressure_percent"]?.graphStyle, .gauge)
        XCTAssertEqual(descriptors["memory_app_active_bytes"]?.deviceClass, .dataSize)
        XCTAssertEqual(descriptors["memory_app_active_bytes"]?.capability, "system.memory")
        XCTAssertEqual(descriptors["memory_app_active_bytes"]?.graphStyle, .progress)
        XCTAssertEqual(descriptors["memory_app_active_bytes"]?.compositionRole, .segment)
        XCTAssertEqual(descriptors["memory_wired_bytes"]?.compositionRole, .segment)
        XCTAssertEqual(descriptors["memory_compressed_bytes"]?.compositionRole, .segment)
        XCTAssertEqual(descriptors["memory_cached_inactive_bytes"]?.compositionRole, .segment)
        XCTAssertEqual(descriptors["memory_free_bytes"]?.compositionRole, .remainder)
        XCTAssertEqual(descriptors["memory_used_percent"]?.isPrimary, true)
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
        XCTAssertEqual(descriptors["uptime_seconds"]?.deviceClass, .duration)
        XCTAssertEqual(descriptors["uptime_seconds"]?.capability, "system.cpu")
        XCTAssertEqual(descriptors["uptime_seconds"]?.unit, "s")
    }

    func testSystemOverviewProviderMapsSnapshotToMetricsAndStates() async {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()), coreCountHint: 4)
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertEqual(snapshot.health, .ok)
        XCTAssertEqual(snapshot.metricValue("cpu_usage_percent"), .percent(20))
        XCTAssertEqual(snapshot.metricValue("cpu_user_percent"), .percent(12.5))
        XCTAssertEqual(snapshot.metricValue("cpu_system_percent"), .percent(7.5))
        XCTAssertEqual(snapshot.metricValue("cpu_core_0_percent"), .percent(10))
        XCTAssertEqual(snapshot.metricValue("cpu_core_3_percent"), .percent(40))
        XCTAssertEqual(snapshot.metricValue("memory_used_percent"), .percent(50))
        XCTAssertEqual(snapshot.metricValue("memory_pressure_percent"), .percent(31.25))
        XCTAssertEqual(snapshot.metricValue("memory_app_active_bytes"), .level(4_000_000_000))
        XCTAssertEqual(snapshot.metricValue("memory_wired_bytes"), .level(2_000_000_000))
        XCTAssertEqual(snapshot.metricValue("memory_compressed_bytes"), .level(1_000_000_000))
        XCTAssertEqual(snapshot.metricValue("memory_cached_inactive_bytes"), .level(7_500_000_000))
        XCTAssertEqual(snapshot.metricValue("memory_free_bytes"), .level(1_500_000_000))
        XCTAssertEqual(snapshot.metricValue("memory_used_bytes"), .level(8_000_000_000))
        XCTAssertEqual(snapshot.metricValue("battery_percent"), .level(88))
        XCTAssertEqual(snapshot.metricValue("battery_charging"), .bool(true))
        XCTAssertEqual(snapshot.metricValue("load_1m"), .level(1.2))
        XCTAssertEqual(snapshot.metricValue("uptime_seconds"), .level(12_345))

        let states = EntityProjection.states(snapshot: snapshot, descriptors: provider.entityDescriptors())
        XCTAssertEqual(states[ProviderInstanceIDs.systemOverview.appending("cpu_usage_percent")]?.value, .number(20))
        XCTAssertEqual(states[ProviderInstanceIDs.systemOverview.appending("memory_used_bytes")]?.value, .number(8_000_000_000))
        XCTAssertEqual(states[ProviderInstanceIDs.systemOverview.appending("battery_percent")]?.value, .number(88))
        XCTAssertEqual(states[ProviderInstanceIDs.systemOverview.appending("battery_charging")]?.value, .bool(true))
    }

    func testSystemOverviewOmitsBatteryMetricsWhenBatteryNotPresent() async {
        let snapshot = SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 12.5, systemPercent: 7.5, idlePercent: 80, coreCount: 10),
            memory: MemoryMetrics(usedBytes: 8_000_000_000, wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000, totalBytes: 16_000_000_000, pressurePercent: 31.25),
            battery: BatteryMetrics(percent: 0, isCharging: false, isPresent: false)
        )
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: snapshot), coreCountHint: 4)

        let result = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        XCTAssertNil(result.metricValue("battery_percent"))
        XCTAssertNil(result.metricValue("battery_charging"))
    }

    func testSystemOverviewDescriptorsRouteThroughGenericSections() {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()), coreCountHint: 4)
        let metricDescriptors = provider.entityDescriptors().filter { $0.metricID != nil }

        let plan = SurfaceComposer.detailPlan(descriptors: metricDescriptors, states: [:])

        XCTAssertEqual(plan.cards.map(\.title), ["CPU", "Memory", "Power"])
    }

    func testMemoryBreakdownDescriptorsComposeIntoRingAndLegend() async {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()), coreCountHint: 4)
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let descriptors = provider.entityDescriptors()
        let states = EntityProjection.states(snapshot: snapshot, descriptors: descriptors)

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)

        let memory = plan.cards.first { $0.title == "Memory" }
        XCTAssertTrue(memory?.children.contains { $0.kind == .segmentedRing } ?? false)
        XCTAssertTrue(memory?.children.contains { $0.kind == .breakdownLegend } ?? false)
        XCTAssertEqual(memory?.children.filter { $0.kind == .segmentedRing }.first?.id, "group:system.memory:dataSize:B:segments")
        XCTAssertEqual(memory?.children.filter { $0.kind == .breakdownLegend }.first?.entities.map(\.rawValue), [
            "system@local/overview.memory_app_active_bytes",
            "system@local/overview.memory_wired_bytes",
            "system@local/overview.memory_compressed_bytes",
            "system@local/overview.memory_cached_inactive_bytes",
            "system@local/overview.memory_free_bytes"
        ])
    }

    func testMemoryBreakdownSegmentsAndRemainderSumToPhysicalMemory() async {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()), coreCountHint: 4)
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))

        let app = snapshot.metricValue("memory_app_active_bytes")?.numberValue ?? 0
        let wired = snapshot.metricValue("memory_wired_bytes")?.numberValue ?? 0
        let compressed = snapshot.metricValue("memory_compressed_bytes")?.numberValue ?? 0
        let cachedInactive = snapshot.metricValue("memory_cached_inactive_bytes")?.numberValue ?? 0
        let free = snapshot.metricValue("memory_free_bytes")?.numberValue ?? 0

        XCTAssertEqual(app + wired + compressed + cachedInactive + free, 16_000_000_000)
    }

    func testPerCoreDescriptorsComposeIntoCoreGrid() async {
        let provider = SystemOverviewProvider(reader: FakeOverviewReader(snapshot: Self.snapshot()), coreCountHint: 4)
        let snapshot = await provider.poll(context: EnvironmentContext(routerHost: nil, settings: AppSettings()))
        let descriptors = provider.entityDescriptors()
        let states = EntityProjection.states(snapshot: snapshot, descriptors: descriptors)

        let plan = SurfaceComposer.detailPlan(descriptors: descriptors, states: states)

        let cpu = plan.cards.first { $0.title == "CPU" }
        let coreGrid = cpu?.children.first { $0.kind == .coreGrid }
        XCTAssertEqual(coreGrid?.id, "group:system.cpu:percent:%:cores")
        XCTAssertEqual(coreGrid?.entities.map(\.rawValue), [
            "system@local/overview.cpu_core_0_percent",
            "system@local/overview.cpu_core_1_percent",
            "system@local/overview.cpu_core_2_percent",
            "system@local/overview.cpu_core_3_percent"
        ])
    }

    private func byKey(_ descriptors: [EntityDescriptor]) -> [String: EntityDescriptor] {
        Dictionary(uniqueKeysWithValues: descriptors.map { (String($0.id.rawValue.split(separator: ".").last ?? ""), $0) })
    }

    private static func snapshot() -> SystemMetricsSnapshot {
        SystemMetricsSnapshot(
            cpu: CPUMetrics(userPercent: 12.5, systemPercent: 7.5, idlePercent: 80, coreCount: 4, loadAverages: [1.2, 1.4, 1.6], coreUsagePercents: [10, 20, 30, 40]),
            memory: MemoryMetrics(usedBytes: 8_000_000_000, wiredBytes: 2_000_000_000, compressedBytes: 1_000_000_000, totalBytes: 16_000_000_000, pressurePercent: 31.25, appActiveBytes: 4_000_000_000, cachedInactiveBytes: 7_500_000_000, freeBytes: 1_500_000_000),
            battery: BatteryMetrics(percent: 88, isCharging: true, isPresent: true),
            uptimeSeconds: 12_345
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

private extension MetricValue {
    var numberValue: Double? {
        switch self {
        case .level(let value), .percent(let value):
            return value
        default:
            return nil
        }
    }
}

private extension ProviderInstanceID {
    func appending(_ key: String) -> EntityID { EntityID(rawValue: "\(rawValue).\(key)") }
}

import XCTest
@testable import AmbitCore

final class SystemSlotAttentionTests: XCTestCase {
    private let bar = SurfaceID(rawValue: "bar")
    private let now = Date(timeIntervalSince1970: 20_000)

    func testElevatedCPUEntityWinsLaneOverHealthyPingPrimary() {
        var engine = AttentionEngine()
        let selection = evaluate([
            candidate(pingLatencyDescriptor(isPrimary: true), value: .number(12), severity: .normal),
            candidate(cpuDescriptor(), value: .number(91), severity: .elevated)
        ], engine: &engine)

        XCTAssertEqual(selection.lanes.first?.id, systemID("overview.cpu_usage_percent"))
        XCTAssertEqual(selection.lanes.first?.tier, .surfaced)
    }

    func testRecoveredCPUReturnsLaneToRestingPingPrimary() {
        var engine = AttentionEngine()
        _ = evaluate([
            candidate(pingLatencyDescriptor(isPrimary: true), value: .number(12), severity: .normal),
            candidate(cpuDescriptor(), value: .number(91), severity: .elevated)
        ], engine: &engine, now: now)

        let recovered = evaluate([
            candidate(pingLatencyDescriptor(isPrimary: true), value: .number(12), severity: .normal),
            candidate(cpuDescriptor(), value: .number(42), severity: .normal)
        ], engine: &engine, now: now.addingTimeInterval(1))

        XCTAssertEqual(recovered.lanes.first?.id, pingID("probe.latency_ms"))
        XCTAssertEqual(recovered.lanes.first?.tier, .detail)
    }

    func testStaleSystemEntitySurfacesCalmWithoutFalseDownAlert() {
        var engine = AttentionEngine()
        let selection = evaluate([
            candidate(
                cpuDescriptor(),
                value: .number(72),
                availability: .stale,
                severity: .elevated
            )
        ], engine: &engine)

        XCTAssertEqual(selection.lanes.first?.id, systemID("overview.cpu_usage_percent"))
        XCTAssertEqual(selection.lanes.first?.tier, .surfaced)
        XCTAssertEqual(selection.lanes.first?.reason.severity, .elevated)
        XCTAssertTrue(selection.alerted.isEmpty)
    }

    func testBatteryChargingStateCanOccupyLaneThroughGenericAttention() {
        var engine = AttentionEngine()
        let battery = EntityDescriptor(
            id: systemID("overview.battery_charging"),
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "Battery Charging",
            kind: .binarySensor,
            deviceClass: .battery,
            category: .primary,
            capability: "power.battery",
            defaultVisibility: .always
        )

        let selection = evaluate([
            candidate(pingLatencyDescriptor(isPrimary: true), value: .number(12), severity: .normal),
            candidate(battery, value: .bool(true), severity: .normal)
        ], engine: &engine)

        XCTAssertEqual(selection.lanes.first?.id, systemID("overview.battery_charging"))
        XCTAssertEqual(selection.lanes.first?.tier, .surfaced)
        XCTAssertEqual(selection.lanes.first?.reason.severity, .normal)
    }

    private func evaluate(
        _ candidates: [AttentionCandidate],
        engine: inout AttentionEngine,
        now: Date? = nil
    ) -> AttentionSelection {
        engine.evaluate(
            candidates: candidates,
            surfaces: [bar: SurfaceCapacity(lanes: 1, overflow: .countBadge)],
            alertingIDs: [],
            config: .empty,
            now: now ?? self.now
        )[bar]!
    }

    private func candidate(
        _ descriptor: EntityDescriptor,
        value: EntityValue?,
        availability: Availability = .online,
        severity: Severity
    ) -> AttentionCandidate {
        AttentionCandidate(
            descriptor: descriptor,
            state: EntityState(id: descriptor.id, value: value, availability: availability, severity: severity)
        )
    }

    private func cpuDescriptor() -> EntityDescriptor {
        EntityDescriptor(
            id: systemID("overview.cpu_usage_percent"),
            instanceID: ProviderInstanceIDs.systemOverview,
            name: "CPU",
            kind: .sensor,
            deviceClass: .percent,
            category: .primary,
            capability: "system.cpu",
            stateClass: .measurement,
            graphStyle: .gauge,
            isPrimary: true
        )
    }

    private func pingLatencyDescriptor(isPrimary: Bool) -> EntityDescriptor {
        EntityDescriptor(
            id: pingID("probe.latency_ms"),
            instanceID: ProviderInstanceID(rawValue: "ping@1.1.1.1/probe"),
            name: "Cloudflare DNS",
            kind: .sensor,
            deviceClass: .latency,
            category: .primary,
            capability: "network.latency",
            unit: "ms",
            stateClass: .measurement,
            graphStyle: .sparkline,
            isPrimary: isPrimary
        )
    }

    private func systemID(_ key: String) -> EntityID {
        EntityID(rawValue: "system@local/\(key)")
    }

    private func pingID(_ key: String) -> EntityID {
        EntityID(rawValue: "ping@1.1.1.1/\(key)")
    }
}

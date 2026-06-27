import XCTest
@testable import AmbitCore

final class SlotReadoutSelectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 30_000)

    func testHealthyDynamicReadoutUsesRestingPrimaryOverNormalAttentionChurn() {
        var engine = AttentionEngine()
        let cpu = descriptor("system.cpu", isPrimary: true, priority: 100)
        let throughput = descriptor("system.network", isPrimary: true, priority: 0)
        let states = [
            cpu.id: state(cpu.id, value: 34, severity: .normal),
            throughput.id: state(throughput.id, value: 77_000, severity: .normal)
        ]

        let result = SlotReadoutSelector.resolve(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: throughput, state: states[throughput.id]!),
                AttentionCandidate(descriptor: cpu, state: states[cpu.id]!)
            ],
            states: states,
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(result.primaryEntityID, cpu.id)
        XCTAssertEqual(result.selection.lanes.first?.tier, .detail)
    }

    func testActivePinnedAlertedOrBoostedAttentionOverridesRestingPrimary() {
        let cpu = descriptor("system.cpu", isPrimary: true, priority: 100)
        let throughput = descriptor("system.network", isPrimary: true, priority: 0)
        let states = [
            cpu.id: state(cpu.id, value: 34, severity: .normal),
            throughput.id: state(throughput.id, value: 77_000, severity: .elevated)
        ]
        var engine = AttentionEngine()

        let elevated = SlotReadoutSelector.resolve(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: cpu, state: states[cpu.id]!),
                AttentionCandidate(descriptor: throughput, state: states[throughput.id]!)
            ],
            states: states,
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(elevated.primaryEntityID, throughput.id)
    }

    func testFixedReadoutUsesFixedEntityWhenPresent() {
        var engine = AttentionEngine()
        let fixed = descriptor("fixed")
        let other = descriptor("other", isPrimary: true)
        let states = [
            fixed.id: state(fixed.id, value: 12, severity: .normal),
            other.id: state(other.id, value: 99, severity: .down)
        ]

        let result = SlotReadoutSelector.resolve(
            mode: .fixed(fixed.id),
            candidates: [
                AttentionCandidate(descriptor: fixed, state: states[fixed.id]!),
                AttentionCandidate(descriptor: other, state: states[other.id]!)
            ],
            states: states,
            alertingIDs: [other.id],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(result.primaryEntityID, fixed.id)
        XCTAssertTrue(result.selection.lanes.isEmpty)
    }

    func testHiddenAndDisabledEntitiesAreSkippedForRestingPrimary() {
        var engine = AttentionEngine()
        let hidden = descriptor("hidden", isPrimary: true, priority: 100, visibility: .never)
        let disabled = descriptor("disabled", isPrimary: true, priority: 90)
        let fallback = descriptor("fallback", isPrimary: false, priority: 1)
        let states = [
            hidden.id: state(hidden.id, value: 1, severity: .normal),
            disabled.id: state(disabled.id, value: 2, severity: .normal),
            fallback.id: state(fallback.id, value: 3, severity: .normal)
        ]
        var config = PresentationConfig.empty
        config.entityOverrides[disabled.id] = EntityPresentationOverride(enabled: false)

        let result = SlotReadoutSelector.resolve(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: hidden, state: states[hidden.id]!),
                AttentionCandidate(descriptor: disabled, state: states[disabled.id]!),
                AttentionCandidate(descriptor: fallback, state: states[fallback.id]!)
            ],
            states: states,
            alertingIDs: [],
            config: config,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(result.primaryEntityID, fallback.id)
    }

    private func descriptor(
        _ key: String,
        isPrimary: Bool = false,
        priority: Int? = nil,
        visibility: GlanceVisibility = .auto
    ) -> EntityDescriptor {
        EntityDescriptor(
            id: EntityID(rawValue: "test.\(key)"),
            instanceID: ProviderInstanceID(rawValue: "test"),
            name: key,
            kind: .sensor,
            deviceClass: .percent,
            defaultVisibility: visibility,
            isPrimary: isPrimary,
            priority: priority
        )
    }

    private func state(_ id: EntityID, value: Double, severity: Severity) -> EntityState {
        EntityState(id: id, value: .number(value), availability: .online, severity: severity)
    }
}

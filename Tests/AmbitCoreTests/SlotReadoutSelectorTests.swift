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

    func testHealthyNonPingSlotIgnoresUnavailableNoDataSecondaryForHeadline() {
        var engine = AttentionEngine()
        let cpu = descriptor("system.cpu", isPrimary: true, priority: 100)
        let optionalMetric = descriptor("system.optional", isPrimary: false, priority: 0)
        let states = [
            cpu.id: state(cpu.id, value: 14, severity: .normal),
            optionalMetric.id: EntityState(id: optionalMetric.id, availability: .unavailable, severity: .down)
        ]

        let result = SlotReadoutSelector.resolve(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: cpu, state: states[cpu.id]!),
                AttentionCandidate(descriptor: optionalMetric, state: states[optionalMetric.id]!)
            ],
            states: states,
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(result.primaryEntityID, cpu.id)
    }

    func testValuedDownEntityStillOverridesRestingPrimary() {
        var engine = AttentionEngine()
        let cpu = descriptor("system.cpu", isPrimary: true, priority: 100)
        let degraded = descriptor("system.degraded", isPrimary: false, priority: 0)
        let states = [
            cpu.id: state(cpu.id, value: 14, severity: .normal),
            degraded.id: state(degraded.id, value: 1, severity: .down)
        ]

        let result = SlotReadoutSelector.resolve(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: cpu, state: states[cpu.id]!),
                AttentionCandidate(descriptor: degraded, state: states[degraded.id]!)
            ],
            states: states,
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(result.primaryEntityID, degraded.id)
    }

    func testActiveHeadlineEligibilityLimitsAttentionOverride() {
        var engine = AttentionEngine()
        let primary = descriptor("ping.primary", deviceClass: .latency, isPrimary: true, priority: 10)
        let peer = descriptor("ping.peer", deviceClass: .latency, priority: 0)
        let states = [
            primary.id: state(primary.id, value: 12, severity: .normal),
            peer.id: EntityState(id: peer.id, availability: .unavailable, severity: .down)
        ]

        let result = SlotReadoutSelector.resolve(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: states[primary.id]!),
                AttentionCandidate(descriptor: peer, state: states[peer.id]!)
            ],
            states: states,
            headlineEligibleActiveIDs: [primary.id],
            alertingIDs: [peer.id],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(result.primaryEntityID, primary.id)
        XCTAssertEqual(result.selection.lanes.first?.id, peer.id)
    }

    func testDiagnosticTextNeverBecomesCompactHeadline() {
        var engine = AttentionEngine()
        let primary = descriptor("ping.primary", deviceClass: .latency, isPrimary: true, priority: 10)
        let diagnostic = diagnosticDescriptor("ping.diagnosis")
        let states = [
            primary.id: state(primary.id, value: 7, severity: .normal),
            diagnostic.id: EntityState(
                id: diagnostic.id,
                value: .text("Elevated latency on the local network."),
                availability: .online,
                severity: .degraded
            )
        ]

        let result = SlotReadoutSelector.resolve(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: states[primary.id]!),
                AttentionCandidate(descriptor: diagnostic, state: states[diagnostic.id]!)
            ],
            states: states,
            headlineEligibleActiveIDs: [primary.id, diagnostic.id],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(result.primaryEntityID, primary.id)
        XCTAssertEqual(result.selection.lanes.first?.id, diagnostic.id)
    }

    func testNilLatencyDownStillOverridesRestingPrimary() {
        var engine = AttentionEngine()
        let cpu = descriptor("system.cpu", isPrimary: true, priority: 100)
        let latency = descriptor("ping.latency", deviceClass: .latency, isPrimary: false, priority: 0)
        let states = [
            cpu.id: state(cpu.id, value: 14, severity: .normal),
            latency.id: EntityState(id: latency.id, availability: .unavailable, severity: .down)
        ]

        let result = SlotReadoutSelector.resolve(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: cpu, state: states[cpu.id]!),
                AttentionCandidate(descriptor: latency, state: states[latency.id]!)
            ],
            states: states,
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(result.primaryEntityID, latency.id)
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
        deviceClass: DeviceClass = .percent,
        isPrimary: Bool = false,
        priority: Int? = nil,
        visibility: GlanceVisibility = .auto
    ) -> EntityDescriptor {
        EntityDescriptor(
            id: EntityID(rawValue: "test.\(key)"),
            instanceID: ProviderInstanceID(rawValue: "test"),
            name: key,
            kind: .sensor,
            deviceClass: deviceClass,
            defaultVisibility: visibility,
            isPrimary: isPrimary,
            priority: priority
        )
    }

    private func diagnosticDescriptor(_ key: String) -> EntityDescriptor {
        EntityDescriptor(
            id: EntityID(rawValue: "test.\(key)"),
            instanceID: ProviderInstanceID(rawValue: "test"),
            name: key,
            kind: .text,
            deviceClass: nil,
            category: .diagnostic,
            defaultVisibility: .auto
        )
    }

    private func state(_ id: EntityID, value: Double, severity: Severity) -> EntityState {
        EntityState(id: id, value: .number(value), availability: .online, severity: severity)
    }
}

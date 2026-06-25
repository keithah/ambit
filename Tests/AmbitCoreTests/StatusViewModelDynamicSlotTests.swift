import XCTest
@testable import AmbitCore
@testable import AmbitMenuBar

final class StatusViewModelDynamicSlotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 20_000)

    func testDynamicReadoutUsesHighestAttentionEntityOverStaticPrimary() {
        var engine = AttentionEngine()
        let primary = descriptor("primary", isPrimary: true)
        let degraded = descriptor("degraded")

        let glyph = StatusSlotReadout.resolveGlyph(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: state(primary.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: degraded, state: state(degraded.id, value: 250, severity: .degraded))
            ],
            descriptors: [primary.id: primary, degraded.id: degraded],
            states: [
                primary.id: state(primary.id, value: 10, severity: .normal),
                degraded.id: state(degraded.id, value: 250, severity: .degraded)
            ],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(glyph.latencyText, "250ms")
        XCTAssertEqual(glyph.tone, .warn)
    }

    func testDynamicReadoutReturnsToRestingPrimaryAfterRecovery() {
        var engine = AttentionEngine()
        let primary = descriptor("primary", isPrimary: true)
        let recovered = descriptor("recovered")

        _ = StatusSlotReadout.resolveGlyph(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: state(primary.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: recovered, state: state(recovered.id, value: 250, severity: .degraded))
            ],
            descriptors: [primary.id: primary, recovered.id: recovered],
            states: [
                primary.id: state(primary.id, value: 10, severity: .normal),
                recovered.id: state(recovered.id, value: 250, severity: .degraded)
            ],
            alertingIDs: [],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        let glyph = StatusSlotReadout.resolveGlyph(
            mode: .dynamic,
            candidates: [
                AttentionCandidate(descriptor: primary, state: state(primary.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: recovered, state: state(recovered.id, value: 25, severity: .normal))
            ],
            descriptors: [primary.id: primary, recovered.id: recovered],
            states: [
                primary.id: state(primary.id, value: 10, severity: .normal),
                recovered.id: state(recovered.id, value: 25, severity: .normal)
            ],
            alertingIDs: [],
            config: .empty,
            now: now.addingTimeInterval(1),
            attentionEngine: &engine
        )

        XCTAssertEqual(glyph.latencyText, "10ms")
        XCTAssertEqual(glyph.tone, .good)
    }

    func testFixedReadoutIgnoresHigherAttentionEntity() {
        var engine = AttentionEngine()
        let fixed = descriptor("fixed")
        let degraded = descriptor("degraded")

        let glyph = StatusSlotReadout.resolveGlyph(
            mode: .fixed(fixed.id),
            candidates: [
                AttentionCandidate(descriptor: fixed, state: state(fixed.id, value: 10, severity: .normal)),
                AttentionCandidate(descriptor: degraded, state: state(degraded.id, value: 250, severity: .degraded))
            ],
            descriptors: [fixed.id: fixed, degraded.id: degraded],
            states: [
                fixed.id: state(fixed.id, value: 10, severity: .normal),
                degraded.id: state(degraded.id, value: 250, severity: .degraded)
            ],
            alertingIDs: [degraded.id],
            config: .empty,
            now: now,
            attentionEngine: &engine
        )

        XCTAssertEqual(glyph.latencyText, "10ms")
        XCTAssertEqual(glyph.tone, .good)
    }

    private func descriptor(_ key: String, isPrimary: Bool = false) -> EntityDescriptor {
        EntityDescriptor(
            id: EntityID(rawValue: "ping@\(key)/probe.latency_ms"),
            instanceID: ProviderInstanceID(rawValue: "ping@\(key)/probe"),
            name: key,
            kind: .sensor,
            deviceClass: .latency,
            defaultVisibility: .auto,
            isPrimary: isPrimary
        )
    }

    private func state(_ id: EntityID, value: Double, severity: Severity) -> EntityState {
        EntityState(id: id, value: .number(value), availability: .online, severity: severity)
    }
}

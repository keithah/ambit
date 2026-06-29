import AmbitCore
import AmbitUI
import Foundation

struct StatusSlotReadoutResult {
    var glyph: MenuBarGlyph
    var primaryEntityID: EntityID?
    var selection: AttentionSelection
}

struct SlotAttentionEngines {
    private var engines: [SlotID: AttentionEngine] = [:]

    mutating func withEngine<T>(for slotID: SlotID, _ body: (inout AttentionEngine) -> T) -> T {
        var engine = engines[slotID] ?? AttentionEngine()
        let result = body(&engine)
        engines[slotID] = engine
        return result
    }

    mutating func resolveReadout(
        slotID: SlotID,
        mode: BarReadoutMode,
        candidates: [AttentionCandidate],
        descriptors: [EntityID: EntityDescriptor],
        states: [EntityID: EntityState],
        headlineEligibleActiveIDs: Set<EntityID>? = nil,
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date
    ) -> StatusSlotReadoutResult {
        withEngine(for: slotID) { engine in
            StatusSlotReadout.resolveReadout(
                mode: mode,
                candidates: candidates,
                descriptors: descriptors,
                states: states,
                headlineEligibleActiveIDs: headlineEligibleActiveIDs,
                alertingIDs: alertingIDs,
                config: config,
                now: now,
                attentionEngine: &engine
            )
        }
    }
}

struct StatusSlotReadout {
    private static let surfaceID = SurfaceID(rawValue: "macos.bar")

    static func resolveSelection(
        candidates: [AttentionCandidate],
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date,
        attentionEngine: inout AttentionEngine
    ) -> AttentionSelection {
        attentionEngine.evaluate(
            candidates: candidates,
            surfaces: [surfaceID: SurfaceCapacity(lanes: 1, overflow: .countBadge)],
            alertingIDs: alertingIDs,
            config: config,
            now: now
        )[surfaceID] ?? AttentionSelection()
    }

    static func resolveGlyph(
        mode: BarReadoutMode,
        candidates: [AttentionCandidate],
        descriptors: [EntityID: EntityDescriptor],
        states: [EntityID: EntityState],
        headlineEligibleActiveIDs: Set<EntityID>? = nil,
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date,
        attentionEngine: inout AttentionEngine
    ) -> MenuBarGlyph {
        resolveReadout(
            mode: mode,
            candidates: candidates,
            descriptors: descriptors,
            states: states,
            headlineEligibleActiveIDs: headlineEligibleActiveIDs,
            alertingIDs: alertingIDs,
            config: config,
            now: now,
            attentionEngine: &attentionEngine
        ).glyph
    }

    static func resolveReadout(
        mode: BarReadoutMode,
        candidates: [AttentionCandidate],
        descriptors: [EntityID: EntityDescriptor],
        states: [EntityID: EntityState],
        headlineEligibleActiveIDs: Set<EntityID>? = nil,
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date,
        attentionEngine: inout AttentionEngine
    ) -> StatusSlotReadoutResult {
        switch mode {
        case .fixed, .dynamic:
            let resolution = SlotReadoutSelector.resolve(
                mode: mode,
                candidates: candidates,
                states: states,
                availableEntityIDs: Set(descriptors.keys),
                headlineEligibleActiveIDs: headlineEligibleActiveIDs,
                alertingIDs: alertingIDs,
                config: config,
                now: now,
                attentionEngine: &attentionEngine,
                surfaceID: surfaceID,
                capacity: SurfaceCapacity(lanes: 1, overflow: .countBadge)
            )

            guard
                let selectedID = resolution.primaryEntityID,
                let descriptor = descriptors[selectedID] ?? candidates.first(where: { $0.descriptor.id == selectedID })?.descriptor
            else {
                return fallbackResult(candidates: candidates, states: states, selection: resolution.selection)
            }
            let selectedState = states[selectedID] ?? candidates.first(where: { $0.descriptor.id == selectedID })?.state
            return StatusSlotReadoutResult(
                glyph: glyph(descriptor: descriptor, state: selectedState),
                primaryEntityID: selectedID,
                selection: resolution.selection
            )
        }
    }

    private static func fallbackResult(
        candidates: [AttentionCandidate],
        states: [EntityID: EntityState],
        selection: AttentionSelection = AttentionSelection()
    ) -> StatusSlotReadoutResult {
        guard let fallback = (candidates.first { $0.descriptor.isPrimary } ?? candidates.first) else {
            return StatusSlotReadoutResult(glyph: noDataGlyph(), primaryEntityID: nil, selection: selection)
        }
        return StatusSlotReadoutResult(
            glyph: glyph(descriptor: fallback.descriptor, state: states[fallback.descriptor.id] ?? fallback.state),
            primaryEntityID: fallback.descriptor.id,
            selection: selection
        )
    }

    private static func glyph(descriptor: EntityDescriptor, state: EntityState?) -> MenuBarGlyph {
        if let state, state.value == nil, (state.severity ?? .normal) <= .normal {
            if descriptor.deviceClass == .latency {
                return MenuBarGlyph(primaryText: "--ms", tone: .neutral)
            }
            return noDataGlyph()
        }
        let readout = EntityReadout.make(descriptor: descriptor, state: state)
        return MenuBarGlyph(primaryText: readout.text, tone: LatencyTone(readout.tone))
    }

    private static func noDataGlyph() -> MenuBarGlyph {
        MenuBarGlyph(primaryText: "No Data", tone: .neutral)
    }
}

private extension LatencyTone {
    init(_ tone: DisplayTone) {
        switch tone {
        case .neutral: self = .neutral
        case .good: self = .good
        case .warn: self = .warn
        case .bad: self = .bad
        }
    }
}

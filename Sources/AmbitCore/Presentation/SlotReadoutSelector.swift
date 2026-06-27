import Foundation

public struct SlotReadoutResolution: Equatable, Sendable {
    public var primaryEntityID: EntityID?
    public var selection: AttentionSelection

    public init(primaryEntityID: EntityID?, selection: AttentionSelection) {
        self.primaryEntityID = primaryEntityID
        self.selection = selection
    }
}

public enum SlotReadoutSelector {
    public static func resolve(
        mode: BarReadoutMode,
        candidates: [AttentionCandidate],
        states: [EntityID: EntityState],
        availableEntityIDs: Set<EntityID>? = nil,
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date,
        attentionEngine: inout AttentionEngine,
        surfaceID: SurfaceID = SurfaceID(rawValue: "compact.readout"),
        capacity: SurfaceCapacity = SurfaceCapacity(lanes: 1, overflow: .countBadge)
    ) -> SlotReadoutResolution {
        switch mode {
        case .fixed(let id):
            if availableEntityIDs?.contains(id) ?? candidates.contains(where: { $0.descriptor.id == id }) {
                return SlotReadoutResolution(primaryEntityID: id, selection: AttentionSelection())
            }
            return SlotReadoutResolution(primaryEntityID: fallbackID(candidates: candidates), selection: AttentionSelection())
        case .dynamic:
            let selection = attentionEngine.evaluate(
                candidates: candidates,
                surfaces: [surfaceID: capacity],
                alertingIDs: alertingIDs,
                config: config,
                now: now
            )[surfaceID] ?? AttentionSelection()

            let selectedID = activeSelectionID(selection, config: config, alertingIDs: alertingIDs)
                ?? restingPrimaryID(candidates: candidates, states: states, config: config)
                ?? fallbackID(candidates: candidates)
            return SlotReadoutResolution(primaryEntityID: selectedID, selection: selection)
        }
    }

    private static func activeSelectionID(
        _ selection: AttentionSelection,
        config: PresentationConfig,
        alertingIDs: Set<EntityID>
    ) -> EntityID? {
        selection.lanes.first { entity in
            entity.tier == .alerted ||
            entity.tier == .surfaced ||
            entity.reason.severity > .normal ||
            entity.reason.transitionBoosted ||
            alertingIDs.contains(entity.id) ||
            (config.entityOverrides[entity.id]?.pinned ?? false)
        }?.id
    }

    private static func restingPrimaryID(
        candidates: [AttentionCandidate],
        states: [EntityID: EntityState],
        config: PresentationConfig
    ) -> EntityID? {
        let visible = candidates.enumerated().filter { _, candidate in
            let override = config.entityOverrides[candidate.descriptor.id]
            return override?.enabled != false && (override?.visibility ?? candidate.descriptor.defaultVisibility) != .never
        }
        return visible.sorted { lhs, rhs in
            let a = lhs.element
            let b = rhs.element
            if a.descriptor.isPrimary != b.descriptor.isPrimary {
                return a.descriptor.isPrimary && !b.descriptor.isPrimary
            }
            let aPriority = a.descriptor.priority ?? 0
            let bPriority = b.descriptor.priority ?? 0
            if aPriority != bPriority { return aPriority > bPriority }
            let aAvailability = availabilityRank(states[a.descriptor.id]?.availability ?? a.state.availability)
            let bAvailability = availabilityRank(states[b.descriptor.id]?.availability ?? b.state.availability)
            if aAvailability != bAvailability { return aAvailability > bAvailability }
            return lhs.offset < rhs.offset
        }.first?.element.descriptor.id
    }

    private static func fallbackID(candidates: [AttentionCandidate]) -> EntityID? {
        (candidates.first { $0.descriptor.isPrimary } ?? candidates.first)?.descriptor.id
    }

    private static func availabilityRank(_ availability: Availability) -> Int {
        switch availability {
        case .online: return 2
        case .stale: return 1
        case .unavailable: return 0
        }
    }
}

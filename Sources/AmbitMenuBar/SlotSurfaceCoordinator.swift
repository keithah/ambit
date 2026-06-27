import AmbitCore
import AmbitUI
import Foundation

@MainActor
final class SlotSurfaceCoordinator {
    typealias HistorySamples = (EntityID, Date) async -> [Sample]

    private var attentionEngines = SlotAttentionEngines()

    func buildSurface(
        slot: Slot,
        diagnosis: NetworkPerspectiveDiagnosis,
        enabledPingRecords: [IntegrationInstanceRecord],
        allRegistryRecords: [IntegrationInstanceRecord],
        allDescriptors: [ProviderInstanceID: [EntityDescriptor]],
        allStates: [EntityID: EntityState],
        firedAlertEvents: [AlertEvent],
        slotFocus: [SlotID: IntegrationInstanceID],
        pingRange: TimeRange,
        config: PresentationConfig,
        now: Date,
        historySamples: @escaping HistorySamples
    ) async -> SlotSurface {
        let flatDescriptors = allDescriptors.values.flatMap { $0 }
        let resolved = SlotResolver.resolve(slot.selection, descriptors: flatDescriptors, records: allRegistryRecords)

        let resolvedInstanceIDs = Set(resolved.map { $0.instanceID.integrationInstanceID })
        let resolvedRecords = enabledPingRecords.filter { resolvedInstanceIDs.contains($0.id) }
        let hostOptions = resolvedRecords.map { InstanceSelectorCard.Option(id: $0.id.rawValue, label: $0.displayName) }

        let focusedID = slotFocus[slot.id]
        let shownRecords = focusedID.map { id in resolvedRecords.filter { $0.id == id } } ?? resolvedRecords
        let shownInstanceIDs = Set(shownRecords.map(\.id))
        let shownResolved = focusedID == nil
            ? resolved
            : resolved.filter { descriptor in
                shownInstanceIDs.contains(descriptor.instanceID.integrationInstanceID)
            }

        guard Self.isPingSlot(slot) else {
            let plan = SurfaceComposer.detailPlan(descriptors: shownResolved, states: allStates, config: config, slotID: slot.id)
            let series = await Self.historySeries(for: plan, now: now, historySamples: historySamples)
            return attentionEngines.withEngine(for: slot.id) { attentionEngine in
                StatusSlotSurfaceBuilder.genericSurface(
                    slot: slot,
                    descriptors: shownResolved,
                    states: allStates,
                    series: series,
                    plan: plan,
                    config: config,
                    now: now,
                    attentionEngine: &attentionEngine
                )
            }
        }

        return await buildPingSurface(
            slot: slot,
            diagnosis: diagnosis,
            shownRecords: shownRecords,
            shownResolved: shownResolved,
            allDescriptors: allDescriptors,
            allStates: allStates,
            firedAlertEvents: firedAlertEvents,
            hostOptions: hostOptions,
            pingRange: pingRange,
            config: config,
            now: now,
            historySamples: historySamples
        )
    }

    private func buildPingSurface(
        slot: Slot,
        diagnosis: NetworkPerspectiveDiagnosis,
        shownRecords: [IntegrationInstanceRecord],
        shownResolved: [EntityDescriptor],
        allDescriptors: [ProviderInstanceID: [EntityDescriptor]],
        allStates: [EntityID: EntityState],
        firedAlertEvents: [AlertEvent],
        hostOptions: [InstanceSelectorCard.Option],
        pingRange: TimeRange,
        config: PresentationConfig,
        now: Date,
        historySamples: @escaping HistorySamples
    ) async -> SlotSurface {
        var descriptors: [EntityID: EntityDescriptor] = [:]
        var states: [EntityID: EntityState] = [:]
        var series: [EntityID: [Sample]] = [:]
        var attentionDescriptors = shownResolved
        var detailDescriptors: [EntityDescriptor] = []
        for record in shownRecords {
            let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
            guard var latency = allDescriptors[providerInstance]?.first(where: { $0.id == latencyID }) else { continue }
            latency.name = record.displayName
            detailDescriptors.append(latency)
            descriptors[latencyID] = latency
            let samples = await historySamples(latencyID, now.addingTimeInterval(-pingRange.seconds))
            series[latencyID] = samples
            if let state = Self.latencyStateForSurface(id: latencyID, current: allStates[latencyID], samples: samples) {
                states[latencyID] = state
            }
        }

        if let (diagnosisDescriptor, diagnosisState) = DiagnosisEntity.make(diagnosis) {
            descriptors[diagnosisDescriptor.id] = diagnosisDescriptor
            states[diagnosisDescriptor.id] = diagnosisState
            attentionDescriptors.append(diagnosisDescriptor)
            detailDescriptors.append(diagnosisDescriptor)
        }

        let candidates = attentionDescriptors.compactMap { descriptor -> AttentionCandidate? in
            guard let state = states[descriptor.id] ?? allStates[descriptor.id] else { return nil }
            return AttentionCandidate(descriptor: descriptor, state: state)
        }
        let alertingIDs = PingDiagnosisCoordinator.alertingEntityIDs(from: firedAlertEvents, candidates: candidates)
        let readout = attentionEngines.resolveReadout(
            slotID: slot.id,
            mode: slot.barReadout,
            candidates: candidates,
            descriptors: descriptors,
            states: states,
            alertingIDs: alertingIDs,
            config: config,
            now: now
        )
        let planCards = SurfaceComposer.detailPlan(descriptors: detailDescriptors, states: states, config: config, slotID: slot.id).cards

        return SlotSurface(
            plan: SurfacePlan(cards: planCards),
            data: SurfaceData(descriptors: descriptors, states: states, series: series),
            glyph: readout.glyph,
            primaryEntityID: readout.primaryEntityID,
            hostOptions: hostOptions
        )
    }

    nonisolated private static func isPingSlot(_ slot: Slot) -> Bool {
        if case .integrationType(let integrationID) = slot.selection, integrationID == IntegrationIDs.ping {
            return true
        }
        return false
    }

    static func historySeries(for plan: SurfacePlan, now: Date, historySamples: @escaping HistorySamples) async -> [EntityID: [Sample]] {
        var result: [EntityID: [Sample]] = [:]
        for card in historyBackedCards(in: plan.cards) {
            let range = card.graphRange ?? .m5
            for id in card.entities {
                result[id] = await historySamples(id, now.addingTimeInterval(-range.seconds))
            }
        }
        return result
    }

    nonisolated static func historyBackedCards(in cards: [CardSpec]) -> [CardSpec] {
        cards.flatMap { card -> [CardSpec] in
            let children = historyBackedCards(in: card.children)
            switch card.kind {
            case .historyGraph, .dualLineGraph, .sampleHistory:
                return [card] + children
            default:
                return children
            }
        }
    }

    nonisolated static func latencyStateForSurface(id: EntityID, current: EntityState?, samples: [Sample]) -> EntityState? {
        if let current, current.value != nil {
            return current
        }
        guard let latest = samples.last, latest.ok, let value = latest.value else {
            return current
        }
        var state = current ?? EntityState(id: id, availability: .online)
        state.value = .number(value)
        state.availability = .online
        state.lastUpdated = latest.timestamp
        state.severity = state.severity ?? .normal
        return state
    }
}

enum StatusSlotSurfaceBuilder {
    static func genericSurface(
        slot: Slot,
        descriptors resolved: [EntityDescriptor],
        states allStates: [EntityID: EntityState],
        series: [EntityID: [Sample]] = [:],
        plan: SurfacePlan? = nil,
        config: PresentationConfig,
        now: Date,
        attentionEngine: inout AttentionEngine
    ) -> SlotSurface {
        let descriptors = Dictionary(uniqueKeysWithValues: resolved.map { ($0.id, $0) })
        let states = allStates.filter { descriptors.keys.contains($0.key) }
        let candidates = resolved.compactMap { descriptor -> AttentionCandidate? in
            guard let state = states[descriptor.id] else { return nil }
            return AttentionCandidate(descriptor: descriptor, state: state)
        }
        let readout = StatusSlotReadout.resolveReadout(
            mode: slot.barReadout,
            candidates: candidates,
            descriptors: descriptors,
            states: states,
            alertingIDs: [],
            config: config,
            now: now,
            attentionEngine: &attentionEngine
        )

        return SlotSurface(
            plan: plan ?? SurfaceComposer.detailPlan(descriptors: resolved, states: states, config: config, slotID: slot.id),
            data: SurfaceData(descriptors: descriptors, states: states, series: series),
            glyph: readout.glyph,
            primaryEntityID: readout.primaryEntityID,
            hostOptions: []
        )
    }
}

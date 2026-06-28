import AmbitCore
import AmbitUI
import Foundation

@MainActor
final class SlotSurfaceCoordinator {
    typealias HistorySamples = (EntityID, Date) async -> [Sample]

    private var attentionEngines = SlotAttentionEngines()
    private let alertTargetResolver = AlertTargetResolver()

    func buildSurface(
        slot: Slot,
        diagnosis: NetworkPerspectiveDiagnosis,
        enabledPingRecords: [IntegrationInstanceRecord],
        allRegistryRecords: [IntegrationInstanceRecord],
        allDescriptors: [ProviderInstanceID: [EntityDescriptor]],
        allStates: [EntityID: EntityState],
        firedAlertEvents: [AlertEvent],
        slotFocus: [SlotID: IntegrationInstanceID],
        primaryPingInstanceID: IntegrationInstanceID? = nil,
        pingRange: TimeRange,
        config: PresentationConfig,
        now: Date,
        historySamples: @escaping HistorySamples
    ) async -> SlotSurface {
        let flatDescriptors = allDescriptors.values.flatMap { $0 }
        let resolved = SlotResolver.resolve(slot.selection, descriptors: flatDescriptors, records: allRegistryRecords)

        let resolvedInstanceIDs = Set(resolved.map { $0.instanceID.integrationInstanceID })
        let resolvedRecords = enabledPingRecords.filter { resolvedInstanceIDs.contains($0.id) }
        let hostOptions = resolvedRecords.map { record in
            InstanceSelectorCard.Option(
                id: record.id.rawValue,
                label: record.displayName,
                subtitle: Self.pingHostSubtitle(record)
            )
        }

        let override = config.slotOverrides[slot.id]
        let defaultFocusID = primaryPingInstanceID.flatMap { id in resolvedRecords.contains(where: { $0.id == id }) ? id : nil }
            ?? resolvedRecords.first?.id
        let requestedFocusID = slotFocus[slot.id] ?? override?.selectedInstanceID
        let validRequestedFocusID = requestedFocusID.flatMap { id in
            resolvedRecords.contains(where: { $0.id == id }) ? id : nil
        }
        let explicitAllHosts = override?.showsAllInstances == true
        let candidateFocusID = explicitAllHosts ? nil : (validRequestedFocusID ?? defaultFocusID)
        let focusedRecords = candidateFocusID.map { id in resolvedRecords.filter { $0.id == id } } ?? []
        let focusedID = focusedRecords.first?.id
        let shownRecords = explicitAllHosts ? resolvedRecords : focusedRecords
        let headlineRecordID = focusedID
            ?? primaryPingInstanceID.flatMap { id in resolvedRecords.contains(where: { $0.id == id }) ? id : nil }
            ?? resolvedRecords.first?.id
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
            headlineRecordID: headlineRecordID,
            shownResolved: shownResolved,
            allDescriptors: allDescriptors,
            allStates: allStates,
            firedAlertEvents: firedAlertEvents,
            hostOptions: hostOptions,
            selectedInstanceID: focusedID,
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
        headlineRecordID: IntegrationInstanceID?,
        shownResolved: [EntityDescriptor],
        allDescriptors: [ProviderInstanceID: [EntityDescriptor]],
        allStates: [EntityID: EntityState],
        firedAlertEvents: [AlertEvent],
        hostOptions: [InstanceSelectorCard.Option],
        selectedInstanceID: IntegrationInstanceID?,
        pingRange: TimeRange,
        config: PresentationConfig,
        now: Date,
        historySamples: @escaping HistorySamples
    ) async -> SlotSurface {
        var descriptors: [EntityID: EntityDescriptor] = [:]
        var states: [EntityID: EntityState] = [:]
        var series: [EntityID: [Sample]] = [:]
        var attentionDescriptors: [EntityDescriptor] = []
        var detailDescriptors: [EntityDescriptor] = []
        var headlineLatencyID: EntityID?
        for record in shownRecords {
            let providerInstance = ProviderInstanceID(rawValue: "\(record.id.rawValue)/probe")
            let latencyID = EntityID(rawValue: "\(providerInstance.rawValue).latency_ms")
            guard var latency = allDescriptors[providerInstance]?.first(where: { $0.id == latencyID }) else { continue }
            latency.name = record.displayName
            latency.isPrimary = record.id == headlineRecordID
            if record.id == headlineRecordID {
                headlineLatencyID = latencyID
            }
            detailDescriptors.append(latency)
            attentionDescriptors.append(latency)
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
        let candidateDescriptors = candidates.map(\.descriptor)
        let alertingIDs = Set(firedAlertEvents.flatMap { event in
            alertTargetResolver.resolve(event, descriptors: candidateDescriptors)
        })
        var headlineEligibleActiveIDs = Set<EntityID>()
        if let headlineLatencyID { headlineEligibleActiveIDs.insert(headlineLatencyID) }
        if descriptors[DiagnosisEntity.entityID] != nil { headlineEligibleActiveIDs.insert(DiagnosisEntity.entityID) }
        let readout = attentionEngines.resolveReadout(
            slotID: slot.id,
            mode: slot.barReadout,
            candidates: candidates,
            descriptors: descriptors,
            states: states,
            headlineEligibleActiveIDs: headlineEligibleActiveIDs,
            alertingIDs: alertingIDs,
            config: config,
            now: now
        )
        let sampleHistoryEntityID = SurfaceComposer.sampleHistoryEntityID(
            preferredEntityID: readout.primaryEntityID,
            in: detailDescriptors
        )
        let planCards = SurfaceComposer.detailPlan(
            descriptors: detailDescriptors,
            states: states,
            config: config,
            slotID: slot.id,
            preferredSampleHistoryEntityID: sampleHistoryEntityID
        ).cards

        let data = SurfaceData(
            descriptors: descriptors,
            states: states,
            series: series,
            primaryEntityID: readout.primaryEntityID
        )

        return SlotSurface(
            plan: SurfacePlan(cards: planCards),
            data: data,
            glyph: readout.glyph,
            primaryEntityID: readout.primaryEntityID,
            selectedInstanceID: selectedInstanceID,
            hostOptions: hostOptions
        )
    }

    nonisolated private static func isPingSlot(_ slot: Slot) -> Bool {
        if case .integrationType(let integrationID) = slot.selection, integrationID == IntegrationIDs.ping {
            return true
        }
        return false
    }

    nonisolated private static func pingHostSubtitle(_ record: IntegrationInstanceRecord) -> String? {
        guard let host = PingHostConfig(configObject: record.config, displayNameFallback: record.displayName) else { return nil }
        return "\(host.method.rawValue.uppercased()) \(host.address)"
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
        guard !samples.isEmpty else {
            var state = current ?? EntityState(id: id, availability: .stale)
            state.value = nil
            state.availability = .stale
            state.severity = .normal
            return state
        }
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

        let data = SurfaceData(
            descriptors: descriptors,
            states: states,
            series: series,
            primaryEntityID: readout.primaryEntityID
        )

        return SlotSurface(
            plan: plan ?? SurfaceComposer.detailPlan(descriptors: resolved, states: states, config: config, slotID: slot.id),
            data: data,
            glyph: readout.glyph,
            primaryEntityID: readout.primaryEntityID,
            selectedInstanceID: nil,
            hostOptions: []
        )
    }
}

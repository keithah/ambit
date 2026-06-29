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
        monitoringDiagnosis: MonitoringDiagnosis? = nil,
        allRegistryRecords: [IntegrationInstanceRecord],
        allDescriptors: [ProviderInstanceID: [EntityDescriptor]],
        allStates: [EntityID: EntityState],
        firedAlertEvents: [AlertEvent],
        slotFocus: [SlotID: IntegrationInstanceID],
        primaryPingInstanceID: IntegrationInstanceID? = nil,
        fallbackGraphRange: GraphRange,
        config: PresentationConfig,
        now: Date,
        historySamples: @escaping HistorySamples
    ) async -> SlotSurface {
        let flatDescriptors = allDescriptors.values.flatMap { $0 }
        let resolved = SlotResolver.resolve(slot.selection, descriptors: flatDescriptors, records: allRegistryRecords)

        let resolvedInstanceIDs = Set(resolved.map { $0.instanceID.integrationInstanceID })
        let resolvedRecords = allRegistryRecords.filter { record in
            record.enabled && resolvedInstanceIDs.contains(record.id)
        }
        let hostOptions = resolvedRecords.map { record in
            InstanceSelectorCard.Option(
                id: record.id.rawValue,
                label: record.displayName,
                subtitle: Self.instanceSubtitle(record, descriptors: resolved)
            )
        }

        let override = config.slotOverrides[slot.id]
        let graphRange = override?.graphRange ?? fallbackGraphRange
        let defaultFocusID = Self.defaultFocusID(
            records: resolvedRecords,
            primaryPingInstanceID: override?.primaryInstanceID ?? primaryPingInstanceID
        )
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
            ?? defaultFocusID
        let shownInstanceIDs = Set(shownRecords.map(\.id))
        let shownResolved = focusedID == nil
            ? resolved
            : resolved.filter { descriptor in
                shownInstanceIDs.contains(descriptor.instanceID.integrationInstanceID)
            }

        guard !Self.hasMultiInstanceMeasurementSurface(resolved: resolved, records: resolvedRecords) else {
            return await buildMultiInstanceSurface(
                slot: slot,
                monitoringDiagnosis: monitoringDiagnosis,
                shownRecords: shownRecords,
                headlineRecordID: headlineRecordID,
                shownResolved: shownResolved,
                allStates: allStates,
                firedAlertEvents: firedAlertEvents,
                hostOptions: hostOptions,
                selectedInstanceID: focusedID,
                graphRange: graphRange,
                config: config,
                now: now,
                historySamples: historySamples
            )
        }

        do {
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
    }

    private func buildMultiInstanceSurface(
        slot: Slot,
        monitoringDiagnosis: MonitoringDiagnosis?,
        shownRecords: [IntegrationInstanceRecord],
        headlineRecordID: IntegrationInstanceID?,
        shownResolved: [EntityDescriptor],
        allStates: [EntityID: EntityState],
        firedAlertEvents: [AlertEvent],
        hostOptions: [InstanceSelectorCard.Option],
        selectedInstanceID: IntegrationInstanceID?,
        graphRange: GraphRange,
        config: PresentationConfig,
        now: Date,
        historySamples: @escaping HistorySamples
    ) async -> SlotSurface {
        var descriptors: [EntityID: EntityDescriptor] = [:]
        var states: [EntityID: EntityState] = [:]
        var series: [EntityID: [Sample]] = [:]
        var attentionDescriptors: [EntityDescriptor] = []
        var detailDescriptors: [EntityDescriptor] = []
        var headlineMeasurementID: EntityID?
        let recordsByID = Dictionary(uniqueKeysWithValues: shownRecords.map { ($0.id, $0) })
        let allowCategoryPrimary = hostOptions.count > 1
        let recordOrder = Dictionary(uniqueKeysWithValues: shownRecords.enumerated().map { ($0.element.id, $0.offset) })
        let surfaceDescriptors = shownResolved.enumerated()
            .filter { _, descriptor in Self.isSurfaceDescriptor(descriptor) }
            .sorted { lhs, rhs in
                let lhsOrder = recordOrder[lhs.element.instanceID.integrationInstanceID] ?? Int.max
                let rhsOrder = recordOrder[rhs.element.instanceID.integrationInstanceID] ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        for rawDescriptor in surfaceDescriptors {
            var descriptor = rawDescriptor
            let instanceID = descriptor.instanceID.integrationInstanceID
            let isHeadlineInstance = instanceID == headlineRecordID
            if Self.isPrimaryMeasurement(descriptor, allowCategoryPrimary: allowCategoryPrimary) {
                descriptor.isPrimary = isHeadlineInstance
                if let record = recordsByID[instanceID], shownRecords.count > 1 {
                    descriptor.name = record.displayName
                }
                if isHeadlineInstance {
                    headlineMeasurementID = descriptor.id
                }
            }
            detailDescriptors.append(descriptor)
            attentionDescriptors.append(descriptor)
            descriptors[descriptor.id] = descriptor
            if descriptor.stateClass != nil {
                let samples = await historySamples(descriptor.id, now.addingTimeInterval(-graphRange.seconds))
                series[descriptor.id] = samples
                if descriptor.deviceClass == .latency,
                   let state = Self.latencyStateForSurface(id: descriptor.id, current: allStates[descriptor.id], samples: samples) {
                    states[descriptor.id] = state
                } else if let state = allStates[descriptor.id] {
                    states[descriptor.id] = state
                }
            } else if let state = allStates[descriptor.id] {
                states[descriptor.id] = state
            }
        }

        var diagnosticEntityID: EntityID?
        if let monitoringDiagnosis,
           let (diagnosisDescriptor, diagnosisState) = DiagnosticSummaryEntity.make(monitoringDiagnosis, owner: .ping) {
            diagnosticEntityID = diagnosisDescriptor.id
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
        if let headlineMeasurementID { headlineEligibleActiveIDs.insert(headlineMeasurementID) }
        if let diagnosticEntityID { headlineEligibleActiveIDs.insert(diagnosticEntityID) }
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
        let planCards = Self.applyingGraphRange(
            graphRange,
            to: SurfaceComposer.detailPlan(
            descriptors: detailDescriptors,
            states: states,
            config: config,
            slotID: slot.id,
            preferredSampleHistoryEntityID: sampleHistoryEntityID
            ).cards
        )

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
            graphRange: graphRange,
            selectedInstanceID: selectedInstanceID,
            primaryInstanceID: headlineRecordID,
            hostOptions: hostOptions
        )
    }

    nonisolated private static func hasMultiInstanceMeasurementSurface(
        resolved: [EntityDescriptor],
        records: [IntegrationInstanceRecord]
    ) -> Bool {
        !records.isEmpty && resolved.contains { isPrimaryMeasurement($0, allowCategoryPrimary: records.count > 1) }
    }

    nonisolated private static func instanceSubtitle(_ record: IntegrationInstanceRecord, descriptors: [EntityDescriptor]) -> String? {
        let instanceDescriptors = descriptors.filter { $0.instanceID.integrationInstanceID == record.id }
        let address = instanceDescriptors.compactMap { $0.monitoring?.address?.rawValue }.first
            ?? record.config["address"]?.stringValue
        guard let address else { return nil }
        let method = record.config["method"]?.stringValue?.uppercased()
        return [method, address].compactMap { $0 }.joined(separator: " ")
    }

    nonisolated private static func defaultFocusID(
        records: [IntegrationInstanceRecord],
        primaryPingInstanceID: IntegrationInstanceID?
    ) -> IntegrationInstanceID? {
        let nonLoopbackRecords = records.filter { record in
            record.config["address"]?.stringValue.map { AddressClassifier.scope(for: $0) != .loopback } ?? true
        }
        if let primaryPingInstanceID,
           let primaryRecord = records.first(where: { $0.id == primaryPingInstanceID }),
           (primaryRecord.config["address"]?.stringValue.map { AddressClassifier.scope(for: $0) != .loopback } ?? true) || nonLoopbackRecords.isEmpty {
            return primaryPingInstanceID
        }
        return nonLoopbackRecords.first?.id ?? records.first?.id
    }

    nonisolated private static func isSurfaceDescriptor(_ descriptor: EntityDescriptor) -> Bool {
        guard descriptor.category != .config else { return false }
        return descriptor.stateClass != nil || descriptor.kind == .table || descriptor.category == .diagnostic
    }

    nonisolated private static func isPrimaryMeasurement(_ descriptor: EntityDescriptor, allowCategoryPrimary: Bool = false) -> Bool {
        descriptor.stateClass != nil && (descriptor.isPrimary || (allowCategoryPrimary && descriptor.category == .primary))
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

    nonisolated static func applyingGraphRange(_ range: GraphRange, to cards: [CardSpec]) -> [CardSpec] {
        cards.map { card in
            var copy = card
            copy.children = applyingGraphRange(range, to: card.children)
            switch card.kind {
            case .historyGraph, .dualLineGraph, .sampleHistory:
                copy.graphRange = range
            default:
                break
            }
            return copy
        }
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
            graphRange: nil,
            selectedInstanceID: nil,
            primaryInstanceID: nil,
            hostOptions: []
        )
    }
}

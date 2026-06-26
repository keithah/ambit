import Foundation

// The entity-driven binding decision: descriptors + states + user config → a SurfacePlan.
// Replaces the Metric-based ProviderDisplayModel / ProviderSurfaceModel / ProviderMetricSection.
// UI-free and pure, so AmbitCheck and tests assert layout without SwiftUI.

public enum SurfaceComposer {

    private enum Section: Int, CaseIterable {
        case cpu, memory, disk, network, power, sensors, fans, state, controls, other
        var title: String {
            switch self {
            case .cpu: return "CPU"
            case .memory: return "Memory"
            case .disk: return "Disk"
            case .network: return "Network"
            case .power: return "Power"
            case .sensors: return "Sensors"
            case .fans: return "Fans"
            case .state: return "State"
            case .controls: return "Controls"
            case .other: return "Other"
            }
        }
    }

    public static func detailPlan(
        descriptors: [EntityDescriptor],
        states: [EntityID: EntityState],
        config: PresentationConfig = .empty
    ) -> SurfacePlan {
        let visible = descriptors.filter { descriptor in
            if descriptor.category == .config { return false }
            if config.entityOverrides[descriptor.id]?.enabled == false { return false }
            return true
        }

        var bySection: [Section: [EntityDescriptor]] = [:]
        for descriptor in visible {
            bySection[section(for: descriptor), default: []].append(descriptor)
        }

        var cards: [CardSpec] = []
        for section in Section.allCases {
            guard let group = bySection[section], !group.isEmpty else { continue }
            let ordered = group.sorted(by: ordering)
            let children = deduplicatingEponymousTitle(
                in: groupRows(in: buildCards(for: ordered, states: states, config: config), section: section),
                section: section
            )
            let role: CardRole = ordered.contains(where: \.isPrimary) ? .primary : .secondary
            cards.append(CardSpec(id: "section.\(section.title)", kind: .section,
                                  title: section.title, children: children, role: role))
        }
        return SurfacePlan(cards: cards)
    }

    private static func section(for d: EntityDescriptor) -> Section {
        if isControl(d.kind) { return .controls }
        if let section = section(for: d.capability) { return section }
        switch d.deviceClass {
        case .connectivity, .throughput, .latency: return .network
        case .battery, .power: return .power
        case .percent, .count, .duration, .dataSize, .temperature, .fan: return .other
        case .none:
            switch d.kind {
            case .binarySensor, .text: return .state
            default: return .other
            }
        }
    }

    private static func section(for capability: ProviderCapability?) -> Section? {
        switch capability?.rawValue {
        case "system.cpu": return .cpu
        case "system.memory": return .memory
        case "system.disk": return .disk
        case "system.network": return .network
        case "power.battery": return .power
        case "system.sensors": return .sensors
        case "system.fans": return .fans
        default: return nil
        }
    }

    private static func ordering(_ a: EntityDescriptor, _ b: EntityDescriptor) -> Bool {
        if a.isPrimary != b.isPrimary { return a.isPrimary }
        let pa = a.priority ?? Int.min
        let pb = b.priority ?? Int.min
        if pa != pb { return pa > pb }
        // Preserve input order when priority is equal (stable sort via false = no swap).
        return false
    }

    /// Build a section's cards, collapsing same-deviceClass/unit measurement history graphs into
    /// one multi-line card (generic: drives the multi-host pingscope graph and P6 cores/disks).
    private static func buildCards(for ordered: [EntityDescriptor], states: [EntityID: EntityState], config: PresentationConfig) -> [CardSpec] {
        var result: [CardSpec] = []
        var combinedIndexByKey: [String: Int] = [:]
        let segmentedGroups = segmentedRingGroups(in: ordered, states: states, config: config)
        let segmentedIDs = Set(segmentedGroups.flatMap { $0.map(\.id) })
        let coreGroups = coreGridGroups(in: ordered, excluding: segmentedIDs)
        let coreIDs = Set(coreGroups.flatMap { $0.map(\.id) })
        let dualLineGroups = dualLineGraphGroups(in: ordered, excluding: segmentedIDs.union(coreIDs), states: states, config: config)
        let dualLineIDs = Set(dualLineGroups.flatMap { $0.map(\.id) })
        for group in segmentedGroups {
            result.append(segmentedRingCard(for: group))
            result.append(breakdownLegendCard(for: group))
        }
        for group in coreGroups {
            result.append(coreGridCard(for: group))
        }
        for group in dualLineGroups {
            result.append(dualLineGraphCard(for: group, config: config))
        }
        for d in ordered {
            if segmentedIDs.contains(d.id) { continue }
            if coreIDs.contains(d.id) { continue }
            if dualLineIDs.contains(d.id) { continue }
            guard cardKind(for: d, state: states[d.id], config: config) == .historyGraph, d.stateClass == .measurement else {
                result.append(card(for: d, state: states[d.id], config: config))
                continue
            }
            let key = "\(d.deviceClass?.rawValue ?? "none")|\(d.unit ?? "")"
            if let index = combinedIndexByKey[key] {
                result[index].entities.append(d.id)
                result[index].title = nil   // multi-line: the legend names the series, not a title
            } else {
                combinedIndexByKey[key] = result.count
                result.append(card(for: d, state: states[d.id], config: config))
            }
        }
        return result
    }

    private static func groupRows(in cards: [CardSpec], section: Section) -> [CardSpec] {
        var result: [CardSpec] = []
        var buffer: [CardSpec] = []
        var rowIndex = 0

        func flushBuffer() {
            while buffer.count >= 2 {
                let rowChildren = Array(buffer.prefix(min(3, buffer.count)))
                buffer.removeFirst(rowChildren.count)
                result.append(CardSpec(
                    id: "row:\(section.title):\(rowIndex)",
                    kind: .cardRow,
                    children: rowChildren,
                    role: rowChildren.contains(where: { $0.role == .primary }) ? .primary : .secondary
                ))
                rowIndex += 1
            }
            if buffer.count == 1 {
                result.append(buffer.removeFirst())
            }
        }

        for card in cards {
            if isRowEligible(card) {
                buffer.append(card)
            } else {
                flushBuffer()
                result.append(card)
            }
        }
        flushBuffer()
        return result
    }

    private static func deduplicatingEponymousTitle(in cards: [CardSpec], section: Section) -> [CardSpec] {
        guard cards.count == 1,
              let title = cards[0].title,
              normalizedTitle(title) == normalizedTitle(section.title)
        else { return cards }
        var card = cards[0]
        card.title = nil
        return [card]
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func isRowEligible(_ card: CardSpec) -> Bool {
        switch card.kind {
        case .gauge, .progress: return true
        case .statusRow, .historyGraph, .dualLineGraph, .segmentedRing, .breakdownLegend, .coreGrid, .statTable, .control, .instanceSelector, .section, .statusBanner, .cardRow:
            return false
        }
    }

    private static func segmentedRingGroups(in ordered: [EntityDescriptor], states: [EntityID: EntityState], config: PresentationConfig) -> [[EntityDescriptor]] {
        let candidates = ordered.filter { descriptor in
            guard descriptor.kind == .sensor else { return false }
            guard effectiveGraphStyle(descriptor, config: config) == .progress else { return false }
            guard descriptor.stateClass == .measurement || descriptor.stateClass == nil else { return false }
            return descriptor.capability != nil && descriptor.deviceClass != nil
        }
        let grouped = Dictionary(grouping: candidates) { descriptor in
            segmentedRingGroupKey(for: descriptor)
        }
        return grouped.values
            .map { $0.sorted(by: ordering) }
            .filter { $0.count >= 3 }
            .filter { group in group.allSatisfy { numericOnlineValue(for: $0, states: states) != nil } }
            .sorted { lhs, rhs in
                guard let a = ordered.firstIndex(where: { $0.id == lhs[0].id }),
                      let b = ordered.firstIndex(where: { $0.id == rhs[0].id }) else { return false }
                return a < b
            }
    }

    private static func segmentedRingCard(for group: [EntityDescriptor]) -> CardSpec {
        let role: CardRole = group.contains(where: \.isPrimary) ? .primary : .secondary
        return CardSpec(
            id: "group:\(segmentedRingGroupKey(for: group[0])):segments",
            kind: .segmentedRing,
            entities: group.map(\.id),
            graphStyle: .progress,
            role: role
        )
    }

    private static func breakdownLegendCard(for group: [EntityDescriptor]) -> CardSpec {
        CardSpec(
            id: "group:\(segmentedRingGroupKey(for: group[0])):breakdown",
            kind: .breakdownLegend,
            entities: group.map(\.id),
            role: .secondary
        )
    }

    private static func dualLineGraphGroups(
        in ordered: [EntityDescriptor],
        excluding excludedIDs: Set<EntityID>,
        states: [EntityID: EntityState],
        config: PresentationConfig
    ) -> [[EntityDescriptor]] {
        let candidates = ordered.filter { descriptor in
            guard !excludedIDs.contains(descriptor.id) else { return false }
            guard cardKind(for: descriptor, state: states[descriptor.id], config: config) == .historyGraph else { return false }
            guard descriptor.stateClass == .measurement || descriptor.stateClass == nil else { return false }
            return descriptor.capability != nil && descriptor.deviceClass != nil
        }
        let grouped = Dictionary(grouping: candidates) { descriptor in
            segmentedRingGroupKey(for: descriptor)
        }
        return grouped.values
            .compactMap { group -> [EntityDescriptor]? in
                guard group.count == 2 else { return nil }
                let sorted = group.sorted(by: dualLineOrdering)
                guard dualLineRolePair(for: sorted) != nil else { return nil }
                return sorted
            }
            .sorted { lhs, rhs in
                guard let a = ordered.firstIndex(where: { $0.id == lhs[0].id }),
                      let b = ordered.firstIndex(where: { $0.id == rhs[0].id }) else { return false }
                return a < b
            }
    }

    private static func dualLineGraphCard(for group: [EntityDescriptor], config: PresentationConfig) -> CardSpec {
        let role = dualLineRolePair(for: group) ?? "pair"
        let range = config.entityOverrides[group[0].id]?.graphRange ?? group[0].defaultGraphRange ?? .m5
        return CardSpec(
            id: "group:\(segmentedRingGroupKey(for: group[0])):\(role)",
            kind: .dualLineGraph,
            entities: group.map(\.id),
            graphStyle: .sparkline,
            graphRange: range,
            role: group.contains(where: \.isPrimary) ? .primary : .secondary
        )
    }

    private static func coreGridGroups(in ordered: [EntityDescriptor], excluding excludedIDs: Set<EntityID>) -> [[EntityDescriptor]] {
        let candidates = ordered.filter { descriptor in
            guard !excludedIDs.contains(descriptor.id) else { return false }
            guard descriptor.kind == .sensor else { return false }
            guard descriptor.compositionRole == .channel else { return false }
            guard descriptor.deviceClass == .percent else { return false } // A5a replaces this with the generic axis model.
            guard descriptor.stateClass == .measurement || descriptor.stateClass == nil else { return false }
            return descriptor.capability != nil
        }
        let grouped = Dictionary(grouping: candidates) { descriptor in
            segmentedRingGroupKey(for: descriptor)
        }
        return grouped.values
            .map { $0.sorted(by: ordering) }
            .filter { $0.count >= 3 }
            .sorted { lhs, rhs in
                guard let a = ordered.firstIndex(where: { $0.id == lhs[0].id }),
                      let b = ordered.firstIndex(where: { $0.id == rhs[0].id }) else { return false }
                return a < b
            }
    }

    private static func coreGridCard(for group: [EntityDescriptor]) -> CardSpec {
        let role: CardRole = group.contains(where: \.isPrimary) ? .primary : .secondary
        return CardSpec(
            id: "group:\(segmentedRingGroupKey(for: group[0])):cores",
            kind: .coreGrid,
            entities: group.map(\.id),
            graphStyle: .gauge,
            role: role
        )
    }

    private static func segmentedRingGroupKey(for descriptor: EntityDescriptor) -> String {
        [
            descriptor.capability?.rawValue ?? "unknown",
            descriptor.deviceClass?.rawValue ?? "none",
            descriptor.unit ?? "none"
        ].joined(separator: ":")
    }

    private static func dualLineRolePair(for group: [EntityDescriptor]) -> String? {
        let roles = Set(group.compactMap(dualLineRole))
        if roles == Set(["user", "system"]) { return "user-system" }
        if roles == Set(["in", "out"]) { return "in-out" }
        return nil
    }

    private static func dualLineOrdering(_ a: EntityDescriptor, _ b: EntityDescriptor) -> Bool {
        let ra = dualLineRank(dualLineRole(for: a))
        let rb = dualLineRank(dualLineRole(for: b))
        if ra != rb { return ra < rb }
        return ordering(a, b)
    }

    private static func dualLineRank(_ role: String?) -> Int {
        switch role {
        case "user", "in": return 0
        case "system", "out": return 1
        default: return 2
        }
    }

    private static func dualLineRole(for descriptor: EntityDescriptor) -> String? {
        let tokens = Set(tokenizeForPairing([descriptor.name, descriptor.metricID ?? "", descriptor.id.rawValue]))
        if tokens.contains("user") { return "user" }
        if tokens.contains("system") { return "system" }
        if !tokens.isDisjoint(with: ["in", "input", "download", "rx"]) { return "in" }
        if !tokens.isDisjoint(with: ["out", "output", "upload", "tx"]) { return "out" }
        return nil
    }

    private static func tokenizeForPairing(_ values: [String]) -> [String] {
        values.flatMap { value in
            value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
    }

    private static func numericOnlineValue(for descriptor: EntityDescriptor, states: [EntityID: EntityState]) -> Double? {
        guard let state = states[descriptor.id], state.availability == .online else { return nil }
        guard case .number(let value)? = state.value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func card(for d: EntityDescriptor, state: EntityState?, config: PresentationConfig) -> CardSpec {
        let kind = cardKind(for: d, state: state, config: config)
        let role: CardRole = kind == .statusBanner ? .banner : (d.isPrimary ? .primary : .secondary)
        let style = effectiveGraphStyle(d, config: config)
        let range: GraphRange? = (kind == .historyGraph)
            ? (config.entityOverrides[d.id]?.graphRange ?? d.defaultGraphRange ?? .m5)
            : nil
        return CardSpec(id: "card.\(d.id.rawValue)", kind: kind, title: d.name,
                        entities: [d.id], graphStyle: style, graphRange: range, role: role)
    }

    private static func cardKind(for d: EntityDescriptor, state: EntityState?, config: PresentationConfig) -> CardKind {
        if isControl(d.kind) { return .control }
        if d.kind == .table { return .statTable }
        if d.category == .diagnostic, d.kind == .text, (state?.severity ?? .normal) >= .elevated {
            return .statusBanner
        }
        if d.kind == .binarySensor || d.kind == .text { return .statusRow }
        switch effectiveGraphStyle(d, config: config) {
        case .some(.gauge): return .gauge
        case .some(.progress): return .progress
        case .some(.sparkline): return .historyGraph
        case .some(.none): return .statusRow
        case nil:
            return d.stateClass == .measurement ? .historyGraph : .statusRow
        }
    }

    private static func effectiveGraphStyle(_ d: EntityDescriptor, config: PresentationConfig) -> GraphStyle? {
        config.entityOverrides[d.id]?.graphStyle ?? d.graphStyle
    }

    private static func isControl(_ kind: EntityKind) -> Bool {
        switch kind {
        case .toggle, .select, .number, .button: return true
        case .sensor, .binarySensor, .text, .table: return false
        }
    }
}

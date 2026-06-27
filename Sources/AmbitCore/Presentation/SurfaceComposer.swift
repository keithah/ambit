import Foundation

// The entity-driven binding decision: descriptors + states + user config → a SurfacePlan.
// Replaces the Metric-based ProviderDisplayModel / ProviderSurfaceModel / ProviderMetricSection.
// UI-free and pure, so AmbitCheck and tests assert layout without SwiftUI.

public enum SurfaceComposer {
    public struct SurfaceItem: Equatable, Sendable {
        public var id: SurfaceItemID
        public var label: String
        public var section: String
        public var card: CardSpec
        public var isShown: Bool
        public var isHidden: Bool

        public init(
            id: SurfaceItemID,
            label: String,
            section: String,
            card: CardSpec,
            isShown: Bool,
            isHidden: Bool
        ) {
            self.id = id
            self.label = label
            self.section = section
            self.card = card
            self.isShown = isShown
            self.isHidden = isHidden
        }
    }

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
        config: PresentationConfig = .empty,
        slotID: SlotID? = nil
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
            if slotOverride(for: slotID, config: config)?.hiddenItems.contains(sectionItemID(for: section)) == true {
                continue
            }
            let leaves = sectionSurfaceItems(
                section: section,
                ordered: ordered,
                states: states,
                config: config,
                slotID: slotID
            ).filter(\.isShown).map(\.card)
            guard !leaves.isEmpty else { continue }
            let children = deduplicatingEponymousTitle(
                in: groupRows(in: leaves, section: section),
                section: section
            )
            let role: CardRole = ordered.contains(where: \.isPrimary) ? .primary : .secondary
            cards.append(CardSpec(id: "section.\(section.title)", kind: .section,
                                  title: section.title, children: children, role: role))
        }
        return SurfacePlan(cards: cards)
    }

    public static func surfaceItems(
        descriptors: [EntityDescriptor],
        states: [EntityID: EntityState],
        config: PresentationConfig = .empty,
        slotID: SlotID? = nil
    ) -> [SurfaceItem] {
        let visible = descriptors.filter { descriptor in
            if descriptor.category == .config { return false }
            if config.entityOverrides[descriptor.id]?.enabled == false { return false }
            return true
        }

        var bySection: [Section: [EntityDescriptor]] = [:]
        for descriptor in visible {
            bySection[section(for: descriptor), default: []].append(descriptor)
        }

        return Section.allCases.flatMap { section -> [SurfaceItem] in
            guard let group = bySection[section], !group.isEmpty else { return [] }
            let ordered = group.sorted(by: ordering)
            return sectionSurfaceItems(
                section: section,
                ordered: ordered,
                states: states,
                config: config,
                slotID: slotID
            )
        }
    }

    private static func slotOverride(for slotID: SlotID?, config: PresentationConfig) -> SlotPresentationOverride? {
        guard let slotID else { return nil }
        return config.slotOverrides[slotID]
    }

    private static func sectionSurfaceItems(
        section: Section,
        ordered: [EntityDescriptor],
        states: [EntityID: EntityState],
        config: PresentationConfig,
        slotID: SlotID?
    ) -> [SurfaceItem] {
        let override = slotOverride(for: slotID, config: config)
        let baseCards = buildCards(for: ordered, states: states, config: config).map { card -> CardSpec in
            guard card.kind == .statTable, let limit = override?.tableRowLimit else { return card }
            var card = card
            card.tableRowLimit = limit
            return card
        }
        let autoSampleHistoryID = primaryLatencyHistoryEntityID(in: ordered)
        let cardsWithDefaultVisibility = baseCards.map { (card: $0, defaultShown: true) }
            + sampleHistoryCards(for: ordered).map { card in
                (card: card, defaultShown: card.entities.first == autoSampleHistoryID)
            }
        let sectionHidden = override?.hiddenItems.contains(sectionItemID(for: section)) == true
        let items = cardsWithDefaultVisibility.map { card, defaultShown in
            let itemID = surfaceItemID(for: card)
            let hidden = sectionHidden || (override?.hiddenItems.contains(itemID) == true)
            return SurfaceItem(
                id: itemID,
                label: surfaceItemLabel(for: card, section: section),
                section: section.title,
                card: card,
                isShown: defaultShown && !hidden,
                isHidden: hidden
            )
        }

        guard let shownItems = override?.shownItems else {
            return items
        }

        let byItemID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let shownIDs = Set(shownItems)
        let configured = shownItems.compactMap { itemID -> SurfaceItem? in
            guard var item = byItemID[itemID] else { return nil }
            // Explicit shownItems is leaf-only and wins over leaf hiddenItems; section hides
            // remain a coarse opt-out because sections are not persisted as ordered items.
            item.isShown = !sectionHidden
            return item
        }
        let available = items.filter { !shownIDs.contains($0.id) }.map { item -> SurfaceItem in
            var item = item
            item.isShown = false
            return item
        }
        return configured + available
    }

    private static func sectionItemID(for section: Section) -> SurfaceItemID {
        SurfaceItemID(rawValue: "section:\(section.title)")
    }

    private static func surfaceItemID(for card: CardSpec) -> SurfaceItemID {
        if card.id.hasPrefix("group:") {
            return SurfaceItemID(rawValue: card.id)
        }
        if card.kind == .sampleHistory {
            return SurfaceItemID(rawValue: card.id)
        }
        if let entityID = card.entities.first {
            return SurfaceItemID(rawValue: "entity:\(entityID.rawValue)")
        }
        return SurfaceItemID(rawValue: card.id)
    }

    private static func surfaceItemLabel(for card: CardSpec, section: Section) -> String {
        if let title = card.title, !title.isEmpty { return title }
        switch card.kind {
        case .sampleHistory:
            if let entity = card.entities.first {
                return "\(entity.rawValue.split(separator: ".").last.map(String.init) ?? section.title) history"
            }
            return "\(section.title) history"
        case .segmentedRing:
            return "\(section.title) breakdown"
        case .breakdownLegend:
            return "\(section.title) breakdown details"
        case .coreGrid:
            return "\(section.title) Cores"
        case .dualLineGraph:
            if card.id.hasSuffix(":user-system") { return "\(section.title) User/System" }
            return "\(section.title) comparison"
        default:
            break
        }
        if card.entities.count == 1, let entity = card.entities.first {
            return entity.rawValue.split(separator: ".").last.map(String.init) ?? card.id
        }
        return card.id
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
        let sectionTitle = normalizedTitle(section.title)
        return cards.map { original in
            guard let title = original.title, normalizedTitle(title) == sectionTitle else {
                return original
            }
            var card = original
            card.title = nil
            return card
        }
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func isRowEligible(_ card: CardSpec) -> Bool {
        switch card.kind {
        case .gauge, .progress: return true
        case .statusRow, .historyGraph, .dualLineGraph, .sampleHistory, .segmentedRing, .breakdownLegend, .coreGrid, .statTable, .control, .instanceSelector, .section, .statusBanner, .cardRow:
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

    private static func sampleHistoryCards(for ordered: [EntityDescriptor]) -> [CardSpec] {
        ordered
            .filter { descriptor in
                descriptor.stateClass == .measurement && descriptor.kind == .sensor
            }
            .map { descriptor in
                CardSpec(
                    id: "history:\(descriptor.id.rawValue)",
                    kind: .sampleHistory,
                    entities: [descriptor.id],
                    graphRange: descriptor.defaultGraphRange ?? .m5,
                    tableRowLimit: 8,
                    role: .secondary
                )
            }
    }

    private static func primaryLatencyHistoryEntityID(in ordered: [EntityDescriptor]) -> EntityID? {
        ordered.first { descriptor in
            descriptor.isPrimary
                && descriptor.kind == .sensor
                && descriptor.deviceClass == .latency
                && descriptor.stateClass == .measurement
        }?.id
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

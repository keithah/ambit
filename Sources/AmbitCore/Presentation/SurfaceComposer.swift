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
            let children = buildCards(for: ordered, states: states, config: config)
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
        for d in ordered {
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

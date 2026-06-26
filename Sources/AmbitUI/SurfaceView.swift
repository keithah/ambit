import SwiftUI
import AmbitCore

// The value side of the layout/value split: a snapshot of descriptors + live states + history
// the cards read from. Wiring to the live Engine/HistoryService happens when a surface host
// adopts AmbitUI (P2+); P1 hands it pre-resolved data, which keeps the views testable.
public struct SurfaceData {
    public var descriptors: [EntityID: EntityDescriptor]
    public var states: [EntityID: EntityState]
    public var series: [EntityID: [Sample]]

    public init(descriptors: [EntityID: EntityDescriptor] = [:],
                states: [EntityID: EntityState] = [:],
                series: [EntityID: [Sample]] = [:]) {
        self.descriptors = descriptors
        self.states = states
        self.series = series
    }

    public func readout(_ id: EntityID) -> EntityReadout {
        guard let descriptor = descriptors[id] else { return EntityReadout(text: "—", tone: .neutral) }
        return EntityReadout.make(descriptor: descriptor, state: states[id])
    }

    public func title(_ id: EntityID) -> String { descriptors[id]?.name ?? id.rawValue }
    public func samples(_ id: EntityID) -> [Sample] { series[id] ?? [] }
}

/// Renders one CardSpec by dispatching on its kind. Unknown/compound kinds with no single-entity
/// binding fall back to the generic status row.
public struct CardView: View {
    let spec: CardSpec
    let data: SurfaceData
    public init(spec: CardSpec, data: SurfaceData) {
        self.spec = spec
        self.data = data
    }

    private var primaryID: EntityID? { spec.entities.first }

    public var body: some View {
        switch spec.kind {
        case .section:
            SectionCard(title: spec.title) {
                ForEach(spec.children) { child in
                    CardView(spec: child, data: data)
                }
            }
        case .cardRow:
            HStack(alignment: .top, spacing: 10) {
                ForEach(spec.children) { child in
                    CardView(spec: child, data: data)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        case .statusRow:
            if let id = primaryID { StatusRowCard(title: data.title(id), readout: data.readout(id)) }
        case .gauge:
            if let id = primaryID { GaugeCard(title: data.title(id), readout: data.readout(id)) }
        case .segmentedRing:
            SegmentedRingCard(title: spec.title, model: SegmentedRingCard.Model(entityIDs: spec.entities, data: data))
        case .breakdownLegend:
            BreakdownLegendCard(title: spec.title, model: BreakdownLegendCard.Model(entityIDs: spec.entities, data: data))
        case .coreGrid:
            CoreGridCard(title: spec.title, model: CoreGridCard.Model(entityIDs: spec.entities, data: data))
        case .progress:
            if let id = primaryID { ProgressCard(title: data.title(id), readout: data.readout(id)) }
        case .historyGraph:
            if !spec.entities.isEmpty {
                let descriptor = spec.entities.first.flatMap { data.descriptors[$0] }
                let lines = spec.entities.enumerated().map { index, id in
                    GraphLine(id: data.title(id), color: Theme.lineColor(index), samples: data.samples(id))
                }
                let summary = spec.entities.count == 1
                    ? GraphSummary.summary(samples: data.samples(spec.entities[0]), deviceClass: descriptor?.deviceClass, unit: descriptor?.unit)
                    : []
                HistoryGraphCard(title: spec.title ?? "",
                                 lines: lines,
                                 deviceClass: descriptor?.deviceClass,
                                 unit: descriptor?.unit,
                                 summary: summary,
                                 showLegend: spec.entities.count > 1)
            }
        case .dualLineGraph:
            DualLineGraphCard(title: spec.title ?? "",
                              lines: spec.entities.map { GraphLine(id: data.title($0), color: DisplayTone.good.color, samples: data.samples($0)) })
        case .control:
            if let id = primaryID, let descriptor = data.descriptors[id] {
                ControlCard(descriptor: descriptor, state: data.states[id])
            }
        case .statTable:
            if
                let id = primaryID,
                case .table(let table)? = data.states[id]?.value
            {
                StatTableCard(title: spec.title, table: table)
            } else {
                StatTableCard(title: spec.title,
                              rows: spec.entities.map { StatTableCard.Row(id: $0.rawValue, label: data.title($0), value: data.readout($0).text) })
            }
        case .statusBanner:
            if let id = primaryID {
                let r = data.readout(id)
                StatusBannerCard(title: data.title(id), detail: r.text, tone: r.tone)
            }
        case .instanceSelector:
            EmptyView()  // bound by the host (needs selection state + action); wired in P3 chrome.
        }
    }
}

/// Renders a full SurfacePlan top to bottom.
public struct SurfaceView: View {
    let plan: SurfacePlan
    let data: SurfaceData
    public init(plan: SurfacePlan, data: SurfaceData) {
        self.plan = plan
        self.data = data
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plan.cards) { card in
                CardView(spec: card, data: data)
            }
        }
    }
}

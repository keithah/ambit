import Foundation

// The fixed, generic card vocabulary (presentation-model.md §2). A CardSpec is the
// render-agnostic decision "this kind of card, bound to these entities" — produced by
// SurfaceComposer, consumed by AmbitUI. Values flow separately (live EntityState + history).

public enum CardKind: String, Equatable, Sendable, Codable {
    case statusRow
    case gauge
    case historyGraph
    case dualLineGraph
    case segmentedRing
    case progress
    case statTable
    case control
    case instanceSelector
    case section
    case statusBanner
}

public enum CardRole: String, Equatable, Sendable, Codable {
    case primary
    case secondary
    case banner
}

public struct CardSpec: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: CardKind
    public var title: String?
    public var entities: [EntityID]      // 1 for a gauge, 2 for dual-line, N for a table, 0 for a section
    public var graphStyle: GraphStyle?
    public var graphRange: GraphRange?
    public var children: [CardSpec]      // populated for .section
    public var role: CardRole

    public init(
        id: String,
        kind: CardKind,
        title: String? = nil,
        entities: [EntityID] = [],
        graphStyle: GraphStyle? = nil,
        graphRange: GraphRange? = nil,
        children: [CardSpec] = [],
        role: CardRole = .secondary
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.entities = entities
        self.graphStyle = graphStyle
        self.graphRange = graphRange
        self.children = children
        self.role = role
    }
}

public struct SurfacePlan: Equatable, Sendable {
    public var cards: [CardSpec]
    public init(cards: [CardSpec] = []) { self.cards = cards }
}

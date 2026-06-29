import Foundation

// User overrides over descriptor presentation-defaults (presentation-model.md §5–6). All
// optional: nil means "use the descriptor default". The generic settings renderer (P5) writes
// these; SurfaceComposer + the Attention engine read them.

public struct EntityPresentationOverride: Equatable, Sendable, Codable {
    public var visibility: GlanceVisibility?
    public var pinned: Bool?
    public var displayThreshold: DisplayThreshold?
    public var alertPolicy: AlertPolicy?
    public var graphStyle: GraphStyle?
    public var graphRange: GraphRange?
    public var enabled: Bool?
    public var interval: TimeInterval?

    public init(
        visibility: GlanceVisibility? = nil,
        pinned: Bool? = nil,
        displayThreshold: DisplayThreshold? = nil,
        alertPolicy: AlertPolicy? = nil,
        graphStyle: GraphStyle? = nil,
        graphRange: GraphRange? = nil,
        enabled: Bool? = nil,
        interval: TimeInterval? = nil
    ) {
        self.visibility = visibility
        self.pinned = pinned
        self.displayThreshold = displayThreshold
        self.alertPolicy = alertPolicy
        self.graphStyle = graphStyle
        self.graphRange = graphRange
        self.enabled = enabled
        self.interval = interval
    }
}

public struct IntegrationPresentationOverride: Equatable, Sendable, Codable {
    public var enabled: Bool?
    public var pinned: Bool?
    public init(enabled: Bool? = nil, pinned: Bool? = nil) {
        self.enabled = enabled
        self.pinned = pinned
    }
}

public struct SurfaceItemID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct SlotPresentationOverride: Equatable, Sendable, Codable {
    public var shownItems: [SurfaceItemID]?
    public var hiddenItems: Set<SurfaceItemID>
    public var tableRowLimit: Int?
    public var graphRange: GraphRange?
    public var selectedInstanceID: IntegrationInstanceID?
    public var primaryInstanceID: IntegrationInstanceID?
    public var showsAllInstances: Bool

    public init(
        shownItems: [SurfaceItemID]? = nil,
        hiddenItems: Set<SurfaceItemID> = [],
        tableRowLimit: Int? = nil,
        graphRange: GraphRange? = nil,
        selectedInstanceID: IntegrationInstanceID? = nil,
        primaryInstanceID: IntegrationInstanceID? = nil,
        showsAllInstances: Bool = false
    ) {
        self.shownItems = shownItems
        self.hiddenItems = hiddenItems
        self.tableRowLimit = tableRowLimit
        self.graphRange = graphRange
        self.selectedInstanceID = selectedInstanceID
        self.primaryInstanceID = primaryInstanceID
        self.showsAllInstances = showsAllInstances
    }

    private enum CodingKeys: String, CodingKey {
        case shownItems, hiddenItems, tableRowLimit, graphRange, selectedInstanceID, primaryInstanceID, showsAllInstances
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shownItems = try container.decodeIfPresent([SurfaceItemID].self, forKey: .shownItems)
        hiddenItems = try container.decodeIfPresent(Set<SurfaceItemID>.self, forKey: .hiddenItems) ?? []
        tableRowLimit = try container.decodeIfPresent(Int.self, forKey: .tableRowLimit)
        graphRange = try container.decodeIfPresent(GraphRange.self, forKey: .graphRange)
        selectedInstanceID = try container.decodeIfPresent(IntegrationInstanceID.self, forKey: .selectedInstanceID)
        primaryInstanceID = try container.decodeIfPresent(IntegrationInstanceID.self, forKey: .primaryInstanceID)
        showsAllInstances = try container.decodeIfPresent(Bool.self, forKey: .showsAllInstances) ?? false
    }
}

public struct PresentationConfig: Equatable, Sendable, Codable {
    public var entityOverrides: [EntityID: EntityPresentationOverride]
    public var integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride]
    public var slotOverrides: [SlotID: SlotPresentationOverride]
    public var slots: [Slot]

    public init(
        entityOverrides: [EntityID: EntityPresentationOverride] = [:],
        integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride] = [:],
        slotOverrides: [SlotID: SlotPresentationOverride] = [:],
        slots: [Slot] = []
    ) {
        self.entityOverrides = entityOverrides
        self.integrationOverrides = integrationOverrides
        self.slotOverrides = slotOverrides
        self.slots = slots
    }

    // Forward-compatible decode: every field is optional-with-default, so a config saved by an
    // older or newer build (missing or with extra keys) loads instead of failing. encode(to:)
    // is synthesized from these keys.
    private enum CodingKeys: String, CodingKey { case entityOverrides, integrationOverrides, slotOverrides, slots }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityOverrides = try container.decodeIfPresent([EntityID: EntityPresentationOverride].self, forKey: .entityOverrides) ?? [:]
        integrationOverrides = try container.decodeIfPresent([IntegrationInstanceID: IntegrationPresentationOverride].self, forKey: .integrationOverrides) ?? [:]
        slotOverrides = try container.decodeIfPresent([SlotID: SlotPresentationOverride].self, forKey: .slotOverrides) ?? [:]
        slots = try container.decodeIfPresent([Slot].self, forKey: .slots) ?? []
    }

    public static var empty: PresentationConfig { PresentationConfig() }
}

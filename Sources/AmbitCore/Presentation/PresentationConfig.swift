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

public struct OverlayFrame: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = max(180, width)
        self.height = max(64, height)
    }
}

public struct OverlayPresentationConfig: Equatable, Sendable, Codable {
    public var selectedSlotID: SlotID?
    public var isVisible: Bool
    public var alwaysOnTop: Bool
    public var compactMode: Bool
    public var opacity: Double
    public var frame: OverlayFrame?

    public init(
        selectedSlotID: SlotID? = nil,
        isVisible: Bool = false,
        alwaysOnTop: Bool = true,
        compactMode: Bool = false,
        opacity: Double = 1,
        frame: OverlayFrame? = nil
    ) {
        self.selectedSlotID = selectedSlotID
        self.isVisible = isVisible
        self.alwaysOnTop = alwaysOnTop
        self.compactMode = compactMode
        self.opacity = min(1, max(0.25, opacity))
        self.frame = frame
    }

    private enum CodingKeys: String, CodingKey {
        case selectedSlotID, isVisible, alwaysOnTop, compactMode, opacity, frame
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selectedSlotID: try container.decodeIfPresent(SlotID.self, forKey: .selectedSlotID),
            isVisible: try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false,
            alwaysOnTop: try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? true,
            compactMode: try container.decodeIfPresent(Bool.self, forKey: .compactMode) ?? false,
            opacity: try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1,
            frame: try container.decodeIfPresent(OverlayFrame.self, forKey: .frame)
        )
    }
}

public struct PresentationConfig: Equatable, Sendable, Codable {
    public var entityOverrides: [EntityID: EntityPresentationOverride]
    public var integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride]
    public var slotOverrides: [SlotID: SlotPresentationOverride]
    public var slots: [Slot]
    public var overlay: OverlayPresentationConfig

    public init(
        entityOverrides: [EntityID: EntityPresentationOverride] = [:],
        integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride] = [:],
        slotOverrides: [SlotID: SlotPresentationOverride] = [:],
        slots: [Slot] = [],
        overlay: OverlayPresentationConfig = OverlayPresentationConfig()
    ) {
        self.entityOverrides = entityOverrides
        self.integrationOverrides = integrationOverrides
        self.slotOverrides = slotOverrides
        self.slots = slots
        self.overlay = overlay
    }

    // Forward-compatible decode: every field is optional-with-default, so a config saved by an
    // older or newer build (missing or with extra keys) loads instead of failing. encode(to:)
    // is synthesized from these keys.
    private enum CodingKeys: String, CodingKey { case entityOverrides, integrationOverrides, slotOverrides, slots, overlay }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityOverrides = try container.decodeIfPresent([EntityID: EntityPresentationOverride].self, forKey: .entityOverrides) ?? [:]
        integrationOverrides = try container.decodeIfPresent([IntegrationInstanceID: IntegrationPresentationOverride].self, forKey: .integrationOverrides) ?? [:]
        slotOverrides = try container.decodeIfPresent([SlotID: SlotPresentationOverride].self, forKey: .slotOverrides) ?? [:]
        slots = try container.decodeIfPresent([Slot].self, forKey: .slots) ?? []
        overlay = try container.decodeIfPresent(OverlayPresentationConfig.self, forKey: .overlay) ?? OverlayPresentationConfig()
    }

    public static var empty: PresentationConfig { PresentationConfig() }
}

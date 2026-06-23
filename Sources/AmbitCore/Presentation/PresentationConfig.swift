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

public struct PresentationConfig: Equatable, Sendable, Codable {
    public var entityOverrides: [EntityID: EntityPresentationOverride]
    public var integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride]

    public init(
        entityOverrides: [EntityID: EntityPresentationOverride] = [:],
        integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride] = [:]
    ) {
        self.entityOverrides = entityOverrides
        self.integrationOverrides = integrationOverrides
    }

    public static var empty: PresentationConfig { PresentationConfig() }
}

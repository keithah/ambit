import Foundation

// Menu-bar slot model (presentation-model.md §3). A slot binds a SELECTION of entities /
// integrations to (a) a compact bar readout and (b) a popover surface rendered through the
// card primitives. Dedicated and combined are the same mechanism, different selections.
// UI-free: the chrome that renders slots lives in AmbitMenuBar.

public struct SlotID: StringIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// What a slot is bound to. `.integrationType` resolves to the integration's CURRENT enabled
/// instances at render time — no stored membership list to go stale as hosts come and go.
public enum SlotSelection: Equatable, Sendable, Codable {
    case integration(IntegrationInstanceID)        // one instance (single-instance integration, or one picked host)
    case integrations([IntegrationInstanceID])     // an explicit set of instances
    case integrationType(IntegrationID)            // all current instances of an integration (resolved live)
    case capability(ProviderCapability)            // modeled now; first-class capability-slot UI deferred post-P6
    case entities([EntityID])
}

/// How a slot's compact bar readout is chosen. `.dynamic` (highest-attention now) is wired in
/// P4 — in P3 it renders a STATIC primary-entity fallback. `.fixed` pins the bar to one entity.
public enum BarReadoutMode: Equatable, Sendable, Codable {
    case dynamic
    case fixed(EntityID)
}

public struct Slot: Identifiable, Equatable, Sendable, Codable {
    public var id: SlotID
    public var title: String?
    public var selection: SlotSelection
    public var barReadout: BarReadoutMode

    public init(id: SlotID, title: String? = nil, selection: SlotSelection, barReadout: BarReadoutMode = .dynamic) {
        self.id = id
        self.title = title
        self.selection = selection
        self.barReadout = barReadout
    }
}

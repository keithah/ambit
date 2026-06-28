import AmbitCore
import AmbitUI

/// Per-slot value computed by StatusViewModel and consumed by the chrome.
struct SlotSurface {
    var plan: SurfacePlan
    var data: SurfaceData
    var glyph: MenuBarGlyph
    var primaryEntityID: EntityID?
    var selectedInstanceID: IntegrationInstanceID?
    var primaryInstanceID: IntegrationInstanceID?
    /// Options for the InstanceSelectorCard. Only shown when count > 1.
    var hostOptions: [InstanceSelectorCard.Option]

    @MainActor static let empty = SlotSurface(
        plan: SurfacePlan(),
        data: SurfaceData(),
        glyph: MenuBarGlyph(primaryText: "No Data", tone: .neutral),
        primaryEntityID: nil,
        selectedInstanceID: nil,
        primaryInstanceID: nil,
        hostOptions: []
    )
}

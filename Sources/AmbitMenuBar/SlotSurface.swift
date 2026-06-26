import AmbitCore
import AmbitUI

/// Per-slot value computed by StatusViewModel and consumed by the chrome.
struct SlotSurface {
    var plan: SurfacePlan
    var data: SurfaceData
    var glyph: MenuBarGlyph
    var primaryEntityID: EntityID?
    /// Options for the InstanceSelectorCard. Only shown when count > 1.
    var hostOptions: [InstanceSelectorCard.Option]

    @MainActor static let empty = SlotSurface(
        plan: SurfacePlan(),
        data: SurfaceData(),
        glyph: MenuBarGlyph(latencyText: "No Data", tone: .neutral),
        primaryEntityID: nil,
        hostOptions: []
    )
}

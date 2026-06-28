# Floating Overlay Generalization

Status: implementation spec for the final core feature-complete pass.

## Design Note

The floating overlay is a generic glance surface for a selected slot. It must not assume Ping, `slots.first`, or a host-only focus model. The overlay consumes the already-built `SlotSurface` for the selected `SlotID`, renders a compact subset of that surface through the same `SurfaceView` and cards as the popover, and uses the same `SlotReadoutSelector` result already stored in `SlotSurface.glyph` / `primaryEntityID`. Ping remains a first-class overlay because the selected Ping slot exposes a multi-instance focus list, not because the overlay knows about Ping.

## Contract

- Overlay state is `selectedSlotID: SlotID?`.
- The default selected slot is the first currently available slot.
- If the selected slot is deleted or no longer present, selection reconciles to the first available slot.
- The overlay can select any current slot at runtime, matching the status-item coordinator's reconciled slot list.
- Opening the popover from the overlay opens the selected slot's status item, not the first status item.
- Slot focus controls are generic:
  - Show a focus menu only when the selected surface exposes `hostOptions`.
  - The "All Hosts" label is generalized to "All Items".
  - Options remain `IntegrationInstanceID` values because `SlotSurfaceCoordinator` already resolves multi-instance slot focus that way.
- No integration-id branches are allowed in the overlay. Ping behavior is preserved by selecting the Ping slot and using its existing focus options.

## Rendering Rule

The overlay renders compact, glanceable cards from the selected `SlotSurface`:

1. Prefer history cards (`historyGraph`, `dualLineGraph`) because they fit the existing compact overlay use case.
2. If no history cards exist, fall back to the first bounded/status card from the selected surface so non-graph slots are not blank.
3. Use `SurfaceView(plan:data:)` unchanged. The overlay does not build bespoke cards.

This keeps the overlay useful for System and future integrations without making a dashboard-specific overlay layout.

## Test Plan

- Pure selection reconciliation: nil/default selects first slot; explicit selected slot is preserved; missing selected slot falls back to first; empty slots clear selection.
- Compact card extraction: graph cards are preferred; non-graph surfaces fall back to a first useful card.
- Popover routing: selected slot ID is used when invoking the status-item coordinator.
- Existing Ping overlay behavior remains: when Ping is selected, focus options drive `slotFocus` and the overlay uses the same graph cards as before.

# Multi-host Ping Parity

Date: 2026-06-27

## Reader And Outcome

Reader: an Ambit engineer implementing the next ping milestone.

After reading this spec, they should be able to implement pingscope-style multi-host ping behavior in Ambit without adding ping-specific UI branches. The goal is parity with the pingscope oracle's "All Hosts" popover mode while preserving Ambit's generic presentation shape.

## Scope

This milestone makes the ping slot work as a real multi-instance slot:

- "All Hosts" means a combined surface with one latency series per enabled ping host.
- A focused host means a single-host surface with the selected host's graph, sample history, diagnosis, and headline.
- Host switching is driven by the existing slot focus mechanism.
- The menu bar glyph and popover header use the same Core readout selection result.
- The graph, legend, axis, sample history, and failure behavior stay generic and reusable.

Out of scope:

- New bespoke ping settings UI.
- Notification redesign beyond preserving the ping alert bridge isolated by `PingDiagnosisCoordinator`.
- Overlay generalization. The overlay can later consume the same combined/focused slot surface contract.
- Per-host card customization. Available Items remains card-level, not host-series-level.

## Current Baseline

Ambit already has most of the primitives:

- A ping slot is `.integrationType("ping")`, so it resolves all enabled ping instances dynamically.
- `slotFocus[slotID] == nil` already represents "All Hosts"; a non-nil value represents a focused integration instance.
- `SlotSurfaceCoordinator` resolves the slot, loads history series, builds `SurfaceData`, and runs per-slot attention.
- `InstanceSelectorCard` can present "All Hosts" plus individual host options.
- `SurfaceData.graphLines` already maps multiple entity IDs to multiple graph lines with deterministic line colors.
- `GraphSeriesGeometry` already breaks lines on failed samples and exposes failure marks.
- `sampleHistory` is generic and bound to one measurement entity.

The missing piece is an explicit surface contract for combined mode. Today the ping surface happens to include multiple latency descriptors, but the intended combined graph, legend, sample-history binding, focus behavior, and headline selection are not documented or fully pinned down.

## UX Contract

### Combined: All Hosts

When a ping slot has multiple enabled hosts and no `slotFocus` entry, the popover header shows "All Hosts" and the detail graph is a combined multi-series latency graph:

- One line per enabled host.
- Lines use the host display name as the legend label.
- The graph uses a single shared axis across all host samples in the selected range.
- The primary/resting host is visually emphasized in the graph and legend.
- Non-primary lines are still visible but less dominant.
- The menu bar glyph and header headline resolve across all host candidates using the generic readout rule: active attention wins; otherwise the resting primary wins.

This matches pingscope's "All Hosts" behavior: the graph answers "how are all monitored hosts behaving together?" while the compact readout still answers "what should I look at now?"

### Focused Host

When `slotFocus[slotID]` is a ping instance ID, the popover becomes a single-host detail surface:

- Only that host's latency descriptor participates in graph/detail cards.
- The graph is a single latency series.
- The sample-history card binds to that host.
- Diagnosis banners still represent the network-level diagnosis, because diagnosis is about the whole monitored perspective, not only the selected host.
- The menu bar glyph and header use the same focused candidate set, so they cannot diverge.

### Host Switching

The header selector is the slot-level focus control:

- "All Hosts" clears `slotFocus[slotID]`.
- Selecting a host stores that host's `IntegrationInstanceID`.
- If the focused host disappears or is disabled, the coordinator treats it as no focus for rendering and the selector returns to "All Hosts" on the next refresh.
- Host options are built from enabled ping records resolved by the slot, in registry order.

This keeps host switching generic: it is a slot focus operation, not a ping view mode.

## Surface Composition Design

### Explicit Combined Mode

`SlotSurfaceCoordinator` should make the ping combined/focused state explicit before invoking the composer:

- `focusedInstanceID == nil` and more than one shown ping record: combined mode.
- `focusedInstanceID != nil`: focused mode.
- One enabled host: focused-equivalent mode, without showing an "All Hosts" selector.

In combined mode, the coordinator passes all shown latency descriptors to the detail composer, with each descriptor renamed to the host display name for graph legend/readout purposes. The primary host's descriptor should keep `isPrimary == true`; other latency descriptors should not become primary unless their source descriptor/override already says so. If multiple descriptors claim primary, Core's resting-primary priority rule breaks the tie.

The composer should emit one primary `historyGraph` card for the set of sibling latency measurement descriptors. This is not ping-specific: it is the existing generic rule for homogeneous measurements in one section. The graph becomes multi-series because the card has multiple entity IDs.

### SurfaceData And Series

`SurfaceData.series` must include history for every latency entity in the combined graph. Samples stay keyed by `EntityID`; line labels and colors are derived at render time from descriptors and entity order.

The coordinator should load samples for the graph range used by the card. For ping, that remains the selected `TimeRange` window until per-slot graph ranges replace the global ping range.

### Legend

The legend is a generic graph feature, not a ping-specific card:

- Any `historyGraph` with more than one line shows a compact legend.
- Legend label = descriptor name.
- Legend color = line color.
- The primary line is visually emphasized.
- Long labels truncate to one line.

The pingscope oracle caps visible legend entries to avoid crowding. Ambit should follow the same spirit: render the first few visible lines inline, ordered by descriptor order, and rely on the graph colors plus host selector for the rest. A future tooltip or expandable legend can expose all hosts if needed.

### Color Assignment

Color assignment must be deterministic and generic:

- The color index is the line's index in `CardSpec.entities`.
- A host keeps the same color as long as registry/order and card entity order are stable.
- Colors are not keyed by host names, addresses, provider IDs, or integration IDs.

This matches the existing `SurfaceData.graphLines` behavior and keeps the rule reusable for system/network/device multi-series graphs.

### Primary Emphasis

Graph line emphasis should be generic:

- The line whose entity ID equals `SlotSurface.primaryEntityID` is the emphasized line.
- If `primaryEntityID` is nil, emphasize the first entity in the card.
- Emphasis changes stroke width/opacity and legend weight, not the card identity.

This requires `SurfaceView` or `SurfaceData` to expose the selected primary entity to graph cards. The data model should carry a primary/selected entity ID for the current surface rather than making graph cards recompute attention.

## Recent Samples Rule

Decision: in combined mode, the recent-samples table follows the focused/headline host, not all hosts.

Rationale:

- The pingscope reference table is a single-host `Time | Result | Status` table.
- A combined table interleaving hosts would need a Host column, more vertical space, and different scan behavior.
- Ambit already has a single-entity `sampleHistory` card and the Available Items model can later add explicit per-host history cards if needed.
- The compact readout already resolves a primary entity across all hosts; binding sample history to that same entity keeps the table explainable.

Implementation contract:

- In focused mode, auto `sampleHistory` binds to the focused host's latency entity.
- In combined mode, auto `sampleHistory` binds to `SlotSurface.primaryEntityID` if that entity is a latency measurement.
- If the primary entity is a diagnosis banner or another non-latency entity because attention is active, fall back to the resting primary latency entity for sample history.
- Do not auto-render one sample-history card per host.

The card ID remains `history:<entityID>`, so Available Items customization stays leaf-card based.

## Failure Bars And Axis Scaling

Multi-host graph behavior follows the existing graph-fidelity rules:

- Failed samples are `value == nil` or `ok == false`.
- Failed samples break their line segment; they never plot as zero.
- In a multi-line graph, failure bars draw only for the primary/emphasized series.
- Bar constants stay the existing generic multi-line constants: red with lower opacity and thinner stroke than a single-line graph.
- Axis bounds are computed from non-nil, ok samples across all series plus current numeric states where relevant.
- A timeout/failure never inflates the axis and never forces a zero baseline beyond the normal axis resolver rules.

This is generic graph behavior; ping only supplies latency samples.

## Headline Selection

The menu bar glyph and popover header must consume one resolved primary result from Core:

- Candidates are built from all shown latency descriptors plus diagnosis entity, after focus filtering.
- `SlotReadoutSelector` resolves the primary entity and attention selection.
- `SlotSurface.primaryEntityID` stores that result.
- The glyph and header readout are produced from the same selected entity/state.
- Graph emphasis and sample-history binding consume the same `primaryEntityID` with the latency fallback described above.

This avoids the old class of bugs where the menu bar and popover chose different headline metrics.

## Generic vs Ping-specific

Generic:

- Slot focus state.
- Multi-series `historyGraph` card.
- Graph legend, line colors, primary emphasis, shared axis, failure geometry.
- Sample-history card shape and rows.
- Readout selection through `SlotReadoutSelector`.
- Available Items identity and customization.

Ping-specific:

- Which instances are considered ping hosts.
- Host option labels from ping integration records.
- Network diagnosis entity and ping alert event mapping.
- Latency-state backfill from recent ping samples.
- The current global ping range picker, until per-slot range settings replace it.

The ping-specific work should remain inside `SlotSurfaceCoordinator` and `PingDiagnosisCoordinator`. AmbitUI and SurfaceComposer should not branch on integration ID.

## Proposed Implementation Phases

### Phase A: Pin The Combined Surface Contract

Add tests around `SlotSurfaceCoordinator`:

- All-host mode with two ping records produces a surface with one multi-entity primary history graph.
- Focused mode filters descriptors, series, and sample history to the focused host.
- Host options include "All Hosts" behavior through nil focus and enabled host options.
- A missing focused host falls back to all-host rendering.

No UI changes in this phase unless the tests reveal an existing composer gap.

### Phase B: Graph Legend And Primary Emphasis

Add generic graph-model support for primary line identity:

- `SurfaceData` or graph model carries the current primary entity ID.
- Multi-line `HistoryGraphCard` emphasizes the primary line.
- Legend shows descriptor labels and deterministic colors.
- Tests cover color order, primary emphasis, and no ping-specific branches.

### Phase C: Sample History Binding

Make auto `sampleHistory` bind correctly in combined mode:

- Focused mode binds to focused latency entity.
- Combined mode binds to selected/resting primary latency entity.
- Active diagnosis can take the headline without causing the sample table to bind to the diagnosis entity.
- Tests cover attention override, resting fallback, and Available Items identity.

### Phase D: Popover Parity Eyeball

Run the app and compare against the pingscope oracle:

- "All Hosts" selector clears focus and shows combined graph.
- Selecting a host shows a single-host graph and recent samples for that host.
- Combined graph has one colored line per host, shared axis, legend, primary emphasis, and failure bars only for the primary line.
- Header/glyph stay in sync with Core selection.
- Ping diagnosis banner still surfaces generically.
- System slot remains unchanged.

## Test Plan

Core/pure tests:

- Slot resolver plus coordinator: all-host vs focused descriptor sets.
- Surface plan: multi-host latency descriptors become one `historyGraph` with multiple entities.
- Surface data: series loaded for every graph entity.
- Slot readout: healthy multi-host slot chooses resting primary; elevated host overrides; diagnosis can alert.
- Sample history: combined mode binds to primary latency fallback, focused mode binds to selected host.
- Axis resolver: multi-series latency axis ignores failed samples and shares max across hosts.

UI/model tests:

- Graph line model uses deterministic colors and labels.
- Primary line is emphasized without changing entity order.
- Legend truncates labels and omits empty/no-sample lines as needed.
- `InstanceSelectorCard` nil selection represents "All Hosts" and host selection stores raw integration instance ID.

Regression tests:

- System slot surfaces unchanged.
- Single-host ping slot still renders as a single-host surface.
- Existing sample-history and graph-fidelity tests stay green.

## Open Decisions

None blocking implementation.

Deferred decisions:

- Whether combined sample history should later support an optional Host column. Current decision is focused/headline-host only.
- Whether legend should expose more than the first few hosts through expansion. Current decision is compact inline legend.
- Whether ping range becomes a generic per-slot graph range setting. Current milestone keeps the existing ping range picker.

# History and Graph Fidelity

Date: 2026-06-26
Branch: `history-graph-fidelity`
Baseline: master `ad9dac8`, 534 tests green

## Goal

Bring Ambit's generic history presentation up to the fidelity of pingscope's detail popover without adding ping-specific UI. The ping detail surface should compose to the pingscope reference shape:

- labeled three-tick graph axis
- failure gaps and red vertical failure bars
- generic graph summaries with ping latency retaining TX/RX/Loss
- recent samples table
- export and clear from settings

Every primitive must remain reusable by system and future device integrations. The data source is already generic: `Sample(value:ok:metadata:)`, `SampleStats`, `HistoryService.samples/stats/clear`, and 7-day retention.

## Non-Goals

- No edits to `~/src/pingscope`.
- No integration-specific Ambit views or branches.
- No new history backend.
- No custom ping settings pane revival.
- No fabricated values for failed or missing samples.

## Existing Shape

Ambit already has:

- `Sample`: timestamp, optional numeric value, `ok`, optional metadata string.
- `SampleStats`: transmitted/received/loss/min/avg/max.
- `HistoryService`: records all `stateClass` measurements, returns samples/stats, prunes by retention, clears all samples.
- `GraphAxisResolver`: descriptor-driven axis model.
- `SurfaceComposer`: generic card plan and canonical `surfaceItems` for Available Items.
- `SurfaceData.series`: per-entity sample windows loaded by `StatusViewModel.historySeries(for:)`.
- `HistoryGraphCard` and `DualLineGraphCard`: AmbitUI renderers.

Current fidelity gaps:

- `GraphGeometry.points` maps `nil` values to zero, drawing false dips instead of failures.
- Graphs show only a top-right max label instead of pingscope's left labels + right ticks.
- Recent samples are not a generic card.
- Export is not generic.

## Oracle Details

From pingscope:

- Single-line failure mark:
  - draw when latency is nil
  - x is the sample's evenly-spaced index position
  - y from `plotTop + plotHeight * 0.2` to `plotTop + plotHeight`
  - color `.red.opacity(0.72)`
  - line width `1.5`
- Multi-line failure mark:
  - draw only for the primary series
  - color `.red.opacity(0.55)`
  - line width `1.2`
- Shows-axes graph layout:
  - left labels at `[axisMax, axisMax / 2, 0]`
  - monospaced 9pt secondary text
  - label column width 34
  - graph/right-tick spacing 6
  - right tick marks 6x1, secondary opacity 0.45
  - graph vertical padding 6
  - gridlines at all three ticks
- Recent samples table:
  - columns: Time, Result, Status
  - success result is unit-formatted value
  - failure result is failure reason from metadata, red
  - status is OK/Failed
  - most recent first, capped to about 8 rows

## Phase A: Graph Fidelity

### Graph Geometry

Replace `GraphGeometry.points(samples:in:axisMax:)` as the rendering contract with a geometry model that preserves missing/failed samples:

```swift
public struct GraphSeriesGeometry: Equatable, Sendable {
    public var segments: [[CGPoint]]
    public var failureXPositions: [CGFloat]
}

public enum GraphGeometry {
    public static func series(
        samples: [Sample],
        in size: CGSize,
        axisMax: Double,
        plotVerticalPadding: CGFloat = 0
    ) -> GraphSeriesGeometry
}
```

Rules:

- A sample is failed when `sample.value == nil || sample.ok == false`.
- Failed samples are not plotted as zero.
- Failed samples terminate the current line segment.
- Adjacent successful samples form a drawable segment.
- A one-point success segment is returned as a one-point segment for future marker support, but the Canvas may skip stroking it.
- `failureXPositions` uses the same index-to-x mapping as pingscope.
- Axis clamping remains: values above `axisMax` draw at the top.

Existing `niceMax` stays as a UI helper where needed, but card rendering should prefer `GraphAxisResolver`.

Tests:

- nil sample splits two successful runs into two segments.
- `ok == false` with a non-nil value is treated as failure and not plotted.
- failure x positions match sample index spacing.
- one-sample and empty windows do not invent a line.
- Ping and system samples use the same geometry path.

### Failure Rendering

`HistoryGraphCard` draws failure marks from `GraphSeriesGeometry.failureXPositions`.

Single-line cards:

- `.red.opacity(0.72)`
- line width `1.5`
- y from 20% of plot height to baseline

Multi-line cards:

- only the primary line emits failure bars
- `.red.opacity(0.55)`
- line width `1.2`

Primary line is generic:

- for `DualLineGraphCard`, the first line after composer ordering is primary for failure bars.
- for multi-entity `historyGraph`, the first entity in `CardSpec.entities` is primary.
- a later descriptor-level primary line hint can refine this, but the initial rule is deterministic and integration-free.

### Labeled Axis

Add a graph axis tick helper:

```swift
public struct GraphAxisTick: Equatable, Sendable {
    public var value: Double
    public var label: String
}

public enum GraphAxisTicks {
    public static func ticks(axis: GraphAxis, descriptor: EntityDescriptor?) -> [GraphAxisTick]
}
```

Rules:

- If `axis.max` is present, ticks are `[max, max / 2, 0]`.
- Labels use `EntityReadout.format(_:deviceClass:unit:)`.
- If `axis.isEmpty`, non-zero labels render as `"--"` and zero renders unit-aware zero.
- The plotted scale remains `GraphAxisResolver.axis(...)`.
- `showsAxes == true` replaces the old top-right max label with:
  - left label column
  - gridlines
  - right ticks
- `showsAxes == false` keeps the compact card shape for dense dashboard cards.

Drive `showsAxes` from the detail surface:

- `showsAxes` is per-card, not a blanket popover setting.
- The slot's primary or featured graph gets `showsAxes: true`.
- Ping's detail graph gets `showsAxes: true` because it is the featured graph in that surface.
- Dense dashboards with many graphs keep secondary graphs compact (`showsAxes: false`) so a 34pt gutter and right ticks do not crowd the 420pt popover.
- The rule is generic: surface density + `CardRole.primary`/featured position decides, never integration ID.

Tests:

- percent axis labels `100%`, `50%`, `0%`.
- latency axis labels in ms.
- load/count axis labels are not percent.
- empty axis does not invent a max.
- `HistoryGraphCard` no longer renders the top-right max label when `showsAxes` is true.

## Phase B: Recent Samples Card

Add a generic card kind:

```swift
public enum CardKind {
    case sampleHistory
}

public struct SampleHistoryRow: Equatable, Sendable {
    public var timestamp: Date
    public var result: String
    public var isFailure: Bool
    public var status: String
}

public enum SampleHistoryModel {
    public static func rows(
        samples: [Sample],
        descriptor: EntityDescriptor,
        limit: Int
    ) -> [SampleHistoryRow]
}
```

Binding:

- `CardSpec.entities` contains exactly one measurement `EntityID`.
- `SurfaceData.series[id]` supplies rows.
- Rows are most-recent-first.
- Default cap is 8, with the same cap plumbing style as stat tables.
- Empty state says no samples for the selected range.
- In a multi-entity slot, the table follows the same resolved focus/primary entity used by the graph header and glyph. For a multi-host ping slot this means the focused host when focus is set, otherwise the resolved primary/resting host. The sample table never independently picks a different host.

Row semantics:

- Time: sample timestamp, rendered as time in AmbitUI.
- Result success: `EntityReadout.format(value, deviceClass: descriptor.deviceClass, unit: descriptor.unit)`.
- Result failure:
  - `sample.metadata` when non-empty
  - otherwise `"Failed"`
  - red foreground
- Status:
  - `"OK"` only when `sample.ok == true && sample.value != nil`
  - `"Failed"` otherwise

Composer and Available Items:

- The canonical `SurfaceComposer.surfaceItems` path must own sample-history item IDs.
- For every measurement descriptor with `stateClass == .measurement`, the composer can expose a selectable `sampleHistory` item.
- Auto layout includes `sampleHistory` only for latency measurement entities that are primary in their section. This matches the ping detail surface generically by `DeviceClass.latency`, not by integration ID.
- Other measurement entities can be added through Available Items.
- `SurfaceItemID` should be stable and leaf-only, for example `history:<entityID>`.

Tests:

- success/failure row mapping, including metadata reason and red/failure flag.
- most-recent-first ordering.
- row cap.
- empty state model.
- SurfaceComposer emits a default sample-history item for a primary latency measurement.
- Available Items lists sample-history candidates for non-latency measurements without auto-showing them.
- Multi-host ping focus changes the bound sample-history entity to the same host used by the graph/glyph.
- Ping surface gains the recent samples card; system remains unchanged unless explicitly customized.

## Phase C: Generic History Export and Settings Pane

### Core Export

Add AmbitCore export primitives:

```swift
public enum HistoryExportFormat: String, CaseIterable, Sendable, Codable {
    case csv
    case json
    case text
}

public struct HistoryExportRow: Equatable, Sendable, Codable {
    public var timestamp: Date
    public var name: String
    public var value: Double?
    public var ok: Bool
    public var unit: String?
    public var metadata: String?
}

public enum HistoryExport {
    public static func data(
        rows: [HistoryExportRow],
        format: HistoryExportFormat
    ) throws -> Data
}
```

Columns:

- `timestamp` ISO8601
- `name` descriptor name
- `value` numeric value or empty
- `ok` boolean or OK/Failed depending format
- `unit`
- `metadata`

CSV:

- header row is always present.
- fields are CSV-escaped for commas, quotes, and newlines.
- failure rows keep empty value and preserve metadata.

JSON:

- pretty printed, sorted keys, ISO8601 dates.
- includes generated metadata only if needed; row shape is stable.

Text:

- human-readable title, sample count, then timestamp/value/status lines.
- generalized from pingscope's text export, no host-specific fields.

Querying:

- Entity export uses `HistoryService.samples(id:since:limit:)`.
- Slot export resolves a slot through `SlotResolver`, filters measurement descriptors, and exports rows for each descriptor.
- Range uses existing `GraphRange` seconds where possible; settings may offer retention-wide export.

Tests:

- CSV escaping for quotes, commas, and newlines.
- success and failure rows in all formats.
- unit/name preservation.
- deterministic JSON output.

### Settings Pane

Add a generic History pane to `AmbitSettings`.

Sidebar:

- Add "History" next to Slots.

Pane:

- entity/slot picker driven by `PresentationSettingsModel`, registry descriptors, and slots.
- range picker using existing graph ranges plus retention-wide option.
- retention label, e.g. "Retained for 7 days".
- export buttons for CSV/JSON/Text.
- Clear action calling `HistoryService.clear`.

No integration-specific panes or field names.

Implementation seams:

- `StatusViewModel` owns async export/clear helpers because it already owns `Engine` and `HistoryService` access indirectly.
- If `Engine` does not expose enough history query access, add UI-free methods there rather than reaching into stores from SwiftUI.
- Export button writes through a save panel in AmbitMenuBar, but formatting stays in AmbitCore.

Tests:

- export helper maps descriptors + samples to rows.
- clear invokes `HistoryService.clear` and removes subsequent query results.
- settings model exposes enough descriptors/slots for the pane without provider branches.

## Data Honesty

- `nil` and failed samples never become zero.
- Failed samples are visible as graph bars, table failures, and export rows.
- Axis bounds ignore failed samples, including samples with a numeric value but `ok == false`; failures/timeouts never inflate the max and never force a zero baseline beyond the normal zero-baseline rule.
- Empty windows render an empty state, not a fabricated max or flat zero line.
- Metadata is treated as opaque text; card/export code may display it but must not parse provider-specific structure.

## Implementation Phases

### Commit 1: Design

Write this spec and keep build/test green.

### Phase A1: GraphGeometry failure segments

- Add `GraphSeriesGeometry`.
- Replace tests that currently assert nil maps to zero.
- Keep existing graph rendering compiling, then wire cards in A2.

### Phase A2: Failure bars in graph cards

- Update `HistoryGraphCard` and `DualLineGraphCard`.
- Draw single-line and multi-line failure bars with pingscope constants.
- Tests cover geometry and card model seams where practical.

### Phase A3: showsAxes graph layout

- Add `GraphAxisTicks`.
- Add `showsAxes` to graph cards.
- Render left labels, gridlines, and right ticks.
- Use detail popover graph cards with `showsAxes: true`.

### Phase B1: sampleHistory model and card vocabulary

- Add `.sampleHistory`, model rows, and AmbitUI card.
- Unit tests for row mapping/order/cap.

### Phase B2: composer and data wiring

- Add sample-history candidates to `SurfaceComposer.surfaceItems`.
- Auto-include primary latency sample history.
- Load series for those cards through existing history paths.
- Tests prove ping gains the card and system is unaffected unless customized.

Eyeball checkpoint after Phase A/B:

- Ping detail graph matches pingscope's axis layout.
- Failed samples break the line and show red bars.
- Recent samples table appears below the graph/stats.
- System graphs still use generic axes and do not show ping-only vocabulary.

### Phase C1: HistoryExport core

- Add AmbitCore exporter and tests for CSV/JSON/Text.

### Phase C2: History settings pane

- Add generic History pane to `AmbitSettings`.
- Add `StatusViewModel` export/clear helpers.
- Tests for pure mapping and clear behavior.

Final eyeball checkpoint:

- Export a ping entity and a system entity.
- Clear history and confirm graphs/tables show empty states.
- Ping and system surfaces still compose through generic primitives.

## Merge Criteria

- `swift build` green.
- `swift test` green, no regression from 534 baseline.
- No integration-specific UI branches.
- No edits under `~/src/pingscope`.
- User eyeball passes for graph axes, failure bars, sample table, and export/clear workflow.

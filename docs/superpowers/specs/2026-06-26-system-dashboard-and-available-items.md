# System Dashboard And Available Items Design

## Goal

This milestone turns the P6 `system` integration from a proof-of-plumbing surface into an
iStat-style dashboard while preserving Ambit's core presentation thesis:

```text
EntityDescriptor + EntityState + history
  -> SurfaceComposer
  -> CardSpec / SurfacePlan
  -> AmbitUI
```

There is no integration-specific UI. If the system dashboard needs a visual or layout concept
that the generic presentation layer does not have, this milestone adds the missing generic
primitive and proves it with system entities. The same primitives must be reusable by the
rebuilt device integrations that follow.

The milestone also adds a per-slot "Available Items" customization palette. Users can add,
remove, and reorder the cards/entities shown in a slot without creating provider-specific
settings screens.

## Non-Negotiable Invariants

- `AmbitCore` remains UI-free.
- No `if system`, `if ping`, or provider-ID branches in `AmbitUI` or `AmbitMenuBar`.
- Dashboard composition is driven by descriptor metadata: `kind`, `deviceClass`, `capability`,
  `stateClass`, `graphStyle`, `isPrimary`, `priority`, and presentation overrides.
- Missing data is honest. A no-op reader must not fabricate temperatures, fan speeds, or
  "down" states for hardware it cannot observe.
- Ping remains visually and behaviorally stable unless a generic bug fix intentionally improves
  both ping and system.

## Current Shape

The current generic vocabulary is sufficient for P6's proof but not for the denser dashboard:

- `CardKind`: `statusRow`, `gauge`, `historyGraph`, `dualLineGraph`, `progress`, `statTable`,
  `control`, `instanceSelector`, `section`, `statusBanner`.
- `GraphStyle`: `sparkline`, `gauge`, `progress`, `none`.
- `SurfaceComposer.detailPlan` groups by known capability sections: CPU, Memory, Disk,
  Network, Power, Sensors, Fans, State, Controls, Other.
- `CardSpec.children` already supports container cards for sections. This milestone extends
  that mechanism instead of introducing a separate dashboard model.
- `PresentationConfig` stores entity overrides, integration overrides, and slots. It does not
  yet store per-slot card inclusion or order.

The iStat-style target asks for several concepts that do not yet exist generically: segmented
rings, breakdown legends, per-core grids, horizontal card rows, better axis rules, and explicit
per-slot item ordering.

## Generic Card Vocabulary Additions

### `segmentedRing`

A ring/progress visualization split into labeled proportional segments. It is generic over any
set of sibling measurement entities whose values form parts of a whole.

Examples:

- Memory app / wired / compressed / free.
- Storage used / available if future descriptors expose components.
- Power load composition for later device integrations.

Binding rule:

- `CardSpec.kind = .segmentedRing`
- `CardSpec.entities = [EntityID]` for segment entities.
- Segment labels come from descriptor names.
- Segment values come from numeric `EntityState.value`.
- Segment total comes from either the sum of segment values or a sibling total descriptor when
  the composer can identify one from the same capability/device class and unit.

### `breakdownLegend`

A dense labeled value list that complements a graph or segmented ring. It uses the same
descriptor/state binding as a status row group but renders as a compact legend with stable
ordering and optional tones.

Examples:

- Memory App / Wired / Compressed / Free in GB.
- Disk Used / Available / Total.
- Network In / Out totals if later providers expose them.

Binding rule:

- `CardSpec.kind = .breakdownLegend`
- `CardSpec.entities = [EntityID]`
- Values are rendered through `EntityReadout`.
- Ordering is descriptor `priority` first, then existing stable order.

### `coreGrid`

A compact grid of small bounded gauges for a set of homogeneous per-core or per-channel
measurements.

Examples:

- CPU per-core usage.
- Per-cell battery telemetry in a future power-station integration.
- Per-port link utilization in a router integration.

Binding rule:

- `CardSpec.kind = .coreGrid`
- `CardSpec.entities = [EntityID]`
- All entities must share capability, device class, and unit.
- Percent metrics are bounded to `0...100`; non-percent grid metrics use the generic axis model.

### `cardRow`

A layout container that places two or three small cards side-by-side within the single-column
popover. This is a presentation primitive, not a system-only layout.

Examples:

- CPU usage + memory pressure ring pair.
- Temperature / GPU / fan trio when real values exist.
- Battery percent + charging state pair in a future power dashboard.

Binding rule:

- `CardSpec.kind = .cardRow`
- `CardSpec.children = [CardSpec]`
- Child cards remain normal card specs and are independently testable.
- `CardSpec.entities` is empty for the row container.

`cardRow` is preferred over adding ad hoc grouping fields to leaf cards because the existing
section model already uses container children. It also keeps layout decisions in the plan where
tests can assert them.

## Generic Composition Rules

`SurfaceComposer` continues to produce a default surface from descriptors when a slot has no
explicit customization. The default layout is deterministic and metadata-driven.

### Sectioning

Existing capability sectioning stays authoritative:

- `system.cpu` and later device CPU-like telemetry -> CPU.
- `system.memory` -> Memory.
- `system.disk` -> Disk.
- `system.network` and ping latency/throughput -> Network.
- `power.battery` -> Power.
- `system.sensors` -> Sensors.
- `system.fans` -> Fans.
- Diagnostic text with elevated severity -> State/status banner.

This milestone does not add integration IDs to sectioning. New device integrations must either
reuse existing capability prefixes or add new capability taxonomy entries.

### Pairing And Grouping

The composer can infer richer cards when entities share a capability and complementary names,
metric IDs, or device classes:

- `user` + `system` CPU percentages -> `dualLineGraph`.
- `in` + `out`, `download` + `upload`, or `rx` + `tx` throughput -> `dualLineGraph`.
- Multiple homogeneous percent children with core-like names -> `coreGrid`.
- Multiple component values plus a total/free value -> `segmentedRing` and `breakdownLegend`.
- Two or three small bounded gauges in the same section -> `cardRow`.

Inference is conservative. If a set does not match a generic pattern, the composer falls back to
existing `gauge`, `progress`, `historyGraph`, `statTable`, or `statusRow` cards.

### Label De-Duplication

Card titles should not repeat section titles when the card is the only eponymous child of that
section. The generic rule:

- If a section contains exactly one child card and the child title normalizes to the section
  title, the child title is omitted.
- If a multi-entity card has a legend, the card title may be omitted so entity labels carry the
  meaning.

This removes cases like `CPU` section + `CPU` gauge caption without special-casing CPU.

## Per-Metric Axis Model

Graph axes must derive from metric semantics and observed data, not a hardcoded percent range.
The current `HistoryGraphCard` already computes a nice max from samples, but callers and summary
formatting still need a formal rule so load, throughput, latency, and percent values behave
consistently.

Add a UI-free axis decision helper in Core, for example:

```swift
public struct GraphAxis: Equatable, Sendable {
    public var min: Double
    public var max: Double
    public var unitLabel: String?
    public var isFixed: Bool
}

public enum GraphAxisResolver {
    public static func axis(
        descriptor: EntityDescriptor,
        samples: [Sample],
        currentValue: EntityState?
    ) -> GraphAxis
}
```

Rules:

- `DeviceClass.percent` and `DeviceClass.battery`: fixed `0...100`.
- `GraphStyle.progress` with a descriptor `range`: fixed to that range.
- Latency, throughput, load/level, count, duration, and data size: auto-scale from observed
  samples plus current value using a "nice max" function and a zero baseline.
- Temperature and fan speed: auto-scale unless a descriptor range exists.
- Empty sample sets use the current value if present; otherwise they render an unavailable or
  empty state without inventing a maximum.

AmbitUI cards receive the resolved axis or resolve it from descriptor + `SurfaceData`; they do
not special-case system load or network throughput.

## Primary Readout Selection

The dynamic attention engine is correct for exceptional states, but a healthy slot also needs a
stable headline metric. Today the system slot can surface network throughput because throughput
is a changing measurement and attention has no generic "resting primary" preference strong
enough to beat it.

The generic rule:

1. If the slot readout mode is `.fixed`, use that entity.
2. If an entity is alerted, pinned, or currently surfaced by attention, use the attention result.
3. For healthy/resting slots, prefer visible descriptors in this order:
   - `isPrimary == true`
   - higher `priority`
   - enabled and not `GlanceVisibility.never`
   - online over stale over unavailable
   - stable descriptor order as the final tie-break
4. If multiple integrations are intentionally combined in one slot, apply the same rule to the
   resolved descriptor set; do not branch on integration type.

For `system@local`, this should naturally choose CPU because the CPU usage descriptor is primary
and high priority. Future router or power integrations get the same behavior by marking their
headline descriptor primary.

## Data Source Gaps And Honesty

The current system surface revealed several data-source and rendering gaps. They should be fixed
in generic provider/model terms.

### Add Public macOS Readers

Public APIs should cover these clean wins:

- Uptime: `sysctl` / boot time -> `DeviceClass.duration`, capability `system.cpu` or
  `system.host` if a host capability is added.
- Memory pressure: `host_statistics64` / VM counters -> percent or level descriptor under
  `system.memory`.
- Per-core CPU usage: `host_processor_info` -> homogeneous percent descriptors under
  `system.cpu`, grouped into `coreGrid`.
- Memory breakdown: VM counters for wired, compressed, free, and a clearly documented
  app/active approximation. Labels must not imply precision beyond the public data.

### Omit Private Or Fabricated Values

- GPU telemetry requires private or unstable APIs and is omitted for now.
- SMC temperature/fan readers remain optional. If no real reader is available, providers should
  omit temperature/fan descriptors rather than showing clamped placeholders such as `100 C` or
  `Down`.
- If a real reader was available and then fails transiently, keeping known descriptors with
  `.unavailable` states is acceptable because the item represents real hardware. The no-op
  reader should not create fake hardware.

### Network Interface Noise

Aggregate network throughput excludes loopback today. This milestone should also reduce visible
interface table noise generically:

- Keep physical and active interfaces.
- Hide virtual interfaces with zero traffic over the sampled window by default.
- Continue to allow tables to expose loopback/virtual rows when an explicit descriptor or
  future advanced setting asks for raw detail.

## Dual-Line Graph Binding

`dualLineGraph` is already part of the vocabulary, but the live CPU user/system graph exposed a
binding gap: the card can render an axis without plotting lines when its entities do not receive
series data or colors correctly.

Fix rule:

- `CardSpec.entities` is the source of truth for all graph lines.
- `SurfaceData.series[id]` must be populated for every graph entity that has history.
- AmbitUI assigns deterministic complementary colors by line index or display role.
- A dual-line card with no samples renders an empty state; it does not silently draw only axes.

## Available Items Model

Available Items is a generic per-slot customization layer over the auto-composed surface. It
does not replace descriptor defaults; it records user intent for one slot.

### Stable Surface Item Identity

Cards derived from one or more descriptors need stable IDs so settings can persist inclusion and
order. Existing `CardSpec.id` strings are already stable for simple cards (`card.<entityID>`) and
sections. This milestone formalizes that into a `SurfaceItemID` convention:

```swift
public struct SurfaceItemID: StringIdentifier {
    public let rawValue: String
}
```

Examples:

- `entity:<entityID>` for a single-entity card.
- `group:<capability>:<role>` for inferred groups such as CPU user/system or memory breakdown.
- `section:<sectionName>` for section containers when needed by settings previews.

The exact stored ID can remain a string as long as it is deterministic and covered by tests.

### Slot Customization

Extend `PresentationConfig` with per-slot customization, for example:

```swift
public struct SlotPresentationOverride: Equatable, Sendable, Codable {
    public var shownItems: [SurfaceItemID]?
    public var hiddenItems: Set<SurfaceItemID>
}
```

`shownItems == nil` means "use auto layout." Once the user edits a slot, `shownItems` becomes
the explicit ordered list. `hiddenItems` lets the UI remember intentionally removed auto items
without deleting the underlying entity override. If a referenced item disappears because an
integration is disabled or a provider no longer exposes it, the composer skips it; if it returns,
the stable ID can place it back in the user's order.

Entity-level overrides remain the source of truth for generic visibility, pinned state, alert
policy, thresholds, graph style, and enabled/show. Slot customization answers a narrower
question: "which cards are on this slot surface, and in what order?"

### Composer Behavior

`SurfaceComposer` should expose two pure steps:

1. Build candidate cards from descriptors/states/config using the default generic composition
   rules.
2. Apply slot customization:
   - If there is no explicit customization, return the default plan.
   - If `shownItems` exists, include only matching candidate cards in that order.
   - Missing candidate cards are skipped without deleting the stored preference.
   - Keep section grouping coherent after filtering and ordering.

This keeps auto layout and customized layout using the same `CardSpec` vocabulary.
Attention can still choose a bar readout from the resolved entity set; slot surface
customization controls the popover card list, not the existence of the underlying entities.

### Settings UI

The existing `AmbitSettings` window gets a generic slot editor:

- Left pane: configured dashboard items for the selected slot, in order.
- Right pane: Available Items, derived from descriptors and candidate cards not currently shown.
- Actions: add, remove, move up/down or drag reorder.
- Persistence: writes `SlotPresentationOverride` through `PresentationConfigStore` and rebuilds
  `PresentationSettingsModel`.

The editor is driven by `Slot`, resolved descriptors, `SurfaceComposer` candidates, and
`IntegrationConfigSchema`. It does not contain provider-specific panes.

## Phasing

### Phase 0: Design Doc

Commit this spec and review it before implementation.

### Phase A1: `segmentedRing`

- Add `CardKind.segmentedRing`.
- Add composer rules for proportional sibling metrics.
- Add AmbitCore tests for plan generation.
- Add AmbitUI rendering and small model tests where practical.

### Phase A2: `breakdownLegend`

- Add `CardKind.breakdownLegend`.
- Reuse `EntityReadout` for formatting.
- Add composer tests for memory-like component descriptors.

### Phase A3: `coreGrid`

- Add `CardKind.coreGrid`.
- Add generic grouping for homogeneous per-core/channel descriptors.
- Add tests for percent grid and non-percent fallback behavior.

### Phase A4: `cardRow`

- Add `CardKind.cardRow` as a container using `CardSpec.children`.
- Teach composer to group small gauges/progress cards conservatively.
- Add tests that row grouping preserves child card identity and section order.

### Phase A5: Generic Data And Rendering Fixes

- Add `GraphAxis` / axis resolver and wire graph cards to it.
- Fix resting primary readout selection so primary/priority wins when the slot is healthy.
- Fix no-op sensor/fan honesty by omitting fabricated descriptors.
- De-duplicate eponymous card labels.
- Fix `dualLineGraph` series binding.
- Filter inactive virtual network interfaces from default tables.
- Add public readers for uptime, memory pressure, memory breakdown, and per-core CPU.

### Phase B: AmbitUI Dashboard Polish

- Render new card kinds with dense, production styling in the fixed-width scrollable popover.
- Verify the System popover reads like the iStat reference while remaining a generic surface.
- Eyeball checkpoint before merge: live values, correct axes, no duplicate labels, CPU graph
  plots, no fabricated temperatures/fans, Ping unchanged.

### Phase C: Available Items Palette

- Add slot customization model to `PresentationConfig`.
- Add pure composer filtering/ordering tests.
- Add generic slot editor in `AmbitSettings`.
- Eyeball checkpoint before merge: add/remove/reorder a System card, confirm popover updates and
  persists across relaunch.

## Test Strategy

- AmbitCore tests assert `SurfaceComposer` output for representative descriptor sets; no SwiftUI
  needed for composition.
- Axis resolver tests cover percent, battery, load/level, throughput, latency, empty samples,
  and descriptor ranges.
- Provider tests use fake readers for uptime, memory pressure, per-core CPU, and sensor/fan
  unavailable behavior.
- AmbitUI tests cover view-model transforms where possible; final visual quality is validated
  by eyeball checkpoints.
- Existing ping surface and slot tests must stay green throughout.

## Merge Criteria

- One commit per logical step.
- `swift build` and `swift test` are green before every commit.
- The 478-test baseline does not regress.
- Phase B and Phase C eyeball checkpoints pass.
- No integration-specific UI branches are introduced.
- The branch is merged using the finishing-a-development-branch flow, and `HANDOFF.md` is updated
  with the new master baseline.

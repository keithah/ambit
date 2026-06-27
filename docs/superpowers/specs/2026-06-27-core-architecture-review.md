# Core Architecture Review

Date: 2026-06-27  
Baseline: `master` at `68d524a`, 567 tests green before this doc-only review

This is a read-only architecture audit for the next core-hardening pass. It reviews the generic seams that now carry Ping, System, settings customization, history, and graph presentation. Ratings are:

- **Solid**: coherent shape, current behavior is well covered, safe to build on.
- **Needs work**: generally sound, but has naming drift, overloaded responsibilities, or missing seams that will slow the next feature.
- **Risky**: likely to cause regressions or design debt if the next milestone builds directly on it.

## Executive Summary

The thesis architecture is real: `EntityDescriptor`/`EntityState` flow through `EntityEnricher`, `AttentionEngine`, `SurfaceComposer`, generic `CardSpec`s, and `AmbitUI` without provider-specific card views. `PresentationSettingsModel`, `IntegrationConfigSchema`, entity overrides, slot overrides, and `HistoryExport` are also generic enough to support the next device integrations.

The main hardening concern is not the Core model. It is orchestration: `Sources/AmbitMenuBar/StatusViewModel.swift` is 1,513 lines and currently owns registry migration, slot seeding/backfill, polling lifecycle, alert delivery, attention state, history export, settings mutation, ping diagnosis composition, slot focus, and surface building. That makes otherwise clean Core primitives easy to misuse. Two confirmed examples:

- `StatusViewModel` stores one shared `AttentionEngine`, while `AttentionEngine.evaluate(...)` prunes `states` to the current candidate set on every call. Because each slot is evaluated with a different candidate set, debounce/boost state can be evicted across slots.
- `MenuBarAppModel` creates `StatusBarController`s once in `init` from `viewModel.slots`. Launch-time slot backfill works, but runtime slot changes are not reconciled into new or removed status items.

Recommended order before feature work: first isolate per-slot orchestration and attention state, then do multi-host ping parity, then generic notifications/alerts, then floating overlay generalization.

## Seam Ratings

| Seam | Rating | Summary |
| --- | --- | --- |
| Entity model | Needs work | Strong descriptor/state base, but taxonomy and composition metadata are carrying several meanings. |
| Composition | Needs work | Generic and heavily tested, but `SurfaceComposer` is now a dense rule engine with inferred roles and several layout passes in one type. |
| Attention | Risky | The model is good, but shared mutable engine state is not isolated per slot. |
| Settings/customization | Needs work | Generic renderer is real; schema and slot customization need credential/config extensibility and thinner view-model boundaries. |
| History | Solid | Clear actor/store/export shape; minor gaps around retention configurability and scoped clear. |
| Slots/status items/StatusViewModel | Risky | Slot model is strong, AppKit status-item lifecycle and view-model responsibilities are the weak seam. |
| Tests | Solid with UI gaps | Pure Core coverage is strong; runtime AppKit, settings UI, notification delivery, and overlay behavior rely more on eyeball passes. |

## Entity Model

Rating: **Needs work**

Reviewed types:

- `EntityDescriptor`, `EntityState`, `EntityKind`, `DeviceClass`, `EntityCategory`, `StateClass`, `EntityCompositionRole`, `TableValue` in `Sources/AmbitCore/Entity.swift`
- System descriptors in `Sources/AmbitCore/System/SystemOverviewProvider.swift`, `SystemStorageProvider.swift`, `SystemProcessProvider.swift`, `SystemNetworkProvider.swift`, `SystemSensorProvider.swift`
- Ping descriptors in `Sources/AmbitCore/Ping/PingProvider.swift` and diagnosis descriptors in `Sources/AmbitCore/Ping/DiagnosisEntity.swift`

What is solid:

- Static descriptor vs dynamic state is the correct split. `EntityDescriptor` owns identity, metadata, defaults, and composition hints; `EntityState` owns value, availability, freshness, error, and severity.
- `EntityValue.table(TableValue)` plus `TableColumn`, `TableRow`, and `TableCellValue` is the right generic primitive for process, disk, interface, and future device tables.
- `stateClass` gates history feed and graph eligibility cleanly. The System and history milestones proved this for latency, CPU, load, network, memory, and uptime.
- `compositionRole` has stayed small and reusable: `.segment`, `.remainder`, `.total`, `.channel`.

Gaps and drift:

- `DeviceClass` and `capability` both influence formatting, sectioning, graph axes, grouping, and semantic meaning. That works today, but the boundary is informal. Example: `system.cpu` sectioning comes from capability, while graph/format behavior comes from `DeviceClass.percent` or `DeviceClass.count`. New integrations can easily choose one correctly and the other incorrectly.
- `DeviceClass.count` is being used for load because there is no first-class `.level` or `.load` device class in the new entity model. That was the right fix to stop load from looking like percent, but it is semantically coarse.
- `EntityCategory.primary` overlaps conceptually with `EntityDescriptor.isPrimary`. Category now means broad row type (`primary`, `diagnostic`, `config`), while `isPrimary` means slot readout preference. The names are close enough that future provider authors can confuse them.
- `metricID` exists on `EntityDescriptor`, but identity and grouping mainly use `id`, `name`, `capability`, `deviceClass`, `unit`, and `compositionRole`. `metricID` is used by pairing heuristics, not as a first-class metric identity contract.
- `EntityCompositionRole` lacks a role token or grouping discriminator beyond the enum. `SurfaceComposer` must infer group identity from capability + deviceClass + unit, then infer dual-line role from names/ids/metric IDs. That is generic, but fragile.
- Legacy metric projection code still lives alongside the entity model (`Metric`, `MetricValue`, `EntityProjection`, default descriptors). Some of it is still needed for old provider snapshots and alert rules, but the boundary between “legacy bridge” and “current model” is not obvious.

Recommendation:

- Keep the current model for the next feature. Do not redesign it first.
- Add a small taxonomy doc or tests for “how to choose capability vs deviceClass vs compositionRole” before rebuilding device integrations.
- Consider adding a generic role/group hint later, not provider-specific fields. The likely shape is a reusable `compositionGroup`/`compositionRole` pair, but this should wait until gl.inet or another device proves the need.

## Composition

Rating: **Needs work**

Reviewed types:

- `SurfaceComposer` and `SurfaceComposer.SurfaceItem` in `Sources/AmbitCore/Presentation/SurfaceComposer.swift`
- `CardKind`, `CardSpec`, `SurfacePlan`, `CardRole` in `Sources/AmbitCore/Presentation/CardSpec.swift`
- `GraphAxisResolver` in `Sources/AmbitCore/Presentation/GraphAxis.swift`
- `GraphAxisTicks` in `Sources/AmbitCore/Presentation/GraphAxisTicks.swift`
- `GraphSeriesGeometry` and `GraphFailureMarkStyle` in `Sources/AmbitUI/GraphGeometry.swift`
- `SurfaceView`, `HistoryGraphCard`, `DualLineGraphCard`, `SampleHistoryCard`, `SegmentedRingCard`, `BreakdownLegendCard`, `CoreGridCard`, `StatTableCard` in `Sources/AmbitUI`

What is solid:

- `CardSpec` is the right abstraction: UI-free decisions in Core, value/history binding in `SurfaceData`, rendering in AmbitUI.
- The card vocabulary is now broad enough for Ping, System, and the likely device integrations: `statusRow`, `gauge`, `historyGraph`, `dualLineGraph`, `sampleHistory`, `segmentedRing`, `breakdownLegend`, `coreGrid`, `cardRow`, `progress`, `statTable`, `control`, `instanceSelector`, `section`, `statusBanner`.
- `SurfaceComposer.surfaceItems(...)` is the single source of truth for Available Items identity and labels. This is the right API for preventing drift between settings and rendering.
- `GraphAxisResolver` is UI-free, unit-aware enough for current data, and correctly excludes failed samples from bounds.
- `GraphSeriesGeometry.series(...)` returns line segments and failure positions, which fixed the historic nil-as-zero graph bug.

Gaps and drift:

- `SurfaceComposer` is now 593 lines and combines section classification, ordering, card inference, group inference, surface item identity, slot customization, table row limits, sample-history defaults, title de-duplication, and card-row layout. It is still pure and tested, but it has become a rule engine rather than a small composer.
- Sectioning is hard-coded around current generic capabilities (`system.cpu`, `system.memory`, `system.disk`, `system.network`, `power.battery`, `system.sensors`, `system.fans`). That is acceptable, but the capability taxonomy now needs to be treated as a public contract.
- Dual-line pairing is inferred from tokens in descriptor `name`, `metricID`, and `id` (`user/system`, `in/out`, `rx/tx`). This kept descriptors simple, but it is fragile for routers and device integrations that use different terms.
- `sampleHistory` auto-inclusion is intentionally limited to primary latency measurements. That matches Ping parity, but it is a generic-card exception inside `SurfaceComposer`.
- `cardRow` IDs are positional (`row:<section>:<index>`), which is fine because rows are not customization units. That invariant is documented, but it should stay well tested as explicit ordering grows.
- `GraphGeometry.points(...)` still exists with an obsolete comment and behavior that maps missing values to zero. The newer `series(...)` path is the correct one. If no caller still needs `points(...)`, this is a low-risk cleanup candidate.
- `SurfaceView` computes graph axes from descriptors and series and often passes `currentState: nil`. That is fine when history exists, but it weakens the `GraphAxisResolver` design for empty-history/current-value cases.

Recommendation:

- Extract `SurfaceComposer` into small pure helper types before adding many more card inference rules: `SectionClassifier`, `CardInference`, `CompositionGrouping`, `SurfaceItemCatalog`, and `SlotCustomizationPass`.
- Keep inferred pairing for now, but expect a generic grouping/role hint if gl.inet exposes labels that do not fit the current token rules.
- Remove or quarantine obsolete graph geometry APIs once tests confirm no live use.

## Attention

Rating: **Risky**

Reviewed types:

- `EntityEnricher` in `Sources/AmbitCore/Presentation/EntityEnricher.swift`
- `AttentionEngine`, `AttentionSelection`, `AttentionCandidate`, `AttentionReason`, `SurfacedEntity` in `Sources/AmbitCore/Presentation/AttentionEngine.swift`
- `StatusSlotReadout` and `StatusSlotSurfaceBuilder` in `Sources/AmbitMenuBar/StatusViewModel.swift`
- Diagnosis integration in `DiagnosisEntity` and `PingAlertMonitor`

What is solid:

- The model is conceptually right: enriched state feeds attention; alerts are explicit `EntityID`s; lanes are surface-capacity based; resting primary is distinct from active attention.
- Debounce and transition boost are deterministic and testable.
- `EntityEnricher` suppresses display-threshold escalation when availability is stale/unavailable, avoiding false “down” behavior for stale samples.
- `StatusSlotReadout` implements the important resting-primary rule: active attention only overrides when a lane is elevated, alerted, pinned, boosted, or otherwise genuinely active.

Confirmed fragile edge:

- `AttentionEngine` owns `private var states: [EntityID: AttentionState]` and begins every `evaluate(...)` by filtering `states` to the candidate IDs for that call. `StatusViewModel` owns one `private var attentionEngine = AttentionEngine()` and passes it into both ping and generic slot surface builders. With multiple slots, evaluating the System slot can prune Ping attention state and evaluating Ping can prune System attention state. This weakens consecutive-sample debounce and transition boost across slots.

Other gaps:

- The canonical “slot primary” decision lives in `StatusSlotReadout` under AmbitMenuBar, not in AmbitCore. The same result is passed into the popover today, but the logic is not reusable by non-macOS surfaces.
- Alert events are still rule/provider keyed (`AlertEvent.providerID`, `ruleID`) and mapped to entities at call sites, with a special network diagnosis mapping for Ping. That was intentional for P4, but notifications will need a generic entity-targeted alert path.
- Staleness is enriched upstream and sampled by a `staleTickTask` in `StatusViewModel`, so presentation freshness depends on menu-bar orchestration rather than a small reusable scheduler/coordinator.

Recommendation:

- Before multi-host parity or notifications, isolate attention state per slot/surface. Options:
  - Store `[SlotID: AttentionEngine]` in `StatusViewModel`.
  - Or make `AttentionEngine` state key include `SurfaceID`/`SlotID`.
- Move `StatusSlotReadout` or its pure selection rule into AmbitCore after the per-slot state fix, so menu bar, popover, overlay, widgets, and future iOS surfaces share one primary-selection function.

## Settings and Customization

Rating: **Needs work**

Reviewed types:

- `IntegrationConfigSchema`, `IntegrationConfigField`, `ConfigFieldKind`, `IntegrationInstanceDraft` in `Sources/AmbitCore/Presentation/IntegrationConfigSchema.swift`
- `EntityPresentationOverride`, `SlotPresentationOverride`, `PresentationConfig` in `Sources/AmbitCore/Presentation/PresentationConfig.swift`
- `PresentationSettingsModel`, `IntegrationSettingsGroup`, `EntitySettingsRow` in `Sources/AmbitCore/Presentation/PresentationSettingsModel.swift`
- `AmbitSettings` in `Sources/AmbitMenuBar/AmbitSettings.swift`
- settings helpers in `StatusViewModel`

What is solid:

- Settings are now descriptor/schema/config driven. `PingSettings.swift` is gone, and Ping host editing, diagnosis sensitivity, visibility, pinning, advanced graph/threshold/alert controls, and history export all flow through generic models.
- `SlotPresentationOverride` has the right core states: auto, auto-minus-hidden, and explicit ordered `shownItems`, with `hiddenItems` and `tableRowLimit`.
- `SurfaceComposer.surfaceItems(...)` prevents settings from re-deriving unstable card IDs.
- `PresentationSettingsModel.build(...)` includes config-excluded/hidden entities in settings rows, which is correct for a management surface.

Gaps:

- `IntegrationConfigSchema` supports `.text`, `.number`, `.toggle`, `.select`, but not credential/password/keychain semantics. The gl.inet rebuild will need router password handling; forcing that through plain `.text` would be a security and UX regression.
- `IntegrationInstanceDraft` is generic, but `StatusViewModel.saveIntegrationInstanceDraft(...)` is still expected to know how to turn schema values into concrete integration records. That may be enough for Ping, but it is not yet a complete generic integration-instance factory.
- `AmbitSettings.swift` is 1,274 lines. It is generic, but it owns many panes and local form models in one file. This mirrors the `StatusViewModel` responsibility problem at the UI layer.
- `tableRowLimit` is slot-wide. It solved the first real need, but future customization may need per-item limits or card options.
- Clear history is global (`HistoryService.clear()`), while the settings UI offers target selection for export. A targeted clear will likely be expected once history settings are used heavily.

Recommendation:

- Add `ConfigFieldKind.secureText` or an equivalent credential primitive before rebuilding gl.inet.
- Extract generic settings panes into smaller SwiftUI files after this audit, without changing behavior.
- Keep Available Items exactly as designed for the next feature; it is the right seam.

## History

Rating: **Solid**

Reviewed types:

- `Sample`, `SampleStats` in `Sources/AmbitCore/History/SampleSeries.swift`
- `HistoryService` in `Sources/AmbitCore/History/HistoryService.swift`
- `HistoryStore`, `InMemoryHistoryStore`, `SQLiteHistoryStore` in `Sources/AmbitCore/History`
- `HistoryExport`, `HistoryExportTarget`, `HistoryExportRange`, `HistoryExportRow` in `Sources/AmbitCore/History/HistoryExport.swift`
- `SampleHistoryModel` and `SampleHistoryCard`

What is solid:

- `HistoryService` is an actor with a store abstraction. That is the right concurrency boundary.
- Retention and pruning are centralized. Default seven-day retention is simple and proven.
- `Sample(value:nil)` and `ok:false` now have honest graph and export semantics.
- `HistoryExport` is generic across entity and slot targets, and CSV/JSON/Text formatting is covered by tests.
- `sampleHistory` is bound by `history:<entityID>` and uses the same entity/sample model as graphs.

Gaps:

- `HistoryExportRange.retention.label` is hard-coded as “7 days” rather than derived from `HistoryService.retentionInterval`.
- `HistoryService.clear()` clears all history only. That is acceptable for the first History pane, but the generic target picker sets user expectations for targeted clear.
- `Sample.metadata` is a single optional string. It is enough for failure reason display/export, but not enough for richer diagnostics without ad hoc parsing.
- SQLite store migration/versioning is not visible in the current API. That is not urgent while stored rows are simple, but export and longer-lived installs make it worth tracking.

Recommendation:

- Leave history as-is for the next core feature unless that feature needs targeted clear.
- Low-risk cleanup: make retention labels derive from the actual configured retention interval.

## Slot Model, Status Items, and StatusViewModel

Rating: **Risky**

Reviewed types:

- `Slot`, `SlotSelection`, `SlotResolver` in `Sources/AmbitCore/Presentation`
- slot seeding/backfill, surface building, settings helpers, history export helpers, and readout selection in `Sources/AmbitMenuBar/StatusViewModel.swift`
- `MenuBarAppModel`, `StatusBarController`, `SettingsWindowController` in `Sources/AmbitMenuBar/App.swift`
- `SlotPopover` and `PingOverlay`

What is solid:

- Slot selection is generic enough: `.integration`, `.integrations`, `.integrationType`, `.capability`, `.entities`.
- Launch-time backfill now adds enabled built-in non-ping integrations like `system@local`, and disabled legacy device integrations stay disabled.
- Generic non-ping slot surfaces work through `SlotResolver`, `StatusSlotSurfaceBuilder.genericSurface`, `AttentionEngine`, `SurfaceComposer`, and `SlotPopover`.

Confirmed gaps:

- Runtime status-item reconciliation is still launch-only. `MenuBarAppModel.init` maps `viewModel.slots` once into `StatusBarController`s. If settings add/delete/reorder slots at runtime, AppKit status items are not reconciled until relaunch.
- `OverlayView` is still ping-coupled. It assumes “the ping slot is always slots.first” and uses host options plus graph cards from that slot. That is the right target for the overlay generalization milestone, but it is not generic today.
- `StatusBarController.updateGlyph(...)` still names the tooltip as `"\(title) · \(glyph.latencyText)"`; the type `MenuBarGlyph` also has `latencyText`. The behavior is generic enough, but naming still carries Ping vocabulary.
- `StatusViewModel.swift` is 1,513 lines and is doing too much. This is the largest architectural risk in the codebase.

Recommended decomposition:

- `SlotSurfaceCoordinator`: builds `SlotSurface`s from slots, descriptors, states, history, focus, and config.
- `AttentionCoordinator`: owns one attention engine per slot/surface and readout selection.
- `PresentationSettingsController`: owns settings mutations and `PresentationSettingsModel` rebuilds.
- `HistoryExportController`: owns target options, export row assembly, and clear.
- `PingDiagnosisCoordinator`: isolates Ping-specific diagnosis and alert-ID mapping until it can be generalized.
- `MenuBarStatusItemCoordinator`: observes slot changes and reconciles `StatusBarController`s.

## Test Coverage Shape

Rating: **Solid with UI gaps**

What is strong:

- Core model and pure composition are well covered: `SurfaceComposerTests`, `SystemSurfaceComposerTests`, `CardSpecTests`, `GraphAxisResolverTests`, `GraphAxisTicksTests`, `GraphGeometryTests`, `SampleHistoryModelTests`, `HistoryExportTests`, `PresentationSettingsModelTests`, `PresentationConfigTests`.
- Attention and enrichment have focused tests: `AttentionEngineTests`, `EntityEnricherTests`, `SystemSlotAttentionTests`, `StatusViewModelDynamicSlotTests`.
- System providers and readers have good fake-reader coverage.
- History has both in-memory and SQLite tests.

Gaps:

- Runtime AppKit behavior is lightly tested or eyeballed: status-item reconciliation, popover behavior, scroll preservation, settings window save panels, and overlay behavior.
- The shared `AttentionEngine` across multiple slots is not covered by a test that evaluates two slots sequentially and expects both slots’ debounce/boost state to persist.
- Notification delivery through `UserNotifications` is not covered end-to-end.
- Available Items UI was manually click-tested; the pure `surfaceItems`/composer path is covered, but the SwiftUI editor is not deeply unit-tested.
- Visual fidelity still depends on screenshot/eyeball review for density, graph rendering, and popover layout.

Recommendation:

- Add a small number of orchestration tests before feature work:
  - two-slot attention state isolation,
  - runtime slot reconciliation,
  - overlay uses a supplied slot rather than `slots.first`,
  - notification event mapping from alert event to entity.

## Readiness: Multi-Host Ping Parity

Assessment: **Ready after attention/status-view-model hardening**

Already present:

- Ping slots resolve all Ping instances via `.integrationType(IntegrationIDs.ping)`.
- `SlotPopover` supports host focus with `slotFocus` and `InstanceSelectorCard`.
- Ping detail data already renames latency descriptors to host display names for multi-host legends.
- History graphs, failure bars, labeled axes, and `sampleHistory` now match the pingscope detail shape.
- `DiagnosisEntity` and `PingAlertMonitor` feed generic state/banner/attention paths.

Missing:

- A clean “All Hosts combined vs focused host” surface contract. The current Ping path filters descriptors based on `slotFocus`, but combined graph/table semantics should be made explicit.
- Multi-series legend behavior should be tested for all-host graph parity.
- Recent samples currently follow the primary/focused latency entity. That matches the latest decision, but combined mode needs a clear rule: table for focused host only, or a combined per-host recent table.
- Ping-specific diagnosis/history building remains embedded in `StatusViewModel`.

Prerequisites:

- Fix per-slot attention state.
- Extract Ping surface assembly out of `StatusViewModel` so multi-host parity does not add another large block there.

## Readiness: Notifications and Alerts

Assessment: **Partially ready; needs entity-targeted alert bridge**

Already present:

- `AlertEngine` supports threshold, state transition, sustained rules, cooldown, and recovery events.
- `AlertPolicy` exists and is surfaced in generic advanced settings.
- `PingAlertMonitor` handles ping host and network diagnosis alert events.
- `AttentionEngine` can accept `alertingIDs` and promote alerted entities.

Missing:

- `AlertEvent` is still rule/provider keyed, not entity keyed. The current entity mapping happens at call sites.
- `AlertRule.defaultRules` still contains legacy provider IDs (`starlink`, `vpn`, `ecoflow`) while those integrations are disabled/rebuilt later. This is not harmful, but it is architectural drift.
- Notification delivery is menu-bar-specific and not modeled as a generic service with testable permission, delivery, and recovery behavior.
- `AlertPolicy` is latency-flavored (`highLatencyMs`, `highLatencyConsecutive`) despite being generic by name.

Prerequisites:

- Introduce a generic `AlertTarget`/entity-targeted alert event or a pure mapper from provider/rule events to `EntityID`.
- Split notification delivery from `StatusViewModel`.
- Decide whether `AlertPolicy` is truly generic or should have typed policy variants.

## Readiness: Floating Overlay Generalization

Assessment: **Not ready until slot orchestration is cleaner**

Already present:

- Overlay rendering uses `SurfaceView`, `SurfacePlan`, and graph cards rather than bespoke drawing.
- The card vocabulary can already describe a small glanceable surface.

Current coupling:

- `Sources/AmbitMenuBar/PingOverlay.swift` assumes the ping slot is `viewModel.slots.first`.
- The overlay host context menu is Ping-specific (`Host`, `All Hosts`, host options).
- `MenuBarAppModel` wires overlay open-popover behavior to the first `StatusBarController`.
- The overlay chooses graph cards by flattening the current ping surface, not by a generic overlay policy or attention/slot configuration.

Prerequisites:

- Runtime slot/status-item reconciliation.
- A generic `OverlaySurface` or slot-selected overlay configuration.
- Shared readout/attention selection in Core, so overlay and menu bar agree on what is important.
- Multi-host Ping parity first, because the overlay’s current useful behavior is a compact multi-host graph.

## Recommended Sequencing

1. **Prerequisite hardening**
   - Isolate `AttentionEngine` state per slot/surface.
   - Extract slot-surface building and readout selection out of `StatusViewModel`.
   - Add runtime status-item reconciliation or explicitly lock slot changes to relaunch-only with UI copy.
   - Remove stale Ping vocabulary from generic types where cheap (`latencyText` naming, graph comments).

2. **Multi-host Ping parity**
   - Build on the graph/history fidelity work while the pingscope oracle is fresh.
   - Clarify combined vs focused semantics in tests.
   - Keep diagnosis through generic `DiagnosisEntity` and status banners.

3. **Notifications and alerts**
   - Add the entity-targeted alert bridge.
   - Make recovery notifications and cooldown behavior visible through generic settings.
   - Test without relying on live `UserNotifications`.

4. **Floating overlay generalization**
   - Convert `PingOverlay` into a slot-driven generic glance surface.
   - Then add Ping-specific convenience only through slot focus/options, not overlay-specific branching.

Device integrations can proceed in parallel only after credential schema and per-slot attention are fixed. gl.inet in particular will need a secure config field and a clean provider-to-entity mapping, but it should not require new UI primitives.

## Low-Risk Cleanups Worth Doing First

- Add a regression test for two-slot sequential attention evaluation, then fix with per-slot `AttentionEngine` ownership.
- Add a launch/runtime status-item reconciliation test around `MenuBarAppModel` or a small extracted coordinator.
- Rename `MenuBarGlyph.latencyText` to a neutral name such as `primaryText` and update tooltip wording.
- Remove or deprecate `GraphGeometry.points(...)` if no live renderer uses it; its nil-as-zero behavior contradicts the new graph fidelity rules.
- Make `HistoryExportRange.retention.label` derive from the actual retention interval.
- Extract `SurfaceComposer` helper passes into separate pure types without behavior changes.
- Split `AmbitSettings.swift` by pane and `StatusViewModel.swift` by responsibility, preserving public behavior.
- Add a secure config field primitive before the gl.inet rebuild.


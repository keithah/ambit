# Ambit Generic Presentation Layer — Design Spec

**Date:** 2026-06-23
**Status:** Approved (design). Source spec: `presentation-model.md`. Read with `entity-model.md`,
`integration-model.md`, `provider-capability-model.md`, `engine-topology.md`, `MIGRATION_PLAN.md`.

**Goal:** Build Ambit's generic, opinionated presentation layer so integrations render consistently
whether 2 or 20 are loaded — replacing pingscope's bespoke M5 UI — then prove it with a second, very
different integration (`system`, iStat-style). Ambit owns the chrome + a fixed card vocabulary;
integrations contribute entities + presentation *defaults*, never views.

---

## 0. Ground truth (what already exists — do not re-build)

The Core **data** layer is built and is already generic:

- **Entity model** (`Sources/AmbitCore/Entity.swift`): `EntityDescriptor`, `EntityState`,
  `EntityProjection`, and the enums `EntityKind`, `DeviceClass`, `EntityCategory`, `EntityAccess`,
  `StateClass`, `EntityValue`, `Availability`; `CommandRef` with `fixedArguments` fan-out.
- **Identity** (`Sources/AmbitCore/Identity.swift`): instance-scoped, engine-independent
  `IntegrationID` / `IntegrationInstanceID` / `ProviderInstanceID` / `EntityID`. No `EngineID` in any id.
- **Engines:** `HistoryService` (actor, keyed by `EntityID`, `Sample`/`SampleStats`/`SampleSeries`,
  retention/prune, swappable `HistoryStore`); `AlertEngine` (threshold / state-transition / sustained
  rules, cooldown/recovery, consecutive-sample debounce via `AlertRuleState`); `HealthState`
  (stateful `ingest`, tracks `consecutiveFailures` + `lastFailureTransition`/`lastRecoveryTransition`).
- **Registry:** `Integration` protocol + `IntegrationRegistry` + 8 built-in integrations; PingScope is
  a real multi-instance integration (`PingScopeProvider` per host, `NetworkPerspectiveDiagnosis`).

**The gap is purely presentation.** `AmbitMenuBar` is 5 SwiftUI files (macOS 13), all pingscope-bespoke
(`PingScopePopover` Canvas graph + stats grid + recent-samples table + host selector + diagnosis banner;
`PingScopeOverlay`; `PingScopeSettings`; a pingscope-shaped `StatusViewModel`; `App`). The menu bar today
renders **only** pingscope. A parallel, pre-entity display path exists in Core
(`ProviderDisplayModel` / `ProviderSurfaceModel` / `ProviderMetricSection`, all `Metric`-based) and is
**being retired** in favor of the entity-driven binding layer below.

This program is therefore "build the generic surface over an already-generic data model," not a data refactor.

---

## 1. Module structure

| Target | Role |
|---|---|
| `AmbitCore` | UI-free. **Gains:** card-binding model (`CardSpec`/`SurfacePlan`/`SurfaceComposer`), slot model, `AttentionEngine`, `PresentationConfig`, descriptor presentation-default fields. |
| `AmbitUI` | **NEW** SwiftUI library (macOS 13+, iOS-ready). The card vocabulary views, slot/popover chrome, generic settings renderer. Depends on `AmbitCore`. |
| `AmbitMenuBar` | Thin: status-item wiring + `AmbitUI`. `StatusViewModel` shrinks to a slot host. |
| `AmbitCheck` | Can dump `SurfacePlan` / `AttentionSelection` headlessly — proof the layer is UI-free. |

`AmbitCore` keeps its hard rule: **no SwiftUI/AppKit imports.**

---

## 2. The layout/value split (makes the layer testable & headless-dumpable)

The **"which card, bound to what" decision is UI-free and lives in Core** so `AmbitCheck` and unit tests
assert it without SwiftUI. **Values flow separately:** cards read live `EntityState` from the snapshot +
`HistoryService` for time series. Layout is stable; values are high-frequency.

```swift
// Render-agnostic plan for one surface (popover or glance).
public struct SurfacePlan: Equatable, Sendable { public var cards: [CardSpec] }

public struct CardSpec: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: CardKind
    public var title: String?
    public var entities: [EntityID]      // binding: 1 for a gauge, 2 for dual-line, N for a table
    public var graphStyle: GraphStyle?   // sensor visualizations
    public var children: [CardSpec]      // for .section
    public var role: CardRole            // primary | secondary | banner
}

public enum CardKind: String, Equatable, Sendable, Codable {
    case statusRow, gauge, historyGraph, dualLineGraph, progress,
         statTable, control, instanceSelector, section, statusBanner
}
public enum GraphStyle: String, Sendable, Codable { case sparkline, gauge, progress, none }

// The entity-driven composer that REPLACES ProviderDisplayModel/SurfaceModel/MetricSection.
public enum SurfaceComposer {
    public static func detailPlan(descriptors: [EntityDescriptor],
                                  states: [EntityID: EntityState],
                                  config: PresentationConfig) -> SurfacePlan
}
```

- `control` resolves toggle/select/number/button from the entity's `kind` + `CommandRef` (already in the descriptor).
- `statTable` covers grouped rows incl. process tables and disk lists — **no separate process-table card kind.**
  Its **tabular binding** (how a group of entities maps to columns/rows; how a top-N process list binds) is
  the one substantive design item left open; **settle it in P6's detailed plan** where the real driver appears.

---

## 3. Descriptor presentation-defaults (additive; land in **P1**, not P5 — the composer needs them)

```swift
extension EntityDescriptor {
    public var defaultVisibility: GlanceVisibility   // .auto default — additive; existing descriptors unaffected
    public var displayThreshold: DisplayThreshold?   // surface tier; SEPARATE from the alert threshold
    public var graphStyle: GraphStyle?
    public var isPrimary: Bool
    public var priority: Int?
}
public enum GlanceVisibility: String, Sendable, Codable { case always, auto, never }
public struct DisplayThreshold: Equatable, Sendable, Codable {
    public var comparison: AlertComparison           // reuse existing enum
    public var value: Double
    public var consecutive: Int                      // debounce, reuses the M4 pattern
}
```

All optional/defaulted — existing descriptors keep compiling. The user overrides every field via `PresentationConfig` (§6).

---

## 4. Slot model

```swift
public struct Slot: Identifiable, Equatable, Sendable, Codable {
    public var id: SlotID
    public var title: String?
    public var selection: SlotSelection
    public var barReadout: BarReadoutMode    // .dynamic (attention) | .fixed(EntityID)
}
public enum SlotSelection: Equatable, Sendable, Codable {
    case integration(IntegrationInstanceID)          // dedicated
    case integrations([IntegrationInstanceID])       // combined
    case capability(ProviderCapability)              // capability surface (modeled now; UI deferred — §8)
    case entities([EntityID])
}
```

Dedicated and combined are the **same mechanism**, different bindings. The menu-bar chrome renders one
status item per slot; each slot → a bar readout + a popover rendered from `SurfacePlan`.

---

## 5. Attention engine (the new third Core service, alongside History/Alert)

```swift
public enum AttentionTier: Int, Sendable, Codable { case detail, surfaced, alerted }
public enum Severity: Int, Sendable { case normal, elevated, degraded, alerting, down } // ascending rank

public struct AttentionItem: Equatable, Sendable {
    public var entity: EntityID
    public var tier: AttentionTier
    public var severity: Severity
    public var score: Double
    public var reason: String            // "ping 142ms > 100ms display, sustained 4, priority 3"
}
public struct SurfaceCapacity: Equatable, Sendable {
    public var lanes: Int
    public var overflow: OverflowMode    // .glyph | .plusN | .rotate
}
public struct AttentionSelection: Equatable, Sendable {
    public var pinned: [AttentionItem]
    public var surfaced: [AttentionItem]
    public var overflowCount: Int
    public var alerted: [AttentionItem]
}
public actor AttentionEngine {
    public func evaluate(snapshot: EngineSnapshot,
                         descriptors: [EntityID: EntityDescriptor],
                         config: AttentionConfig,
                         capacity: SurfaceCapacity,
                         now: Date) -> AttentionSelection
}
```

- **Consumer, not new detection:** reads `HealthState` / `AlertEngine` state, reuses their debounce.
- **Three tiers** with **separate display vs alert thresholds** (detail → surfaced → alerted).
- **Visibility rule per entity:** `always` (reserved lane) · `never` (detail-only) · `auto` (conditional
  on health/alert/display-threshold).
- **Ranking:** `score = pinned-reserved ⊕ severity ⊕ transitionBoost`, transitionBoost from the transition
  timestamps `HealthState` already tracks. Stable tie-break to avoid churn.
- **Surface-agnostic:** Dynamic Island / Live Activity / Watch are later *renderers*, not a rebuild.
- Emits a **reason** per surfaced item (explainability; on-thesis determinism).

---

## 6. Settings & config store

`PresentationConfig` (Codable, persisted) holds per-entity / per-integration overrides + the slot list.
The generic 3-depth settings renderer (in `AmbitUI`) is generated from entities + descriptor defaults and
writes overrides. **No bespoke per-provider settings.**

```swift
public struct PresentationConfig: Codable, Equatable, Sendable {
    public var entityOverrides: [EntityID: EntityPresentationOverride]
    public var integrationOverrides: [IntegrationInstanceID: IntegrationPresentationOverride]
    public var slots: [Slot]
}
public struct EntityPresentationOverride: Codable, Equatable, Sendable {
    public var visibility: GlanceVisibility?
    public var pinned: Bool?
    public var displayThreshold: DisplayThreshold?
    public var alertPolicy: AlertPolicy?     // reuse existing type
    public var graphStyle: GraphStyle?
    public var enabled: Bool?
    public var interval: TimeInterval?
}
```

Three disclosure depths: (1) zero-setup defaults from descriptors; (2) per-integration show/hide/pin/enable;
(3) power drill-in (display threshold, alert threshold, graph range/style, alert preset, interval).

---

## 7. Milestones (each shippable + green; one small commit per step)

**Hard rules across all milestones:** `swift build` + `swift test` green after every step; one small commit
per step; never edit `~/src/pingscope` or `~/src/glinet-travel`; generic layers reusable by any integration;
no `EngineID` in any entity/instance id; the `system` integration adds **no** new UI — a gap is a missing
primitive, not a provider hook.

### P1 — `AmbitUI` target + card vocabulary + Core binding layer
- New `AmbitUI` library target.
- Core: `CardKind` / `CardSpec` / `SurfacePlan` / `GraphStyle` / `CardRole` + `SurfaceComposer`
  (entity-driven) + the descriptor presentation-default fields (§3).
- `AmbitUI`: one SwiftUI view per card kind, harvested from pingscope's M5 (`LatencyGraph` → generic
  `HistoryGraph`/sparkline; stats grid → `StatTable`; status dot/label → `StatusRow`; gauge/ring; progress;
  dual-line; controls; section; status banner; instance selector). History graph reads `HistoryService`.
- **Test retirement / port:** retiring `ProviderDisplayModel` / `ProviderSurfaceModel` /
  `ProviderMetricSection` legitimately deletes their tests (the "don't weaken tests" rule protects code that
  *stays*). **Port their grouping/binding coverage to `SurfaceComposer` tests** so coverage doesn't silently
  drop. (Deletion of the old models lands as consumers migrate, P1–P2.)
- Menubar untouched this milestone (additive).

### P2 — Pingscope renders through the primitives; delete its bespoke UI  ← **eyeball checkpoint**
- Popover / overlay / settings → generic `SurfaceView(plan:)` driven by `SurfaceComposer` over pingscope entities.
- Diagnosis banner → `statusBanner` primitive bound to a new pingscope **summary status entity** (expose
  `NetworkPerspectiveDiagnosis` as a text/status entity carrying severity).
- Per-host settings → generic config-entity settings (pingscope config-category entities already exist).
- Host menu → `instanceSelector` card.
- Delete `PingScopePopover` / `PingScopeSettings` bespoke code; shrink `StatusViewModel`.
- **Checkpoint:** this is the first real test of the "generic good enough to feel native" bet. After P2,
  the user looks at pingscope-through-generic-primitives: does it still feel first-class, or did the generic
  history graph regress vs the bespoke Canvas one? **If it regresses, fix the primitive before P6** — caught
  in a product the user knows well, not discovered at P6.

### P3 — Slot model + generic chrome
- Core: `Slot` / `SlotSelection` / `SlotID` + store (in `PresentationConfig`).
- Chrome renders one status item per slot; seed one dedicated pingscope slot (parity) + demonstrate a
  combined slot. Retire the hardcoded chrome.

### P4 — Attention engine + dynamic bar readout
- Core: `AttentionEngine` + `AttentionConfig` / `AttentionSelection` / `AttentionTier` / `Severity` /
  `SurfaceCapacity`. Consumes `EngineSnapshot` + Health/Alert state.
- Combined-slot readout becomes **dynamic** (highest-attention now); visibility/priority from descriptor
  defaults + overrides.
- Tests: ranking, debounce, overflow, reason emission, transition boost.

### P5 — Generic progressive-disclosure settings
- `AmbitUI`: 3-depth renderer generated from entities + descriptor defaults → writes `PresentationConfig`.
- Delete remaining bespoke pingscope settings.
- (Descriptor presentation-default fields already shipped in P1.)

### P6 — Second integration: `system` (iStat-style) — the thesis proof
- **Sequenced to de-risk the SMC gamble.** Prove the thesis with **public-API metrics first**:
  CPU (`host_statistics`/`host_processor_info`), memory (`vm_statistics`), disk (`statfs`), network
  (interface throughput), battery (IOKit). That alone demonstrates "renders through the same primitives,
  zero bespoke UI" — exercising gauge/ring, progress, dual-line, and `statTable` (process list).
- **SMC sensors/fans are a FLAGGED sub-step that degrades gracefully.** Private SMC access (possibly a
  helper / entitlement handling) is isolated in a platform module; if blocked, the same entity shapes show
  `.unavailable`. **The multi-provider proof must NOT depend on getting private SMC access working.**
- **Tabular binding** (§2) is settled here in the detailed plan, driven by the process/disk lists.
- Adds **no** provider UI hook. Any gap is a missing primitive, added to the vocabulary.

Dynamic Island / Live Activity / Watch remain deferred, but the Attention engine is built surface-agnostic
now so they are a renderer, not a rebuild.

---

## 8. Resolved open questions (from `presentation-model.md` §10)

- **Idle combined readout:** overall health dot + the single highest-`isPrimary` metric (not rotating).
- **Default lanes:** 3, then overflow to a `+N` glyph (configurable per surface).
- **Capability surfaces:** model `SlotSelection.capability` now; defer first-class capability-slot **UI** to post-P6.
- **Transition-boost decay:** linear over a configurable window (default 60s), magnitude ≈ one severity step.

---

## 9. Non-goals

- Not user-composed dashboards (HA Lovelace). Opinionated default layout; customization is
  show/hide/pin/threshold, not free-form composition.
- No bespoke per-provider UI or settings. Integrations contribute entities + defaults + (rarely) a primitive.
- No general "draw arbitrary UI" hook — turn "special" into new primitives.
- No data-model refactor — the entity/identity/engine layer is ground truth and reused as-is.

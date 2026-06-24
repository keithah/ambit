# P4 — Attention Engine — Design

**Date:** 2026-06-24
**Status:** Draft for design review (3 architecture decisions settled in brainstorming; pending plan approval).
**Read with:** `presentation-model.md` (§4 owns this), `entity-model.md`, `provider-capability-model.md`,
the hardening spec `2026-06-24-poll-resilience-staleness-design.md`. Code is ground truth.

**Goal:** Build the differentiator — glance surfaces show **what matters now**, not a statically-configured
metric. A generic, surface-agnostic `AmbitCore` service that consumes the entity set + health/alert state +
the user's visibility/priority config and emits, per surface, an **ordered selection with reasons**. Plus:
land the staleness fix's richer severity/attention integration (the `.stale` tier), and promote the
host-glued ping diagnosis banner to an attention-emitted entity.

This is a **consumer**, not a new detector (presentation-model.md §4b). It reuses `HealthState`, `AlertEngine`,
`Staleness`, and the already-shipped config hooks; it adds no new probing or threshold detection.

---

## 0. Ground truth — what already exists (the scaffolding)

P4's vocabulary was seeded across P1–P3 and the hardening task. Confirmed in the code:

- **Inputs:** `Severity {normal,elevated,degraded,alerting,down}` (Comparable, `Entity.swift:111`),
  `Availability {online,stale,unavailable}`, `HealthState` (stateful: status + consecutiveFailures +
  transition timestamps, `Health/HealthModel.swift`), `AlertEngine` (holds `AlertRuleState` across ticks),
  `Staleness` (pure, time-driven: `isStale`/`availability` of `(lastUpdate, interval, now)`).
- **Config hooks (all present, currently unread by any attention logic):**
  `EntityDescriptor.{defaultVisibility: GlanceVisibility, displayThreshold: DisplayThreshold?, isPrimary, priority}`
  and `EntityPresentationOverride.{visibility, pinned, displayThreshold, alertPolicy, priority?…}`.
  `GlanceVisibility {always,auto,never}`, `DisplayThreshold {comparison, value, consecutive}` (reuses
  `AlertComparison`), `AlertPolicy`.
- **Surface hooks:** `BarReadoutMode.dynamic` (Slot.swift) — wired in P4; **today it's a static
  primary-host fallback**. `DiagnosisEntity` already projects the cross-host diagnosis to a generic
  `.text`/banner entity **with a severity** (`Ping/DiagnosisEntity.swift`), but it is **host-glued** in
  `StatusViewModel.buildSlotSurface` behind an explicit `// P4:` TODO.
- **Gaps P4 fills:**
  1. `Engine.entityStates()` returns the **raw** projection — `severity` is always nil (except the diagnosis
     entity) and `.stale` is never produced there (staleness is applied ad-hoc inside `buildSlotSurface`).
  2. No general per-entity severity rule.
  3. The menu-bar glyph is computed from a single primary host, not attention-selected.
  4. No attention service, no surface-capacity/overflow model, no "reason" output.

---

## 1. Settled decisions (brainstorming)

1. **Severity locus → a pure `EntityEnricher` in Core.** `raw states + thresholds + alert-active + now →
   enriched states`. One enriched truth consumed by the detail view, the bar, and the AttentionEngine — no
   divergence, injected-clock testable. (Rejected: enrichment buried in AttentionEngine; or every consumer
   re-deriving.)
2. **Bar shape → engine emits an ordered (multi-lane-capable) selection; macOS renders `lane[0]`.** Ship
   single-value *visually*; do not hardwire single-value *architecturally*. Dynamic Island / Live Activity
   pick up more lanes later with zero engine change.
3. **Diagnosis + `.stale` → both flow through the AttentionEngine.** Ping keeps *producing* the cross-host
   diagnosis entity (integration-level domain logic); it enters the engine's candidate set like any other
   entity. The `buildSlotSurface` host-glue is cut. The `.stale`/"Monitoring paused" indication flows
   automatically because the enricher produces `.stale` availability and the visibility rule surfaces it.

**The through-line:** `EntityEnricher (pure, Core) → enriched entity set → AttentionEngine → ordered
selection → surface renders lane[0]`.

---

## 2. Layering

```
            descriptors ─┐
            raw states  ─┤
            HealthStatus ┤
EntityEnricher  ─────────┼─▶ enriched EntityState  ──▶ Engine.entityStates()  ──▶ detail surface (tones)
(pure, Core)    interval ┤        (.stale + severity)                          └─▶ AttentionEngine candidates
            displayThr.  ┤
            now          ┘

candidates ─┐
surfaces   ─┤ (capacity)
config     ─┼─▶ AttentionEngine.evaluate ──▶ [SurfaceID: AttentionSelection]  ──▶ bar renders lane[0]
alertingIDs ┤   (stateful across ticks)        (lanes + overflow + alerted, each with reason)   notifications
now        ─┘
```

- **`EntityEnricher`** is pure and instantaneous (no temporal state).
- **`AttentionEngine`** holds per-entity debounce/transition state across ticks — exactly mirroring how
  `AlertEngine` holds `AlertRuleState` (presentation-model.md §4e: "reuse M4's consecutive-samples
  debouncing").
- **Alert-active** is an *overlay*: `AlertEngine` keys events by rule/provider, not `EntityID`, so the caller
  maps fired alerts → the set of alerting `EntityID`s and hands that to the AttentionEngine. The enricher
  takes `alertActive` as an input field (default `false`); `Engine.entityStates()` passes `false` (it doesn't
  own alert evaluation), and the `.alerted` *tier* is assigned by the AttentionEngine from `alertingIDs`. This
  keeps "alerting" the `AlertEngine`'s job and the enricher a pure data+health+display function.

---

## 3. Key types & signatures

### 3a. `EntityEnricher` (new — `Sources/AmbitCore/Presentation/EntityEnricher.swift`)

```swift
/// Pure, UI-free. Folds freshness + health + the display threshold into a raw EntityState,
/// producing the .stale availability and the per-entity Severity that every surface reads.
/// No temporal state — staleness is a function of (lastUpdate, interval, now); the sustained-
/// samples debounce lives in AttentionEngine, not here.
public enum EntityEnricher {
    public struct Inputs: Sendable {
        public var descriptor: EntityDescriptor
        public var state: EntityState                 // raw, from EntityProjection
        public var interval: TimeInterval
        public var lastSampleAt: Date?                // newest history sample for this entity
        public var displayThreshold: DisplayThreshold?// effective (override ?? descriptor.displayThreshold)
        public var health: HealthStatus?              // backing provider's health, when known
        public var alertActive: Bool                  // default false; true only via the caller overlay
    }
    public static func enrich(_ input: Inputs, now: Date) -> EntityState
}
```

**The severity rule** (documented, deterministic — on-thesis "never a black box"):

```
avail = Staleness.availability(state.availability, lastSampleAt, interval, now)   // may downgrade .online → .stale

severity =
  .unavailable           → .down            // genuinely offline: a strong, surfaceable signal   (TUNABLE, §9)
  .stale                 → .elevated        // calm "paused"; SUPPRESS deeper fault from old data (mirrors the diagnoser)
  .online                → max(
                              healthSeverity,        // degraded→.degraded, down→.down, else .normal
                              displaySeverity,       // value crosses displayThreshold → .elevated
                              alertActive ? .alerting : .normal
                            )
```

Stale-suppression is the load-bearing rule: a `.stale` entity is capped at `.elevated` and never reports
`.degraded`/`.down`/`.alerting` from data we didn't collect — the per-entity analogue of the diagnoser's
stale-suppression shipped in the hardening task. `enrich` writes `availability` and `severity` back into the
returned `EntityState` (value/lastUpdated/error pass through).

`displaySeverity` reuses `DisplayThreshold.comparison`/`.value` against `state.value` (the same
`AlertComparison` vocabulary). The `.consecutive` debounce is **not** applied here (it's temporal — see §3b).

### 3b. `AttentionEngine` (new — `Sources/AmbitCore/Presentation/AttentionEngine.swift`)

```swift
public struct SurfaceID: StringIdentifier { public let rawValue: String; public init(rawValue: String) }

public enum OverflowPolicy: Equatable, Sendable, Codable { case countBadge, rotate, drop }

public struct SurfaceCapacity: Equatable, Sendable {
    public var lanes: Int                 // menu-bar slot = 1 in P4; Dynamic Island = 1 (+rotate); Watch tiny
    public var overflow: OverflowPolicy
    public init(lanes: Int, overflow: OverflowPolicy = .countBadge)
}

public enum AttentionTier: Int, Sendable, Codable, Comparable {   // resting → interrupting
    case detail, surfaced, alerted
    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

public struct AttentionReason: Equatable, Sendable {
    public var summary: String            // "ping surfaced: 142ms > 100ms display, sustained 4, priority 3"
    public var tier: AttentionTier
    public var severity: Severity
    public var score: Int
    public var transitionBoosted: Bool
}

public struct SurfacedEntity: Equatable, Sendable, Identifiable {
    public var id: EntityID
    public var tier: AttentionTier
    public var score: Int
    public var reason: AttentionReason
}

public struct AttentionSelection: Equatable, Sendable {
    public var lanes: [SurfacedEntity]    // length ≤ capacity.lanes, descending score; renderers read this
    public var overflowCount: Int         // surfaced-but-didn't-fit (drives "+N"); 0 when all fit
    public var alerted: [SurfacedEntity]  // tier == .alerted → notification-eligible (already deduped by AlertEngine)
}

public struct AttentionCandidate: Equatable, Sendable {
    public var descriptor: EntityDescriptor
    public var state: EntityState         // ENRICHED (post-EntityEnricher)
}

public struct AttentionEngine {
    public init()
    /// Stateful across ticks (debounce + transition boost), like AlertEngine. `surfaces` maps a
    /// SurfaceID to its capacity; `alertingIDs` are entities the AlertEngine is currently firing on.
    public mutating func evaluate(
        candidates: [AttentionCandidate],
        surfaces: [SurfaceID: SurfaceCapacity],
        alertingIDs: Set<EntityID>,
        config: PresentationConfig,
        now: Date
    ) -> [SurfaceID: AttentionSelection]
}
```

Internal per-entity temporal state (not public):

```swift
private struct AttentionState {
    var surfacedStreak: Int          // consecutive ticks the display condition held
    var unsurfacedStreak: Int        // consecutive ticks it didn't (sustained-to-unsurface)
    var isSurfaced: Bool
    var lastTierChangeAt: Date?      // for transition boost decay
}
private var states: [EntityID: AttentionState] = [:]
```

### 3c. Visibility resolution (per entity, per tick)

`effectiveVisibility = override.visibility ?? descriptor.defaultVisibility`

- **`never`** → tier `.detail`; never a lane candidate.
- **`always`** → always a candidate; gets a **reserved lane** (fills before scored candidates).
- **`auto`** → a candidate when the display condition holds *with debounce*:
  `severity >= .elevated` **OR** `availability != .online` **OR** the `displayThreshold` crossed and held for
  `consecutive` ticks (`surfacedStreak >= consecutive`). Sustained-to-unsurface symmetrically: drop only after
  `unsurfacedStreak >= consecutive` (anti-flicker, §4e).

### 3d. Tier assignment (per surfaced candidate)

- `.alerted` if `id ∈ alertingIDs` (the AlertEngine crossed the **alert** threshold — distinct from display).
- `.surfaced` if it's a candidate but not alerting.
- `.detail` otherwise (never reaches a lane).

This is the detail → surfaced → alerted escalation with **separate display vs alert thresholds**:
display threshold (or severity ≥ elevated) → `.surfaced`; alert threshold (AlertEngine) → `.alerted`.

### 3e. Ranking & capacity

```
score = pinnedBit (reserved lane, sorts above everything)
      ⊕ severity.rawValue        (down > alerting > degraded > elevated > normal)
      ⊕ transitionBoost          (set for `boostWindow` after a tier change; decays to 0)
      ⊕ priority                 (override.priority ?? descriptor.priority ?? 0)
```

Concretely `score = effectiveSeverity.rawValue * 1000 + (transitionBoosted ? 100 : 0) + clampedPriority`,
where `effectiveSeverity = max(state.severity ?? .normal, tier == .alerted ? .alerting : .normal)` — so an
alerted entity always outranks a merely-degraded one even though `Engine.entityStates()` passed
`alertActive: false` (the tier, set from `alertingIDs`, is the authority for "alerting"; the enriched severity
is the authority for everything below it). `always`/`pinned` entities are placed into reserved lanes first. Per surface: fill reserved lanes, then fill the
rest by descending score among surfaced candidates; **stable tie-break by `EntityID`** to avoid churn.
`overflowCount = max(0, surfacedCount - lanes)`.

**Resting selection (presentation-model.md §10):** when nothing is `.surfaced`/`.alerted`, `lanes[0]` falls
back to the highest-`priority` entity among `{always}` then `{isPrimary}` candidates — i.e. "health dot +
the single highest-`isPrimary` metric." So the bar is never empty.

### 3f. Reasons (explainability, §4e)

Every `SurfacedEntity` carries an `AttentionReason.summary` string built from the deciding facts
(threshold crossed + sustained count + severity + priority + boost). This is a debugging aid and on-thesis
(deterministic, inspectable). Surfaced via the engine output; a later debug view can render it.

---

## 4. Wiring (AmbitMenuBar + Engine)

### 4a. `Engine.entityStates()` returns enriched states
Apply `EntityEnricher` inside `Engine.entityStates()` (it owns per-instance `interval`, descriptors, and
history → `lastSampleAt`). `alertActive` passed `false` here. Result: the detail popover's `EntityReadout`
tones now reflect `.stale`/severity for free (it already reads `state.severity`/`availability`). The ad-hoc
`Staleness.availability(...)` call in `buildSlotSurface` is **removed** (now redundant — one truth).

### 4b. `buildSlotSurface` becomes attention-driven
- Build `[AttentionCandidate]` from the slot's resolved descriptors + enriched states (+ the diagnosis
  candidate, §4c).
- Map the slot to `SurfaceCapacity(lanes: 1, overflow: .countBadge)` (one macOS status item).
- Compute `alertingIDs` from the existing `PingAlertMonitor`/`AlertEngine` output already gathered in
  `refreshPing`.
- Call `AttentionEngine.evaluate(...)`; render the **glyph from `selection.lanes[0]`** via
  `EntityReadout.make(descriptor:state:)` (generic text + tone) instead of the hardcoded primary-host
  readout. `MenuBarGlyph` stays the same struct; it's just fed the selected entity's readout.
- `overflowCount` is carried but **not rendered** on macOS in P4 (capacity 1; Decision 2). It's there for the
  Island/Live Activity renderers later.

The `AttentionEngine` instance is held by `StatusViewModel` (a `var`, like `alertEngine`) so its debounce
state persists across the snapshot stream **and** the 5s stale tick.

### 4c. Diagnosis promotion (cut the host-glue)
`DiagnosisEntity.make(diagnosis)` already returns a generic `(descriptor, state)` with a severity. Feed it
into the candidate set for the ping slot; **delete** the manual banner-prepend block in `buildSlotSurface`.
The banner now appears because the AttentionEngine surfaces the diagnosis entity (its severity drives tier:
`.monitoringStalled → .elevated` surfaces a calm banner; `…Down → .down/.alerted`). The detail plan still
renders a `.statusBanner` card for any surfaced `.text`/diagnostic entity — generic, no ping special-case.
`DiagnosisEntity.severity(for:)` is the locked default; re-confirm the verdict→severity table here (it
already maps `.monitoringStalled → .elevated`, exactly the `.stale` calm tier).

---

## 5. Phasing (small green steps, one commit each)

**P4.1 — `EntityEnricher` (pure Core) + tests.** Add the type and the severity rule; injected-clock unit
tests (online/stale/unavailable; stale-suppression caps at `.elevated`; display-threshold → `.elevated`;
health degraded/down; alertActive → `.alerting`). No wiring yet. Green.

**P4.2 — Enrich `Engine.entityStates()`; remove ad-hoc staleness.** Route projection through the enricher;
delete the `Staleness.availability` call in `buildSlotSurface`. Detail tones now reflect staleness/severity.
Existing tests stay green; add an `EngineEntityAPITests` case asserting a stale entity comes back `.stale`.

**P4.3 — `AttentionEngine` core (visibility + tier + ranking + capacity), no debounce yet.** Pure selection
from candidates → `[SurfaceID: AttentionSelection]`. Heavy unit tests: visibility always/auto/never; tier
detail/surfaced/alerted from display vs alert thresholds; ranking order; reserved pinned lanes; overflow
count; resting fallback. No UI. Green.

**P4.4 — Debounce + transition boost + reasons.** Add the per-entity `AttentionState`; sustained-to-surface /
sustained-to-unsurface; transition boost with `boostWindow` decay; populate `AttentionReason`. Injected-clock
tests for flicker resistance and boost decay. Green.

**P4.5 — Wire the macOS bar.** `buildSlotSurface` builds candidates + capacity, calls the engine, renders
`lanes[0]` as the glyph. `StatusViewModel` holds the `AttentionEngine`. **Eyeball checkpoint:** bar shows the
highest-attention host; degrade one host → it takes the bar; recover → resting primary returns. At least as
good as the static primary readout.

**P4.6 — Promote the diagnosis; kill the host-glue.** Feed `DiagnosisEntity` as a candidate; delete the
prepend block; confirm the banner + "Monitoring paused" both flow through the engine. **Eyeball checkpoint:**
the staleness path (sleep/wake) shows the calm paused banner via attention, no false down; a real down
escalates to `.alerted`.

Device integrations stay disabled throughout (only `ping` active) — P4 is proven on ping, like its
predecessors; the second integration (`system`, P6) is the multi-provider proof.

---

## 6. Testing

- **`EntityEnricherTests`** — the severity rule, every branch, injected clock; stale-suppression.
- **`AttentionEngineTests`** — visibility resolution; tier assignment (display vs alert separation);
  ranking + reserved lanes + stable tie-break; overflow count; resting fallback; debounce (sustained
  surface/unsurface); transition-boost decay; reason strings.
- **Engine** — `entityStates()` returns enriched states.
- **Diagnosis** — diagnosis entity surfaces through the engine at the right tier per verdict
  (`monitoringStalled → surfaced/elevated`, `localNetworkDown → alerted/down`).
- All existing 364 stay green; no test weakened for retained code.

---

## 7. What this is NOT (non-goals / deferred)

- **No new detection.** No new probes, no new threshold *evaluation* beyond reading `displayThreshold` and
  the existing `AlertEngine` output. Consumer only.
- **No Dynamic Island / Live Activity / Watch renderers** — the engine is built surface-agnostic (capacity +
  overflow modeled, multi-lane selection emitted) but only the macOS `lane[0]` renderer is wired (Decision 2).
- **No settings UI** — that's P5. P4 reads `EntityPresentationOverride` where present and otherwise descriptor
  defaults; it does not add a renderer for editing them.
- **No capability-surface slots** — `.capability` selection stays modeled-not-wired (deferred post-P6).
- **No multi-lane macOS glyph**, no `overflowCount` rendering on macOS.

---

## 8. Resolved presentation-model.md §10 open questions (leans, confirmable in review)

- **Resting combined-slot readout** → health-dot + the single highest-`isPrimary` metric (§3e resting
  fallback). Not rotating.
- **Default menu-bar lanes** → 1 per status item for P4 (multiple *slots* already give multiple items);
  overflow modeled but not rendered.
- **Capability surfaces** → not first-class in v1; deferred.
- **Transition-boost decay** → a fixed `boostWindow` (lean: ~20s or N ticks) after a tier change, then boost
  drops to 0. Tunable constant; injected-clock tested.

## 9. Tunables to confirm in review

- `unavailable → .down` severity (vs `.degraded`): offline is currently mapped to the strongest tier so a
  dead primary always takes the bar. Flagged in case "offline ≠ down" is preferred for ranking.
- `boostWindow` magnitude/units (seconds vs sample count).
- Whether `auto` should surface on `availability == .stale` as `.surfaced` (calm) vs requiring explicit
  user opt-in — current design surfaces it (the staleness fix's whole point is visibility).
```

# Ambit — Presentation & Attention Model (spec)

> **Ambit design docs — read together:**
> - **`MIGRATION_PLAN.md`** — staged build path & current status.
> - **`integration-model.md`** — the installable unit (Integration → install → providers).
> - **`provider-capability-model.md`** — grouping & membership (profiles + capabilities → surfaces).
> - **`entity-model.md`** — the Provider→Entity abstraction (descriptors + per-snapshot state).
> - **`engine-topology.md`** — multi-engine & multi-instance coordination.
> - **`presentation-model.md`** (this doc) — **how integrations are displayed**: the generic card vocabulary, menu-bar slots, the Attention engine, and settings.
>
> **This doc owns: the opinionated, generic presentation layer + the Attention engine.** Integrations contribute entities + presentation *defaults* (via descriptors); they do **not** ship UIs. Pingscope's M5 bespoke UI is the harvest source for the generic primitives, not the destination.

**Status:** design. Supersedes the bespoke per-provider UI shipped in pingscope M5 (that UI is the harvest source).
**Principle:** Ambit owns the chrome and a fixed vocabulary of primitives; integrations contribute *entities + defaults + a tiny set of hooks*. Consistent experience whether 2 or 20 integrations are loaded (the Raycast bet, not HA's user-composed dashboards).

---

## 1. Two tiers

Every surface is one of two tiers, both generic:

1. **Detail surface** — the popover: generic cards bound to an integration's entities. What you see when you click in.
2. **Glance / attention surface** — the menu-bar readout, Dynamic Island, Live Activity, Watch complication: driven by the **Attention engine** (§4). What you see *without* clicking, dynamically.

Integrations never build either. They emit entities (data) + descriptors (kind/deviceClass/stateClass/capability + presentation defaults), and everything renders through the shared layer.

---

## 2. The generic card vocabulary (detail surface)

A fixed set of primitives, keyed off entity `kind` + `deviceClass` + `stateClass`. Harvested from pingscope's M5 UI **and** iStat Menus' panels (which between them cover nearly everything — iStat is the system-stats UX reference; note StarBar/starbar.app is a separate Starlink-dish app, a *later* integration, not the system one):

| Primitive | Renders | Driven by |
|---|---|---|
| Status row | label + value + health badge | any entity |
| Gauge (ring/donut) | a 0–100 / bounded value | `percent`/`level`/`battery`/`temperature` sensor |
| Sparkline / history graph | a time series | `stateClass`-bearing sensor + HistoryService |
| Dual-line graph | up/down or user/system | two related throughput/percent sensors |
| Linear progress | a bounded value | `battery`/`percent` |
| Stat table | rows of label/value | a group of sensors (processes, disks) |
| Toggle / select / number / button | a control | the matching control entity + `CommandRef` |
| Instance selector | switch among an integration's instances | multi-instance integrations (pingscope hosts) |
| Section / group | capability- or category-grouped cards | `capability` / `category` |
| Status banner | a top-level summary message | a summary "status" entity (e.g. pingscope diagnosis) |

Pushing custom UI toward **zero**: things that feel provider-specific become *primitives*, not hooks. pingscope's network-diagnosis banner → the generic **status banner** primitive bound to a summary entity. Reserve a true custom-card hook only for something genuinely unrepresentable; aim to never use it.

---

## 3. Menu-bar slots (dedicated vs combined are one model)

A **slot** binds a *selection* of entities/integrations to (a) a compact bar readout and (b) a popover surface, rendered through the primitives. Dedicated and combined are just different bindings:

- **Dedicated** — a slot bound to one integration (pingscope-as-app; an iStat single module).
- **Combined** — one slot bound to several integrations → a popover of stacked cards (iStat "combined"; the gl.inet-travel dropdown).
- **Multiple dedicated slots** — several single-integration items side by side (iStat's separate modules).
- **Capability surface** — a combined slot whose selection is "everything with capability X" (the Network / VPN / Power panel, grouping across integrations).

One slot mechanism, configured differently. The bar readout of a combined slot is *dynamic* (§4): it shows the highest-attention item(s) right now, not a fixed metric.

---

## 4. The Attention engine (generic Core service)

The differentiator: glance surfaces show **what matters now**, not what's statically configured. A generic `AmbitCore` service (no UI) consuming `EngineSnapshot` + health/alert state (M4) + the user's visibility/priority config, emitting per-surface ordered selections **with reasons**.

### 4a. Three escalation tiers (per entity)
- **Detail** — popover only (resting state).
- **Surfaced** — appears in a glance surface because it crossed a **display** condition. Visual, no interrupt.
- **Alerted** — fires a notification because it crossed an **alert** condition. Interrupt.

**Display threshold and alert threshold are distinct, nested concerns.** Ping may *surface* at 80ms but *alert* at 250ms. Surfacing is the tier between silent and interrupting. The same entity climbs detail → surfaced → alerted as severity rises; this unifies the dynamic menubar, Dynamic Island, Live Activity, and notifications into one model.

### 4b. Visibility rule (per entity)
`always` (pins a reserved lane) · `never` (detail-only) · `conditional` (surface when degraded/down, alert-active, or a metric crosses its *display* threshold). All predicates over the existing `HealthState`/`AlertEngine` — a consumer, not new detection.

### 4c. Ranking (for constrained space)
`score = userPriority (pinned = reserved) ⊕ severity (down > alerting > degraded > elevated > normal) ⊕ transitionBoost (newly-changed outranks chronic)`. Per surface: reserve pinned lanes, fill the rest by descending score among currently-visible candidates. Stable tie-break to avoid churn.

### 4d. Per-surface capacity + overflow
Each surface declares lanes + overflow: menu bar = a few lanes; Dynamic Island = 1 (rotate, or top + "+N"); Live Activity = 1 strip; Watch = tiny. Same engine, surface-agnostic — design now so Dynamic Island / Live Activity are a form-factor swap later, not a rebuild.

### 4e. Debounce + explainability
Reuse M4's consecutive-samples debouncing so items don't flicker in/out around a threshold (sustained-to-surface, sustained-to-unsurface). The engine emits a **reason** per surfaced item ("ping surfaced: 142ms > 100ms display, sustained 4 samples, priority 3") — debugging aid and on-thesis (deterministic, never a black box).

It's the third generic engine alongside **History** and **Alert**, and mostly reuses both.

---

## 5. Settings — progressive disclosure, entity-driven

One generic settings renderer, three depths, all generated from entities — **no bespoke per-provider settings**:

1. **Zero-setup default** — integrations ship defaults via descriptors (suggested primary metric, default graph style, default visibility rule, default display/alert thresholds, default alerts). Works out of the box.
2. **Per-integration quick controls** — expand an integration → its entities with simple show/hide/pin (glance visibility) + enable/disable. This is "choose what stats to display."
3. **Power drill-in** — expand an entity → display threshold, alert threshold, graph range/style, alert preset/policy, interval.

"Integrations choose how it's displayed" = they ship good **defaults through descriptors**, not settings UI. "User customizes" = generic overrides at whatever depth they want. Simple users never expand; power users drill.

---

## 6. Descriptor additions (presentation defaults)

`EntityDescriptor` gains optional presentation-default fields the integration declares and the generic layer/Attention engine read (all overridable by the user):
- `defaultVisibility: always | auto | never` (auto = conditional on health/threshold)
- `displayThreshold` (surface tier; separate from the alert threshold)
- `graphStyle: sparkline | gauge | progress | none`
- `isPrimary` (the metric the bar readout prefers for this integration/instance)
- `priority` (ranking hint)

All optional/defaulted, additive — existing descriptors keep working.

---

## 7. The dedicated single-provider app

A dedicated app (pingscope-standalone) is **not** a separate UI — it's the generic shell configured to one integration with tailored chrome/branding (no integration switcher; that integration's surface fills the window). Same primitives, same engine, same Attention engine. The bet that makes this work is the Raycast bet: **make the primitives good enough that a single-purpose app feels native.**

---

## 8. Build path (harvest → refactor → prove)

1. **Harvest primitives** from pingscope's M5 UI (and iStat/StarBar references) into the generic card vocabulary (§2) in the UI layer; the history graph reads from the HistoryService.
2. **Refactor pingscope** to render through the generic primitives — delete its bespoke popover/graph/settings; its diagnosis banner becomes the generic status-banner primitive; its per-host settings become generic config-entity settings.
3. **Slots** (§3): dedicated + combined as bindings; replace the hardcoded chrome.
4. **Attention engine** (§4): a generic Core service feeding the menu-bar readout; visibility/priority config.
5. **Generic settings** (§5–§6): progressive disclosure from entities + descriptor defaults.
6. **Prove it with a second integration** — bring in the `system` integration (iStat-style: CPU/memory/disk/network/sensors/fans/battery), maximally different from pingscope. It renders through the *same* primitives with **zero bespoke UI**. The day pingscope and a totally different integration look coherent in one popover with no per-provider view code, the multi-provider thesis is proven. (Starlink — the starbar.app functionality — is a separate, later integration; it overlaps pingscope's existing Starlink probe method, a boundary to settle then.)

Dynamic Island / Live Activity are deferred to iOS, but the Attention engine is built surface-agnostic now so they're a renderer, not a rebuild.

---

## 9. Non-goals

- **Not** user-composed dashboards (HA Lovelace). Opinionated default layout; customization is show/hide/pin/threshold, not free-form composition.
- **No** bespoke per-provider UI or settings. Integrations contribute entities + defaults + (rarely) a primitive, never a view.
- **No** general "draw arbitrary UI" hook. Turn "special" into new primitives instead.
- Dynamic Island / Live Activity / Watch: design-for, build later.

## 10. Open questions

- Default combined-slot bar readout when nothing is elevated: overall health dot + primary metric, or rotating? (Lean: health dot + the single highest-`isPrimary` metric.)
- How many menu-bar lanes by default before overflow into a single combined glyph.
- Whether capability surfaces are first-class slots in v1 or a later lens over the by-integration default.
- Exact transition-boost decay curve (how long "newly changed" outranks chronic).

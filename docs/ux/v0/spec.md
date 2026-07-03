# Ambit — Settings UX + Engine Evolution (v0 draft)

Status: v0 design; **Part B implemented, Part A not started** (status updated 2026-07-03). Companion files:
`mocks.html` (interactive screens) and `schema.md` (engine declaration types + a reconciliation against the
current codebase).

This document is in two parts, with different readiness:

- **Part A — Settings UX redesign.** A presentation reorganization of today's settings. Build-ready; uses
  the existing engine seams (entities, presentation overrides, alert-kind declarations, slots) with no new
  engine primitives. The 6-phase plan at the end of Part A can start now. **Not yet built** — the current
  settings UI predates this design.
- **Part B — Engine evolution.** Contexts, a richer reaction set, provider commands surfaced as reactions,
  and the universal rule engine. **BUILT: merged on master 2026-06-29 as B1–B6** (condition tree + evaluator;
  reaction registry; user-rule store/runner/builder; contexts + overlay stacking with cycle detection and
  resolution traces; location/calendar/Focus signal providers; App Intents bridge + Shortcut reactions),
  followed by packaging/privacy hardening (entitlements, App Intents metadata, location-gated SSID). Any
  "not yet build-ready" caveats below are design history, now historical.

The two parts share one model: enable a capability on an entity, compose it onto surfaces, and (Part B) let
conditions over entity state drive reactions. Part B does not block Part A.

---

# Part A — Settings UX redesign (build-ready)

## Why

Today's settings put every ping host, System, and the app sections (App / Slots /
History / Diagnostics) in one flat sidebar, and the detail pane is a dense form of typed
fields plus an "Entities" list that exposes raw entity IDs
(`ping@1.1.1.1:443/probe.latency_ms`) with three cryptic controls each
(`Default(Auto)` / `Pin` / `Show`). It does not scale past a handful of integrations, and
the language is developer-facing.

Goal: an iStat-Menus-class settings experience that stays usable at 20+ integrations, is
visual rather than form-heavy, and uses plain language.

Part A is a presentation reorganization only. The generic engine (entities, presentation
overrides, alert-kind declarations, slots) already supports everything in Part A; no new
engine primitives are required here. (The new engine work lives in Part B.)

## Core model: enable in the provider, compose in the surface

Two levels, strictly separated:

1. Provider settings = capability / enablement. Per metric, you choose which usages it is
   allowed to participate in: Alerts, Menu bar, Popover, and (per platform) Dynamic Island,
   Live Activity, Control Center. Nothing appears anywhere until enabled here. This is the gate.
2. Surfaces + Notifications = composition. Each surface has a builder that arranges only what
   has been enabled for it. The menu-bar builder combines / splits enabled-for-menu-bar
   metrics into however many items you want; Notifications tunes the alert behavior for
   enabled-for-alerts metrics.

This split is what makes arbitrary mixes trivial — e.g. combine all Ping into one menu-bar
item while splitting System into three — because the menu-bar builder composes freely over
the enabled set, independent of other surfaces.

## Surfaces are a family

"Menu bar" is one surface, not the whole concept. Surfaces are all the OS-specific places a
monitor can present:
- macOS: Menu bar, Control Center, Notifications (alerts).
- iOS (later): Dynamic Island, Live Activity, lock-screen / home-screen widgets.

Every surface uses the same builder pattern (combine, split, choose item count, order).
Adding a future surface never touches provider settings — a metric just gains another usage
toggle. Alerting is one usage among the surfaces; it has the richest config, which lives in
Notifications.

## Information architecture (the rail)

- Search (filters across everything).
- MONITORS — searchable, collapsible groups by integration. Each group shows a count and a
  status dot; a failing instance bubbles a red dot to its group. Instances nest under their
  integration. "Add monitor" at the end.
- SURFACES — Menu bar, Dynamic Island, Live Activity, Control Center (each a builder; iOS ones
  greyed on macOS).
- ALERTS — Notifications.
- App-level — General, Display, History, Diagnostics (compact icon strip, not peers of instances).

## Interaction patterns

### Where things get added — membership flows instance → surface (one direction)
Enabling a metric's usage chip *is* the add action, and it is the single source of truth for what
is on each surface. Turn on "Menu bar" for CPU load and CPU load is on the menu bar; turn on
"Control Center" and it is a Control Center widget. Membership is set per-metric, per-instance, in
the instance detail. A surface never decides membership — it only arranges what the instances
enabled. Removing is the same flag viewed from either side: toggle the chip off in the instance, or
"remove from this surface" in the builder; one piece of state, two views. There is no limbo —
enabling makes a metric appear immediately (default: its own item/widget at the end); arranging is
optional polish.

### Metric cards (replaces the Entities list)
Each metric is a card: friendly name + live preview (sparkline / value / status dot) + usage
toggles (chips): Menu bar, Popover, Alerts, Control Center, (iOS) Dynamic Island, Live Activity.
A short "Added to: Menu bar, Popover, Alerts" line under the chips makes the effect explicit, with a
link out to the surface to arrange it. No raw entity IDs in normal view; IDs live in Diagnostics.
Advanced (target, role, thresholds, probe tuning) is a progressive-disclosure section with plain labels.

### Surface builders — graphical, aggregate, arrange-only (replaces "Slots")
Surfaces are visual canvases, not forms. Each surface aggregates everything enabled for it across all
instances and providers, and shows it the way it will actually render — the macOS menu-bar strip, the
Control Center widget grid. You arrange only: group metrics into items, reorder by drag, combine/split,
choose icon/format. Each placed metric carries a small source tag (which instance/provider it came
from). A "combined vs separate" switch is the per-surface default; any item can still be split or merged.

### Notifications (three layers over one engine)
1. Built-in alerts — grouped by provider, each provider's declared alert kinds as toggles
   (Ping: host down / recovered / high latency / internet loss; System: CPU high / memory
   pressure / disk low / battery low; etc.). **Part A** — these `AlertKindDeclaration`s already exist.
2. Custom rules — user-authored "When [metric] [comparison] [value] for [duration] → then [action]"
   (IFTTT / Shortcuts style). **Part B** — needs the condition tree + a user-rule store. The mock shows it,
   but it ships with the engine work, not the Part A redesign.
3. Global — default cooldown, quiet hours, snooze-all. **Part A.**

Built-in and custom are ultimately the same primitive (a condition over entity state → reactions), just
provider-authored vs user-authored; that unification is Part B. As custom-rule actions grow beyond Notify,
custom rules graduate into their own "Automations" area.

## Language / rename map

- "Slots" → "Menu bar" (a surface) / "Surfaces" (the family).
- "Available Items" / "Configured Dashboard" → the surface builder's item composition.
- Entity `Pin` / `Show` / `Default (Auto)` → per-metric usage toggles + an Advanced graph option.
- "Degraded After" → "Warn above (ms)".
- "Down After" → "Down after N failed checks".
- "Diagnosis Sensitivity" → keep, with a one-line plain description.
- "Network Role: Auto" → keep, clarify ("Infer from the address, or set it").
- Raw entity IDs → hidden from normal panes; shown in Diagnostics only.
- Plain, sentence-case copy throughout; no template tokens shown to users
  (`{hostName}` etc. are authoring-only).

## Scope

- Build now (macOS): rail / IA, metric capability cards, menu-bar builder, Notifications v2
  (built-in grouped by provider + custom rules + global), Control Center surface, language pass.
- Define contracts, defer implementation (iOS): Dynamic Island, Live Activity, widgets — the
  usage toggles + surface-builder pattern reserve their place; greyed on macOS.
- No new engine primitives. Part A surfaces what the engine already exposes: it needs System (and other
  providers) to declare their `AlertKindDeclaration`s, and reuses the existing presentation overrides and
  `MonitoringAlertStateMachine`. User-authored custom rules are NOT in Part A — they require the condition
  tree and a user-rule store (both net-new), so they live in Part B.

## Phased, UI-first plan

Each phase is behavior-preserving where it touches existing behavior: characterization goldens
stay byte-identical, the ping-leak grep-gate stays green, and there is an eyeball per screen.

1. Rail restructure — grouped, searchable Monitors; Surfaces + Alerts + app sections; status
   dots bubble up.
2. Metric capability cards — replace the Entities list with cards + usage toggles + Advanced
   disclosure; retire raw IDs to Diagnostics.
3. Menu-bar builder — live preview, N items, combine / split, drag-order, fed by the enabled
   set; replaces the Slots editor.
4. Notifications v2 — built-in kinds grouped by provider (System + others declare kinds),
   permission / test row, status colors.
5. Language pass — apply the rename map; hide entity IDs; plain copy everywhere.
   (Later) iOS surfaces — Dynamic Island / Live Activity builders against the reserved contracts.

(The custom-rule builder moved to Part B — it depends on the condition tree + user-rule store.)

## Decisions (v0)

These resolve the earlier open questions and are reflected in `mocks.html`:

- Menu bar lives only under Surfaces — no duplicate quick-link group in the rail (keeps it clean).
- Custom rules stay in Notifications for now; they graduate to a dedicated Automations pane once
  actions go beyond Notify (run command / run Shortcut).
- Capability defaults are per integration: enabling a usage on one instance becomes the default for
  new instances of that integration; each instance can override, and an "Apply to all" action is offered.
- Combined-vs-separate is a per-surface default plus a per-item override: one switch sets the default,
  and any single item can still be split or merged.

Still open: exact Control Center widget sizing/limits on macOS; whether Diagnostics stays a top-level
app section or folds into a per-instance "Advanced" tab.

## Mocks

`mocks.html` is an interactive click-through (tabs switch screens; chips, toggles, segmented switches,
sub-tabs, and nested rail rows respond; light/dark toggle at top). It renders inside a macOS window frame.
Screens:
- Integrations — the enabled list + the add-monitor gallery.
- Instance detail — grouped rail + metric capability cards + the per-integration default note.
- Surfaces — Menu-bar builder (preview, combine/separate, drag-order) and Control Center builder
  (widget grid), with iOS surfaces greyed.
- Notifications — built-in alerts per provider, the custom-rule builder (inline editor), and global.
- Rail at scale — 40+ monitors as scannable groups with a failing dot bubbling up.
- Model & decisions — the flow, usages, the Surfaces family, and the v0 decisions above.

---

# Part B — Engine evolution (locked design, build after locking)

One thesis, stated once: **everything is one primitive — a Condition (a trigger over entity state, with
dwell/hysteresis) → one or more Reactions.** Built-in alerts are provider-authored conditions; custom rules
are user-authored ones; a Context is the meta-rule whose reaction is "apply this overlay while my condition
holds"; a persistent notification is a Notify reaction bound to the condition's state instead of its edge.
The engine is a pure interpreter over uniformly-addressed entities, so coverage grows by adding declarations,
never engine branches. The sections below (Contexts, Reactions & commands, Universal engine, Interop) are
facets of that one idea; they intentionally restate it from different angles.

`schema.md` holds the concrete types and — critically — a reconciliation against the current codebase. The
short version: addressing (`EntityID`), entity read/write (`EntityAccess`), commands (`CommandDescriptor` +
`CommandParameter`), alert kinds (`AlertKindDeclaration`), comparisons + dwell (`AlertComparison`,
`SustainedAlertRule`, `MonitoringAlertStateMachine`), and presentation overrides already exist and are
reused. The net-new work is the **`Condition` expression tree**, the **`Reaction` registry** (beyond notify),
**Contexts** (stateful + priority-stacked), **user-authored rule persistence/migration**, and
**settable-property addressing**. See `schema.md` §10 for the full mapping and the locked naming.

## Contexts (stateful profiles)

A third axis on top of capability (provider) and composition (surfaces): a **Context** is a named,
detected situation — Home, Work, Car, Travel — that, while active, changes what is visible and which
alerts run. "I'm at home, show me these; it's work time, enable those."

### Generic model (no context-specific logic)

- **Signals are ordinary entities.** Current SSID/BSSID, a geofence membership, a schedule window, the
  current calendar event (busy/free), macOS Focus, even battery or weather — each is a provider entity
  with state, identical in kind to a ping host or CPU. Contexts compose over whatever entities exist.
- **A context's activation condition reuses the custom-rule trigger primitive** — a boolean expression
  over entity states (`network.ssid is "HomeWiFi" OR location in "Home"`), with a dwell/hysteresis hold
  so it doesn't flap. Same comparison machinery as alert rules.
- **A context is itself a derived boolean entity** with `active/inactive` state, run through the same
  alert state machine (dwell + flap suppression). Entering/leaving is a stateful, debounced transition,
  not a momentary reading. This is where "state matters" lives.
- **While active it applies an overlay** — deltas to usage enablement, surface composition
  (SlotPresentationOverride), and alert policy (EntityAlertPolicy). The base config sits underneath.

### Stacked overlays + resolution

Several contexts can be active at once (Home + Evening + Car). Each carries a priority; resolution is a
pure function `(base config + active overlays, ordered by priority) → resolved config`, last-wins on
conflict, base always underneath. Pure and deterministic, so it is golden-testable like the rest of the
composer. The menu bar / popover shows the current active context(s).

### Relationship to notifications

Context enter/leave are events on the same engine that fires alerts — so a transition can also notify
("Welcome home") or stay silent and just reconfigure. This generalizes the Automations idea: a trigger's
action can be Notify / RunCommand / RunShortcut / **ApplyContext**. ApplyContext differs only in being
*sustained while the condition holds* rather than one-shot. Built-in alerts, custom rules, and contexts
are the same primitive (a trigger over entity state) with different actions.

### Weather as the simple case

Weather is just a provider: temp / condition / precipitation entities with state. Transitions (rain
starting, freeze warning) are alerts via the normal state machine; and a context can gate whether the
weather card is even visible (show only when Home + Morning). No special handling.

### What's new to build (defer impl, define contracts now)

- Signal providers: Location (CoreLocation geofences), Calendar (EventKit), Network SSID, Focus — each
  with its own permission prompt and privacy posture (location/calendar are sensitive).
- A context state machine that reuses the existing dwell/flap-suppression.
- A context-overlay input into SurfaceComposer + the enablement resolver (the pure resolution above).
- UI: a "Contexts" rail section; each context = name + icon + condition builder (reuse the rule builder)
  + a "what changes" overlay editor + a live "active now" indicator; a current-context chip in surfaces;
  optional per-metric "active in: Home, Work" tags.

### Locked decisions (contexts)

- **Priority = drag-to-rank.** Stored as an explicit integer order; users never type numbers. Higher row wins.
- **No fallback context.** "Base" is the always-on bottom layer (the user's default config), not a context.
  When no context matches, you see base. Base is editable as the normal settings, not as a context.
- **v1 overlay granularity = visibility + usage deltas + alert-kind enable/disable.** Full threshold-retuning
  deltas are deferred to a later pass.
- **Manual override = yes.** Each context is Auto (detected), or pinned Active / pinned Inactive, overriding
  detection.

## Reactions & commands — the rich "then"

Built-in alerts, custom rules, and contexts are all the same primitive: a Condition (a trigger over
entity state, with dwell/hysteresis) → one or more **Reactions**. The "rain starts" case shows the full
reaction vocabulary, all generic:

- **Notify** — with a lifecycle and optional action buttons. Lifecycle is the key state idea: a notification
  can be one-shot (post on the enter transition) or *state-bound / persistent* (posted on enter, updated,
  and cleared automatically when the condition clears). "Persist until it stops raining" is just binding the
  notification to the condition's active state instead of the edge event. Style maps to macOS interruption
  levels (banner / alert / time-sensitive).
- **Mutate a surface** — change the menu-bar icon / color / badge (or any surface element) *while the
  condition holds*. This is the same conditional-presentation-override primitive as a Context overlay, just
  keyed to an alert's active state instead of a context's. Cloudy → 🌧 while raining, reverts when it stops.
- **Run a command** — invoke an action exposed by a provider (close Tesla windows, close the skylight, set
  EcoFlow output), or a shell command / Shortcut. Also surfaced as **action buttons on the notification**.
- **Apply a context** — activate/deactivate a context (the sustained binding from the Contexts section).

### The new building block: providers declare Commands, not just metrics

Today entities only *report* (read-only metrics). To "close the windows," a provider must also expose
**Commands** — a generic `CommandDeclaration` sibling to `AlertKindDeclaration`: id, friendly label, icon,
parameters, and a confirmation policy. Tesla declares `closeWindows`; Skylight declares `close`; a shell
provider declares arbitrary commands. The UI renders declared commands as buttons (rule reactions and
notification action buttons both consume the same command registry) — no device-specific UI. This turns
Ambit from a pure monitor into a controller for the providers that opt in.

Consequences to design for: commands are outbound and often consequential (closing car windows), so each
needs a confirmation policy and the provider needs write auth/permissions; this is a meaningful capability
and trust expansion, kept generic by living entirely in declarations.

### How it unifies the model

One engine, one primitive. A trigger observes entity state; its reactions draw from {Notify(style,
lifecycle, actions[]), MutateSurface(while active), RunCommand(commandRef), ApplyContext}. Contexts are the
special case whose reaction is "apply this overlay while active"; persistent notifications are the special
case of Notify bound to state; built-in alerts are provider-authored triggers; custom rules are
user-authored ones. All of it resolves through the same state machine (dwell, flap suppression) and the
same conditional-overlay composer — so it stays golden-testable and free of integration-specific logic.

### Locked decisions (reactions)

- **"Persist" is implemented honestly.** A state-bound surface mutation (menu-bar icon/badge holds while the
  condition holds) plus an `.active`/`.timeSensitive` notification that is removed on clear. We do not promise
  iOS-style critical sticky banners on macOS.
- **Confirmation is per-command** via the existing `requiresConfirmation` / a `ConfirmationPolicy`
  (none / whenConsequential / always). Consequential commands default to confirm; confirmation is inline on the
  notification action and a confirm sheet when invoked from the UI.
- **One store, two views for rules.** A rule lives under Notifications while its only reaction is Notify; the
  moment it uses RunCommand / MutateSurface / ApplyContext it also surfaces under "Automations." Same persisted
  declaration, shown in whichever pane fits.

## Universal rule engine — the extensibility contract

Contexts, built-in alerts, custom rules, and reactions are all one thing: a massive, open ruleset
interpreted by a single engine. We will not implement every option up front, but the engine must be
general enough that anything expressible *can* be expressed — including inputs and controls we have not
designed yet. The way to guarantee that is to make the engine an interpreter over a uniform, open registry,
with zero knowledge of any specific integration. The invariants:

1. **Uniform addressing.** Every signal (any entity readout) and every control (any command or settable
   property) has a stable address. Triggers reference any readout by address; reactions reference any
   command/property by address. The engine treats them opaquely — so a field a new provider adds tomorrow is
   instantly a valid trigger source, and a control it adds is instantly a valid reaction target. "Every input
   can be a trigger, even ones we don't cover; every control can be toggled."

2. **Conditions are an open tree, not fixed slots.** Comparisons (`==, <, >, in, changed, transitioned-to`),
   boolean `AND/OR/NOT` with grouping, temporal operators (held-for / within-window / rate-of-change, edge vs
   level), and references to *other* entities' and contexts' states (conditions composed over conditions). A
   condition is an expression tree of arbitrary depth.

3. **Reactions are an open list from a registry.** `{Notify(style, lifecycle, actions[]), MutateSurface(while
   active), RunCommand(ref, params), ApplyContext, …}`. New reaction kinds register without touching the
   engine. Every settable thing is a generic `SettableProperty` with an address, so a reaction can set any
   control the system knows about.

4. **Everything is declarations, not code.** Triggers, conditions, reactions, contexts, and overlays are
   serializable, migratable, golden-testable declarations — provider-authored (built-in) or user-authored
   (custom). The engine is a pure interpreter over them. Coverage grows by adding data, never branches. This
   is the mechanical guarantee behind the existing no-integration-logic grep-gate: the engine literally only
   knows entities, fields, conditions, reactions, and properties.

5. **The UI is generated from the registries.** Pickers (signal picker, command picker, property picker) are
   populated from whatever is registered, so newly-added signals/controls appear automatically. The curated
   builder covers common cases; an **expression / advanced** escape hatch exposes the full address space and
   condition algebra for power users.

6. **Determinism and safety at scale.** A huge ruleset needs deterministic resolution (priority + last-wins +
   base underneath, already decided for contexts), defined evaluation ordering, uniform dwell/flap-suppression,
   cycle detection (rule A applies a context that enables rule B that … back to A), write-conflict resolution
   when two reactions set the same property, rate limiting, and confirmation policies for consequential
   commands. Plus a "why is this active right now?" inspector for debugging the ruleset.

### Scope discipline

v1 ships a curated subset of signals, conditions, reactions, and commands — but built on this interpreter, so
expanding coverage is declarations + UI affordances, not engine surgery. Contexts are simply the meta-rules of
this engine: they read any signal and write any control (including toggling other rules), scoped to while they
are active.

## Interop & prior art

The model isn't novel — and that's reassuring. Existing systems do versions of this, and each maps onto our
primitives, which validates the design.

- **Raycast** — a command registry surfaced in a launcher, plus deeplinks and script commands. Parallels our
  command registry; interop is either exposing our commands as deeplinks or consuming Raycast script commands
  as commands.
- **Shortcuts / App Intents (macOS)** — the OS-level version. The catch you named: an app only participates if
  it is "Shortcuts enabled," i.e. it adopts App Intents.

(Home-automation hubs follow the same entities/triggers/actions shape, so the model generalizes to them later
if we want — but no such bridge is in scope now.)

### Shortcuts is bidirectional

- **Expose** — Ambit adopts the App Intents framework so its registries surface to the OS: entity readouts as
  `AppEntity` + queries, commands (our `CommandDeclaration`s) as `AppIntent`s, and an `AppShortcutsProvider`
  for zero-config phrases. Then "Activate Home context," "Refresh Ping," or any declared command is usable from
  Shortcuts, Spotlight, and Focus filters — and external automations can drive Ambit. This is a concrete build
  item in AmbitMenuBar (the macOS app), and it is exactly what "Shortcuts enabled" requires.
- **Consume** — a `RunShortcut` reaction invokes the user's Shortcuts; more broadly we can call other apps'
  App Intents as commands.

### The unifying rule

Interop stays generic because an integration is simply *anything that contributes addressable signals and/or
controls into the registry* — and Ambit reciprocally exposes its own signals and controls back out via App
Intents. Raycast, Shortcuts, Tesla, a shell script: all the same shape (signals in, commands out), all through
the uniform addressing of the universal engine. This is also why "providers declare commands" was the right
call — those declarations are precisely what become App Intents.

### Build items (later)

- Adopt App Intents / `AppShortcutsProvider` in the macOS app (the "Shortcuts enabled" work).
- `RunShortcut` and `RunAppIntent` reaction kinds.

## Persistence & migration (engine declarations)

Today: `PresentationConfig` persists via `UserDefaultsPresentationConfigStore` with forward-compatible decode;
built-in alert rules are regenerated from provider/manifest declarations each launch, and only an
enabled-toggle (`AlertKindOverride`) persists. Part B keeps that and adds a store for *user-authored* state.

- **What persists:** user-authored rules and contexts (their conditions, reactions, overlays, priority, manual
  override), plus the existing enable-toggles. Built-in declarations stay regenerated, not stored.
- **Versioning:** every persisted declaration carries a `schemaVersion`. Add an `IntegrationConfigMigrator`-style
  migrator with explicit per-version upgrade steps. This replaces today's silent field-drop on shape changes:
  breaking changes get a real migration, additive changes keep forward-compatible decode.
- **Store:** reuse the UserDefaults-backed pattern (or a dedicated file if rule volume warrants); same graceful
  degradation (corrupt → empty, never crash).
- **Tests:** declarations are `Codable` → round-trip golden fixtures per version; the migrator gets old→new
  fixtures; `resolve()` is pure → golden the resolved config; when an existing type is promoted (e.g.
  `AlertKindDeclaration` toward the generic rule shape) add a differential test proving byte-identical output.

## Determinism & safety (resolution)

- **Resolution** = `resolve(base, activeOverlays)`: overlays applied in priority order (drag-rank), last-wins
  per address, base always underneath. Pure and total.
- **Evaluation order** is deterministic: priority ascending, then stable declaration id.
- **Write conflicts** (two reactions/overlays set one address) resolve by the same priority + last-wins, and the
  losing writers are recorded for the "why" inspector.
- **Cycles** (rule → applies context → toggles rule → …) are detected at config-load: the offending rule is
  disabled and a diagnostic surfaced; the runtime never loops.
- **Commands** are rate-limited and gated by `ConfirmationPolicy`.

## Engine phasing (Part B)

Slots on top of the existing `2026-06-27` specs (attention/status-view-model → entity-targeted alerts →
notifications → overlays). Every phase: characterization goldens byte-identical, ping-leak grep-gate green,
differential test whenever an existing type is promoted, eyeball per touched screen.

- **B1 — Condition tree + evaluator.** Introduce `Condition` (comparison / all / any / not / temporal+edge) and
  an evaluator over `EntityState`. Compile the existing fixed `AlertTriggerDeclaration` kinds onto it so output
  is byte-identical (differential test). No UI yet.
- **B2 — Reaction registry.** Generalize alert delivery into `Reaction` — Notify (lifecycle oneShot /
  boundToCondition + action buttons), MutateSurface (while active), RunCommand (wired to the existing
  `execute(commandID:arguments:context:)`), ApplyContext. Existing notification goldens stay green.
- **B3 — User-authored rules + store.** The rule builder UI (picker / expression mock), the versioned store +
  migrator, persistence round-trip goldens. Custom rules appear in Notifications / Automations.
- **B4 — Contexts + overlay stacking.** Context state machine (reusing dwell / flap suppression); `Overlay` as a
  priority-stacked bundle of the existing presentation-override types; the pure `resolve()` + "why" trace +
  cycle detection; the inspector mock.
- **B5 — Signal providers.** Location (CoreLocation geofences), Calendar (EventKit), Network SSID, Focus — each
  behind its permission prompt. They only add entities, so contexts compose over them with no engine change.
- **B6 — App Intents exposure + RunShortcut / RunAppIntent reactions** (the "Shortcuts enabled" work).

Ordering rationale: B1–B2 are pure engine generalizations provable byte-identical against today; B3 adds the
first user-facing authoring; B4 is the headline feature and depends on B1–B3; B5–B6 are additive providers and
OS interop that need no further engine change.

## Status of Part B

Locked: the model, naming (per `schema.md` §10), the decisions above, persistence/migration approach, the
B1–B6 phasing, and the per-phase acceptance checklists below. Remaining before B-build starts: re-verify the
codebase reconciliation in `schema.md` §10 against HEAD at implementation time (it was read once during design).
B1 is the next phase to build.

## Per-phase acceptance checklists

Done = every box checked. The standing gates apply to every phase: characterization goldens byte-identical,
ping-leak grep-gate green, an eyeball on each touched screen, and a differential test whenever an existing
type is promoted.

### Part A — Settings UX

A1 — Rail restructure
- [ ] Monitors grouped by integration, collapsible, searchable; instances nest under their integration.
- [ ] Group status dot reflects the worst instance; a failing instance bubbles a red dot to its group.
- [ ] Surfaces, Alerts, and compact App sections present; every nav target reachable as before.
- [ ] Goldens green; grep-gate green.

A2 — Metric capability cards
- [ ] Entities list replaced by per-metric cards: preview + usage chips + Advanced disclosure.
- [ ] Raw entity IDs no longer shown in normal panes (only in Diagnostics).
- [ ] Toggling a usage maps onto the existing presentation-override data; composition logic unchanged.
- [ ] "Added to …" summary + link to the surface; goldens green.

A3 — Menu-bar builder
- [ ] Live preview, N items, combine/split, drag-order, fed only by the enabled-for-menu-bar set.
- [ ] Output is the same `SlotPresentationOverride` shape the engine already consumes (differential test).
- [ ] Replaces the Slots editor with no change to rendered bar output for an unchanged config.

A4 — Notifications v2
- [ ] Built-in alert kinds grouped by provider; System (and others) declare their `AlertKindDeclaration`s.
- [ ] Permission/test row; status colors; global config (cooldown / quiet hours / snooze).
- [ ] Toggling a kind maps to the existing `AlertKindOverride`; goldens green.

A5 — Language pass
- [ ] Rename map applied; template tokens never shown to users; copy plain and sentence-case.
- [ ] Snapshot / UI tests updated to the new strings.

### Part B — Engine evolution

B1 — Condition tree + evaluator
- [ ] `Condition` (comparison / all / any / not / temporal+edge), `Operand`, `Value` added per `schema.md` §1,4; `Codable`.
- [ ] Evaluator computes truth over current `EntityState` (+ history for temporal); `heldFor` reuses existing dwell.
- [ ] Each existing `AlertTriggerDeclaration` case has a `compile()` to an equivalent `Condition`.
- [ ] Differential test over a state corpus: legacy trigger eval == compiled-`Condition` eval, byte-identical alert outcomes.
- [ ] Table-driven unit tests for every operator and every edge mode (level / rising / falling).
- [ ] No UI, no persisted-format change (Condition used only behind the compile shim); goldens + grep-gate green.

B2 — Reaction registry
- [ ] `Reaction` enum (Notify{level, lifecycle, actions[]}, MutateSurface, RunCommand, ApplyContext) per §5.
- [ ] Alert delivery refactored to emit Reactions; existing notification output byte-identical (golden).
- [ ] RunCommand dispatches via the existing `execute(commandID:arguments:context:)`; `ConfirmationPolicy` enforced.
- [ ] Notification action buttons render and invoke their command.
- [ ] `boundToCondition`: posts on rising edge, clears on falling edge (state-driven test).
- [ ] MutateSurface applies and reverts a surface property while the condition holds (golden on resolved config).

B3 — User-authored rules + store
- [ ] Versioned user-rule store (`schemaVersion`) + migrator; `Codable` round-trip golden fixtures.
- [ ] Rule builder UI (condition picker + reaction palette) writes valid declarations.
- [ ] User rules evaluate through the same engine path as built-ins (shared-path test).
- [ ] Create / edit / delete / reorder survive relaunch; corrupt store → empty, no crash.
- [ ] A v(n−1) fixture migrates to v(n) losslessly.
- [ ] Custom rules appear under Notifications; non-Notify ones also under Automations.

B4 — Contexts + overlay stacking
- [ ] `ContextDeclaration` + `Overlay` (priority-stacked bundle of existing override types) + persistence.
- [ ] Context state machine: condition→active with dwell; manual override (Auto / pinnedActive / pinnedInactive).
- [ ] Pure `resolve(base, activeOverlays)`; golden on resolved config for representative stacks (e.g. Home+Evening).
- [ ] Write-conflict resolution (priority + last-wins) with a recorded "why" trace surfaced in the inspector.
- [ ] Constructed-cycle test: load-time detection disables the offending rule + diagnostic; runtime never loops.
- [ ] Active-context chip in surfaces; base (no contexts active) goldens unchanged.

B5 — Signal providers
- [ ] Location (CoreLocation geofence), Calendar (EventKit), Network SSID, Focus each emit entities.
- [ ] Each gated behind its OS permission; absent permission → unavailable-without-failure, no crash.
- [ ] Entities appear automatically in the signal picker (registry-driven); a context can be built on each.
- [ ] Only provider/registry additions — assert no engine change; grep-gate green; no signal data leaves the device.

B6 — App Intents + Shortcuts
- [ ] App adopts App Intents: readouts as `AppEntity`/queries, commands as `AppIntent`s, `AppShortcutsProvider` phrases.
- [ ] `RunShortcut` + `RunAppIntent` reaction kinds; a rule can invoke a user Shortcut.
- [ ] "Activate <Context>" / "Refresh <monitor>" usable from Shortcuts and Spotlight.
- [ ] No secrets / feed URLs committed; entitlements documented.

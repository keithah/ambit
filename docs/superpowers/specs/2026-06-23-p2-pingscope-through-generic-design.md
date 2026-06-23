# P2 — Pingscope Through Generic Primitives (Design)

**Date:** 2026-06-23
**Status:** Approved (design pending user spec-review).
**Parent spec:** `2026-06-23-presentation-layer-design.md` §7 P2. Read with `presentation-model.md`,
`entity-model.md`. Code is ground truth.

**Goal:** Render pingscope's popover / overlay / settings entirely through the generic AmbitUI card
vocabulary driven by `SurfaceComposer` over pingscope's entities, and delete the bespoke UI. This is the
**eyeball checkpoint** — the first real test that generic primitives feel native in a product the user
knows well. Two entry tasks (P2-1/P2-2 + a doc fix) are genericity-correctness, not pingscope-specific,
and come first.

---

## 0. Decisions settled in brainstorming

1. **Multi-host overlay graph → generic multi-series `historyGraph`.** `CardView.historyGraph` binds *all*
   `spec.entities` as lines (the machinery already exists on `HistoryGraphCard`); `SurfaceComposer`
   collapses multiple same-`deviceClass` measurement entities within a section into one multi-line graph.
   Reusable in P6 (cores/disks). Single entity stays single-line — unchanged look.
2. **Diagnosis → Core synthesizer + a generic severity field.** A small Core helper maps
   `NetworkPerspectiveDiagnosis → (EntityDescriptor, EntityState)` with a generic `Severity` the
   `statusBanner` reads. Diagnoser logic stays in Core; the host produces it from the snapshot for now
   (P3/P4 can promote it to the attention engine / an aggregate). The generic banner render path is the
   point being proved.
3. **Settings: list generic, typed editor deferred to P5.** P2 converts the host *list* + enable / primary
   / delete / add and range / sensitivity to generic cards; the typed per-field `HostEditor` (steppers /
   pickers for interval / timeout / thresholds / alert-preset) stays bespoke until P5 builds the generic
   typed-control renderer. Respects the milestone split.
4. **Stats grid → generic windowed *summary readouts* (not a statTable); recent-samples table dropped.**
   Min/avg/max render as generic readouts derived value-side from `SampleStats` over the windowed series,
   formatted with the unit-aware formatter — generic for any measurement graph, no `statTable` binding
   committed (that stays a P6 item). The recent-samples table is dropped and is **the one parity-watch
   item** flagged for the eyeball checkpoint: if it's missed, that is the signal to add a generic binding
   before P6 — caught in the product the user knows, not discovered at P6.

---

## 1. Architecture deltas

### AmbitCore (generic, additive — existing descriptors/states keep compiling)

- **`GraphGeometry.niceMax`**: replace the latency-only rung ladder (`50…5000`) with a generic
  order-of-magnitude ceiling — smallest of `{1, 2, 2.5, 5, 10} × 10ⁿ` at or above the data max; `100`
  when there is no positive data. Latency series still get sensible ceilings; throughput (bps) no longer
  falls through to the `×1000` branch.
- **`EntityReadout`**: extract the per-`deviceClass`/unit number formatting into a **public** static
  formatter (e.g. `EntityReadout.format(value:deviceClass:unit:)`) so graph axis labels and readouts speak
  one unit vocabulary. `EntityReadout.make` keeps its current behavior by delegating to it.
- **`Severity`** (lifted from parent spec §5; P4 reuses): `normal, elevated, degraded, alerting, down`
  (ascending). Additive **`EntityState.severity: Severity?`** (default `nil`). `EntityReadout.make` maps a
  present `severity → DisplayTone`; absent → existing availability-based tone. No existing caller sets it,
  so behavior is unchanged until P2 wiring.
- **Diagnosis synthesizer** (new, Core, UI-free): `NetworkPerspectiveDiagnosis → (EntityDescriptor,
  EntityState)`. The descriptor is a `.text` diagnostic status entity (stable synthetic `EntityID` owned
  by the pingscope integration namespace, **no `EngineID`**); the state's value is the diagnosis detail
  text and `severity` is mapped from the verdict (`allReachable`/`noData → normal` and the banner is
  omitted; `partialDegradation → degraded`; the `*Down` verdicts → `down`/`alerting`). The banner title is
  the entity name; the detail text is the value.
- **`SurfaceComposer`**:
  - `graphRange` gated to `.historyGraph` cards only (drop on `.gauge`/`.progress`) — **P2-2**.
  - Within a section, collapse multiple measurement entities sharing `deviceClass` (+ unit + a
    sparkline/history graph style) into **one** multi-line `historyGraph` `CardSpec` binding all their
    `EntityID`s. Single such entity → a single-entity `historyGraph` (current behavior).
- **`Engine`**: public accessors for the cached entity descriptors (filterable by integration / instance)
  and the projected current `EntityState`s (via `EntityProjection.states` over the current snapshot) — the
  source the host turns into `SurfaceData`.

### AmbitUI (generic)

- **`CardView.historyGraph`**: bind *all* `spec.entities` as `GraphLine`s (deterministic color per index),
  show the legend when `>1`; thread the primary descriptor's `deviceClass`/`unit` into `HistoryGraphCard`
  for the unit-aware axis label (covers the carried T9 note).
- **`HistoryGraphCard`**: axis label formatted via the Core formatter (unit-generic). Optional **summary
  readouts** (Min/Avg/Max) rendered as a compact readout row beneath the graph, supplied by the value side
  for the single-series case; multi-line (multi-host) relies on the legend. (Decision 4.)
- Summary stats computed value-side in `CardView`/`SurfaceData` from `SampleStats.from(series)` and
  formatted with the Core formatter — generic, not pingscope-specific.

### AmbitMenuBar (shrink + delete bespoke)

- **`StatusViewModel`**: builds `SurfaceData` (descriptors + projected states + windowed series over the
  selected pingscope hosts) and a `SurfacePlan` (`SurfaceComposer` output + the diagnosis banner card).
  Sheds the `PingHostDisplay` / `PingHostRow` bespoke view-model types. Keeps the menu glyph, host
  selection, range, and diagnosis sensitivity (the bar readout stays static — dynamic readout is P4; slot
  hosting is P3). Diagnosis is produced from the snapshot here for now and run through the Core synthesizer.
- **`PingScopePopover`**: body → `SurfaceView(plan:)` + a generic header (host selection rendered via the
  `instanceSelector` card, range picker, overlay/settings buttons as chrome). Delete the `LatencyGraph`
  Canvas, the bespoke stats grid, and the recent-samples table.
- **`PingScopeOverlay`**: render a graph-only `SurfacePlan` through `SurfaceView` inside the retained
  `NSPanel` chrome + context menu (generic chrome).
- **`PingScopeSettings`**: host *list* + enable/primary/delete/add and range/sensitivity rendered generic;
  the typed `HostEditor` form remains the one bespoke piece until P5.

---

## 2. Step sequence (each: `swift build` + `swift test` green; one small commit)

1. **P2-1** — generic `niceMax`; public unit-aware formatter; thread `deviceClass`/`unit` through
   `CardView` → `HistoryGraphCard`. **Verify with a non-latency (throughput) series test** proving the
   axis reads e.g. "Mbps", not "12000000ms".
2. **P2-2** — gate `graphRange` to `.historyGraph` in `SurfaceComposer`; **fold in the parent-spec §Task6
   rule-#3 prose fix** (shipped contract = `isPrimary` → priority desc → stable insertion order).
3. **Multi-series `historyGraph`** — `CardView` multi-line binding + composer same-class collapse. Tests:
   N entities → one card binding N ids; single stays single; deterministic colors/legend.
4. **Generic windowed summary readouts** — Min/Avg/Max on `historyGraph` from `SampleStats`, formatted via
   the Core formatter (single-series). Tests: formatting + unit correctness.
5. **`Severity` + banner tone** — `Severity` enum, `EntityState.severity`, `EntityReadout` mapping. Tests:
   severity → tone precedence over availability.
6. **Diagnosis synthesizer** — `NetworkPerspectiveDiagnosis → entity`; verdict → severity + text + banner
   gating. Tests across verdicts/scopes.
7. **Engine entity API** — public descriptors + projected states; tests over pingscope instances.
8. **Popover via `SurfaceView`** — assemble `SurfaceData`/`SurfacePlan`, swap the popover body, delete the
   `LatencyGraph` Canvas + bespoke stats grid + recent-samples table. Build + visual check.
9. **Overlay + settings-list generic** — overlay through `SurfaceView`; settings host-list generic; delete
   the corresponding bespoke code. Build + visual check.

---

## 3. Hard rules (carried from the brief)

- `swift build` + `swift test` green after **every** step; one small commit per step. Deleting tests for
  intentionally-removed bespoke UI is fine; don't weaken tests for code that stays.
- Never edit `~/src/pingscope` or `~/src/glinet-travel`. **No `EngineID` in any id** (synthetic diagnosis
  id included).
- No new pingscope-specific UI — a missing capability is a missing *primitive*, added to the generic
  vocabulary, never a pingscope special-case.

## 4. Checkpoint

After P2 the user compares pingscope-through-generic against the real pingscope side by side. Bar: **at
least as good as the bespoke Canvas UI.** Known parity-watch item: the dropped recent-samples table. Any
visible downgrade (the history graph especially) is fixed in the **primitive** before P6.

## 5. Non-goals (P2)

- No generic typed-control settings renderer (P5). No slot model / dynamic bar readout (P3/P4). No
  `statTable` tabular-binding design (P6). No data-model refactor.

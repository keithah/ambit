# Ambit — Project Handoff

Context dump for picking this project up fresh (new session / different account). Read this, then the
design docs it references. The design docs and the code are the source of truth; this is the map.

---

## 1. What Ambit is

An extensible, **self-hosted engine + polished native apps** that put every connected thing — routers,
ISPs, Starlink, VPNs, EVs, power stations, system stats — into ambient, glanceable menubar/phone surfaces,
instead of one bloated vendor app per device. **"iStat Menus you can extend" / "Homebridge-meets-Raycast."**

- **Deterministic, not chat.** For a known action a button beats "ask an agent and hope it picks the right
  tool." AI lives *behind* the controls (anomaly detection, rule authoring, generating integrations), never
  as the primary interface. Positioned against the OpenClaw "everything through a chatbox" tide.
- **Monitor + control** are the same primitive seen two ways: typed **state** you read, **commands** you fire.
- **Cross-platform:** macOS first, iOS later. The engine is Swift, kept UI-free so it also runs on a Linux box.
- **Business model (Obsidian/Raycast/Plex):** open engine + open integrations, closed polished apps, free
  local tier; **Pro = the 24/7 cloud relay** that watches your stuff and notifies you (the one thing that's
  hard to self-host). Name is **Ambit** (ships as `ambit.app`).
- **Moat is the platform, not the integrations** — integrations are commodity/community-owned by design.

---

## 2. Repos (and the hard rule about donors)

- **`~/src/ambit`** — THE product. All work happens here. Swift package.
- **`~/src/pingscope`** — a separate, shipped macOS latency-monitor app. It was the **donor/oracle** for the
  network-monitoring integration and the presentation primitives. **NEVER edit it.**
- **`~/src/glinet-travel`** — donor/oracle for the original engine/provider architecture (gl.inet + Starlink +
  Speedify + EcoFlow menubar app). **NEVER edit it.**

Ambit was seeded from glinet-travel, then largely rebuilt. Pingscope was rebuilt *natively* inside Ambit as
the `ping` integration (not ported — reimplemented against Ambit's model, using pingscope as the behavior oracle).

### Module layout
- **`AmbitCore`** — UI-free (no SwiftUI/AppKit). Identity, entity model, the generic engines, registry,
  composer, resolver, config store. The CLI target `AmbitCheck` can dump plans headlessly to prove it's UI-free.
- **`AmbitUI`** — SwiftUI library (macOS 13+, iOS-ready): the generic card vocabulary + chrome.
- **`AmbitMenuBar`** — thin: status-item wiring + AmbitUI. `StatusViewModel` is a slot host.
- **`AmbitCheck`** — headless CLI.

---

## 3. Design docs (source of truth, in `~/src/ambit`)

Each owns one concern; they cross-reference each other in a header block.
- **`integration-model.md`** — the installable unit: Integration → IntegrationInstance → providers ("install
  gl.inet" ⇒ router + vpn). Owns the identity hierarchy.
- **`entity-model.md`** — the Provider→Entity abstraction (EntityDescriptor + EntityState) integrations are
  authored against.
- **`provider-capability-model.md`** — grouping & membership (profiles + capabilities → surfaces).
- **`presentation-model.md`** — the generic, opinionated presentation layer + the Attention engine + settings.
- **`engine-topology.md`** — multi-engine & multi-instance: peer-to-peer ownership, failover, dedup (Phase 3).
- **`docs/superpowers/specs/`** — dated, milestone-level design specs (presentation-layer, P2, etc.).
- **`product-spec.md` / `pitch.md`** — the product/business framing.

---

## 4. Core architecture

**Identity (engine-independent; no `EngineID` ever appears in any id):**
`IntegrationID` (e.g. `"ping"`) → `IntegrationInstanceID` (deterministic from target, e.g. `ping@1.1.1.1:443`)
→ `ProviderInstanceID` (`<instance>/<providerType>`) → `EntityID` (`<providerInstance>.<key>`). Deterministic
so two engines name the same thing identically (needed for failover).

**Entity model:** `EntityDescriptor` (static identity + type metadata — `EntityKind`, `DeviceClass`,
`EntityCategory`, `StateClass`, capability, presentation-defaults) + `EntityState` (dynamic — value,
`Availability` online/stale/unavailable, `Severity`). `EntityProjection` derives them. Descriptors persist
when a provider is offline (offline stability). The Metric-based `ProviderDisplayModel`/`SurfaceModel`/
`MetricSection` were **retired** in favor of the entity-driven `SurfaceComposer`.

**Generic engines in `AmbitCore` (built, shaped by pingscope, reusable by any integration):**
- `IntegrationRegistry` (+ `UserDefaults` store) — enable/disable at integration-type and instance
  granularity; Engine assembles providers from active instances via the `Integration` protocol.
- `HistoryService` — SQLite, `EntityID`-keyed, Engine-fed automatically, `stateClass`-gated, retention/prune,
  swappable store. Every integration gets history + sparklines for free.
- `AlertEngine` — threshold / state-transition / sustained rules, cooldown/recovery, consecutive-sample debounce.
- `HealthState` — stateful (thresholds → degraded, consecutive-failures → down, transition timestamps).
- `SurfaceComposer` — entity → `CardSpec`/`SurfacePlan` (the "which card bound to what" decision, UI-free/testable).
- `SlotResolver` — resolves a slot's `SlotSelection` against live descriptors + registry records.
- `PresentationConfig` (+ `UserDefaults` store) — persisted slots + per-entity/per-integration overrides.

**Presentation (generic, opinionated — the Raycast bet, not HA-style user-composed dashboards):**
- Card vocabulary (`AmbitUI`): statusRow, gauge/ring, historyGraph (multi-series), dualLineGraph, progress,
  statTable, control, instanceSelector, section, statusBanner.
- **Slots** unify dedicated vs combined: `SlotSelection = .integration | .integrations | .integrationType
  (all live instances of an integration, dynamic, no membership sync) | .capability | .entities`. The menu bar
  renders one status item per slot (static bar readout in P3; dynamic comes in P4) + a generic `SurfaceView`.
- **Settings** = generic, progressively disclosed (zero-setup defaults from descriptors → per-integration
  show/hide/pin → power drill-in), no bespoke per-provider settings.

**Engine topology (Phase 3, designed not built):** multiple engines (Mac + always-on Linux box + phone),
**peer-to-peer, no coordinator.** Ownership is *computed* (weighted: always-on > laptop > phone, uptime
tiebreak), mesh-presence required to participate, failover via membership, make-before-break handoff with a
tunable overlap (`maxOverlap`, default ~30s; 0 = strict). Phone = last resort. The Pro relay is an optional
aggregator/viewport, never the coordinator.

---

## 5. Build status (what's merged on master)

- **Entity-model Phase 1** — identity hierarchy, descriptor/state, projection, descriptor classification,
  retired the Metric-based display models.
- **Pingscope program M0–M6** — registry + enable/disable; `ping` as a real multi-instance integration
  (host = instance); TCP/UDP/ICMP probes; the shared `HistoryService`; `AlertEngine` upgrade; the macOS UI;
  tier-diagnosis (`NetworkPerspectiveDiagnosis`).
- **`pingscope → ping` rename** (RESET migration) — merged.
- **Presentation program: P1, P2, P3 merged.**
  - P1: generic card vocabulary + `SurfaceComposer` (retired old display models).
  - P2: pingscope renders entirely through generic primitives; bespoke Canvas UI deleted. (Recent-samples
    table deferred to P6.)
  - P3: slot model + generic chrome; menu bar is slot-driven; `.integrationType("ping")`; `StatusViewModel`
    shrunk to a slot host; `PingGlyphRenderer → StatusGlyphRenderer`.
- Current: ~351 tests green on master. The app runs as **"Ping"**, all hosts polling through slot-driven chrome.
- **Device integrations (gl.inet/speedify/ecoflow/starlink/iperf3/reachability) are seeded DISABLED.** Only
  `ping` is active. They'll be rebuilt later against the proven shape. The old basic `ping` built-in was
  retired (superseded by the pingscope-derived `ping` integration).

---

## 6. Roadmap (presentation program)

- **HARDENING TASK (in flight, before P4)** — see §7.
- **P4 — Attention engine.** The dynamic, "show what matters now" bar readout (the differentiator vs static
  iStat). Three-tier escalation: detail → surfaced → alerted, with **separate display vs alert thresholds**;
  per-entity visibility (always/auto/never); severity+priority ranking; per-surface capacity/overflow;
  consumer of Health/Alert state; surface-agnostic (Dynamic Island/Live Activity are later renderers). Also:
  promote the host-produced ping diagnosis banner to a generic/attention-emitted entity. **The staleness fix
  (§7) lands its richer severity/attention integration here.**
- **P5 — Generic progressive-disclosure settings** renderer (deletes remaining bespoke settings; the typed
  per-field host editor that P3 left bespoke).
- **P6 — Second integration: `system` (iStat-style)** — CPU/mem/disk/network/sensors/fans/battery. **This is
  THE PROOF** of the "consistent whether 2 or 20" thesis: it must render through the SAME generic primitives
  with ZERO bespoke UI (exercises gauges/rings/progress/process-table). Public-API metrics first; SMC
  sensors/fans as a flagged, gracefully-degrading sub-step. Settle the `statTable` tabular-binding design here
  (the deferred recent-samples table + process/disk lists are the real driver). **NOTE: "StarBar"
  (starbar.app) is the *Starlink dish* app — a separate, later integration, NOT the system one; iStat is the
  system-stats reference.**
- **Later:** Starlink integration (reconcile with ping's existing Starlink probe); capability-surface UI;
  multi-engine topology (Phase 3); iOS/widgets/Live Activity; real packaging.

---

## 7. In-flight hardening task (decisions locked, being planned/built)

A monitoring tool that silently stops monitoring and falsely says "Local network down" is a **correctness
bug in the core value prop.** It has disrupted eyeball checkpoints three times (App Nap ×2, system sleep).
Being fixed on its own branch **before P4.** Two parts:

1. **Loop resilience (pure engine correctness).** Root cause: `withTaskGroup` *awaits* a wedged probe.
   - Fix: rewrite `TimeoutProbe` to **abandon-the-loser** — resolve via a continuation on first-to-finish
     (probe OR deadline); on deadline return `.timeout` and best-effort-cancel the in-flight probe **without
     awaiting it**. Reuse the existing resolve-once `ContinuationGate`. Ensure wedged probes don't leak
     unbounded.
   - **Wake observer** (`NSWorkspace.didWake`) kicks a fresh cycle; **stall watchdog** (no completed cycle in
     interval×N → cancel + restart).
2. **Staleness-vs-down (fix the core now; richer severity/attention integration deferred to P4).**
   - No fresh sample within **interval × N (N=3, floored ~10s)** → `Availability.stale`, **never down**.
   - **CRITICAL:** staleness must be evaluated against wall-clock *now* on a cadence **independent of the poll
     loop** (a refresh timer) — a stalled loop produces no snapshots, so a poll-driven projection would never
     fire. Model availability as a pure function of `(lastUpdated, interval, now)`, recomputed on refresh.
   - The diagnoser must **suppress** network-fault/down inference on stale data (you can't diagnose from data
     you didn't collect) and report a distinct **"Monitoring paused"** state, not `noData`, not "down."

---

## 8. Principles & conventions (how this project is run)

- **Harvest, don't predict.** Generic layers are extracted from real, shipped products (glinet-travel for the
  engine; pingscope for the domain + presentation), validated against them as oracles — not designed in the abstract.
- **Refactor in place, stay green.** `swift build` + `swift test` pass after **every** step; **one small
  commit per step**; never weaken tests for code that stays (deleting tests for intentionally-removed code is fine).
- **AmbitCore stays UI-free.** Generic logic in Core; views in AmbitUI/AmbitMenuBar.
- **No `EngineID` in any entity/instance id** (breaks failover).
- **No integration-specific UI.** A gap is a *missing primitive* added to the generic vocabulary, never a
  per-provider special-case. Turn "special" things (e.g. the diagnosis banner) into generic primitives.
- **Never edit the donor repos** (`~/src/pingscope`, `~/src/glinet-travel`).
- **Eyeball checkpoints** validate that generic primitives feel first-class (bar: "at least as good as the
  bespoke version"). These keep catching real bugs — trust them.

---

## 9. Workflow (the two-role loop)

- A **CLI coding agent** (Claude Code / Codex) does the building: brainstorm → post a phased plan + key type
  signatures for approval → implement step by step (green between) → spec+quality-gated, branch per
  milestone, merge via the finishing-a-development-branch flow, delete branch.
- A **design-review partner** (this chat's role) reviews each plan before implementation, adjudicates design
  decisions, and gives go/no-go. **Plan-as-you-reach-it** — don't pre-plan far-future milestones; each gets
  its own plan when reached.
- **Dev run recipe:** there's a run skill for launching Ambit (hand-rolled `.app` bundle + ad-hoc codesign +
  `NSAppSleepDisabled`; `swift run` alone crashes on `UNUserNotificationCenter`). App is `.accessory` (menu
  bar only, no dock icon).

---

## 10. How to resume right now

1. Finish the **hardening task** (§7) — its own branch before P4. Have the CLI brainstorm/plan it; review the
   plan (watch hardest: the staleness must be **time-driven, not poll-driven**, or it silently won't fire).
2. Then **P4 (Attention engine)** — the differentiator, and where the staleness severity/attention work lands.
3. Then P5 (settings), then **P6 (system integration = the proof)**.
4. Keep device integrations disabled until after P6 proves the multi-provider presentation.

Open the design docs in §3 for full detail on anything above — they're current and authoritative.

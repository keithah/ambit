# Poll-Loop Resilience + Staleness-vs-Down (Hardening) — Design

**Date:** 2026-06-24
**Status:** Approved (decisions settled in brainstorming; pending user spec-review).
**Read with:** `presentation-model.md`, `entity-model.md`. Code is ground truth.

**Goal:** Fix the correctness bug that has disrupted three eyeball checkpoints (App Nap ×2, system
sleep ×1): the app silently stops monitoring and then falsely reports "Local network down." A focused
hardening task before P4 — loop resilience + the `Availability.stale` primitive + killing the
false-down. NOT the attention engine (P4).

---

## 0. Root cause (proven)

`TimeoutProbe.measure` (Sources/AmbitCore/Ping/Probes.swift) races the probe against `Task.sleep`
inside `withTaskGroup`. `withTaskGroup` is **structured** — it does not return until *all* child
tasks finish. When the wrapped `NWConnection` probe is wedged (a socket stuck across system sleep,
not honoring cancellation), the group blocks **forever even though the timeout fired** →
`measure()` never returns → the sequential `refresh()` cycle wedges on it → the poll loop hangs and
nothing (timer, wake) recovers it. It sat dead 5.5 h overnight.

Corollaries confirmed in the code:
- `Availability.stale` is **defined but never produced** — `EntityProjection.state` only emits
  `.online`/`.unavailable`; `EntityReadout` maps `.stale → .warn` but nothing sets it.
- The diagnoser (`NetworkPerspectiveDiagnoser`) infers "down" from the snapshot's *last* health, with
  no notion of staleness — so a frozen loop's stale `.down` escalates to "Local network down."
- The poll loop runs `refresh()` inline with no per-cycle cancellation.
- `NSWorkspace` wake notifications are AppKit → the wake observer lives in `AmbitMenuBar`, not Core.
- The existing single-resume guard is `SingleResume.claim()` (TCP/UDP probes already use it).

---

## 1. Part 1 — Loop resilience (Core; fix fully)

### 1a. Abandon-the-loser probe deadline (the load-bearing fix)
Rewrite `TimeoutProbe.measure` so it never awaits the loser. Race the wrapped probe against a
wall-clock deadline using a `withCheckedContinuation` guarded by `SingleResume`:
- two **unstructured** tasks (the probe, and a `Task.sleep(deadline)`); whichever finishes first
  `claim()`s the gate and resumes the continuation with its result (probe outcome) / `.timeout`.
- the continuation returns as soon as one side wins — it does **not** await the other.
- on deadline-wins, **best-effort cancel** the in-flight probe (cancel its `Task`; the probe's own
  teardown cancels the `NWConnection` via its existing `SingleResume` path). A wedged socket can no
  longer block the cycle.
- **No leak:** the abandoned probe Task is cancelled, and the stall watchdog (1b) reclaims anything
  the cancel can't (so a stuck socket every 2 s for hours can't accumulate). Hold the probe Task
  handle and cancel it on deadline.

Same public API (`func measure(_:) async -> ProbeResult`).

### 1b. Cancellable cycle + stall watchdog (Core)
Run each `refresh()` cycle as a child `Task` the Engine holds. A watchdog: if the in-flight cycle
hasn't completed within `interval × N` (the staleness window, §2), cancel that Task and start a
fresh cycle. General net for hung-probe / App-Nap / sleep — independent of whether any single probe
cooperates.

### 1c. Wake observer (AmbitMenuBar — Core stays UI-free)
An `NSWorkspace.didWakeNotification` observer (in the app layer) calls a new `Engine.pollNow()` to
kick a fresh cycle on wake — the targeted system-sleep fix. Core exposes `pollNow()`; the AppKit
observer lives in the menu-bar app.

---

## 2. Part 2 — Staleness-vs-down (establish the primitive, kill false-down)

### 2a. Time-driven staleness (THE make-or-break detail)
Staleness MUST be a pure function of `(lastUpdate, interval, now)` recomputed against wall-clock
`now` on a **time-driven tick**, NOT a value stamped once at poll time. The whole failure is that
the loop stopped producing snapshots — so if staleness is only computed inside the poll-driven
projection, a stalled loop never re-projects and the UI shows the last `.online` snapshot frozen
forever. Therefore:

```swift
// Core, pure
public enum Staleness {
    /// Window = max(interval × factor, floor). Default factor 3, floor ~10s.
    public static func isStale(lastUpdate: Date?, interval: TimeInterval, now: Date, factor: Int = 3, floor: TimeInterval = 10) -> Bool
    /// Downgrades .online → .stale when the backing data is older than the window; leaves
    /// .unavailable as-is.
    public static func availability(_ base: Availability, lastUpdate: Date?, interval: TimeInterval, now: Date, factor: Int = 3, floor: TimeInterval = 10) -> Availability
}
```
- The poll-time projection uses it (entities go `.stale` when old at poll time).
- A **time-driven tick** in the menu-bar host (a `Timer`, ~every few seconds, independent of engine
  snapshots) recomputes slot-surface staleness + the diagnosis against `now` and re-publishes — so
  even when the loop stalls, entities flip to `.stale` and the banner flips to "Monitoring paused"
  rather than freezing on the last online state. (Part 1's watchdog/wake then recover polling; this
  tick guarantees honest UI during any gap.)

`Availability.stale` (the dead primitive) thus comes alive; `EntityReadout` already maps it to `.warn`.

### 2b. Diagnoser: suppress fault inference on stale data (the real fix)
The non-negotiable change: **when data is stale, the diagnoser stops inferring network faults** — you
cannot diagnose "Local network down" from data you didn't collect.
- Add `var isStale: Bool` to `DiagnosisHost`.
- Stale hosts are excluded from the up/down tier inference.
- When staleness is the cause (no fresh data to infer from), the diagnoser returns a distinct
  **`.monitoringStalled`** verdict, surfaced as **"Monitoring paused — data is N old."** — never a
  down/up-tier fault. (`.noData` keeps its meaning: "no samples yet / just started.")

Deeper modeling — how `.stale` interacts with severity/attention tiers and how the stale tier
surfaces in glance surfaces — is **P4**. Here we establish the primitive + suppression + honest label.

---

## 3. Tests (the validation method we're protecting — make them real)

- **Probe deadline fires & abandons:** a never-resolving probe wrapped by `TimeoutProbe` returns
  `.timeout` within the deadline and does not block (no await of the loser); the wrapped probe is
  cancelled.
- **Watchdog restarts a stalled cycle;** `pollNow()` kicks a fresh cycle.
- **Time-driven staleness:** with a fixed `now` advanced past `interval × N` and no fresh update,
  `Staleness.availability(.online, …)` → `.stale`; within the window → `.online`.
- **Diagnoser suppression:** a stalled window (hosts `isStale = true`) → diagnoser returns
  `.monitoringStalled`, NOT `.localNetworkDown` — even when the last health was `.down`.

(Probe/watchdog timing tests use injected clocks / fixed dates — no real sleeping; the stall
watchdog is driven by an injectable time source, not wall-clock waits in tests.)

---

## 4. Scope / non-goals

- **In:** probe abandonment, cancellable cycle + watchdog, wake observer, the `Staleness` primitive +
  time-driven evaluation, `Availability.stale` production, diagnoser stale-suppression + "Monitoring
  paused" verdict.
- **Out (P4):** the AttentionEngine; how `.stale` maps to severity/attention tiers; dynamic
  attention bar readout. **Out:** parallelizing the sequential provider poll (pre-existing; not this task).

## 5. Hard rules
`swift build` + `swift test` green after every step; one small commit per step; `AmbitCore` stays
UI-free (probe/watchdog/staleness/diagnoser in Core; wake observer + time-driven tick in
AmbitMenuBar); never edit `~/src/pingscope` or `~/src/glinet-travel`; no `EngineID` in any id; don't
weaken tests for code that stays.

## 6. Verification (empirical, after it lands)
The dev app survives sleep/relaunch and never shows a false "Local network down": induce a stale
window (or sleep), confirm the banner reads "Monitoring paused," entities show `.stale`, and polling
resumes (watchdog/wake) with the banner clearing — verified via the run-ambit skill + the SQLite store.

# Poll-Loop Resilience + Staleness-vs-Down — Implementation Plan

> **For agentic workers:** execute task-by-task, green between. Steps use `- [ ]`. This task posts each phase's plan + signatures for review BEFORE implementing it.

**Goal:** The app must never silently stop monitoring and never falsely report "Local network down" — bound hung probes, recover the poll loop after sleep/App-Nap, and make data staleness a first-class state that suppresses fault inference.

**Architecture:** Part 1 (Core) hardens the probe deadline (abandon-the-loser) and the poll loop (cancellable cycle + stall watchdog + `pollNow()`). Part 2 establishes a pure, time-driven `Staleness` primitive, produces `Availability.stale`, and makes the diagnoser suppress fault inference on stale data (a distinct "Monitoring paused" verdict). The AppKit wake observer + the time-driven refresh tick live in AmbitMenuBar.

**Tech Stack:** Swift 5.9+, SwiftPM, XCTest, Network.framework (probes), AppKit (`NSWorkspace`, app layer only).

## Global Constraints
- `swift build` + `swift test` green after EVERY step; one small commit per step.
- `AmbitCore` stays UI-free — no SwiftUI/AppKit/`NSWorkspace` in Core (probe/watchdog/staleness/diagnoser in Core; wake observer + the ~5s tick in AmbitMenuBar).
- Never edit `~/src/pingscope` or `~/src/glinet-travel`. No `EngineID` in any id.
- Don't weaken tests for code that stays. Tests use injected clocks / fixed `Date`s — **no real sleeping**.
- Staleness window = `max(interval × factor, floor)`, factor 3, floor 10s. Staleness evaluated against wall-clock `now` on a tick **independent of the poll loop** (the make-or-break detail).

---

## Phase 1 — Loop resilience (Core)

### Task 1: TimeoutProbe abandon-the-loser
**Files:** Modify `Sources/AmbitCore/Ping/Probes.swift` (`TimeoutProbe`); Test `Tests/AmbitCoreTests/PingProbesTests.swift`.
**Interfaces:** Produces `TimeoutProbe.measure(_:) async -> ProbeResult` (unchanged API). Reuses `SingleResume` (Probes-adjacent, TCPProbe.swift).
Rewrite to race the wrapped probe vs a deadline via `withCheckedContinuation` guarded by a `SingleResume`: two **unstructured** `Task`s (probe; `Task.sleep(timeout)`), first to `claim()` resumes the continuation; the continuation returns WITHOUT awaiting the loser. On deadline-win → resume `.timeout` and `cancel()` the probe Task (best-effort; its `SingleResume` path cancels the `NWConnection`). Hold the probe Task handle so it's cancelled (no unbounded accumulation of wedged sockets — the watchdog is the second net).
TDD: a `NeverResolvingProbe` (returns nothing) wrapped in `TimeoutProbe` with a tiny timeout (e.g. 0.05s) → `measure` returns `.timeout` promptly and does not hang (test has its own timeout/`XCTestExpectation`); a fast probe still returns its real result (loser-not-awaited doesn't drop the winner).

### Task 4 (sequenced after 2–3): Engine cancellable cycle + watchdog + pollNow()
**Files:** Modify `Sources/AmbitCore/Engine.swift`; Test `Tests/AmbitCoreTests/EnginePollLoopTests.swift`.
**Interfaces:** Produces `Engine.pollNow()` (kick a fresh cycle — distinct from `refresh()`); a pure watchdog decision helper `static func shouldRestartCycle(cycleStartedAt: Date?, now: Date, window: TimeInterval) -> Bool`.
The poll loop runs each `refresh()` as a child `Task` the Engine holds (`cycleTask`) with a recorded start time; the loop (or a watchdog tick) calls `shouldRestartCycle`; if true, `cycleTask?.cancel()` and start a fresh cycle. `pollNow()` cancels any in-flight cycle and starts a fresh one immediately.
TDD: unit-test `shouldRestartCycle` against fixed dates (nil start → false; within window → false; past window → true). Light integration: an Engine with a `NeverResolvingProbe`-backed provider; `pollNow()` returns/kicks without hanging (probe deadline from Task 1 bounds it). No real long sleeps.

---

## Phase 2 — Staleness-vs-down (Core)

### Task 2: Staleness pure helper
**Files:** Create `Sources/AmbitCore/Presentation/Staleness.swift`; Test `Tests/AmbitCoreTests/StalenessTests.swift`.
**Interfaces (Produces):**
```swift
public enum Staleness {
    public static func window(interval: TimeInterval, factor: Int = 3, floor: TimeInterval = 10) -> TimeInterval   // max(interval*factor, floor)
    public static func isStale(lastUpdate: Date?, interval: TimeInterval, now: Date, factor: Int = 3, floor: TimeInterval = 10) -> Bool   // nil lastUpdate => stale
    public static func availability(_ base: Availability, lastUpdate: Date?, interval: TimeInterval, now: Date, factor: Int = 3, floor: TimeInterval = 10) -> Availability   // .online → .stale past window; .unavailable unchanged
}
```
TDD (fixed dates): within window → not stale / `.online` preserved; past window → stale / `.online`→`.stale`; `nil` lastUpdate → stale; `.unavailable` stays `.unavailable`; window floors at 10s for a 2s interval.

### Task 3: Diagnoser suppresses fault inference on stale data
**Files:** Modify `Sources/AmbitCore/Ping/NetworkDiagnosis.swift`; Test `Tests/AmbitCoreTests/NetworkDiagnosisTests.swift`.
**Interfaces:** `DiagnosisHost` gains `public var isStale: Bool` (default false, last init param — additive). `Scope` + `Verdict` gain `case monitoringStalled`. `diagnose` excludes stale hosts from inference: `observed = hosts.filter { $0.status != .noData && !$0.isStale }`; if `observed` is empty AND any host `isStale` → return `.monitoringStalled` ("Monitoring paused", "No fresh data — monitoring resuming."); else the existing `.noData`.
TDD: hosts with last health `.down` but `isStale = true` → verdict `.monitoringStalled`, NOT `.localNetworkDown`; a mix (one fresh down, one stale) → infers only from the fresh host; all fresh → unchanged behavior (existing tests stay green, `isStale` defaults false).

---

## Phase 3 — Wake observer + time-driven tick (AmbitMenuBar)

### Task 5: Wire staleness into the host + wake/tick
**Files:** Modify `Sources/AmbitMenuBar/StatusViewModel.swift` (compute per-host `isStale` from latest-sample age vs `now`; downgrade entity `Availability` via `Staleness.availability`; pass `isStale` to `DiagnosisHost`; a ~5s `Timer` calling `refreshPing` independent of engine snapshots) + `Sources/AmbitMenuBar/App.swift` (`NSWorkspace.didWakeNotification` → `engine.pollNow()`).
No new unit tests (UI/wiring; Core logic is covered by Tasks 1–4). Verify by `swift build` + empirical run-ambit check: induce a stale window (or sleep), confirm banner reads "Monitoring paused", entities show stale, and polling resumes with the banner clearing.

---

## Self-review notes
- Spec coverage: 1a→Task1; 1b/1c→Task4; 2a→Task2+Task5(tick); 2b→Task3+Task5(wiring). All spec items mapped.
- Order of execution: **Task 1, Task 2, Task 3, Task 4, Task 5** (probe + staleness + diagnoser are independent Core; watchdog uses the bounded probe; wiring last).
- Each phase's detailed step list + signatures is posted for review before implementing it.

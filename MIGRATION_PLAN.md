# glinet-travel → Provider Engine — Migration Plan

**Audience:** a coding agent (Codex) executing this without prior conversation context.
**Goal:** evolve glinet-travel from a fixed, hand-wired menubar app into an **extensible, provider-based monitoring/control engine** — the reference implementation for a larger ambient-device-control platform.

This is a **refactor in place**, not a rewrite. The app must compile and the test suite must stay green after **every** step. Work step by step, commit per step, and preserve exact current behavior unless a step explicitly changes it.

---

## Guiding principles

1. **Harvest, don't predict.** We already have five working integrations. The abstractions below are *derived* from them and are starting points — refine the protocol shapes against the real code, don't force the code to match a guessed protocol.
2. **Refactor in place, stay green.** After each step: `swift build` succeeds, `swift test` passes, the menubar app launches and shows the same data, and the existing controls (VPN toggle, Speedify connect/bonding, EcoFlow output) still work.
3. **Engine is platform-agnostic.** All new engine code lives in `GLiNetCore` with **no SwiftUI/AppKit imports**. The `RouterCheck` CLI must be able to drive the same engine headlessly — that's the proof the boundary is clean.
4. **Behavior parity is sacred.** The messy real-world logic (router login backoff, Speedify focus fast-poll, endpoint auto-resolution, EcoFlow enable-gating, Keychain credentials) must be preserved exactly. These behaviors are *features*, not accidents.
5. **Scope discipline.** Do **only** what's in the staged plan. Explicit non-goals are listed at the end.

---

## Current architecture (as-is)

Swift package `GLiNetTravel` (swift-tools 6.0, macOS 13). Targets:

- **`GLiNetCore`** (library, AppKit-free) — the logic layer.
- **`GLiNetMenuBar`** (executable) — SwiftUI menubar app, depends on Core.
- **`RouterCheck`** (executable) — headless CLI, depends on Core. *(Proof the core runs without UI.)*
- **`GLiNetCoreTests`** — substantial unit-test suite.

Key Core types:

- **Per-service clients:** `GLiNetClient` (+`GLiNetClientPool`), `StarlinkClient` (+`StarlinkClientProtocol`), `SpeedifyClient`, `RouterSpeedifyClient`, `EcoFlowHTTPClient`, `ReachabilityProbe` (+`ReachabilityProbeProtocol`).
- **Per-service status structs:** `RouterStatus`, `VPNStatus`, `ReachabilityStatus`, `SpeedifyStatus`, `StarlinkStatus`, `EcoFlowSnapshot`.
- **State envelope:** `SourceState<Value>` (`value` / `isLoading` / `errorMessage`) — generic, reusable.
- **Aggregate:** `StatusSnapshot` — a struct with **one hardcoded field per source**.
- **Support:** `CredentialStore`/`KeychainCredentialStore`, `Settings`/`AppSettings`/`SettingsStore`, `EndpointSelector`/`EndpointSelection`, `ProcessRunner`/`SystemProcessRunner`, `JSONRPC`/`JSONValue`, `AggregateVPNStatus`, `InternetInterfaceStatus`.

**Where the "engine" currently lives (the problem):** `GLiNetMenuBar/StatusViewModel.swift` — a `@MainActor ObservableObject` — owns the poll loop (`start()`/`refresh()`), snapshot assembly, the Speedify focus fast-poll (`speedifyFocusTask`), the router login backoff (`routerBackoffUntil`), endpoint resolution, and **all command methods** (`toggleVPN`, `toggleSpeedify`, `setSpeedifyBondingMode`, `setSpeedifyNetworkPriority`, `setEcoFlowOutput`). The engine is fused to the UI, and `StatusSnapshot` hardcodes the provider set. These are the two coupling points the migration removes.

---

## Target architecture (to-be)

A small set of protocols in `GLiNetCore`. **These signatures are illustrative starting points** — adjust names/shape to fit the real code and Swift 6 concurrency, but keep the intent.

```swift
public typealias ProviderID = String

/// A monitored/controllable thing. One per integration.
public protocol Provider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    /// Desired poll cadence; the engine may clamp it.
    var pollInterval: TimeInterval { get }
    /// Read current state using shared context.
    func poll(context: EnvironmentContext) async -> ProviderSnapshot
    /// Declared, dispatchable actions (metadata only).
    var commands: [CommandDescriptor] { get }
    /// Execute one declared command. No-op default for read-only providers.
    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws
}

/// Normalized result of a poll. Keep rich per-provider detail AND a normalized facet.
public struct ProviderSnapshot: Sendable, Equatable {
    public var health: Health            // .ok / .degraded / .down / .unknown
    public var metrics: [Metric]         // normalized — feeds widgets + alerts
    public var detail: ProviderDetail?   // boxed existing struct (RouterStatus, StarlinkStatus, …) — nothing lost
    public var error: String?
}

public enum Health: Sendable, Equatable { case ok, degraded, down, unknown }

/// Normalized, provider-agnostic metric the UI and alert engine can bind to
/// without knowing what produced it.
public struct Metric: Sendable, Equatable, Identifiable {
    public var id: String                // e.g. "downlink_bps", "pop_latency_ms"
    public var label: String
    public var value: MetricValue
}

public enum MetricValue: Sendable, Equatable {
    case throughput(bitsPerSecond: Int)
    case latency(ms: Double)
    case percent(Double)                 // 0–100
    case level(Double)                   // e.g. battery %
    case bool(Bool)                      // e.g. connected
    case text(String)                    // e.g. state string
}

public struct CommandDescriptor: Sendable, Identifiable {
    public var id: String                // e.g. "vpn.toggle", "ecoflow.setOutput"
    public var label: String
    public var parameters: [CommandParameter]   // empty for simple toggles
    public var requiresConfirmation: Bool
}

/// Shared per-cycle context the engine hands every provider.
public struct EnvironmentContext: Sendable {
    public var routerHost: String?       // resolved by EndpointSelector each cycle
    public var settings: AppSettings
}

/// Owns the poll loop, snapshot assembly, and command dispatch. No UI imports.
public actor Engine {
    public init(providers: [Provider], endpointSelector: EndpointSelector, settingsStore: SettingsStore, credentialStore: CredentialStore)
    public func start()
    public func stop()
    /// Stream of assembled snapshots for any client (menubar, CLI, future iOS) to render.
    public var snapshots: AsyncStream<EngineSnapshot> { get }
    public func dispatch(provider: ProviderID, commandID: String, arguments: CommandArguments) async throws
    /// Temporarily shorten a provider's interval while its UI is focused (replaces speedifyFocusTask).
    public func setFocused(_ providerID: ProviderID?, focused: Bool)
}

public struct EngineSnapshot: Sendable, Equatable {
    public var providers: [ProviderID: SourceState<ProviderSnapshot>]
    public var lastUpdated: Date?
}
```

`ProviderDetail` should box the existing status structs (an enum or type-erased wrapper) so the menubar keeps rendering provider-specific detail exactly as today. **Do not delete the existing status structs or their parsing/tests** — they become the `detail` payload.

---

## Staged plan

Each step lists Goal / Changes / Acceptance. Commit after each. Do not start a step until the previous one is green.

### Step 1 — Extract the engine from the ViewModel into Core (no protocol yet)

**Goal:** move the poll loop, snapshot assembly, backoff, focus fast-poll, endpoint resolution, and command methods out of `StatusViewModel` into a new `Engine` in `GLiNetCore`. **Keep `StatusSnapshot` as-is** (still hardcoded fields) — this step is purely about moving the orchestration down a layer.

**Changes:**
- New `GLiNetCore/Engine.swift`: an `actor` (or `@MainActor`-free class) that reproduces `StatusViewModel.refresh()` logic verbatim, publishing `StatusSnapshot` updates via `AsyncStream`. Move `routerBackoffUntil`, `speedifyFocusTask` behavior (as `setFocused`), `resolveEndpoint`, all `load*Status` helpers, and the command methods (`toggleVPN`, `toggleSpeedify`, `setSpeedifyBondingMode`, `setSpeedifyNetworkPriority`, `setEcoFlowOutput`).
- `StatusViewModel` becomes a thin `@MainActor` adapter: holds an `Engine`, subscribes to its stream → republishes `@Published var snapshot`, and forwards UI actions to engine methods. Target: well under ~80 lines.
- Make `RouterCheck/main.swift` instantiate the `Engine` and print a snapshot — proving headless operation.

**Acceptance:**
- `swift build` + `swift test` green (existing tests unchanged).
- Menubar app: identical data, identical refresh cadence, VPN/Speedify/EcoFlow controls work, router backoff and Speedify focus-poll behave exactly as before.
- `RouterCheck` prints a populated snapshot.
- Add `EngineTests` covering the poll cycle with injected fakes (reuse `TestDoubles`).

### Step 2 — Introduce the `Provider` protocol; replace the hardcoded snapshot with a registry

**Goal:** turn each source into a `Provider`; replace `StatusSnapshot`'s fixed fields with `[ProviderID: SourceState<ProviderSnapshot>]`; introduce `EnvironmentContext`.

**Changes:**
- Add `Provider`, `ProviderSnapshot`, `CommandDescriptor`, `EnvironmentContext`, `ProviderDetail` to Core.
- Wrap existing clients as providers (the engine resolves the endpoint once per cycle and passes `routerHost` in context):
  - `GLiNetRouterProvider` — polls **both** router and VPN in one `poll()` (they share one authenticated `GLiNetClient`/login; this preserves the single-login + backoff semantics). Commands: `vpn.toggle`.
  - `SpeedifyProvider` — wraps `RouterSpeedifyClient`; honors focus fast-poll via `Engine.setFocused`. Commands: `speedify.toggle`, `speedify.setBondingMode`, `speedify.setNetworkPriority`.
  - `StarlinkProvider` — wraps `StarlinkClient`.
  - `EcoFlowProvider` — wraps `EcoFlowHTTPClient`; **conditionally registered** based on `settings.ecoflowEnabled`, rebuilt when settings change (mirror today's `saveSettings` client reset). Commands: `ecoflow.setOutput`.
  - `ReachabilityProvider` — wraps `ReachabilityProbe`.
- Engine iterates `providers`, polls each per its interval, assembles the keyed snapshot. Router backoff stays in the engine (or in `GLiNetRouterProvider`), gating only that provider.
- Update `StatusViewModel` + menubar views to read by `ProviderID` and render `detail`. Keep per-provider detail views.

**Acceptance:**
- Build + tests green; behavior parity (all five sources, all commands, backoff, focus-poll, EcoFlow gating).
- Adding a provider now requires **zero** changes to `Engine` or the snapshot type — verify by reasoning/comment.

### Step 3 — Normalized metric vocabulary

**Goal:** populate `ProviderSnapshot.metrics` and `health` for each provider, alongside the existing rich `detail`.

**Changes:** map each provider's key fields into `Metric`s (e.g. Starlink → downlink/uplink throughput, pop latency, obstruction %, outage count; Speedify → throughput, connected; EcoFlow → battery level, output state; Reachability/router → latency, online bool). Set `health` per provider from sensible thresholds.

**Acceptance:** build + tests green; add tests asserting metric extraction for each provider; menubar unchanged (still renders `detail`).

### Step 4 — Alerting engine over the snapshot stream

**Goal:** a rules layer in Core consuming `EngineSnapshot` updates — the platform's most differentiating feature.

**Changes:** `AlertRule` types: threshold, state-transition, and sustained-for-duration, evaluated against normalized `Metric`s/`health`. An `AlertEngine` that subscribes to the snapshot stream and emits `AlertEvent`s. Wire a few real rules (Starlink obstruction high, VPN disconnected, EcoFlow battery < 20%). Surface events via macOS `UNUserNotificationCenter` from the menubar layer (delivery is UI-layer; rule evaluation is Core).

**Acceptance:** build + tests green; unit tests for each rule type with synthetic metric streams; a real alert fires in the running app.

### Step 5 — Add `ping` and `iperf3` providers (active-measurement archetype)

**Goal:** validate the model against *active, on-demand measurement* (vs. passive state polling). `iperf3` is a Command that produces a Metric (a triggered, time-bounded throughput test), not a continuous poll.

**Changes:** `PingProvider` (periodic) and `Iperf3Provider` (command-triggered measurement that records the latest result as metrics/detail; via `ProcessRunner`). If expressing "run iperf3 → emit a throughput sample" is awkward in the current protocol, **that's the signal to refine the Provider/Command/Metric shape** — fix it here while it's cheap.

**Acceptance:** build + tests green; ping polls continuously; an iperf3 run is triggerable and its result appears as metrics + detail; note any protocol refinements that were needed.

---

## Non-goals (do NOT do these)

- No JavaScript/WASM/manifest runtime. Providers stay native Swift conforming to `Provider`. (Shape the seam *as if* a manifest could implement it later — don't build that yet.)
- No iOS/Windows/Android client, no cloud relay, no message bus / Tailscale.
- No store/registry/extension packaging.
- No package split or `GLiNet*` → neutral rename yet (cosmetic; a later step once the protocol has proven itself across 6–8 providers).
- No UI redesign — the menubar should look and behave the same throughout.

---

## Testing & verification

- The existing `GLiNetCoreTests` suite must remain green at every step; do not weaken or delete tests (the parsing tests guard the `detail` structs).
- Add new tests per step (`EngineTests`, provider adapter tests, metric-extraction tests, alert-rule tests) using the existing `TestDoubles`/injected `ProcessRunner` patterns.
- Manual parity check after Steps 1 and 2: launch the menubar app, confirm all five sources populate, toggle VPN and Speedify, change Speedify bonding mode, set an EcoFlow output, confirm router-backoff and Speedify focus-poll behavior.
- `swift run glinet-router-check` must produce a populated snapshot after Step 1 (headless proof).

## Codebase gotchas

- **Swift 6 strict concurrency.** New `Engine`/`Provider` types are `Sendable`/`actor`. Avoid putting closures in `Sendable` structs — that's why command dispatch is `Provider.execute(...)` (metadata in `CommandDescriptor`, behavior in the method), not a stored handler.
- **The `@MainActor` boundary** belongs only in `GLiNetMenuBar`. `GLiNetCore` must not import SwiftUI/AppKit.
- **Single-login semantics:** router + VPN come from one authenticated `GLiNetClient` via `GLiNetClientPool`; keep them in one provider so backoff and the pool keep working.
- **EcoFlow** is enable-gated and host-auto-resolved (`"auto"` → router host); preserve both, and rebuild the provider on settings change as the current `saveSettings` does.
- **Speedify focus fast-poll** (1s while the menu is open) must survive as `Engine.setFocused`.
```

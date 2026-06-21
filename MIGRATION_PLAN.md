# Ambit — Migration Plan (seeded from glinet-travel)

**Audience:** a coding agent (Codex) executing this without prior conversation context.
**Goal:** evolve this codebase — a verbatim seed copy of `glinet-travel` — into **Ambit**, an extensible, provider-based ambient device-monitoring/control engine. This repo is the reference implementation of the larger Ambit platform.

**This repo (`~/src/ambit`) is where all work happens.** It was seeded as an exact copy of `glinet-travel` (initial commit `Seed Ambit from glinet-travel`). The original **`~/src/glinet-travel` is the untouched donor and reference oracle — never edit it.** When in doubt about intended behavior, diff against glinet-travel; it's the known-good baseline.

This is a **refactor in place** (within this repo), not a rewrite. The app must compile and the test suite must stay green after **every** step. Work step by step, commit per step, preserve exact current behavior unless a step explicitly changes it.

## Migration status

The staged migration below has been executed through Step 5. Current state:

- Framework/package names are Ambit (`AmbitCore`, `AmbitMenuBar`, `ambit-check`).
- `StatusViewModel` is a thin UI adapter over `AmbitCore.Engine`.
- `Engine` is provider-registry backed: refresh and command dispatch run through `Provider` instances, not legacy per-service branches.
- Built-in provider composition lives in `BuiltInProviderFactory`, outside the engine actor.
- `StatusSnapshot` stores `[ProviderID: SourceState<ProviderSnapshot>]` and keeps typed compatibility accessors for the menubar.
- Provider snapshots carry normalized metrics/health plus rich `ProviderDetail`.
- `AlertEngine` evaluates rules over `EngineSnapshot`; notification delivery remains in the menubar layer.
- `PingProvider` and `Iperf3Provider` are registered when a `ProcessRunner` is supplied; `ambit-check --run-iperf3 <host>` triggers an iperf3 measurement.
- Provider manifest packages now have a schema, validation, credential declarations, HTTP GET/POST endpoint requests with static headers/body, installed provider setup, example packages, a metric runtime, value transforms, layout hints, alert declarations, and CLI validation/execution paths (`--validate-manifest`, `--run-manifest`).
- Generic provider surfaces now use a shared `ProviderDisplayModel` for health, primary messages, metric sections, commands, diagnostics, missing credential prompts, and layout hints.
- Installed manifest providers are persisted in Core, loaded by `Engine`, and manageable from Settings.

Remaining follow-up work is product/UI expansion and integration hardening, not core migration: polish the built-in integrations, deepen provider setup ergonomics, add richer non-menubar surfaces, and harden real-world manifest/integration behavior.

---

## Guiding principles

1. **Harvest, don't predict.** Five working integrations already exist. The abstractions below are *derived* from them and are starting points — refine the protocol shapes against the real code; don't contort the code to match a guessed protocol.
2. **Refactor in place, stay green.** After each step: `swift build` succeeds, `swift test` passes, the menubar app launches and shows the same data, and the existing controls (VPN toggle, Speedify connect/bonding, EcoFlow output) still work. glinet-travel is the oracle to diff behavior against.
3. **Engine is platform-agnostic.** All new engine code lives in the core library with **no SwiftUI/AppKit imports**. The CLI target must drive the same engine headlessly — that's the proof the boundary is clean.
4. **Behavior parity is sacred.** The messy real-world logic (router login backoff, Speedify focus fast-poll, endpoint auto-resolution, EcoFlow enable-gating, Keychain credentials) must be preserved exactly. These behaviors are *features*, not accidents.
5. **Scope discipline.** Do **only** what's in the staged plan. Explicit non-goals are listed at the end.

---

## Historical seed architecture (pre-rename)

Swift package `GLiNetTravel` (swift-tools 6.0, macOS 13). Targets:

- **`GLiNetCore`** (library, AppKit-free) — logic layer.
- **`GLiNetMenuBar`** (executable) — SwiftUI menubar app, depends on Core.
- **`RouterCheck`** (executable) — headless CLI, depends on Core. *(Proof the core runs without UI.)*
- **`GLiNetCoreTests`** — substantial unit-test suite.

Key Core types:

- **Per-service clients:** `GLiNetClient` (+`GLiNetClientPool`), `StarlinkClient` (+`StarlinkClientProtocol`), `SpeedifyClient`, `RouterSpeedifyClient`, `EcoFlowHTTPClient`, `ReachabilityProbe` (+`ReachabilityProbeProtocol`).
- **Per-service status structs:** `RouterStatus`, `VPNStatus`, `ReachabilityStatus`, `SpeedifyStatus`, `StarlinkStatus`, `EcoFlowSnapshot`.
- **State envelope:** `SourceState<Value>` (`value`/`isLoading`/`errorMessage`) — generic, reusable.
- **Aggregate:** `StatusSnapshot` — a struct with **one hardcoded field per source**.
- **Support:** `CredentialStore`/`KeychainCredentialStore`, `Settings`/`AppSettings`/`SettingsStore`, `EndpointSelector`/`EndpointSelection`, `ProcessRunner`/`SystemProcessRunner`, `JSONRPC`/`JSONValue`, `AggregateVPNStatus`, `InternetInterfaceStatus`.

**Where the "engine" currently lives (the problem):** `GLiNetMenuBar/StatusViewModel.swift` — a `@MainActor ObservableObject` — owns the poll loop (`start()`/`refresh()`), snapshot assembly, the Speedify focus fast-poll (`speedifyFocusTask`), the router login backoff (`routerBackoffUntil`), endpoint resolution, and **all command methods** (`toggleVPN`, `toggleSpeedify`, `setSpeedifyBondingMode`, `setSpeedifyNetworkPriority`, `setEcoFlowOutput`). The engine is fused to the UI, and `StatusSnapshot` hardcodes the provider set. These are the two coupling points the migration removes.

> Naming note: provider-*specific* types stay gl.inet-named (e.g. `GLiNetClient`, `RouterStatus`) — that provider genuinely *is* gl.inet. Only the **framework/package** layer gets a neutral Ambit name (Step 0).

---

## Implemented architecture

A small set of protocols in the core library. **These signatures are illustrative starting points** — adjust names/shape to fit the real code and Swift 6 concurrency, but keep the intent.

```swift
public typealias ProviderID = String

/// A monitored/controllable thing. One per integration.
public protocol Provider: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }
    var pollInterval: TimeInterval { get }            // desired cadence; engine may clamp
    func poll(context: EnvironmentContext) async -> ProviderSnapshot
    var commands: [CommandDescriptor] { get }         // declared, dispatchable (metadata)
    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws
}

/// Normalized poll result. Keep rich per-provider detail AND a normalized facet.
public struct ProviderSnapshot: Sendable, Equatable {
    public var health: Health            // .ok / .degraded / .down / .unknown
    public var metrics: [Metric]         // normalized — feeds widgets + alerts
    public var detail: ProviderDetail?   // boxed existing struct (RouterStatus, StarlinkStatus, …) — nothing lost
    public var error: String?
}

public enum Health: Sendable, Equatable { case ok, degraded, down, unknown }

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
    case bool(Bool)
    case text(String)
}

public struct CommandDescriptor: Sendable, Identifiable {
    public var id: String                // e.g. "vpn.toggle", "ecoflow.setOutput"
    public var label: String
    public var parameters: [CommandParameter]
    public var requiresConfirmation: Bool
}

/// Shared per-cycle context the engine hands every provider.
public struct EnvironmentContext: Sendable {
    public var routerHost: String?       // resolved by EndpointSelector each cycle
    public var settings: AppSettings
}

/// Owns the poll loop, snapshot assembly, command dispatch. No UI imports.
public actor Engine {
    public init(providers: [Provider], endpointSelector: EndpointSelector, settingsStore: SettingsStore, credentialStore: CredentialStore)
    public func start()
    public func stop()
    public var snapshots: AsyncStream<EngineSnapshot> { get }
    public func dispatch(provider: ProviderID, commandID: String, arguments: CommandArguments) async throws
    public func setFocused(_ providerID: ProviderID?, focused: Bool)   // replaces speedifyFocusTask
}

public struct EngineSnapshot: Sendable, Equatable {
    public var providers: [ProviderID: SourceState<ProviderSnapshot>]
    public var lastUpdated: Date?
}
```

`ProviderDetail` should box the existing status structs (enum or type-erased) so the menubar keeps rendering provider-specific detail exactly as today. **Do not delete the existing status structs or their parsing/tests** — they become the `detail` payload.

---

## Staged plan

Each step: Goal / Changes / Acceptance. Commit after each. Don't start a step until the previous is green.

### Step 0 — Neutral rename to Ambit — Complete

**Goal:** rename the framework/package layer from `GLiNet*` to `Ambit*` so the repo reads as its own product. Purely mechanical; no behavior change.

**Changes:**
- `Package.swift`: package `GLiNetTravel` → `Ambit`; library `GLiNetCore` → `AmbitCore`; app `GLiNetMenuBar` → `AmbitMenuBar`; CLI product `glinet-router-check` → `ambit-check` (target `RouterCheck` may keep its dir name or become `AmbitCheck`).
- Rename `Sources/GLiNetCore` → `Sources/AmbitCore`, `Sources/GLiNetMenuBar` → `Sources/AmbitMenuBar`; update all `import GLiNetCore` → `import AmbitCore`; update the test target name + `@testable import`.
- Leave provider-specific type names (`GLiNetClient`, `RouterStatus`, etc.) as-is — they belong to the gl.inet provider.

**Acceptance:** `swift build` + `swift test` green; app + CLI run identically. Commit: "Step 0: rename to Ambit".

### Step 1 — Extract the engine from the ViewModel into Core (no protocol yet) — Complete

**Goal:** move the poll loop, snapshot assembly, backoff, focus fast-poll, endpoint resolution, and command methods out of `StatusViewModel` into a new `Engine` in `AmbitCore`. **Keep `StatusSnapshot` as-is** (still hardcoded fields) — this step only moves orchestration down a layer.

**Changes:**
- New `AmbitCore/Engine.swift`: an `actor` reproducing `StatusViewModel.refresh()` verbatim, publishing `StatusSnapshot` via `AsyncStream`. Move `routerBackoffUntil`, the focus fast-poll (as `setFocused`), `resolveEndpoint`, all `load*Status` helpers, and the command methods.
- `StatusViewModel` becomes a thin `@MainActor` adapter (target < ~80 lines): holds an `Engine`, subscribes → republishes `@Published var snapshot`, forwards UI actions.
- `ambit-check` CLI instantiates the `Engine` and prints a snapshot — headless proof.

**Acceptance:** build + tests green; menubar identical (data, cadence, controls, backoff, focus-poll); CLI prints a populated snapshot; add `EngineTests` with injected fakes (reuse `TestDoubles`).

### Step 2 — Introduce the `Provider` protocol; replace the hardcoded snapshot with a registry — Complete

**Goal:** turn each source into a `Provider`; replace `StatusSnapshot`'s fixed fields with `[ProviderID: SourceState<ProviderSnapshot>]`; introduce `EnvironmentContext`.

**Changes:**
- Add `Provider`, `ProviderSnapshot`, `CommandDescriptor`, `EnvironmentContext`, `ProviderDetail` to `AmbitCore`.
- Wrap existing clients as providers (engine resolves the endpoint once per cycle, passes `routerHost` in context):
  - `GLiNetRouterProvider` — polls **both** router and VPN in one `poll()` (they share one authenticated `GLiNetClient`/login; preserves single-login + backoff). Command: `vpn.toggle`.
  - `SpeedifyProvider` — wraps `RouterSpeedifyClient`; honors focus fast-poll via `Engine.setFocused`. Commands: `speedify.toggle`, `speedify.setBondingMode`, `speedify.setNetworkPriority`.
  - `StarlinkProvider` — wraps `StarlinkClient`.
  - `EcoFlowProvider` — wraps `EcoFlowHTTPClient`; **conditionally registered** on `settings.ecoflowEnabled`, rebuilt on settings change (mirror today's `saveSettings` reset). Command: `ecoflow.setOutput`.
  - `ReachabilityProvider` — wraps `ReachabilityProbe`.
- Engine iterates `providers`, polls each per interval, assembles the keyed snapshot. Router backoff stays in the engine (or `GLiNetRouterProvider`), gating only that provider.
- Update `StatusViewModel` + menubar views to read by `ProviderID` and render `detail`. Keep per-provider detail views.

**Acceptance:** build + tests green; full behavior parity; adding a provider now requires **zero** changes to `Engine`. `ProviderDetail` remains an enum for rich first-party details; generic providers can still publish metrics/health without changing the snapshot storage model.

### Step 3 — Normalized metric vocabulary — Complete

**Goal:** populate `ProviderSnapshot.metrics` and `health` for each provider alongside the rich `detail`.

**Changes:** map key fields into `Metric`s (Starlink → throughput/latency/obstruction/outages; Speedify → throughput/connected; EcoFlow → battery level/output; reachability/router → latency/online). Set `health` from sensible thresholds.

**Acceptance:** build + tests green; tests asserting metric extraction per provider; menubar unchanged (still renders `detail`).

### Step 4 — Alerting engine over the snapshot stream — Complete

**Goal:** a rules layer in `AmbitCore` consuming `EngineSnapshot` — the platform's most differentiating feature.

**Changes:** `AlertRule` types (threshold, state-transition, sustained-for-duration) over normalized metrics/health; an `AlertEngine` subscribing to the snapshot stream emitting `AlertEvent`s. Wire real rules (Starlink obstruction high, VPN disconnected, EcoFlow battery < 20%). Deliver via `UNUserNotificationCenter` from the menubar layer (delivery is UI; evaluation is Core).

**Acceptance:** build + tests green; unit tests per rule type with synthetic streams; a real alert fires in the running app.

### Step 5 — Add `ping` and `iperf3` providers (active-measurement archetype) — Complete

**Goal:** validate the model against *active, on-demand measurement* vs. passive polling. `iperf3` is a Command that produces a Metric (a triggered, time-bounded test), not a continuous poll.

**Changes:** `PingProvider` (periodic) and `Iperf3Provider` (command-triggered measurement recording the latest result as metrics/detail, via `ProcessRunner`). If "run iperf3 → emit a throughput sample" is awkward in the protocol, **that's the signal to refine the Provider/Command/Metric shape** — fix it here while it's cheap.

**Acceptance:** build + tests green; ping polls continuously; an iperf3 run is triggerable and its result appears as metrics + detail. Protocol refinement made during implementation: command behavior remains on `Provider.execute(...)`, with post-command polling publishing the resulting metric/detail snapshot.

---

## Non-goals (do NOT do these)

- No JavaScript/WASM/untrusted extension runtime. Providers stay native Swift conforming to `Provider`; the manifest runtime is intentionally limited to declarative HTTP metric providers.
- No iOS/Windows/Android client, no cloud relay, no message bus / Tailscale.
- No store/registry distribution packaging.
- **Never edit `~/src/glinet-travel`** — it's the untouched donor/reference.
- No UI redesign — the menubar should look and behave the same throughout.
- No renaming of provider-specific gl.inet types (only the framework layer is renamed, in Step 0).

---

## Testing & verification

- The existing test suite must remain green at every step; do not weaken or delete tests (the parsing tests guard the `detail` structs).
- Add new tests per step (`EngineTests`, provider-adapter tests, metric-extraction tests, alert-rule tests) using existing `TestDoubles`/injected `ProcessRunner` patterns.
- Manual parity check after Steps 1 and 2: launch the app, confirm all five sources populate, toggle VPN and Speedify, change Speedify bonding mode, set an EcoFlow output, confirm router-backoff and Speedify focus-poll behavior. Diff against `glinet-travel` if anything looks off.
- `swift run ambit-check` must produce a populated snapshot after Step 1 (headless proof).

## Codebase gotchas

- **Swift 6 strict concurrency.** New `Engine`/`Provider` types are `Sendable`/`actor`. Avoid closures in `Sendable` structs — that's why command dispatch is `Provider.execute(...)` (metadata in `CommandDescriptor`, behavior in the method), not a stored handler.
- **The `@MainActor` boundary** belongs only in `AmbitMenuBar`. `AmbitCore` must not import SwiftUI/AppKit.
- **Single-login semantics:** router + VPN come from one authenticated `GLiNetClient` via `GLiNetClientPool`; keep them in one provider so backoff and the pool keep working.
- **EcoFlow** is enable-gated and host-auto-resolved (`"auto"` → router host); preserve both, and rebuild the provider on settings change as `saveSettings` does today.
- **Speedify focus fast-poll** (1s while the menu is open) must survive as `Engine.setFocused`.

# Ambit — Comprehensive Product & Rearchitecture Spec (v2)

**Date:** 2026-07-03 · **Source of truth:** this repo's code (`Sources/`) and the design docs in `docs/` (including `HANDOFF.md`), all read and synthesized on this date.
**Purpose:** a single, complete capture of what Ambit *is* — product vision, domain model, every behavior the current implementation encodes, its architectural debt, and the invariants and guidance a ground-up rearchitecture must honor. A fresh implementation built against this document should be behaviorally indistinguishable from today's app (where behavior is specified) and structurally better (where debt is called out).

---

## 0. How to read this document

- §1 is the product. §2–§9 are the behavioral spec: everything the current system does, with exact type names, enum cases, IDs, defaults, and semantics. §10–§12 are persistence, verification, and a built/designed/deferred status ledger. §13 is the honest critique. §14 is the rearchitecture guidance: invariants to keep, seams to fix, and a proposed target shape.
- Names in `code font` are real identifiers in the current codebase. They document *semantics*, not required spellings — a rearchitecture may rename, but must preserve meaning and (for persisted formats and IDs) wire compatibility or provide migration.
- Existing behavior is locked by ~745 test functions including frozen golden fixtures (§11). Any rearchitecture should port those fixtures first and build against them.

---

## 1. Product definition

### 1.1 What Ambit is

An extensible, **self-hosted monitoring/control engine + polished native apps** that put every connected thing — routers, ISPs, Starlink, VPNs, EVs, power stations, local system stats — into ambient, glanceable surfaces (macOS menu bar first; iOS widgets/Live Activity/Dynamic Island later), instead of one bloated vendor app per device. Elevator pitches: **"iStat Menus you can extend"**, **"Homebridge meets Raycast."** Marketable promise: *delete 15 single-purpose apps.*

### 1.2 Target user

The technical prosumer adjacent to a self-hoster: knows the person running 200 containers, wants the *outcomes* of self-hosting (privacy, control, no cloud dependency) without Proxmox/docker-compose/YAML. Feels the fifteen-vendor-apps pain acutely.

### 1.3 Design tenets (non-negotiable product DNA)

1. **Direct over indirect.** For a known action, a button beats a chatbox. AI lives *behind* controls (anomaly detection, rule authoring, manifest generation), never as the primary interface. Explicitly positioned against the "everything through an agent" tide.
2. **Monitor + control are one primitive.** Typed state you read; commands you fire. Widgets bind to state, alerts watch state, and neither knows what produced it. That decoupling *is* the product.
3. **Local-first, self-hosted.** Credentials stay on the user's hardware. Trust is the product.
4. **Ambient, not a destination.** Live where the user already looks (menu bar, Lock Screen, Control Center); never a dashboard you must visit.
5. **Deterministic and scoped.** Each control fires exactly one known action with scoped credentials.
6. **Generic, opinionated presentation** (the Raycast bet, not Home-Assistant-style user-composed dashboards). Integrations ship data + defaults; the platform renders. A presentation gap is a *missing generic primitive*, never a per-provider special case.

### 1.4 Positioning foils

Home Assistant (destination dashboard + project overhead), iStat Menus (UX gold standard, but closed and inextensible), Raycast (right business model, no always-on engine or rich menubar widgets), OpenClaw-style agents (validates self-hosted appetite; Ambit is the deterministic anti-chat).

### 1.5 Business model & moat

Obsidian/Raycast/Plex template: open engine + open integrations, closed polished apps, free local tier. **Pro = the 24/7 cloud relay** (the one thing genuinely hard to self-host: something always-on that watches and notifies). Per-module usage **metering is built into the engine from day one** — it double-duties as iOS background-budget accounting and as the monetization unit. The moat is the platform (engine, cross-platform notification/attention machinery, ambient UX, trust model), *not* the integrations — those are commodity and community-owned by design.

### 1.6 Deployment tiers (topology vision)

- **Tier 0 — embedded in the Mac app** (today's reality): engine runs in-process while the Mac is awake.
- **Tier 1 — dedicated always-on box:** the same UI-free Swift engine lifts onto a Linux box with zero code change; the app becomes a client. The "Plex NAS moment."
- **Tier 2 — iOS as best-effort engine:** opportunistic polling only; deliberately limited (Apple constraints), which makes the paid relay a fair trade rather than a paywall.
- **Transport (designed):** outbound-only connections from engine and clients to a lightweight message broker (MQTT/WebSocket/NATS class) with E2E-encrypted payloads; optional self-hosted Headscale tier for power users. Explicitly *not* a mesh VPN by default.
- **Multi-engine (Phase 3, designed not built):** peer-to-peer, no coordinator. At most one engine polls each provider instance; ownership is *computed* from mesh membership + eligibility (reach tags like `.localHost` / `.lan(subnet)` / `.internet` vs. instance needs) + weight (always-on > laptop > phone; uptime tiebreak). Handoff is make-before-break with tunable overlap (`maxOverlap` ≈ 30s default; 0 = strict). This is why identity determinism (§2.1) is a hard invariant.

---

## 2. Domain model

### 2.1 Identity hierarchy (hard invariant)

All IDs are string-backed (`StringIdentifier` protocol: raw string, Codable as bare string), **deterministic and engine-independent**. Two engines configured identically must compute identical IDs — this is the linchpin of failover, cross-engine state merge, and offline stability. **`EngineID` exists for ownership/telemetry only and must never appear inside any entity/instance ID.**

```
IntegrationID                "ping", "glinet", "system"
 └─ IntegrationInstanceID    deterministic from target: "ping@1.1.1.1:443", "glinet@192.168.8.1", "system@local"
     └─ ProviderTypeID       kind within the integration: "router", "vpn", "overview"
         └─ ProviderInstanceID  "<instanceID>/<typeID>": "glinet@192.168.8.1/router", "system@local/overview"
             └─ EntityID        "<providerInstanceID>.<key>": "glinet@192.168.8.1/router.wan_up"
```

An *integration* is the installable, branded unit (installing "gl.inet" stands up router + vpn providers under one instance). A *provider* is one polling/command unit. Phase-1 built-ins use fixed default instance IDs (e.g. bare `"glinet"`); a compat shim (`ProviderInstanceIDs.resolve`) maps legacy type-keyed IDs to scoped ones — rearchitecture should retire this shim via migration.

### 2.2 Entity model — descriptor/state split (hard invariant)

Every observable or controllable thing is an **entity**, split into two halves:

**`EntityDescriptor` (STATIC — exists as long as the instance is configured, even offline):**
`id`, `instanceID`, `name`, plus:

- `kind: EntityKind` — `sensor | binarySensor | toggle | select | number | button | text | table`
- `deviceClass: DeviceClass?` — `connectivity | throughput | latency | battery | power | duration | percent | count | dataSize | temperature | fan` (drives formatting, graph axes, unit semantics)
- `category: EntityCategory` — `primary | diagnostic | config`
- `access: EntityAccess` — `read | write | readWrite`
- `stateClass: StateClass?` — `measurement | total | totalIncreasing` (gates history recording & graph eligibility)
- `capability: ProviderCapability?` — string tag for cross-vendor grouping (`"net.vpn.client"`, `"system.cpu"`, `"context.active"`); static per instance, never per-poll
- `unit`, `options` (for selects), `range` (for numbers), `command: CommandRef?` (ties a control entity to a dispatchable command, with fixed arguments for parameterized fan-out), `icon`, `metricID`
- **Presentation defaults** (all additive/defaulted): `defaultVisibility: GlanceVisibility` (`.auto` default; always/never/conditional semantics), `displayThreshold`, `graphStyle`, `defaultGraphRange`, `isPrimary`, `priority`, `compositionRole` (`segment | remainder | total | channel` — powers rings/dual-line pairing)
- `monitoring: MonitoringMetadata?` — roles/perspectives for the generic monitoring engines (§5) without widening the core model

**`EntityState` (DYNAMIC — per poll):** `value: EntityValue?`, `availability`, `lastUpdated`, `error`, `severity`.

- `EntityValue`: `number(Double) | bool(Bool) | text(String) | table(TableValue)`. `TableValue` carries typed columns/cells (text, number+unit, badge+severity) for process/disk/network tables.
- `Availability`: `online | stale | unavailable`. **Offline stability:** when a provider goes offline its descriptors persist and states become stale/unavailable; UI greys rather than drops; alerts may fire on availability transitions.
- `Severity` (ordered, Comparable): `normal < elevated < degraded < alerting < down`. Decodes legacy aliases (`info`→normal, `warning`→elevated, `critical`→down).

An `EntityProjection`/`EntityEnricher` layer derives enriched presentation state from raw descriptors+states.

### 2.3 Terminology

*Signal* = anything that emits an entity readout. *Control* = anything that accepts a command. *Manifest* = declarative HTTP provider package. *Slot* = a binding of a selection of entities/integrations to a menu-bar item + popover surface. *Surface* = any glanceable rendering target (menu bar, popover, overlay; later: widgets, Live Activity, Control Center).

---

## 3. Integrations & providers

### 3.1 Provider contract

A provider (protocol `Provider`) has an `instanceID`, a `pollInterval`, descriptor enumeration, an async poll producing states/samples, and optional command dispatch. Integrations implement the `Integration` protocol; the `IntegrationRegistry` (UserDefaults-backed) records per-integration-type and per-instance enable/disable plus instance configuration records, and the Engine assembles live providers from active registry records. **Registry changes rebuild providers at runtime** (a fixed TCP-ping bug: this must hold).

### 3.2 Built-in integrations

IDs: `glinet, speedify, starlink, ecoflow, reachability, ping, iperf3, system`.

- **Active by default:** `ping` and `system@local`.
- **Seeded DISABLED, pending rebuild against the proven generic shape:** glinet (router+vpn providers), speedify, starlink (needs HTTP/2+protobuf telemetry), ecoflow, reachability, iperf3. Their old clients exist in Core (`GLiNetClient`, `SpeedifyClient`, `RouterSpeedifyClient`, `StarlinkClient`, `EcoFlowModels`, `ActiveMeasurementProviders`) as donors. All need a **secure config field** primitive (credential/password in `IntegrationConfigSchema`) that does not exist yet.

### 3.3 The `ping` integration (reference implementation #1 — network monitoring)

Rebuilt natively from the shipped PingScope app (the behavior oracle; repo `~/src/pingscope`, never edited). Multi-instance: **host = instance** (`ping@1.1.1.1:443`). Probes: **TCP, UDP, ICMP** (ICMP via `/sbin/ping`) with typed failure classification (`ProbeFailureReason`: timeout, dnsFailure, connectionRefused, networkUnavailable, hostUnreachable, noRoute, ttlExpired, cancelled, icmpUnavailable, unknown). Declares — as *data*, not code — roles/perspectives (`MonitoringMetadata`; e.g. gateway vs. remote perspective), alert kinds, presets, commands, and entity metadata. A **grep-gate test enforces zero ping-specific identifiers in Core engines or UI modules** (allowlist: the Ping integration itself, seed/migration code, frozen fixtures).

Behaviors: auto-seeded **Gateway** host with stable `autoGatewayInstanceID` and mutable address, re-detected live on `NWPathMonitor` changes and wake; "All Hosts" combined multi-series latency graph (deterministic per-index colors, legend capped at 4, shared axis, primary-line emphasis, failure bars on primary series only); focused-host mode via per-slot `slotFocus` filtering descriptors/series/history; recent-samples table follows the selected/headline latency entity; per-host alerts suppressed during link drops.

### 3.4 The `system` integration (reference implementation #2 — iStat-class)

Providers under `system@local`: `overview` (CPU incl. per-core, load, uptime, memory incl. pressure and honest breakdown — App/Active, Wired, Compressed, Cached/Inactive, Free — summing to physical RAM), `storage`, `processes` (top-N tables, short names), `network` (interfaces, throughput), `sensors`, `fans` (SMC; degrade gracefully to unavailable), plus **signal providers**: `calendar` (EventKit), `location` (CoreLocation geofence/SSID support), `focus` (macOS Focus). GPU intentionally omitted (no stable public API). Read via `DarwinSystemMetricsReader` and friends; permission state modeled by `SystemSignalPermission` and requested from Darwin readers.

The two live integrations are the **thesis proof**: Ping and System — utterly different domains — render through identical generic primitives with zero bespoke UI.

### 3.5 Manifest providers (declarative HTTP integrations)

`ProviderManifest` — a folder package with `manifest.json`: display name; `credentials` list (`id`, `label`, `kind` — bearerToken/apiKey/basicAuth/…, `required`), referenced as `{credential.<id>}` in URLs/headers/bodies; `endpoint` (method, URL, headers, optional body); `metrics` (JSON-path mappings with typed values and transforms: multiply, divide, round, clamp, defaultValue); `layout` hints (icon, accent, primaryMetric); optional declarative `alerts` (threshold/state-transition, severity, title/message templates); optional commands. Setup states derived from validation + credential completeness: `ready | disabled | invalid | needsCredentials` — disabled/invalid stay *visible* in Settings for inspection/repair; missing credentials produce an actionable "down" snapshot rather than silence. Persisted via `InstalledProviderStore`; validated/executed headlessly via CLI (§9).

### 3.6 Credentials

`CredentialStore` protocol with `KeychainCredentialStore` on macOS. The engine owns auth so integrations declare needs rather than implement flows — the hardest 80% of contributing an integration, and where the trust story lives. (OAuth flows, token refresh: designed, not yet needed by live integrations.)

---

## 4. Engine runtime

### 4.1 Poll orchestration

`Engine` (828 lines, actor-flavored async/await; AmbitCore is **UI-free** — no SwiftUI/AppKit imports, provable via the headless CLI) assembles providers from the registry and runs a poll loop:

- **Loop cadence = fastest registered provider's `pollInterval`, floored at 1s** (a 2s ping host is polled every 2s even if global settings are slower). Per-provider throttle gates slower providers to their own intervals (a provider is skipped while `now - lastPoll < provider.pollInterval`). Fallback interval when unknown: 2s.
- Snapshots stream to subscribers (`EngineSnapshot` — descriptors, states, health, diagnosis); history is fed automatically (§4.4).
- **Sleep/wake:** system sleep cancels in-flight poll cycles; `NSWorkspace.didWake` kicks a fresh cycle immediately.
- **Stall watchdog:** no completed cycle within interval×N ⇒ cancel + restart the loop.

### 4.2 Probe resilience (correctness-critical)

`TimeoutProbe` implements **abandon-the-loser**: resolve via a resolve-once continuation (`ContinuationGate`) on first-to-finish of probe vs. deadline; on deadline return `.timeout` and best-effort-cancel the wedged probe **without awaiting it**. Rationale: `withTaskGroup` awaits a wedged probe and silently freezes the whole loop. A monitoring tool that silently stops monitoring is a correctness bug in the core value prop.

### 4.3 Staleness vs. down (correctness-critical, hard invariant)

- No fresh sample within **`interval × 3`, floored at 10s** ⇒ `Availability.stale` — **never down**.
- Staleness is a **pure function of `(lastUpdated, interval, now)`** recomputed on a wall-clock tick (≈5s) **independent of the poll loop** — a stalled loop produces no snapshots, so poll-driven projection would never fire.
- Diagnosis **suppresses** network-fault/down inference on stale data (you can't diagnose from data you didn't collect) and reports a distinct **"Monitoring paused"** state. No false "Local network down" during App Nap, sleep, or engine handoff — ever.

### 4.4 History

`HistoryService` over a swappable `HistoryStore` (SQLite at `~/Library/Application Support/Ambit/history.sqlite`, table `history_samples`; in-memory store for tests). `EntityID`-keyed `Sample`s (`timestamp`, `value: Double?`, `ok: Bool`), recorded automatically by the Engine, **gated by `stateClass`** (only measurement-class entities). Retention + prune with a `retentionInterval` that also drives UI labels. Every integration gets history/sparklines/export for free. `HistoryExport`: CSV/JSON/Text over any slot or history-backed entity, plus history clear.

### 4.5 Health

`HealthState` — stateful per-monitor health: thresholds ⇒ degraded; consecutive-failures ⇒ down; transition timestamps preserved. `HealthStatus` (`ok | degraded | down | unknown`) feeds diagnosis, alerting, and tone mapping.

### 4.6 Metering & diagnostics

Per-module usage metering (CPU/memory/latency per provider; surfaced via `ambit-check --usage`) — kept from day one for iOS budget + monetization accounting. `DiagnosticsSupport` exposes current state, recent failures (from generic `ok == false` history), and debug-log actions.

---

## 5. Monitoring intelligence (generic, provider-agnostic)

All of the following operate on *declarations* (data), never on integration-specific code paths:

- **`MonitoringMetadata`** on descriptors declares roles/perspectives (e.g. "this entity observes the gateway tier", "this one a remote service") without expanding the entity model.
- **`TopologyDiagnosisEngine`** consumes declared perspectives + `NetworkAwarenessConfig` + connectivity to produce a provider-agnostic `MonitoringVerdict` (topology-level diagnosis: local network down vs. internet down vs. specific remote down vs. monitoring paused). Its verdict feeds banners and headlines via **`DiagnosticSummaryEntity`** — a generic, owner-scoped diagnostic *text entity* (diagnosis is itself just an entity; the banner is just a card bound to it).
- **`NetworkAwarenessConfig`** owns app-level connectivity behavior: `NetworkConnectivityStatus` (`connected | noInternet | noIPAddress | notConnected`) derived from `NWPathMonitor`; network-change, path-recovery, and internet-loss safety-net alerts; link-state overrides are live (per-host alerts suppressed during link drops).
- **`MonitoringAlertStateMachine`** turns provider-declared `AlertKindDeclaration`s (id, trigger, severity, title/message templates, optional recovery) into **entity-targeted** alert events. Trigger vocabulary (`AlertTriggerDeclaration`): `healthTransition(to:)`, `diagnosisVerdict(kind)`, `connectivityTransition(to:)`, `allMembersFailing(minimumCount:ratio:)`, `metricThreshold(policy)` — each compilable onto the generic Condition tree (§6.1).
- **Quieting (intentional behavior):** warm-up and first-observation baselines suppress startup/wake noise; degraded states must be *sustained* before firing; unified network-tier cooldowns; **recovery notifications only follow a delivered active alert** and respect cooldown. Multi-host remote-service-down notifications summarize with a capped "+N more hosts" body.
- **`AlertEngine` / `AlertTarget` / `AlertTargetResolver`:** all alert events target entities generically (phase-based: `active | recovered`); `EntityAlertPolicy` is device-class-neutral with migration from the old latency-shaped policy. `AlertFiringState` centralizes cooldown bookkeeping.

---

## 6. Automation engine ("everything is a Condition → Reactions")

One universal primitive underlies built-in alerts, user rules, and contexts. Everything here is **serializable declarations** (Codable, versioned, migratable, golden-testable); coverage grows by adding data, never engine branches. UI pickers are generated from registries.

### 6.1 Condition tree

```
Condition = comparison(Comparison)         lhs/rhs Operand (.address(EntityID) | .literal), AlertComparison:
                                           equal | notEqual | greaterThan | greaterThanOrEqual | lessThan | lessThanOrEqual
          | all([Condition])               AND
          | any([Condition])               OR
          | not(Condition)
          | temporal(Temporal)             child condition + op + edge
          | predicate(ConditionPredicate)  healthTransition | diagnosisVerdict | connectivityTransition | allMembersFailing
```

- `ConditionValue`: `number | string | bool | duration | timestamp | enumeration | missing`. Type-mismatched comparisons resolve false (true only for `.notEqual`).
- `TemporalOp`: `heldFor(TimeInterval)`, `consecutiveSamples(Int)`, `withinWindow(TimeInterval)` (any sample in window satisfies child), `rateOfChange(per:comparison:threshold)` (first→last slope over samples, scaled to the interval).
- `Edge`: `level | rising | falling` — level-vs-edge semantics with per-node keyed temporal state (`startedAt`, `consecutiveCount`, `lastLevel`) inside a stateful `ConditionEvaluator`.
- **Legacy compilation:** every `AlertTriggerDeclaration` compiles onto this tree (`metricThreshold` ⇒ comparison wrapped in `consecutiveSamples(policy.consecutive)`), verified byte-identical against goldens. The evaluator also retains a direct `legacyEvaluate` path (debt — see §13).

### 6.2 Reactions

```
Reaction = notify(NotifySpec)                      title/body templates, level: passive|active|timeSensitive,
                                                   lifecycle: oneShot | boundToCondition, action buttons = [CommandInvocation]
         | mutateSurface(SurfaceMutation)          SurfacePropertyAddress(surfaceID, itemID, property: icon|badge|color|visible) ← value,
                                                   applied while active, reverted on exit (SurfaceMutationState)
         | runCommand(CommandInvocation)           providerID + commandID + arguments + requiresConfirmation
         | applyContext(id, active)                activate/deactivate a context while the trigger holds
         | runShortcut(ShortcutInvocation)         macOS Shortcuts by name
         | runAppIntent(ExternalAppIntentInvocation)
```

`ReactionExecutor` dispatches with a **confirmation protocol** (`notRequired | notConfirmed | confirmed`; invocations flagged `requiresConfirmation` return `.requiresConfirmation(...)` until confirmed). `boundToCondition` notifications are posted on enter, cleared on exit (`.notificationCleared`); one-shot fire once per rising edge. Alert-kind declarations map to reactions automatically (severity ≥ down ⇒ `.timeSensitive`; has recovery ⇒ `boundToCondition`).

### 6.3 User rules

`UserRule` (`id`, `displayName`, `condition`, `reactions`, `enabled`, `source: .user`, `schemaVersion` = 1, `cooldown` default **60s**), persisted as a versioned `UserRuleDocument` (unknown future versions ⇒ safe empty; old rules migrated on load). `UserRuleRunner` semantics: per-rule isolated `ConditionEvaluator`; fire reactions on **rising edge only** (active while condition holds, no repeat); notify/command/shortcut/intent gated by `AlertFiringState` cooldown; on **falling edge** clear bound notifications, revert surface mutations, deactivate applied contexts. Rules appear in Settings under Notifications (all) and Automations (rules with non-notify reactions). `UserRuleBuilder` provides the "When [signal] [comparison] [value] for [duration] → then [actions]" authoring model.

### 6.4 Contexts (stateful profiles: Home / Work / Travel / VPN-active…)

`ContextDeclaration`: `id`, `displayName`, `icon`, activation `condition` (same Condition tree; **auto-wrapped in `heldFor(15s)` dwell** unless already temporal), `priority` (drag-rank ⇒ index), `manualOverride` (`auto | pinnedActive | pinnedInactive`), and an **overlay** of deltas: entity/integration/slot presentation overrides, alert-kind overrides (global and per-entity), and rule enable/disable toggles.

- **Resolution is a pure function:** `ContextResolver.resolve(base, activeContexts)` — active contexts sorted by priority (id tiebreak), applied in order, **last-wins, base underneath** — returning both the resolved `PresentationConfig` and a full **"why" trace** (`ContextResolutionTrace` per address: layered base→context attributions with a `winningSource`).
- **Context is itself a derived entity:** `context:<id>#active` (binarySensor, capability `"context.active"`) — so rules can trigger on contexts, and contexts can reference each other. `ContextCycleDetector` disables rules that form cycles (rule applies context X while X's overlay toggles that rule) with a diagnostic.
- `ContextStateMachine` evaluates with per-context evaluators, honors manual pins and rule-applied overrides, and emits `ContextEvaluation` (ordered active contexts + derived states). Active contexts render as chips in the popover header (first 3).

### 6.5 Signal providers & App Intents

Context/rule fuel is ordinary entities: Wi-Fi SSID (read by `SystemNetworkProvider`, gated by Location permission on macOS 14.4+), geofence/location (`SystemLocationProvider`), calendar windows (`SystemCalendarProvider`), macOS Focus (`SystemFocusProvider`), plus everything else in the system (battery, connectivity…). **`AppIntentBridge`** (AmbitMenuBar) exposes provider commands as App Intents (usable from Shortcuts/Spotlight) and `ShortcutRunner` executes Shortcut reactions; packaging must run the App Intents metadata processor (§8.5).

---

## 7. Attention & surface composition

### 7.1 Attention engine (the differentiator: show what matters *now*)

Per-entity three-tier escalation: **detail** (popover only, resting) → **surfaced** (appears in the glance surface because it crossed a *display* threshold — visual, no interrupt) → **alerted** (crossed an *alert* threshold — interrupt). Display and alert thresholds are distinct, nested concerns (surface at 80ms, alert at 250ms).

`AttentionEngine` consumes enriched entities + alert state + visibility config and emits per-surface ordered selections **with human-readable reasons** ("ping surfaced: 142ms > 100ms display, sustained 4 samples, priority 3"). Ranking: pinned lanes reserved (`GlanceVisibility.always`) ⊕ severity (down > alerting > degraded > elevated > normal) ⊕ transition boost (newly-changed outranks chronic) ⊕ user priority; consecutive-sample debounce; per-surface capacity/overflow; resting-primary fallback when nothing demands attention. **Attention state is per-slot** (`SlotAttentionEngines`) — sharing one engine across slots evicts debounce state (a fixed bug; must hold). `SlotReadoutSelector` (pure, Core) picks the single headline readout shared by the menu-bar glyph and popover header.

### 7.2 Surface composition

`SurfaceComposer` (pure, ~600 lines): entities → `SurfacePlan` (tree of `CardSpec`). Owns section classification (capability/category grouping), ordering, card-kind inference (deviceClass/kind/stateClass/compositionRole → card), group inference (dual-line pairing inferred from name/metricID tokens like user/system, in/out, rx/tx — fragile, see §13), surface-item identity (the canonical `surfaceItems` API used by per-slot Available Items customization), table row limits, sample-history defaults, title de-dup, and card-row layout. `GraphAxisResolver` computes per-metric axes; `GraphAxisTicks` labeled three-tick axes on primary detail cards only (dashboard graphs stay compact).

### 7.3 Card vocabulary (closed, generic — 15 kinds)

`statusRow` (label + tone dot + monospaced value) · `gauge` (ring) · `progress` (linear) · `historyGraph` (multi-series Canvas sparkline: broken lines across failures, red failure bars — opacity 0.72/width 1.5 single-series, 0.55/1.2 multi-series primary-only; `nil` or `ok == false` **never plots as zero**; legend max 4; min/max/avg summary; 112pt) · `dualLineGraph` · `sampleHistory` (Time/Result/Status rows, limit 8, identity `history:<entityID>`, follows focused host) · `segmentedRing` (+ center readout) · `breakdownLegend` · `coreGrid` · `statTable` (legacy rows or typed `TableValue`, limit 5) · `control` (toggle/select/number/button → command closures) · `instanceSelector` (host dropdown, primary star) · `section` (uppercased title group) · `statusBanner` (tone + icon, compact single-line mode; diagnosis banners) · `cardRow` (horizontal composite). `CardSpec`: kind, bound entities, children, title override, `role: .primary/.secondary` (axes vs. compact), tableRowLimit.

### 7.4 Slots

A **slot** binds a selection to one menu-bar item + popover:
`SlotSelection = .integration(id) | .integrations([ids]) | .integrationType(id)` (all enabled instances, dynamic, no membership sync) `| .capability(cap) | .entities([ids])`. Slot model: `id`, `title`, `selection`, `barReadout` (dynamic attention-driven). `SlotResolver` resolves selections against live descriptors + registry. Graph ranges: `.m1 | .m5 | .m10 | .h1`. Per-slot state: focus (`slotFocus`), graph range, Available Items (`SlotPresentationOverride`: `shownItems`, `hiddenItems`, `tableRowLimit`).

### 7.5 Settings model (generic, progressive disclosure — zero bespoke provider panes)

1. **Zero-setup defaults** ship in descriptors (primary metric, graph style, visibility, thresholds).
2. **Per-integration quick controls:** entity show/hide/pin, instance enable/disable.
3. **Power drill-in:** display threshold, alert threshold, graph range/style, alert policy, poll interval.

Driven entirely by `IntegrationConfigSchema` (field kinds: text, number, toggle, select — **no secret kind yet**), `EntityPresentationOverride`, `IntegrationPresentationOverride`, `SlotPresentationOverride`, `AlertKindOverride`, composed in `PresentationSettingsModel`, persisted as `PresentationConfig` via `PresentationConfigStore` (UserDefaults). `PingSettings.swift` was deleted — proof the generic path suffices.

---

## 8. macOS app behavior (AmbitMenuBar + AmbitUI)

### 8.1 Chrome

Menu-bar-only accessory app (`LSUIElement`, no dock icon; `NSApp.setActivationPolicy(.accessory)`). One `NSStatusItem` per slot via `StatusBarController`; `MenuBarStatusItemCoordinator` + `MenuBarStatusItemReconciler` **reconcile status items at runtime from `$slots`** (create/remove/reorder without relaunch). Glyph (`StatusGlyphRenderer`): 22pt NSImage, tone dot + monospaced primary text, non-template (exact RGB); tooltip "Slot Title · Value"; updates every snapshot. Click toggles a transient **NSPopover 420×640** (dark, 18pt padding): header = host selector (if >1 instance) or title/subtitle, active-context chips (≤3), 25pt bold readout + tone dot + status label, overlay & settings buttons; optional range picker; scrollable `SurfaceView` (scroll position preserved per slot, reset on slot change).

### 8.2 Floating overlay

`OverlayController`: always-on-top NSPanel rendering compact cards from the **selected slot's** existing `SlotSurface` (generic — any slot, not just ping). Config: overlay visibility, always-on-top, compact mode, opacity, saved frame, reset. Click-through to open the slot's popover; slot/focus menus with no integration-id branches.

### 8.3 Notifications

`NotificationDelivering` protocol → `MacNotificationDeliverer` (UNUserNotificationCenter) via `AlertNotificationService`. Permission/test ("Send Test")/settings controls in the App pane. Per-kind provider-declared toggles + status-color overrides. Interruption levels map from severity; action buttons dispatch `CommandInvocation`s; bound notifications clear on recovery.

### 8.4 Settings window

AppKit NSWindow (740×480) hosting SwiftUI: sidebar (integration groups with health dots, App, Slots, History, Notifications, Automations, Contexts, Diagnostics) + detail pane. Instance management: status dots, PRIMARY badges, suggested presets, role dropdowns, generic **Test** action. Dynamic `IntegrationConfigForm` from schema with inline validation. Rule builder, context editor (manual pin toggles, priority reorder), slot Available Items editor (drag reorder), history export/clear, diagnostics, Start-at-Login (`SMAppService`), reset/about/quit, Sparkle service *hooks* (no feed/keys yet). Live-syncs UserDefaults. `Cmd+,` opens it.

### 8.5 Packaging, permissions, ops (macOS reality — must survive rearchitecture)

- **SwiftPM only** (Swift 6.0, macOS 13+); no Xcode project. `swift run` **crashes** (UNUserNotificationCenter requires a bundle): a launch script hand-rolls `.build/bundle/Ambit.app`, generates Info.plist, copies resources, codesigns (ad-hoc default; `AMBIT_CODESIGN_IDENTITY` for a stable identity so TCC grants survive rebuilds), and `open`s it.
- Info.plist: `LSUIElement=true`; **`NSAppSleepDisabled=true`** (App Nap otherwise freezes the poll loop — rediscovered the hard way); location + local-network usage descriptions. Entitlements: location, calendars, network client; provisioned **Wi-Fi entitlement path for location-gated SSID** (macOS 14.4+ requires Location authorization to read SSID). Dev bundle id `com.hadm.ambit` (HANDOFF also references a historical `tv.kodi.ambit` defaults domain for the dev registry; not present in source).
- App Intents metadata requires an `xcodebuild` pass with `SWIFT_ENABLE_EMIT_CONST_VALUES=YES` + `appintentsmetadataprocessor` (plain SwiftPM builds lack it).
- Single-instance enforcement via `FileAppInstanceLock` (lockfile).
- Local Network permission checklist surfaces for private/link-local/loopback targets.
- Ops check: newest row in `history.sqlite` should be <5s old; staler ⇒ App Nap regression.
- Dev registry fixtures (leave in place): `ping@1.1.1.1:443` (Cloudflare TCP, multi-host eyeballs) and `ping@127.0.0.1:22` ("Local", intentionally failing to exercise down rendering).

### 8.6 Module layout & dependency rule

`AmbitCore` (UI-free: identity, entities, engines, registry, composer, resolver, config stores) ← `AmbitUI` (SwiftUI card vocabulary + chrome, iOS-ready) ← `AmbitMenuBar` (thin: status-item wiring, view model, coordinators). `AmbitCheck` depends on Core only — its existence *proves* Core is UI-free.

---

## 9. CLI (`ambit-check`)

Headless multi-mode diagnostic sharing the same Engine: default (router endpoint status), `--probe-vpn-methods`, `--probe-speedify`, `--dump-speedify-networks`, `--probe-starlink`, `--run-iperf3 <host>`, `--validate-manifest <dir>`, `--run-manifest <dir> [--manifest-credential id=value]`, `--usage` (per-module metering). Exit codes: 0 ok, 1 error, 2 no endpoint. Doubles as the proof that Core runs without UI (and would run on Linux).

---

## 10. Persistence inventory (all formats need migration or export in a rearchitecture)

| What | Where | Format |
|---|---|---|
| History samples | `~/Library/Application Support/Ambit/history.sqlite` | SQLite, `EntityID`-keyed samples (timestamp, value?, ok) |
| Presentation config (slots, entity/integration/slot/alert-kind overrides) | UserDefaults | Codable JSON via `PresentationConfigStore` |
| Integration registry (enable/disable, instance records incl. ping hosts) | UserDefaults | Codable records; migrations in a dedicated generic migrator (`IntegrationConfigMigrator`) |
| User rules | UserDefaults key `userRules` | `UserRuleDocument` (schemaVersion 1; future-version ⇒ empty; forward-migrating decode) |
| Contexts | UserDefaults key `contexts` | `ContextDocument` (schemaVersion 1, same policy) |
| Installed manifest providers | `InstalledProviderStore` | Manifest packages + records |
| Credentials | macOS Keychain (`KeychainCredentialStore`) | Per-credential items |
| Overlay window frame, misc app settings | UserDefaults | Scalars |

Known decode-compat obligations: legacy alert-policy records without `preset`, record-level display names, legacy severity aliases, latency-shaped `AlertPolicy` → `EntityAlertPolicy`.

---

## 11. Verification strategy (port this before rearchitecting anything)

~745 test functions green (`swift build` + `swift test`; 684 tests at the pre-B-series checkpoint, plus B1–B6 coverage). The load-bearing pieces:

1. **Frozen golden fixtures** (`Tests/AmbitCoreTests/Fixtures/GenericMonitoringParity/`): `network_diagnosis_matrix.json` (50+ topology scenarios), `ping_alert_monitor_events.json` (alert state machine transitions incl. warm-up), `observable_ping_surface.json` (surface plans + glyphs per scenario), multi-host presentation/instance fixtures. These lock *behavior*, not implementation — they are the rearchitecture's acceptance suite.
2. **Differential tests** — legacy trigger declarations compiled onto the Condition tree produce byte-identical outcomes.
3. **Migration tests** — every persisted format decodes from its historical shapes.
4. **The grep-gate** — no ping-specific identifiers in Core engines or UI modules (allowlisted: Ping integration, seeds/migrations, fixtures). Keep this concept: it is what keeps "generic" true.
5. **Non-ping fixture proof** — a synthetic non-ping integration exercises the full generic path.
6. **Eyeball checkpoints** — human validation that generic primitives feel first-class ("at least as good as the bespoke version"). These repeatedly caught real gaps; budget for them.
7. UI unit tests (~49): graph geometry, failure marks, axis density, legends, summaries, table formatting, tone mapping.

Principles that produced this quality bar (keep them): harvest from shipped donors instead of designing in the abstract; refactor in place, green after every step, one small commit per step; never weaken tests for surviving code.

---

## 12. Status ledger

**Built and locked (on master):** identity hierarchy; entity model with offline stability; registry + runtime rebuild; poll loop + TimeoutProbe + watchdog + sleep/wake; staleness-vs-down; SQLite history + export; health; manifest system + CLI validation; credentials (Keychain); generic monitoring (MonitoringMetadata, TopologyDiagnosisEngine, MonitoringAlertStateMachine, DiagnosticSummaryEntity, NetworkAwarenessConfig, quieting); entity-targeted alerting + injectable notifications; Condition tree (B1); Reaction registry incl. Shortcuts/App Intents (B2, B6); user rules store/runner/builder (B3); contexts + overlay stacking + cycle detection + traces (B4); signal providers — location/SSID, calendar, focus (B5); App Intents bridge + packaging (B6); attention engine (per-slot); SurfaceComposer + 15-card vocabulary; slots + runtime status-item reconciliation; generic settings; System dashboard + Available Items; history/graph fidelity; multi-host ping parity; floating overlay generalization; network resilience; ping + system integrations live.

**Designed, not built:** multi-engine topology (Phase 3: computed ownership, eligibility/reach, make-before-break handoff, `maxOverlap`); Settings UX v0 "Part A" (rail IA, metric cards with usage chips, surface builders as visual canvases, notifications v2 three-layer model, plain-language pass — see `docs/ux/v0/spec.md`; the current settings UI predates this design); broker transport + relay.

**Deferred / not started:** Sparkle auto-update (hooks exist; needs feed, EdDSA keys, release workflow); device integrations rebuilt (gl.inet first, then Starlink HTTP/2+protobuf, reachability, Speedify, EcoFlow — all blocked on a secure config field); iOS app/widgets/Live Activity/Control Center; web viewport (narrow, read-only setup — never the hero dashboard); Windows/Android.

**Explicitly rejected:** federation/server-to-server; a general "draw arbitrary UI" extension hook (turn special cases into new generic primitives instead); mesh VPN as default transport; autonomous-agent UX.

---

## 13. Architectural debt & critique (what the rearchitecture should fix)

**Orchestration is the weak layer — the Core model is proven, the app shell around it is overgrown.**

1. **`StatusViewModel` (~1,800 lines) is a god object:** registry migration, slot seeding/backfill, gateway auto-seeding, polling lifecycle, alert delivery, attention state, history export, settings mutation, slot focus, surface building, network-change handling, sleep/wake. Highest-risk seam in the codebase. (Partially mitigated: per-slot attention, `SlotSurfaceCoordinator`, runtime reconciler, Phase J file decomposition — but the responsibilities still converge here.)
2. **Taxonomy drift between `DeviceClass` and `capability`:** both influence formatting, sectioning, axes, grouping; the boundary is informal (CPU sections come from capability, formatting from `DeviceClass.percent`/`.count`; load abuses `.count` for want of a `.level` class). `EntityCategory.primary` overlaps `isPrimary` conceptually. Needs one crisply-owned semantic axis each.
3. **`SurfaceComposer` is a 600-line rule engine** (pure and tested, but dense); dual-line pairing inferred from name tokens (`user/system`, `in/out`, `rx/tx`) will break on devices with different vocabularies — pairing should be declared (`compositionRole`-style), not inferred.
4. **Dual alerting stacks:** the legacy `AlertEngine`/`AlertTriggerDeclaration` path coexists with the Condition/Reaction engine (bridged by compilation + `legacyEvaluate`). One engine should remain.
5. **`StatusSnapshot` compat layer** (router/VPN-era shape) still wraps `EngineSnapshot`.
6. **Persistence sprawl:** six-plus UserDefaults-backed stores with hand-rolled versioning each; no unified declaration store, no export/import, no cross-store transactional consistency (contexts reference rules/slots/entities by ID with no referential integrity).
7. **No secret field kind** in `IntegrationConfigSchema` — blocks every device integration; `saveIntegrationInstanceDraft` still needs type-specific knowledge to turn schema values into records.
8. **UI split-brain:** AppKit settings window + SwiftUI popover; `AmbitSettings` still large; dark-mode-only hardcoded colors; Canvas graph rendering untested beyond its pure geometry; overlay NSPanel multi-display focus quirks; status icons loaded via FileManager.
9. **Sequential awaits** in surface building (parallelizable); temporal-state keying by string paths (`"root.all[0]"`) is fragile under condition-tree edits (state silently resets when a rule is restructured).
10. **Vestiges:** retired-but-present device clients in Core (donors for rebuilds), `ProviderIDs`-vs-`ProviderInstanceIDs` resolution shim, occasional latency-flavored naming in generic types.

---

## 14. Rearchitecture guidance

### 14.1 Invariants — do not break these

1. **Deterministic, engine-independent identity**; no EngineID in any entity/instance ID. (Failover depends on it.)
2. **Descriptor/state split with offline stability.** Descriptors outlive connectivity; absence is a state, not a deletion.
3. **Staleness ≠ down**, computed as a pure function of `(lastUpdated, interval, now)` on a wall-clock cadence independent of polling; diagnosis suppressed on stale data; "Monitoring paused" is a distinct state.
4. **Never await a wedged probe.** First-to-finish resolution, abandon the loser.
5. **Core stays UI-free and Linux-capable.** A headless target must exercise the full engine.
6. **No integration-specific logic outside integration declarations** — keep an enforcement mechanism equivalent to the grep-gate.
7. **Everything declarative:** conditions, reactions, rules, contexts, alert kinds, manifests are serializable data with schema versions and forward-safe decoding.
8. **Quiet by default:** warm-up baselines, sustained-state requirements, cooldowns, recovery-only-after-delivery.
9. **Honest rendering:** missing/failed samples never plot as zero; sensors degrade to "unavailable", never fabricate.
10. **The generic card vocabulary is closed and opinionated** — gaps become new primitives, never provider-drawn UI.
11. **Metering stays built-in.**
12. **Behavioral goldens are the acceptance contract** — port fixtures before code.

### 14.2 Target shape (proposal)

- **Kernel:** a small actor-per-concern engine — `Poller` (per-provider actors, structured concurrency, per-provider intervals), `Clock/StalenessService` (owns the wall-clock tick), `HistoryWriter`, `DeclarationStore` (one versioned, transactional store for rules/contexts/slots/overrides/registry with referential integrity and export/import — replacing the UserDefaults sprawl; SQLite or a single JSON document store), `RuleKernel` (the *only* evaluator: built-in alert kinds compile to it; delete the legacy AlertEngine path and `StatusSnapshot`), `AttentionService` (per-surface, not just per-slot — ready for widgets/Live Activity), `CommandDispatcher` (confirmation + rate-limiting + audit log in one place).
- **Stable temporal-state identity:** key evaluator state by content-hash or explicit node IDs, not positional paths, so editing a rule doesn't silently reset its dwell state.
- **Taxonomy cleanup:** make `deviceClass` own *value semantics* (format, unit, axis; add `.level`), `capability` own *membership/grouping*, and a single explicit primary-readout mechanism. Declare composition (pairing/breakdown) on descriptors; delete name-token inference.
- **App shell:** replace StatusViewModel with per-slot/per-surface presenters fed by a single snapshot pipeline; one SwiftUI app (Settings included), theme-aware (light mode), with the Settings UX v0 design (§12 "Part A") as the settings information architecture — it is fully specified and better than what's built.
- **Integration SDK:** the manifest system plus a typed Swift protocol are the two authoring tiers; add the secure config/credential field first — it unblocks all six shelved device integrations.
- **Topology readiness, not topology:** keep IDs, snapshots, and stores multi-engine-clean (they already are); build Phase 3 only when Tier 1 hardware exists.

### 14.3 Suggested sequencing

1. Port golden fixtures + migration tests (acceptance harness).
2. Kernel: identity/entity/registry/poller/staleness/history on the new persistence layer.
3. RuleKernel unification (compile alert kinds; delete legacy paths) — differential-test against goldens.
4. Attention + composer + card vocabulary (pure; ports nearly verbatim).
5. New app shell (presenters, SwiftUI settings per UX v0).
6. Secure config field → gl.inet rebuild (proves the integration SDK) → remaining devices.
7. Then: Sparkle, iOS, topology.

---

*Companion documents, all in `docs/`: `pitch.md`, `product-spec.md` (v1 framing), `entity-model.md`, `integration-model.md`, `provider-capability-model.md`, `presentation-model.md`, `engine-topology.md`, `ux/v0/spec.md` (+ `schema.md`, `b6-app-intents-packaging.md`, `mocks.html`), `provider-manifests.md`, `superpowers/specs/*` (dated design specs), `HANDOFF.md` (running project map). This document supersedes none of them; it is the synthesis. (`MIGRATION_PLAN.md`, the completed seed migration, was removed 2026-07-03; see git history.)*

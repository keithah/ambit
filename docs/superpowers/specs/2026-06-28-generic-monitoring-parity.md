# Generic Monitoring Parity

Date: 2026-06-28

Pre-milestone HEAD: `989751a`

Reader: an Ambit engineer implementing the next core milestone after Ping + System reached feature-complete.

Post-read action: implement full PingScope feature parity while removing ping-specific diagnosis, alert, role, and UI logic. At the end, Ping is only an integration that declares metadata and providers; all monitoring behavior runs through generic primitives that any integration can reuse.

## Goal

Ambit currently proves the generic presentation path for Ping and System, but some behavior still lives in Ping-named modules:

- topology diagnosis: local gateway, ISP path, upstream, remote service
- network/path alert state machines
- address-to-tier classification
- diagnosis summary entity construction
- ping-focused slot surface assembly and range/focus defaults
- host-management affordances that are still shaped by PingScope

This milestone converts those into generic monitoring primitives. Ping keeps its probe implementation and declares metadata for each host, but it stops owning bespoke diagnosis and alert engines. A router, system, or future device integration should be able to drive the same engines by declaring roles, topology position, alert kinds, and commands.

## Non-Goals

- Do not rebuild gl.inet, Speedify, EcoFlow, Starlink, or reachability in this milestone.
- Do not add bespoke Ping UI.
- Do not hardcode Sparkle feed URLs, EdDSA keys, hosting paths, or signing secrets.
- Do not begin iOS/widgets/Live Activity implementation. Record the generic contracts they will consume later.

## End State Invariant

No code outside the Ping integration should need to ask, "is this Ping?" to diagnose, alert, render, focus, export, or configure the monitor.

Allowed Ping-specific code:

- Ping provider/probe implementations: TCP, UDP, ICMP, timeout wrapping, probe result parsing.
- Ping integration declaration: config schema, suggested presets, provider construction, default entity descriptors, declared topology roles, declared alert kinds, and declared commands.
- Migration code for old persisted Ping/PingScope records, until the migration window can close.

Disallowed after Half 1 ships:

- Ping-specific diagnosis coordinator.
- Ping-specific network diagnoser types.
- Ping-specific alert monitor/state machine.
- Ping-specific diagnosis entity type.
- Ping-specific UI branches in settings, overlay, popover, menu bar, history, notification panes, or surface rendering.

## Already Generic

These primitives are already shared and should be preserved:

- Entity-targeted alert bridge: `AlertTarget`, `AlertTargetResolver`, and `AlertEvent.target`.
- Generic alert policy: `EntityAlertPolicy` with threshold, comparison, consecutive, cooldown, and recovery.
- Notification delivery: `NotificationDelivering`, `NotificationIntent`, and `AlertNotificationService`.
- Per-slot attention and headline selection: `SlotAttentionEngines`, `AttentionEngine`, and `SlotReadoutSelector`.
- Generic surfaces: `SurfaceComposer`, `SurfaceData`, `SurfaceItemID`, `CardSpec`, and AmbitUI cards.
- Generic settings model: `IntegrationConfigSchema`, `EntityPresentationOverride`, `SlotPresentationOverride`, and `PresentationSettingsModel`.
- History and export: `HistoryService`, `Sample`, `SampleStats`, `sampleHistory`, and `HistoryExport`.
- Overlay surface selection: selected slot + generic compact cards.

## Current Ping Leakage Audit

| Current seam | Leakage | Generic primitive it becomes |
| --- | --- | --- |
| `PingDiagnosisCoordinator` | Knows Ping records, Ping host config, Ping range, Ping network status, diagnosis entity, and alert monitor. | `MonitoringPerspectiveCoordinator`, fed by resolved descriptors/states plus declared roles and alert kind declarations. |
| `NetworkPerspectiveDiagnoser` / `NetworkDiagnosis` | Hard-coded network tiers, verdict enum, titles, and detail copy. | `TopologyDiagnosisEngine` over generic topology roles and perspective scopes. |
| `NetworkTier` / `NetworkTierClassifier` | Address-derived tier is Ping host config specific. | `MonitoringRole` metadata plus generic `AddressClassifier` helpers available to all integrations. |
| `PingAlertMonitor` | Host-down/recovery, path degraded, internet loss, network status, network change all emit `ping.*` rule IDs and target Ping diagnosis. | `MonitoringAlertStateMachine` keyed by declared `AlertKind` and `AlertTarget`. |
| `DiagnosisEntity` | Synthetic ID and descriptor are `ping.summary.*`. | Generic `DiagnosticSummaryEntity` emitted per integration/slot/perspective. |
| `SlotSurfaceCoordinator.buildPingSurface` | Separate Ping path for focus, host options, range, diagnosis, latency sample fallback, headline eligibility. | Generic multi-instance slot focus, primary instance selection, perspective diagnosis injection, and history fallback rules. |
| `StatusViewModel.refreshPing` | Poll loop has Ping-only diagnosis, event delivery, and range refresh. | Generic post-poll monitoring pass over all integration-declared perspectives. |
| Ping config save path | Saves Ping host config by hand and preserves Ping tier. | Generic multi-instance config draft saving with integration-owned draft normalizer. |
| Ping range | `pingRange` is stored separately from generic graph range overrides. | Per-slot graph range/display profile in `SlotPresentationOverride` or generic display config. |
| Ping suggested hosts | Defaults are hardcoded in seed/migration. | `IntegrationPreset` declarations exposed in generic instance editor. |

## Split Delivery

This milestone is split into two shippable halves.

### Half 1: Genericize, Cut Over, Delete

Half 1 replaces existing Ping-specific diagnosis, alerting, role, diagnostic summary, and surface-assembly behavior with generic primitives. It ships green with current Ping behavior preserved.

Half 1 phases:

1. Phase 0.5: Characterization.
2. Phase A: Vocabulary.
3. Phase B: Topology diagnosis + live diagnosis cutover.
4. Phase C: Diagnostic summary entity.
5. Phase D: Alert state machine + live alert cutover.
6. Phase E: Genericize ping surface assembly and range leakage.
7. Phase H: Delete ping engines + CI grep-gate.

Deletion and grep-gating happen only at the end of Half 1, after characterization, differential tests, second-provider proof, and migration tests are green.

### Half 2: New Generic Features

Half 2 adds the remaining PingScope affordances on top of the generic Half 1 foundation.

Half 2 phases:

1. Phase E2: Instance management: presets, roles, test action, status dot, primary badge.
2. Phase F: Display and overlay config: graph range, overlay visibility, always-on-top, compact mode, opacity, saved size, reset.
3. Phase G: Diagnostics pane and App/About/Reset/Quit/Sparkle hooks.
4. Phase N2: Notification per-kind toggles and per-status colors.

Half 2 starts only after Half 1 has shipped with the grep-gate active.

## Workflow Gates

The implementation order is intentionally gated:

1. Amend this spec and stop for review.
2. After spec approval, implement Phase 0.5 characterization tests only. Commit green and stop for review of both this spec and the fixtures.
3. Only after fixture approval, begin Phase A.
4. From Phase A onward, each phase is one green commit, with a stop/report after every phase.
5. No production cutover occurs until the matching differential tests are green.
6. No deletion occurs until Half 1 migration tests, non-Ping proof tests, differential tests, and live cutovers are green.

## Generic Model Additions

### Monitoring Metadata

Avoid broad entity-model sprawl by adding a single nested optional to `EntityDescriptor`:

```swift
public struct MonitoringMetadata: Equatable, Codable, Sendable {
    public var role: MonitoringRole?
    public var perspectiveID: MonitoringPerspectiveID?
    public var alertKindIDs: [AlertKindID]
    public var diagnosticSummary: DiagnosticSummaryRole?
    public var address: MonitoredAddress?
    public var roleAssignment: MonitoringRoleAssignment?
}
```

`EntityDescriptor.monitoring: MonitoringMetadata?` becomes the only new monitoring-specific descriptor surface. Ping populates it from host config and address classification. Other providers can populate it directly or omit it.

### Roles and Perspective Diagnosis

```swift
public enum MonitoringRole: String, Codable, Sendable, CaseIterable {
    case localLink
    case localGateway
    case accessNetwork
    case upstreamInternet
    case remoteService
    case endpoint
}

public struct MonitoringPerspectiveMember: Equatable, Sendable {
    public var entityID: EntityID
    public var instanceID: IntegrationInstanceID
    public var displayName: String
    public var role: MonitoringRole
    public var status: HealthStatus
    public var isStale: Bool
    public var consecutiveFailures: Int
}

public struct MonitoringPerspective: Equatable, Sendable {
    public var id: MonitoringPerspectiveID
    public var title: String
    public var members: [MonitoringPerspectiveMember]
    public var linkStatus: NetworkConnectivityStatus?
    public var sensitivity: DiagnosisSensitivity
}

public struct MonitoringDiagnosis: Equatable, Sendable {
    public var perspectiveID: MonitoringPerspectiveID
    public var verdict: MonitoringVerdict
    public var severity: Severity
    public var confidence: DiagnosisConfidence
    public var affectedEntityIDs: [EntityID]
    public var title: String
    public var detail: String
    public var evidence: [MonitoringEvidence]
}
```

Ping drives this by declaring one default perspective over enabled host latency entities. A router integration can mark WAN connectivity as `accessNetwork`. A modem or dish integration can mark link state as `accessNetwork`. A SaaS endpoint integration can mark endpoint checks as `remoteService`. System can opt out unless it declares a perspective.

### Generic Role Assignment

```swift
public enum AddressScope: String, Codable, Sendable {
    case loopback
    case linkLocal
    case privateNetwork
    case publicInternet
    case hostname
    case unknown
}

public struct MonitoringRoleAssignment: Equatable, Sendable, Codable {
    public var explicitRole: MonitoringRole?
    public var derivedRole: MonitoringRole?
    public var source: RoleAssignmentSource
}
```

The current Ping tier classifier becomes generic address classification. Ping config exposes a generic role field, not a Ping tier field. Suggested presets set explicit roles where known. Auto mode uses `AddressClassifier`.

### Diagnostic Summary Entity

```swift
public struct DiagnosticSummaryDescriptor {
    public static func descriptor(owner: DiagnosticOwner, id: DiagnosticID) -> EntityDescriptor
    public static func state(id: EntityID, diagnosis: MonitoringDiagnosis) -> EntityState
}
```

The summary is a generic diagnostic/text entity. Any integration can emit one when it declares a perspective or diagnostic source.

### Alert Declarations

Alert events reuse the existing entity `Severity` enum. Do not introduce a parallel alert severity taxonomy. If a distinct alert-specific severity becomes necessary later, it must map to/from `Severity` in one explicit conversion point.

```swift
public struct AlertKindDeclaration: Equatable, Sendable, Codable {
    public var id: AlertKindID
    public var titleTemplate: String
    public var messageTemplate: String
    public var severity: Severity
    public var defaultEnabled: Bool
    public var target: AlertTargetTemplate
    public var trigger: AlertTriggerDeclaration
    public var recovery: AlertRecoveryDeclaration?
    public var cooldown: TimeInterval
}

public enum AlertTriggerDeclaration: Equatable, Sendable, Codable {
    case healthTransition(to: HealthStatus)
    case diagnosisVerdict(MonitoringVerdict.Kind)
    case connectivityTransition(to: NetworkConnectivityStatus)
    case allMembersFailing(minimumCount: Int, ratio: Double)
    case metricThreshold(EntityAlertPolicy)
}

public struct MonitoringAlertStateMachine: Sendable {
    public mutating func evaluate(
        declarations: [AlertKindDeclaration],
        inputs: MonitoringAlertInputs,
        now: Date
    ) -> [AlertEvent]
}
```

Delivery remains global: `AlertNotificationService` delivers one notification per resolved entity event. Promotion remains per-slot: `SlotSurfaceCoordinator` intersects resolved alerting IDs with each slot's candidates before passing them to `AttentionEngine`. This split prevents duplicate per-slot delivery while preserving slot-local attention.

### App-Level Network Awareness

Connectivity and network-change alerts are app-level, not Ping declarations:

```swift
public struct NetworkAwarenessConfig: Codable, Equatable, Sendable {
    public var connectivityAlertsEnabled: Bool
    public var networkChangeAlertsEnabled: Bool
    public var pathRecoveredAlertsEnabled: Bool
    public var cooldown: TimeInterval
}
```

`NetworkAwarenessConfig` owns connected/noIP/noInternet/notConnected transitions and gateway old-to-new network-change notifications. Ping consumes the resulting connectivity status for diagnosis, but it does not own those alert kinds.

### Alert Template Tokens

The declaration renderer supports a fixed token vocabulary:

- `{hostName}`
- `{entityName}`
- `{affectedCount}`
- `{totalCount}`
- `{moreCount}`
- `{roleName}`
- `{tierName}` as a migration alias of `{roleName}` while old Ping copy is characterized
- `{gatewayOld}`
- `{gatewayNew}`
- `{statusOld}`
- `{statusNew}`

Tests must reproduce exact current strings, including:

- `N/M gateway host(s) unreachable`
- `+N more host(s)`
- current host-down, recovery, internet-loss, network-status, path-recovered, and network-change notification title/message strings

## Half 1 Phase Plan

### Phase 0.5: Characterization

Scope: tests only. No production behavior changes.

Purpose: lock current behavior before any generic refactor.

Golden fixtures:

- `NetworkPerspectiveDiagnoser`: full matrix over role/tier, stale/non-stale, every `NetworkConnectivityStatus`, every `DiagnosisSensitivity`, confidence level, and representative host health/failure counts.
- `PingAlertMonitor`: host down/recovery, cooldown suppression, recovery-after-delivered-active, internet loss, network status transitions, network change, path degraded, path recovered, sensitivity thresholds, and notification copy.
- Observable ping surface: menu-bar/popup headline, single-host default, All Hosts combined graph, failure bars, recent-samples binding, diagnosis banner, and recovery.
- Real pre-milestone config fixtures: `presentationConfig` and `integrationInstances` JSON captured from `989751a`.

Migration fixture assertions:

- Available Items preferences survive.
- Primary selection survives.
- Slot overrides survive.
- `ping@gateway` identity survives stable gateway changes.
- History entity IDs survive; where any ID changes are unavoidable, aliases preserve history continuity.

Acceptance criteria:

- Characterization tests are committed green.
- Fixtures are readable and named by scenario.
- No generic production implementation is added.
- Stop for review before Phase A.

### Phase A: Vocabulary

Scope: additive model and declaration vocabulary only.

Add:

- `EntityDescriptor.monitoring: MonitoringMetadata?`.
- `MonitoringRole`, `MonitoringPerspective`, `MonitoringDiagnosis`, `MonitoringEvidence`, `MonitoringRoleAssignment`, `AddressClassifier`.
- `AlertKindID`, `AlertKindDeclaration`, `AlertTargetTemplate`, alert template renderer, and app-level `NetworkAwarenessConfig`.
- A permanent minimal non-Ping fixture integration that conforms to the real generic protocols and declares one perspective plus one alert kind. This fixture is for permanent tests, not a throwaway mock.

Acceptance criteria:

- Ping descriptors can declare monitoring roles without changing live behavior.
- The non-Ping fixture declares a perspective and alert kind through the same real protocols Ping will use.
- Template token tests reproduce current notification strings.
- No live diagnosis or alert cutover yet.

### Phase B: Topology Diagnosis + Live Cutover

Scope: generic diagnosis engine and live Ping diagnosis cutover.

Implement `TopologyDiagnosisEngine` beside the current Ping diagnoser. Before live cutover, run differential tests:

- old `NetworkPerspectiveDiagnoser` input fixture -> old output
- same input converted to `MonitoringPerspective` -> new output
- outputs must be byte-identical for title, detail, severity, confidence, affected IDs, verdict kind, and evidence order across the full Phase 0.5 diagnosis matrix

Exact cutover point:

1. Differential tests pass.
2. Ping descriptors emit `MonitoringMetadata`.
3. `MonitoringPerspectiveCoordinator` feeds `DiagnosticSummaryEntity` from `TopologyDiagnosisEngine` in the live slot-surface path.
4. `NetworkPerspectiveDiagnoser` and `NetworkDiagnosis` remain only as test oracles until Phase H.

Acceptance criteria:

- Live Ping diagnosis behavior is unchanged.
- The non-Ping fixture can produce a topology diagnosis without Ping types.
- Link-state overrides still win over sample inference.
- Stale/monitoring-paused remains calm and non-alerting.
- Stop/report after commit for eyeball against golden + live diagnosis.

### Phase C: Diagnostic Summary Entity

Scope: replace Ping diagnosis entity construction with generic diagnostic summary descriptors/states.

Implement `DiagnosticSummaryEntity` / `DiagnosticSummaryDescriptor` as an owner-scoped generic diagnostic text entity. Ping's old summary ID is migrated or aliased so Available Items, attention, and history do not drift.

Acceptance criteria:

- Ping diagnosis banners render from the generic diagnostic entity.
- The non-Ping fixture renders a diagnostic summary through the same entity path.
- `DiagnosisEntity` remains only as a migration/test alias until Phase H.
- No UI branches are introduced.

### Phase D: Alert State Machine + Live Cutover

Scope: declaration-driven alert generation and live Ping alert cutover.

Implement `MonitoringAlertStateMachine` and declaration evaluation. Before live cutover, run differential tests:

- old `PingAlertMonitor` input fixture -> old `AlertEvent` list
- same input converted to generic declarations and inputs -> new `AlertEvent` list
- outputs must be byte-identical for event ID/rule ID, target, phase, severity, title/message, cooldown behavior, recovery behavior, and ordering across the full Phase 0.5 alert matrix

Exact cutover point:

1. Differential tests pass.
2. Ping integration declares host/path alert kinds.
3. App-level `NetworkAwarenessConfig` declares connectivity and network-change alerts.
4. Live alert events are emitted by `MonitoringAlertStateMachine`.
5. `PingAlertMonitor` remains only as a test oracle until Phase H.

Acceptance criteria:

- Host down/recovery, internet loss, network status, network change, path degraded, and path recovered stay behavior-compatible.
- Recovery only fires after a delivered active alert.
- Cooldown is phase-based, not string-parsed.
- The non-Ping fixture emits active and recovery alerts through declarations.
- Delivery stays global and per-slot attention promotion stays slot-local.

### Phase E: Generic Slot Surface and Range Cutover

Scope: remove Ping-specific surface assembly/range leakage without deleting the old engines yet.

Move remaining ping-specific focus, primary instance, graph range, history fallback, and sampleHistory binding rules into generic slot primitives:

- multi-instance focus defaults
- selected/focused instance persistence
- primary instance resolution
- per-slot range/display profile
- history fallback from headline measurement to primary latency-like measurement by device class/role
- host options derived from generic integration instances

Acceptance criteria:

- Ping single-host default, All Hosts explicit mode, focused host mode, headline, stats, recent samples, failure bars, and recovery remain unchanged.
- System and the non-Ping fixture continue through the same generic slot path.
- No UI module branches on `IntegrationIDs.ping`.

### Phase H: Delete Ping Engines + Grep-Gate

Scope: deletion and permanent static guard.

Delete:

- `PingDiagnosisCoordinator`
- `NetworkPerspectiveDiagnoser`
- `NetworkDiagnosis`
- `NetworkTier`
- `PingAlertMonitor`
- `DiagnosisEntity`

Add a precise CI grep-gate that fails on Ping identifiers in AmbitCore diagnosis/alert/role/engine code and all UI modules.

Forbidden patterns:

- `IntegrationIDs.ping`
- `Ping*Diagnos*`
- `Ping*Alert*`
- `NetworkTier`
- `DiagnosisEntity`

Allowlist:

- Ping integration/provider/probe directory.
- Built-in seed/migration code.
- Migration tests and characterization oracle tests while the oracle is intentionally retained.

The gate stays green forever after Half 1. If a future feature needs Ping behavior, it must be declared in the Ping integration and consumed by a generic primitive.

Acceptance criteria:

- Differential tests still pass or old oracle fixtures are preserved as serialized golden data.
- Non-Ping fixture proof remains permanent.
- Migration tests pass against real pre-milestone JSON fixtures.
- Grep-gate is active and green.
- Half 1 ships green.

## Half 2 Phase Plan

### Phase E2: Generic Instance Management

Add PingScope instance-management parity through generic settings primitives:

- add/edit/delete/enable
- status dot
- primary badge
- suggested presets
- per-entity network role dropdown with descriptions
- per-instance test action

Generic primitives:

```swift
public struct IntegrationPreset: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var systemImage: String?
    public var values: [String: JSONValue]
}

public enum StandardCommandRole: String, Codable, Sendable {
    case testConnection
    case refreshNow
    case resetToDefaults
}
```

Non-Ping reuse: gl.inet router login probes, endpoint checks, battery API tests, device discovery presets.

### Phase F: Generic Display / Overlay Settings

Add:

- graph range
- overlay show/hide
- always-on-top
- compact mode
- opacity
- saved size/position
- reset position

Generic config:

```swift
public struct OverlayPresentationConfig: Codable, Equatable, Sendable {
    public var selectedSlotID: SlotID?
    public var isVisible: Bool
    public var alwaysOnTop: Bool
    public var compactMode: Bool
    public var opacity: Double
    public var frame: OverlayFrame?
}
```

Non-Ping reuse: System overlay, router/device overlays, future widgets.

### Phase G: Diagnostics / App / About / Reset / Sparkle Hooks

Add generic diagnostics and app controls:

- current state
- debug log path/reveal/copy/clear
- recent failures from generic `ok == false` history
- local-network monitor toggle/status
- ICMP availability indicator
- build flavor
- reset to defaults
- quit
- about
- Sparkle service hooks

Sparkle remains infrastructure-blocked:

- Add a generic update service abstraction with status, check-now, feed URL status, and public-key status.
- Developer ID builds can bind a Sparkle adapter later.
- App Store builds hide or report unavailable.
- Do not hardcode feed URLs, EdDSA keys, or hosting decisions.

### Phase N2: Per-Kind Notification Controls and Status Colors

Add:

- provider-declared alert-kind toggles
- per-status color customization
- alert-kind policy overrides where needed

Non-Ping reuse: router WAN, battery, VPN, disk health, device connectivity.

## Feature Mapping for Half 2

### Notifications

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Permission status/request/test/open settings | Done | `NotificationDelivering`, App settings pane | All integrations |
| Per-alert-kind toggles | Half 2 | `AlertKindDeclaration` + `AlertKindOverride` | Router WAN, battery, VPN, disk health |
| Network-status alerts | Half 1 app-level | `NetworkAwarenessConfig` | Any integration contributing path status |
| Per-status color customization | Half 2 | `StatusStyleOverride` keyed by status/severity | System/battery/VPN state coloring |
| Threshold/cooldown/recovery | Done/partial | `EntityAlertPolicy`; add alert-kind policy overrides | Any measurable entity |

### Instances

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Add/edit/delete/enable | Partial | Generic multi-instance config schema editor | gl.inet routers, endpoints, batteries |
| Primary instance | Partial | `SlotPresentationOverride.primaryInstanceID` | System primary dashboard, router primary WAN |
| Status dot and primary badge | Half 2 | Generic instance list row from descriptors/states | All multi-instance integrations |
| Suggested presets | Half 2 | `IntegrationPreset` declarations | Default gateway, public DNS, router discovery, common devices |
| Per-entity network role dropdown | Half 2 | `MonitoringRole` field rendered by generic config form | Router WAN, Starlink, reachability endpoints |
| Per-instance test action | Half 2 | Generic `probeNow` or `testConnection` command kind | Ping probe, router login probe, battery API probe |

### Display / Overlay

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Graph range | Half 1 cutover / Half 2 UI | Per-slot graph range/display profile | System dashboard, device slots |
| Overlay show | Partial | `OverlayPresentationConfig.isVisible` | Any selected slot |
| Always on top | Half 2 | `OverlayPresentationConfig.level` | Any selected slot |
| Compact mode | Half 2 | `OverlayPresentationConfig.mode` | Any selected slot |
| Opacity | Half 2 | `OverlayPresentationConfig.opacity` | Any selected slot |
| Saved size/position | Partial runtime only | Persisted overlay frame | Any selected slot |
| Reset position | Half 2 | Generic overlay command | Any selected slot |

### History

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Export target/range/format | Done | `HistoryExportTarget`, `HistoryExportRange`, `HistoryExportFormat` | All history-backed entities |
| Retention | Done | `HistoryService.retentionInterval` | All history |
| Clear | Done global | `HistoryService.clear()`; future targeted clear | All history |

### Diagnostics Pane

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Current state | Half 2 | `DiagnosticsSnapshot` from selected slot/perspective | System, router, battery |
| Debug log path/reveal/copy/clear | Half 2 | `DiagnosticsLogService` protocol + AppKit adapter | All app diagnostics |
| Recent failures | Half 2 | Query `ok == false` samples for target/range | Any history-backed entity |
| Setup/checklist hints | Partial | Existing local-network hint; extend to generic checklist items | Credentials, permissions, sensors |

### Advanced / App

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Local-network monitor toggle/status | Partial | App-level `NetworkAwarenessConfig` | Local routers/devices |
| ICMP availability indicator | Half 2 | Capability/status entity or App diagnostics row | Ping and other ICMP users |
| Build flavor | Half 2 | `AppBuildInfo` | About/App pane |
| Start at login | Done | `StartAtLoginCoordinator` | App-level |
| Single instance | Done | `FileAppInstanceLock` | App-level |
| Reset to defaults | Half 2 | Generic reset action over config stores | App-level |
| Quit | Half 2 | App pane action | App-level |
| About | Half 2 | `AppBuildInfo` + static metadata | App-level |
| Widgets/iOS | Deferred | Future surface consumers | iOS/widget milestones |
| Sparkle auto-update | Design only | `SoftwareUpdateService` protocol + Sparkle adapter | App-level |

## Test Strategy

### Phase 0.5 Characterization

- Golden matrix tests for current diagnosis.
- Golden transition tests for current alerts.
- Observable ping surface tests for headline, default focus, All Hosts, failure bars, sample history, and recovery.
- Serialized pre-milestone config fixtures from `989751a`.

### Differential Tests

- Phase B: old diagnosis engine vs new topology engine, byte-identical output before live cutover.
- Phase D: old alert monitor vs new declaration state machine, byte-identical events before live cutover.

### Permanent Non-Ping Proof

- A minimal fixture integration conforms to the real declaration protocols.
- It declares a perspective and alert kind.
- Tests assert it diagnoses, alerts, renders diagnostic summary, and promotes attention without Ping types.

### Migration Tests

Use real pre-milestone `presentationConfig` and `integrationInstances` JSON fixtures. Assert:

- Available Items item IDs survive.
- Primary selection survives.
- Slot overrides survive.
- `ping@gateway` id survives.
- History ids survive.
- Alias and continuity behavior is explicit if any ID changes.

### Template Tests

- Token substitution covers host name, entity name, affected/total counts, role/tier name, gateway old-to-new, status old-to-new, and more-count.
- Exact current notification strings are reproduced, including `N/M gateway host(s) unreachable` and `+N more host(s)`.

### Grep-Gate Tests

- Static check fails on forbidden Ping identifiers in AmbitCore diagnosis/alert/role/engine modules and all UI modules.
- Allowlist is limited to Ping integration/provider/probe code, seed/migration code, and intentional characterization oracle tests.

### Integration Coverage

- Ping remains PingScope-parity: primary/focused host glyph, single-host default popover, All Hosts mode, multi-series graph, sample history, diagnosis banners, notifications, network resilience.
- System remains unchanged: no monitoring perspective unless declared, CPU primary headline, dashboard cards, history/export.
- The non-Ping fixture proves the new diagnosis and alert engines without Ping types.

### UI / Eyeball Coverage

- After Phase B: live Ping diagnosis matches golden behavior and Wi-Fi/link-state diagnosis remains correct.
- At Half 1 cutover: Ping behavior is identical, grep-gate is green, and the non-Ping proof remains green.
- Half 2: Settings shows generic instance management for Ping with presets, status dot, primary badge, role dropdown, and test action; App pane shows notification/status/app controls; Diagnostics pane shows current state, logs, and recent failures; overlay settings persist and apply to Ping and System.

## Migration Notes

- Preserve existing Ping entity IDs where practical. Where IDs must change, add compatibility aliases or one-shot migrations so Available Items, primary selection, and history continue.
- Preserve `ping@gateway` stable identity and history continuity.
- Keep old Ping/PingScope record migrations until a later cleanup milestone.
- Keep dev test artifacts noted in `HANDOFF.md`: Cloudflare TCP host and failing Local TCP host remain useful for parity eyeballs.
- Capture real pre-milestone JSON fixtures from `989751a` before changing formats.
- Half 1 deletion only happens after differential tests, second-provider proof, migration tests, and live cutovers are green.

## Review Checklist

- Does Half 1 ship as a complete green cutover before Half 2 starts?
- Is Phase 0.5 test-only and first?
- Are B and D live cutover points exact and guarded by byte-identical differential tests?
- Is there a permanent non-Ping fixture integration using real generic protocols?
- Are migration fixtures real pre-milestone JSON, not synthetic-only fixtures?
- Does alert templating reproduce exact current notification strings?
- Is `MonitoringMetadata` the only new descriptor monitoring surface?
- Are connectivity and network-change alerts app-level through `NetworkAwarenessConfig`?
- Does the grep-gate run only after Half 1 cutover and deletion?
- Are Ping strings absent from UI and generic engines at the end of Half 1?
- Are Sparkle and iOS/widgets explicitly deferred rather than half-implemented?

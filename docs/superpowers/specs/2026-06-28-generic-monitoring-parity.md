# Generic Monitoring Parity

Date: 2026-06-28

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

Disallowed after this milestone:

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
| `NetworkTier` / `NetworkTierClassifier` | Address-derived tier is Ping host config specific. | `MonitoringRole` / `TopologyRole` metadata plus generic `AddressClassifier` helpers available to all integrations. |
| `PingAlertMonitor` | Host-down/recovery, path degraded, internet loss, network status, network change all emit `ping.*` rule IDs and target Ping diagnosis. | `MonitoringAlertStateMachine` keyed by declared `AlertKind` and `AlertTarget`. |
| `DiagnosisEntity` | Synthetic ID and descriptor are `ping.summary.*`. | Generic `DiagnosticSummaryEntity` emitted per integration/slot/perspective. |
| `SlotSurfaceCoordinator.buildPingSurface` | Separate Ping path for focus, host options, range, diagnosis, latency sample fallback, headline eligibility. | Generic multi-instance slot focus, primary instance selection, perspective diagnosis injection, and history fallback rules. |
| `StatusViewModel.refreshPing` | Poll loop has Ping-only diagnosis, event delivery, and range refresh. | Generic post-poll monitoring pass over all integration-declared perspectives. |
| Ping config save path | Saves Ping host config by hand and preserves Ping tier. | Generic multi-instance config draft saving with integration-owned draft normalizer. |
| Ping range | `pingRange` is stored separately from generic graph range overrides. | Per-slot graph range / display profile in `SlotPresentationOverride` or generic display config. |
| Ping suggested hosts | Defaults are hardcoded in seed/migration. | `IntegrationPreset` declarations exposed in generic instance editor. |

## Half 1: Genericize Existing Ping Logic

### 1. Generic Topology / Perspective Diagnosis

Current behavior:

- Ping classifies monitored hosts as local gateway, ISP edge, upstream, or remote service.
- Diagnosis blames the innermost failing tier.
- Link-state overrides from path monitoring can produce local-network/no-IP/no-internet verdicts.
- Stale samples produce monitoring-paused, not false down.

Generic primitive:

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

How Ping drives it:

- Each latency entity declares `monitoringRole`, either explicit from host config or derived by generic address classification.
- The Ping integration declares one default perspective over its enabled host latency entities.
- The current local/ISP/upstream/remote verdicts become generic role-depth verdicts with Ping-compatible titles by default.

How non-Ping providers drive it:

- A router integration can mark its WAN connectivity entity as `localGateway` or `accessNetwork`.
- A modem/dish integration can mark link state as `accessNetwork`.
- A SaaS endpoint integration can mark its endpoint checks as `remoteService`.
- System can opt out entirely unless it declares a perspective.

Migration plan:

1. Add role metadata to `EntityDescriptor` or a nested monitoring metadata struct.
2. Add `AddressClassifier` helper for private/link-local/loopback/public/hostname classification.
3. Implement `TopologyDiagnosisEngine` in Core with tests using fake non-Ping entities.
4. Make Ping emit role metadata and build a generic perspective.
5. Convert `DiagnosisEntity` to `DiagnosticSummaryEntity.make(diagnosis, owner:)`.
6. Delete `NetworkPerspectiveDiagnoser`, `NetworkDiagnosis`, `NetworkTier`, and `PingDiagnosisCoordinator` after parity tests pass.

### 2. Generic Alert State Machines

Current behavior:

- Ping emits host down, host recovered, path degraded, internet loss, network status transitions, path recovered, and network change.
- The state machine is in `PingAlertMonitor`.
- Delivery is already generic, but event generation is Ping-owned.

Generic primitive:

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

How Ping drives it:

- Ping declares `hostDown`, `hostRecovered`, `highLatency`, `localNetworkDown`, `ispPathDown`, `upstreamDown`, `remoteServiceDown`, `pathDegraded`, `internetLoss`, `networkStatus`, `pathRecovered`, and `networkChange`.
- Existing notification copy becomes declaration templates with token substitution for display names and counts.
- Per-alert-kind toggles write generic alert-kind overrides.

How non-Ping providers drive it:

- System can declare CPU over-threshold or battery state alerts with the same kind model.
- A router can declare WAN down/recovered and VPN disconnected/recovered.
- A power station can declare battery low/recovered or AC output changed.

Migration plan:

1. Introduce `AlertKindID`, `AlertKindDeclaration`, and `AlertKindOverride`.
2. Add declarations to `Integration` or a new `MonitoringIntegrationCapabilities`.
3. Implement state-machine tests for a fake non-Ping provider.
4. Convert Ping alert monitor tests to declaration-driven tests.
5. Delete `PingAlertMonitor` and keep `AlertNotificationService` unchanged.

### 3. Generic Role Assignment

Current behavior:

- Ping host config has an optional tier override.
- If omitted, a Ping-only classifier maps private IPv4 to local gateway, public IPv4 to upstream, and hostnames to remote service.

Generic primitive:

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

How Ping drives it:

- Ping config schema exposes a generic role field, not a Ping tier field.
- Suggested presets set roles explicitly where known.
- Auto mode uses generic `AddressClassifier`.

How non-Ping providers drive it:

- A router marks its own gateway/WAN metrics explicitly.
- A manifest provider can set role metadata in descriptors.
- Any endpoint provider can choose auto address classification without linking to Ping.

### 4. Generic Diagnostic Summary Entity

Current behavior:

- Ping emits a diagnostic text entity for network diagnosis.

Generic primitive:

```swift
public struct DiagnosticSummaryDescriptor {
    public static func descriptor(owner: DiagnosticOwner, id: DiagnosticID) -> EntityDescriptor
    public static func state(id: EntityID, diagnosis: MonitoringDiagnosis) -> EntityState
}
```

How Ping drives it:

- The Ping integration declares one perspective diagnostic summary.

How non-Ping providers drive it:

- A router can emit "WAN disconnected".
- System can emit "Sensors unavailable" or "Battery service unavailable" without bespoke banner code.

## Half 2: Remaining PingScope Features, Mapped Generically

### Notifications

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Permission status/request/test/open settings | Done | `NotificationDelivering`, App settings pane | All integrations |
| Per-alert-kind toggles | New | `AlertKindDeclaration` + `AlertKindOverride` | Router WAN, battery, VPN, disk health |
| Network-status alerts | Partial | Connectivity alert declarations | Any integration contributing path status |
| Per-status color customization | New | `StatusStyleOverride` keyed by status/severity | System/battery/VPN state coloring |
| Threshold/cooldown/recovery | Done/partial | `EntityAlertPolicy`; add alert-kind policy overrides | Any measurable entity |

### Instances

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Add/edit/delete/enable | Partial | Generic multi-instance config schema editor | gl.inet routers, endpoints, batteries |
| Primary instance | Partial | `SlotPresentationOverride.primaryInstanceID` | System primary dashboard, router primary WAN |
| Status dot and primary badge | New | Generic instance list row from descriptors/states | All multi-instance integrations |
| Suggested presets | New | `IntegrationPreset` declarations | Default gateway, public DNS, router discovery, common devices |
| Per-entity network role dropdown | New | `MonitoringRole` field rendered by generic config form | Router WAN, Starlink, reachability endpoints |
| Per-instance test action | New | Generic `probeNow` or `testConnection` command kind | Ping probe, router login probe, battery API probe |

Proposed type:

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

### Display / Overlay

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Graph range | Partial | Per-slot graph range/display profile | System dashboard, device slots |
| Overlay show | Partial | `OverlayPresentationConfig.isVisible` | Any selected slot |
| Always on top | New | `OverlayPresentationConfig.level` | Any selected slot |
| Compact mode | New | `OverlayPresentationConfig.mode` | Any selected slot |
| Opacity | New | `OverlayPresentationConfig.opacity` | Any selected slot |
| Saved size/position | Partial runtime only | Persisted overlay frame | Any selected slot |
| Reset position | New | Generic overlay command | Any selected slot |

Proposed config:

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

### History

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Export target/range/format | Done | `HistoryExportTarget`, `HistoryExportRange`, `HistoryExportFormat` | All history-backed entities |
| Retention | Done | `HistoryService.retentionInterval` | All history |
| Clear | Done global | `HistoryService.clear()`; future targeted clear | All history |

### Diagnostics Pane

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Current state | New | `DiagnosticsSnapshot` from selected slot/perspective | System, router, battery |
| Debug log path/reveal/copy/clear | New | `DiagnosticsLogService` protocol + AppKit adapter | All app diagnostics |
| Recent failures | New | Query `ok == false` samples for target/range | Any history-backed entity |
| Setup/checklist hints | Partial | Existing local-network hint; extend to generic checklist items | Credentials, permissions, sensors |

Proposed type:

```swift
public struct DiagnosticsSnapshot: Equatable, Sendable {
    public var selectedSlot: SlotID?
    public var primaryEntity: EntityID?
    public var currentStatus: HealthStatus?
    public var latestFailure: Sample?
    public var activeDiagnoses: [MonitoringDiagnosis]
    public var checklist: [SetupChecklistItem]
}
```

### Advanced / App

| Feature | Status | Generic primitive | Non-Ping reuse |
| --- | --- | --- | --- |
| Local-network monitor toggle/status | Partial | App-level `NetworkAwarenessConfig` | Local routers/devices |
| ICMP availability indicator | New | Capability/status entity or App diagnostics row | Ping and other ICMP users |
| Build flavor | New | `AppBuildInfo` | About/App pane |
| Start at login | Done | `StartAtLoginCoordinator` | App-level |
| Single instance | Done | `FileAppInstanceLock` | App-level |
| Reset to defaults | New | Generic reset action over config stores | App-level |
| Quit | New | App pane action | App-level |
| About | New | `AppBuildInfo` + static metadata | App-level |
| Widgets/iOS | Deferred | Future surface consumers | iOS/widget milestones |
| Sparkle auto-update | New design only | `SoftwareUpdateService` protocol + Sparkle adapter | App-level |

Sparkle wiring:

- Add a generic update service abstraction with status, check-now, feed URL status, and public-key status.
- Developer ID builds can bind the Sparkle adapter behind that protocol.
- App Store builds hide or report unavailable.
- Do not hardcode feed URLs, EdDSA keys, or hosting decisions in this milestone.

## Dependency-Ordered Phase Plan

### Phase A: Generic Metadata Vocabulary

Add role/topology metadata, alert-kind declarations, integration presets, command roles, overlay config, and app diagnostics types. No behavior changes yet.

Tests:

- Ping descriptors can declare monitoring roles.
- A fake non-Ping descriptor can declare the same roles.
- Config schemas can render role/select fields and presets without Ping branches.

### Phase B: Generic Topology Diagnosis

Implement `TopologyDiagnosisEngine` beside the current Ping diagnoser. Feed it fake non-Ping members first, then Ping members.

Tests:

- Fake router + remote endpoint diagnoses local-gateway vs upstream vs remote-service faults.
- Stale data yields monitoring-paused.
- Link statuses override member inference.
- Ping diagnosis output remains text/severity-compatible.

### Phase C: Generic Diagnostic Summary Entity

Replace Ping `DiagnosisEntity` with generic diagnostic summary descriptors/states. Keep status banners generic.

Tests:

- Fake non-Ping diagnosis renders a diagnostic text entity and status banner.
- Ping diagnosis IDs migrate or alias cleanly so existing customizations do not break.

### Phase D: Generic Alert Kind State Machine

Introduce declaration-driven alert generation. Migrate Ping alert monitor behavior into declarations.

Tests:

- Fake non-Ping provider emits down/recovery and diagnosis alerts through declarations.
- Ping host down/recovery, internet loss, network status, network change, path degraded, path recovered remain equivalent.
- Per-kind toggles suppress only the selected alert kind.
- Cooldown and recovery are phase-based and not string-parsed.

### Phase E: Generic Multi-Instance Management

Move Ping host-management parity into generic settings primitives: status dots, primary badge, presets, role dropdown, test action, add/edit/delete/enable.

Tests:

- A fake multi-instance integration gets add/edit/delete/enable/primary behavior without custom UI.
- Ping suggested presets populate default values.
- Explicit primary and role selections persist and reconcile if an instance disappears.
- Test action invokes a declared command and reports success/failure.

### Phase F: Generic Display / Overlay Settings

Persist overlay visibility, level, mode, opacity, frame, reset position, and per-slot graph range generically.

Tests:

- Overlay config survives relaunch.
- Overlay on System and Ping consumes the same settings.
- Graph range affects history-backed cards by slot, not by Ping global state.

### Phase G: Generic Diagnostics / App / About

Add Diagnostics and About/App capabilities: current state, debug log actions, recent failures, build flavor, ICMP capability, local-network monitor status, reset defaults, quit, and Sparkle status hooks.

Tests:

- Recent failures query returns `ok == false` samples for Ping and a fake System/entity target.
- Debug log actions call injected service methods.
- Reset defaults clears config stores through a confirmation-gated service.
- Sparkle service can report unavailable/configured/checking without a live Sparkle dependency.

### Phase H: Delete Ping-Specific Engines

Remove `PingDiagnosisCoordinator`, `NetworkPerspectiveDiagnoser`, `NetworkDiagnosis`, `NetworkTier`, `PingAlertMonitor`, and `DiagnosisEntity`. Remove `SlotSurfaceCoordinator` Ping branches by replacing them with generic multi-instance focus and perspective hooks.

Tests:

- Add a guard test that no production type names match `PingDiagnosisCoordinator`, `PingAlertMonitor`, `NetworkTier`, or `DiagnosisEntity`.
- Add a grep-style test or static check for `IntegrationIDs.ping` in UI modules, allowing only migration/seed and Ping integration declarations.

## Test Strategy

### Unit Coverage

- Role assignment from explicit metadata and generic address classification.
- Topology diagnosis for Ping-equivalent and non-Ping provider fixtures.
- Alert kind declarations and state-machine transitions for active/recovered/cooldown.
- Diagnostic summary entity construction for any owner.
- Generic multi-instance settings model: presets, primary badge, status dot, role dropdown, test action.
- Overlay config persistence and reconciliation.
- Diagnostics snapshot and recent-failure queries.

### Integration Coverage

- Ping remains pingscope-parity: primary/focused host glyph, single-host default popover, All Hosts mode, multi-series graph, sample history, diagnosis banners, notifications, network resilience.
- System remains unchanged: no monitoring perspective unless declared, CPU primary headline, dashboard cards, history/export.
- Fake non-Ping monitoring provider proves the new diagnosis and alert engines without any Ping types.

### UI / Eyeball Coverage

- Settings shows generic instance management for Ping with presets, status dot, primary badge, role dropdown, test action.
- App pane shows notifications, local network, ICMP/build/update/about/reset/quit controls.
- Diagnostics pane shows current state, log actions, and recent failures.
- Overlay settings persist and apply to Ping and System.
- Real macOS notification banner from App pane Send Test remains the manual environment check.

## Migration Notes

- Preserve existing Ping entity IDs where practical. Where IDs must change, add compatibility aliases or one-shot migration so Available Items, primary selection, and history continue.
- Keep old Ping/PingScope record migrations until a later cleanup milestone.
- Do not regress existing dev test artifacts: the Cloudflare TCP host and failing Local TCP host remain useful for parity eyeballs.
- Each phase must be green before the next. The deletion phase comes last, after non-Ping proof tests exist.

## Review Checklist

- Does every remaining PingScope feature map to a generic primitive?
- Is there a non-Ping test proof for diagnosis and alert behavior?
- Are Ping strings absent from UI and generic engines at the end?
- Are Sparkle and iOS/widgets explicitly deferred rather than half-implemented?
- Does the phase order avoid a big-bang rewrite?

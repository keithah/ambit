# Notifications and Alerts Design

Status: Phase 0 design. No implementation in this document.

Reader: the engineer implementing the notifications milestone after the core hardening and multi-host ping parity work.

Post-read action: implement generic, entity-targeted alerting and notification delivery without adding integration-specific UI branches.

## Goals

- Resolve alert events to `EntityID`s through a generic bridge so Attention, menu bar headlines, popovers, and notifications all target the same entities.
- Replace menu-bar-local notification delivery with an injectable service that can be tested without live `UserNotifications`.
- Make `AlertPolicy` genuinely generic, or split the latency-specific parts into typed policy data so the generic settings renderer can expose alert behavior for any measurable entity.
- Reuse the existing entity `Severity` taxonomy for alert severity. If a distinct delivery severity is ever needed, it must be mapped to and from `Severity` in one explicit adapter.
- Preserve and generalize the pingscope semantics that matter: cooldowns, recovery notifications, permission handling, and test notifications.
- Keep integration-specific diagnosis logic at the integration boundary. The UI layer should consume resolved entity alerts, not ping rule/provider strings.

## Non-Goals

- No new bespoke notification settings pane for Ping.
- No live OS notification dependency in unit tests.
- No rebuild of disabled device integrations in this milestone.
- No change to the AttentionEngine debounce/boost model except feeding it better `alertingIDs`.

## Current State

The generic primitives are mostly present, but the alert seam is still transitional.

- `AlertEngine` evaluates `AlertRule`s and emits `AlertEvent`s.
- `AlertEvent` is keyed by `ruleID` and `providerID`, not by target entity.
- `PingDiagnosisCoordinator.alertingEntityIDs(from:candidates:)` maps fired events to entities with ping-specific rules:
  - `ping.network` maps to `DiagnosisEntity.entityID`.
  - host events map `providerID` to `<host>/probe.latency_ms`.
- `PingAlertMonitor` emits domain events for host down/recovered and network diagnosis alerts.
- `AlertNotifier` lives inside `StatusViewModel` and directly uses `UNUserNotificationCenter`.
- `AlertPolicy` is stored in `EntityPresentationOverride`, but its fields are latency-shaped: `highLatencyMs` and `highLatencyConsecutive`.
- `AlertRule.defaultRules` still references legacy disabled providers (`starlink`, `vpn`, `ecoflow`).

That shape was acceptable while Ping was the only notification source. It will not scale cleanly to System, rebuilt device integrations, or overlay surfaces.

## Oracle Behaviors to Preserve

The pingscope oracle separates three concerns that Ambit should keep separate:

- A rule set controls enabled state, cooldown, recovery notifications, high-latency sensitivity, diagnosis sensitivity, and alert type selection.
- A decision engine turns host/network state transitions into alert decisions without knowing about macOS delivery.
- A dispatcher owns notification permission state, authorization requests, delivery, and test notifications.

Ambit should preserve those behaviors while translating them into the generic entity model:

- Cooldowns suppress repeated active notifications for the same alert.
- Recovery notifications are opt-in.
- Diagnosis sensitivity belongs to Ping configuration, not to the generic entity alert policy.
- Notification delivery has explicit permission states and is injectable in tests.
- User-facing notification text is built from generic alert intents, not from UI-specific branches.

## Target Architecture

### 1. Entity-Targeted Alert Bridge

Alert events need a stable target model that can resolve to one or more `EntityID`s before they enter Attention or notification presentation.

Recommended core types:

```swift
public enum AlertEventPhase: String, Codable, Equatable, Sendable {
    case active
    case recovered
}

public enum AlertTarget: Codable, Equatable, Sendable {
    case entity(EntityID)
    case providerMetric(providerID: ProviderID, metricID: String)
    case provider(ProviderID)
    case capability(ProviderCapability)
}

public struct AlertEvent: Equatable, Identifiable, Sendable {
    public var id: String
    public var ruleID: String
    public var providerID: ProviderID
    public var target: AlertTarget?
    public var phase: AlertEventPhase
    public var title: String
    public var message: String
    public var severity: Severity
    public var triggeredAt: Date
}

public struct ResolvedAlertEvent: Equatable, Sendable {
    public var event: AlertEvent
    public var entityIDs: Set<EntityID>
}

public protocol AlertTargetResolving: Sendable {
    func resolve(_ event: AlertEvent, descriptors: [EntityDescriptor]) -> Set<EntityID>
}
```

Resolution rules:

- `.entity` returns the exact entity if it exists in the candidate descriptor set.
- `.providerMetric` finds the descriptor whose provider and metric match the target.
- `.provider` resolves to primary descriptors for that provider.
- `.capability` resolves descriptors with the matching capability, preferring primary/visible descriptors.
- Missing targets resolve to an empty set. They do not crash and do not invent entities.

Migration rule:

- Keep `providerID` and `ruleID` for compatibility and diagnostics.
- Add `target` and `phase` as the new authoritative fields.
- Provide a legacy fallback resolver during migration:
  - `providerID + metricID` threshold/sustained rules map to `.providerMetric`.
  - ping host down/recovery maps to the host latency entity.
  - ping network diagnosis maps to `DiagnosisEntity.entityID`.
- Delete the call-site ping mapping once `PingAlertMonitor` and `AlertRule` constructors emit targets directly.

### 2. Generic Notification Delivery Service

Notification delivery should be a service that consumes resolved alert events and emits platform notifications through an injected adapter.

Keep OS-specific `UserNotifications` types out of AmbitCore. Core owns notification intent and policy. AmbitMenuBar owns the macOS adapter.

Recommended core types:

```swift
public enum NotificationAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case provisional
    case unavailable
    case unknown(String)
}

public struct NotificationIntent: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var severity: Severity
    public var entityIDs: Set<EntityID>
    public var phase: AlertEventPhase
    public var triggeredAt: Date
}

public protocol NotificationDelivering: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async -> NotificationAuthorizationStatus
    func deliver(_ intent: NotificationIntent) async throws
}

public actor AlertNotificationService {
    public func deliver(_ events: [ResolvedAlertEvent], using notifier: NotificationDelivering) async -> [NotificationDeliveryResult]
}
```

Responsibilities:

- Request permission only when needed.
- Convert `ResolvedAlertEvent` to `NotificationIntent`.
- Respect recovery notification settings already represented in the event stream.
- Return structured results for tests and future UI state.
- Support a generic test notification using the same delivery path.

The macOS adapter maps `NotificationIntent` to `UNMutableNotificationContent`. Critical alerts can still map to `.defaultCritical` where allowed. Tests use a fake `NotificationDelivering`.

### 3. Generic Alert Policy

The current `AlertPolicy` name is generic, but the fields are latency-specific. That mismatch blocks System and device metrics from using the same settings UI honestly.

Decision: split the model into a generic entity alert policy plus a migration path for the old latency fields.

Recommended model:

```swift
public struct EntityAlertPolicy: Codable, Equatable, Sendable {
    public var preset: AlertPreset
    public var enabled: Bool
    public var threshold: AlertThreshold?
    public var consecutive: Int
    public var cooldown: TimeInterval
    public var notifyOnRecovery: Bool
}

public struct AlertThreshold: Codable, Equatable, Sendable {
    public var comparison: AlertComparison
    public var value: Double
}
```

Rules:

- Threshold value is interpreted through the entity descriptor's `deviceClass`, unit, and display range.
- Consecutive is sample count at the entity level. Integrations may translate it to time-based `SustainedAlertRule.duration` using their poll interval.
- Presets stay generic: quiet/balanced/verbose adjust consecutive, cooldown, and recovery defaults. They do not imply "latency."
- Existing `AlertPolicy.highLatencyMs` and `highLatencyConsecutive` decode into an `EntityAlertPolicy` threshold for latency descriptors during migration.
- Ping diagnosis sensitivity remains an integration config field, not an entity alert policy field.

The generic advanced settings controls should render:

- Enabled toggle.
- Preset picker.
- Threshold comparison and value, unit-aware.
- Consecutive count.
- Cooldown.
- Notify on recovery.

No settings row should mention latency unless the descriptor being edited is a latency descriptor.

### 4. Cooldown and Recovery Semantics

Cooldown and recovery should be state-machine behavior, not notification-adapter behavior.

Recommended semantics:

- Active alert fires on inactive-to-active transition.
- Active repeats are suppressed until cooldown expires.
- Recovery fires on active-to-inactive transition only if `notifyOnRecovery == true`.
- Recovery should be tied to a delivered or deliverable active alert. A suppressed active event should not necessarily imply a later recovery notification.

The current `AlertRuleState.fireOnRisingEdge` inserts active state before checking cooldown. That means a cooldown-suppressed active alert can later produce a recovery event. The implementation phase should decide explicitly whether that is desired. Recommended fix:

- Track evaluation state separately from delivery state.
- Track `notifiedActiveRuleIDs`.
- Emit recovery only when the rule was previously active and a notification was emitted or queued for that active period.

Recovery events should set:

- `phase = .recovered`
- `severity = .info`
- `target` equal to the active event target

### 5. Attention Promotion

After alert events resolve to entity IDs, slot surface building should pass only candidate-local alerting IDs into the per-slot `AttentionEngine`.

Delivery and promotion intentionally differ:

- Notification delivery is global. A resolved alert event produces one notification intent for its resolved entity set, independent of how many slots might show those entities.
- Attention promotion is per-slot. Each `SlotSurfaceCoordinator` intersects resolved entity IDs with that slot's candidates before passing `alertingIDs` into that slot's `AttentionEngine`.

Flow:

1. Engine and integration monitors emit `AlertEvent`s with `target`.
2. `AlertTargetResolver` resolves them against current descriptors.
3. `SlotSurfaceCoordinator` intersects resolved IDs with that slot's candidate set.
4. `AttentionEngine.evaluate(... alertingIDs: ...)` promotes those candidates immediately.
5. `SlotReadoutSelector` consumes the same selection result for menu-bar glyph and popover header.

There should be no UI-layer branch for Ping diagnosis events.

### 6. Legacy Default Rule Cleanup

`AlertRule.defaultRules` still references disabled legacy providers. That creates confusing rule counts and makes tests reason about providers that do not exist in the rebuilt generic shape.

Plan:

- Remove legacy disabled provider rules from `AlertRule.defaultRules`.
- Keep built-in default rules owned by each `Integration.alertRules(instance:)`.
- Keep manifest-loaded rules supported, but require compiled rules to carry a resolvable `AlertTarget`.
- If historical defaults need to be preserved for future rebuilt integrations, move them into disabled fixture tests or integration-specific TODO docs, not the runtime default rule list.

## Generic vs Integration-Specific Boundary

Generic:

- Alert rule evaluation.
- Alert targets and target resolution.
- Cooldown and recovery state.
- Notification intents and delivery protocol.
- Permission handling result model.
- Generic settings controls for entity alert policy.
- Attention promotion through `alertingIDs`.

Integration-specific:

- Domain diagnosis and confidence logic.
- Default policy values chosen for an integration.
- Translation from domain event to generic `AlertEvent(target:)`.
- Secure config needed to reach a provider.

Ping remains allowed to own network diagnosis semantics. It should not own UI alert mapping.

## Phased Implementation Plan

### N1: Alert Target Model and Resolver

- Add `AlertTarget`, `AlertEventPhase`, `ResolvedAlertEvent`, and `AlertTargetResolver`.
- Extend `AlertEvent` with `target` and `phase`.
- Update generic rule types to emit `.providerMetric(providerID:metricID:)` targets.
- Add legacy fallback resolution for old ping events during migration.
- Tests:
  - Threshold event resolves to the matching metric entity.
  - Missing descriptor resolves to an empty set.
  - Capability target prefers candidate descriptors with matching capability.
  - Ping network legacy event resolves to diagnosis entity only while fallback exists.

### N2: Generic Notification Delivery Service

- Add `NotificationIntent`, `NotificationAuthorizationStatus`, `NotificationDelivering`, and `AlertNotificationService`.
- Replace `StatusViewModel`'s private notifier with an injected macOS adapter.
- Keep the delivery call in orchestration, but make it consume resolved events.
- Tests with a fake notifier:
  - Authorized delivery emits one intent per event.
  - Denied permission emits no OS delivery and returns a denied result.
  - Recovery event keeps phase and info severity.
  - Request path only runs when status is `notDetermined`.

### N3: Alert Policy Genericization

- Introduce `EntityAlertPolicy` or refactor `AlertPolicy` to generic threshold fields.
- Preserve decoding of existing latency-shaped policies.
- Update generic advanced settings to render unit-aware threshold fields.
- Update Ping high-latency rule creation to translate latency descriptor policy into sustained rules.
- Tests:
  - Old latency JSON decodes into equivalent generic policy.
  - Settings helpers persist/reset the generic policy without phantom overrides.
  - Ping high-latency rules remain equivalent for quiet/balanced/verbose presets.
  - Non-latency descriptor can express a threshold without latency field names.

### N4: Ping Alert Bridge Migration

- Update `PingAlertMonitor` to emit explicit targets:
  - Host down/recovered targets the host latency entity.
  - Network diagnosis targets `DiagnosisEntity.entityID`.
- Delete `PingDiagnosisCoordinator.alertingEntityIDs(from:candidates:)` or reduce it to a generic resolver call.
- Tests:
  - Host down event resolves to that host's latency entity.
  - Host recovery has the same target and `.recovered` phase.
  - Local network down targets the diagnosis entity.
  - `monitoringStalled` still does not alert.

### N5: AlertEngine Recovery/Cooldown Hardening

- Separate active-state tracking from delivered-notification tracking if the N2/N3 implementation confirms recovery should only follow delivered active alerts.
- Make recovery IDs explicit through `phase`, not `.recovered` string parsing.
- Tests:
  - Cooldown suppresses repeated active events.
  - Recovery emits once after a delivered active event.
  - Recovery does not spam across repeated normal ticks.
  - Suppressed active event recovery behavior is documented and tested.

### N6: Legacy Rule Cleanup

- Remove disabled legacy provider rules from runtime defaults.
- Ensure installed manifest rule compilation attaches targets.
- Tests:
  - Fresh engine has no starlink/vpn/ecoflow rules unless those integrations or manifests provide them.
  - Manifest threshold rules resolve to entities through provider metric target.

### N7: OS Eyeball and Permission Pass

- Launch the app with Ping and System enabled.
- Trigger a real ping down event and confirm notification delivery.
- Recover the host and confirm recovery notification only when enabled.
- Confirm cooldown suppresses repeated active notifications.
- Confirm System alerts, once configured through generic settings, deliver through the same path.
- Confirm alerting entities promote through the relevant slot's AttentionEngine.

## Test Plan Summary

Core tests:

- Alert target resolution across exact entity, provider metric, provider, and capability.
- AlertEngine cooldown and recovery state transitions.
- Generic policy migration from latency-shaped stored policies.
- Notification service behavior with fake notifier and permission states.
- Attention promotion using resolved entity IDs.

Menu-bar tests:

- StatusViewModel or coordinator injects the notifier and resolver.
- No live `UNUserNotificationCenter` in tests.
- Ping diagnosis no longer requires UI-layer special mapping.

Regression tests:

- Ping down still promotes the failing host and delivers the host-down notification.
- Ping recovery still delivers recovery when enabled.
- Monitoring stalled remains calm and non-alerting.
- System healthy state does not alert or show down.
- Disabled legacy integrations do not contribute runtime alert rules.

## Open Decisions for Implementation Review

1. Whether to rename `AlertPolicy` in place or add `EntityAlertPolicy` and typealias/migrate.
2. Whether recovery should require a previously delivered active notification or merely a previously active rule.
3. Whether `.provider` target should resolve to all provider descriptors or only the provider's primary descriptor by default.
4. Whether notification permission state should be surfaced in generic settings immediately or deferred until after delivery is functional.

Recommended defaults:

- Add `EntityAlertPolicy` and migrate old `AlertPolicy` decoding into it.
- Recovery follows delivered active notifications.
- `.provider` resolves primary descriptors first, all descriptors only if no primary exists.
- Defer permission-state UI beyond a simple status/test-notification row until delivery semantics are stable.

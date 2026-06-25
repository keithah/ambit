# P5: Generic Progressive-Disclosure Settings Renderer

Date: 2026-06-24

## Goal

P5 replaces the remaining bespoke settings UI with one generic renderer driven by integration instances, entity descriptors, entity states, descriptor defaults, and `PresentationConfig` overrides. Settings must follow the same thesis as P6 surfaces: integrations contribute data, descriptors, defaults, and generic config schemas, not SwiftUI screens.

The immediate deletion target is the ping-specific settings window and typed host editor that P3 intentionally left behind. Ping host management becomes a generic multi-instance integration config flow. System settings render through the same renderer without any system-specific branch.

## Current Inventory

Remaining bespoke settings code lives in `AmbitMenuBar`:

- `PingSettings.swift`
  - `SettingsTab`
  - `PingSettings`
  - `DisplayPane`
  - `HistoryPane`
  - `DiagnosticsPane`
  - `AdvancedPane`
  - `NotificationsPane`
  - `HostsPane`
  - `HostEditor`
  - `PingHostRow`
- `App.swift`
  - `SettingsWindowController` hardcodes `"Ping Settings"` and mounts `PingSettings`.
- `StatusViewModel.swift`
  - `pingHostRows`
  - settings-only ping host actions: add/update/delete/enable/primary/reset
  - ping-specific settings bindings such as diagnosis sensitivity and range where they are not represented generically yet.

Existing generic pieces to preserve and build on:

- `PresentationConfigStore`
- `PresentationConfig`
- `EntityPresentationOverride`
- `IntegrationPresentationOverride`
- `Slot`
- `SlotResolver`
- `SurfaceComposer`
- descriptor defaults on `EntityDescriptor`
- `IntegrationRegistry`

## Model

P5 has two generic inputs:

1. Existing entity presentation data: `EntityDescriptor`, `EntityState`, and `PresentationConfig`.
2. A new integration instance config schema for create/edit flows. This schema is generic and Core-owned; integrations may provide it, but not UI.

### Config Schema

```swift
public enum ConfigFieldKind: String, Codable, Sendable {
    case text
    case number
    case toggle
    case select
}

public struct IntegrationConfigField: Identifiable, Equatable, Sendable, Codable {
    public var id: String
    public var title: String
    public var kind: ConfigFieldKind
    public var options: [EntityOption]?
    public var range: ValueRange?
    public var defaultValue: JSONValue?
    public var required: Bool
}

public struct IntegrationConfigSchema: Equatable, Sendable, Codable {
    public var fields: [IntegrationConfigField]
}

public struct IntegrationInstanceDraft: Equatable, Sendable {
    public var integrationID: IntegrationID
    public var replacing: IntegrationInstanceID?
    public var values: [String: JSONValue]
}
```

`ConfigFieldKind` is separate from `EntityKind`. Entity kinds describe runtime entities; config field kinds describe editor controls for an integration instance draft.

Ping's schema includes:

- display name: text
- address: text
- method: select
- port: number
- interval: number
- timeout: number
- degraded threshold: number
- down-after-failures: number
- alert preset: select
- diagnosis sensitivity: select with options `conservative`, `standard`, `aggressive`

Diagnosis sensitivity is a normal ping config field. There is no bespoke notifications pane.

### Settings View Model

Core exposes a pure settings model builder:

```swift
public struct PresentationSettingsModel: Equatable, Sendable {
    public var integrations: [IntegrationSettingsGroup]
    public var slots: [Slot]
}

public struct IntegrationSettingsGroup: Identifiable, Equatable, Sendable {
    public var id: IntegrationInstanceID
    public var integrationID: IntegrationID
    public var displayName: String
    public var enabled: Bool
    public var entities: [EntitySettingsRow]
    public var configSchema: IntegrationConfigSchema?
}

public struct EntitySettingsRow: Identifiable, Equatable, Sendable {
    public var descriptor: EntityDescriptor
    public var state: EntityState?
    public var override: EntityPresentationOverride
    public var effectiveVisibility: GlanceVisibility
}

public extension PresentationSettingsModel {
    static func build(
        integrations: [IntegrationInstanceRecord],
        descriptors: [ProviderInstanceID: [EntityDescriptor]],
        states: [EntityID: EntityState],
        overrides: PresentationConfig,
        schemas: [IntegrationID: IntegrationConfigSchema]
    ) -> PresentationSettingsModel
}
```

The builder is UI-free, timer-free, and observer-free. It does not filter config or hidden entities: settings must show everything a user can configure, including entities that detail surfaces exclude.

## Renderer Design

The window becomes `AmbitSettings`, not `PingSettings`.

Progressive disclosure:

1. Integrations
   - list configured integration instances
   - enable/disable instance
   - show generic summary from current entity states
   - add/edit/delete where an integration has a config schema
2. Display
   - per entity show/hide/detail-only via `enabled`
   - glance visibility via `GlanceVisibility`
   - pin via `pinned`
   - descriptor defaults shown as inherited values
3. Power drill-in
   - display threshold
   - graph style
   - graph range
   - alert policy
   - interval when represented by config schema or descriptor override

No new per-provider settings screens are allowed. A provider-specific need either maps to an existing generic field/control or becomes a new generic primitive.

## Phasing

### P5.1: Core settings model

Add `IntegrationConfigSchema` and `PresentationSettingsModel` in `AmbitCore/Presentation`.

Tests:

- build groups ping + system into correct `IntegrationSettingsGroup`s
- `EntitySettingsRow.effectiveVisibility == override.visibility ?? descriptor.defaultVisibility`
- hidden/config-excluded entities still appear in settings rows
- disabled integration instance is reflected in `group.enabled`
- system and ping are both present with correct entity counts

### P5.2: Generic settings shell

Add `AmbitSettings` and point `SettingsWindowController` at it. The shell reads `PresentationSettingsModel` from `StatusViewModel`. Keep create/edit flows out of this step.

### P5.3: Show/hide/pin controls

Wire generic entity rows to `PresentationConfigStore`. SurfaceComposer and AttentionEngine should observe the saved overrides through existing config reads.

### P5.4: Power drill-in

Add generic controls for display thresholds, graph style/range, and alert policy. Only show controls meaningful for the descriptor.

### P5.5: Generic instance config schema

Add integration schema plumbing and implement ping's schema. Replace `HostEditor` with a generic config sheet that creates/updates `IntegrationInstanceRecord`s from `IntegrationInstanceDraft`.

### P5.6: Delete bespoke settings

Delete `PingSettings.swift`, remove ping-specific settings APIs/state from `StatusViewModel` where replaced, and rename the window to `Ambit Settings`.

### P5.7: Eyeball + hardening

Launch the app and verify:

- settings show ping + system
- ping host add/edit/delete works through the generic sheet
- enable/disable works generically
- entity hide/pin works
- threshold/range changes persist and affect surfaces

Then run `swift build` and `swift test`.

## Non-Goals

- No provider-specific SwiftUI settings panes.
- No free-form dashboards or arbitrary layout editing.
- No replacement of `IntegrationRegistry` or `PresentationConfigStore`.
- No migration of device integrations back on by default.
- No custom UI hook for provider settings.

## Acceptance Criteria

- The settings renderer can configure ping and system through the same generic model.
- `PingSettings` and `HostEditor` are deleted by the end of P5.
- `AmbitCore` remains UI-free.
- `swift build` and `swift test` pass after each implementation commit.

# Provider Polish And Surface Foundation Design

## Goal

Ambit should feel less like a manifest runtime prototype and more like a product surface for real integrations. This milestone polishes provider setup, improves generic provider runtime/UI behavior, and creates shared surface models that can later feed widgets, island-style glances, notifications, and a full app window.

This milestone does not build OS widget extensions, a Dynamic Island implementation, or a separate app window. It creates the reusable Core layer and improves the menubar surfaces that already exist.

## Approach

Use a Core-first model with menubar consumers:

- Core owns provider package validation, provider setup summaries, credential completeness, generic provider display models, alert summaries, command summaries, and compact surface models.
- AmbitMenuBar renders those models in Settings and the existing generic detail view.
- Future surfaces consume the same models instead of re-deriving status from `StatusSnapshot`.

This keeps the menubar from becoming the product architecture and avoids building platform-specific surfaces before the shared data contracts are solid.

## Provider Setup UX

Settings should show each installed manifest provider as an understandable setup item:

- Package identity: display name, provider id, package path, enabled state.
- Validation state: valid/invalid, with concise actionable error text.
- Credentials: declared credentials, required/optional status, saved/missing state, save action.
- Lifecycle actions: install folder, reinstall/update from folder, enable/disable, remove, refresh validation.

Credential values remain in `CredentialStore`; Settings only holds editable draft strings. Required credentials should be visibly incomplete until saved. Invalid manifests should remain manageable but should not load as active runtime providers.

## Generic Provider Runtime And UI Polish

Generic provider detail should become a good default surface for any manifest provider:

- Header uses layout hints when present: icon, accent, primary metric.
- Primary status summarizes health, loading, missing credentials, and most relevant metric.
- Alerts are visible as declared rules and recent triggered events where available.
- Commands show parameter count, confirmation requirement, execution state, and last result.
- Diagnostics remain concise and actionable.

The CLI should report the same metadata: credentials, layout hints, transforms, alert declarations, command parameter details, and validation failures.

## Surface Foundation

Add shared Core models for surface consumers:

- `ProviderSurfaceModel`: one provider’s compact state for any surface.
- `SurfaceSnapshot`: a sorted collection of provider surface models plus timestamp.
- `NotificationSurfaceModel`: event-focused data for notifications.

These models should use existing `ProviderDisplayModel`, `ProviderOverviewSummary`, `AlertEvent`, and `ProviderDiagnostic` rather than replacing them. The first consumers are tests and menubar helpers; OS-specific targets can come later.

The surface models should be intentionally compact:

- provider id and title
- health and tone
- primary metric/value
- short message
- icon/accent hints
- optional diagnostic
- actionable command count
- active alert count or recent alert event summary

## Data Flow

1. `Engine` loads built-in and installed providers.
2. `Engine` publishes `StatusSnapshot` and exposes provider names/layouts/commands/installed records/alert rules.
3. Core builders convert those inputs into setup summaries and surface models.
4. Settings renders setup summaries and writes credentials through `CredentialStore`.
5. MenuContent renders generic provider detail from `ProviderDisplayModel` and compact summaries from surface models.

## Error Handling

- Manifest validation errors should name the exact broken field when practical.
- Setup summaries should never throw to UI; they should carry invalid/missing states.
- Missing credentials should be represented separately from endpoint failures.
- Disabled providers should disappear from runtime surfaces but remain visible in setup.
- Invalid installed providers should remain visible in setup with their last validation error.

## Testing

Use TDD for each behavior:

- Core tests for setup summary construction, credential completeness, reinstall/update behavior, validation refresh, and disabled provider runtime cleanup.
- Core tests for surface model construction from mixed provider health, metrics, commands, alerts, and layout hints.
- CLI/report tests for richer manifest metadata.
- Build verification for SwiftUI Settings and generic detail changes.
- Full `swift test`, `swift build`, manifest validation, and app relaunch before completion.

## Non-Goals

- No OS widget extension target.
- No Dynamic Island target.
- No separate app-window target.
- No cloud sync or provider registry distribution.
- No JavaScript/WASM plugin runtime.
- No deep built-in integration hardening in this milestone; that remains the next focused track.

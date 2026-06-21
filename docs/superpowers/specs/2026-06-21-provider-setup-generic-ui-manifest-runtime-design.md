# Provider Setup, Generic UI, and Manifest Runtime Design

## Reader And Goal

Reader: a future Ambit implementer who understands Swift, SwiftUI, and the existing provider model, but does not have this conversation.

Post-read action: implement manifest provider setup UX, generic provider UI polish, and the next manifest runtime expansion without making the menubar the platform boundary.

## Design Principles

Ambit is an ambient platform, not a menubar-only app. The menubar is the first surface, but the same provider state must later feed widgets, notification rules, a Dynamic Island-style glance surface, and a full app window.

Provider installation, credential requirements, manifest validation, provider registration, snapshots, diagnostics, command metadata, and alert declarations belong in Core. UI targets render those shared models. A surface may decide how much detail to show, but it must not own the underlying setup state.

The first setup experience should support local manifest folders and durable installed providers. It should not introduce a package registry, cloud sync, sandboxed JavaScript, or a store. Those are later product decisions.

## Provider Setup UX

The setup UX uses the hybrid, Core-owned design:

- A provider manager in Settings or a future app window handles install, inspect, credential entry, enable/disable, and remove.
- The menubar surfaces runtime problems, especially missing credentials or invalid packages, and offers a direct path to the provider manager.
- The Engine loads saved manifest providers on startup, so installed providers survive app restarts.

The provider manager flow:

1. User chooses a local manifest package folder.
2. Core loads and validates the package.
3. UI shows manifest name, provider id, endpoint method and URL, metric count, command count, and credential requirements.
4. User enters required scoped credentials.
5. App saves the installed provider metadata outside the secret store.
6. App saves credential values through the scoped credential store.
7. Engine rebuilds providers and starts polling.

Installed provider metadata should include the package location, provider id, display name, enabled state, and last validation result. It must not contain secret values.

Credentials remain scoped by provider id and credential id. The same credential framework should work for manifest providers and future native providers.

## Generic Provider UI

Generic provider UI should feel like a first-class runtime surface, not a debug fallback. The shared display model should expose:

- Provider title and id.
- Health, loading state, and last error.
- Primary metrics and secondary metric groups.
- Diagnostics and next steps.
- Commands, including labels, parameter counts, and confirmation requirements.
- Missing credential state when a manifest requires credentials.

The menubar generic provider detail should use this model to render:

- A compact status hero with health, provider id, loading state, and error summary.
- Metric sections for network, power, state, and other values.
- Inline command affordances that jump to the command palette or run simple no-parameter commands where appropriate.
- Diagnostic cards for degraded/down providers.
- Empty states that explain whether the provider has no metrics yet, is waiting for credentials, or failed validation.

Future widgets and glance surfaces should consume the same display model, selecting only the small subset they can display. A widget might show one primary metric and health. Notifications might use diagnostics and alert declarations. A full app window can show complete package metadata and credential setup.

## Manifest Runtime Expansion

The manifest runtime remains declarative-first. The next expansion should add useful authoring power without introducing an untrusted code runtime.

Recommended schema additions:

- Value transforms: simple operations such as multiply, divide, round, clamp, invert bool, map text, and default value.
- Layout hints: primary metric id, metric section override, icon, accent, and preferred display title.
- Default alert declarations: thresholds, state transitions, and sustained conditions over manifest metrics.
- Credential placeholders: keep the existing `{credential.id}` style, with validation that referenced credentials are declared.

Transforms should be deterministic and limited to metric mapping. They should not execute arbitrary scripts or access the network. If a future integration needs logic beyond these transforms, that should trigger a separate sandbox design.

Layout hints are optional. If omitted, the generic provider UI should continue using derived sections and stable defaults.

Default alerts should compile into the existing alert engine model. A manifest package can suggest alerts, but the user should ultimately be able to enable, disable, or tune them.

## Data Flow

The intended flow is:

1. Installed provider store loads saved manifest package records.
2. Each enabled record is validated against its package on disk.
3. Valid records become `ManifestProvider` instances.
4. Engine merges built-in providers, active measurement providers, and installed manifest providers.
5. Engine publishes snapshots and command metadata.
6. Core derives provider display models from snapshots, diagnostics, commands, and manifest metadata.
7. Menubar, app window, widgets, island-style surfaces, and notifications render those display models.

The credential flow is separate:

1. Manifest declares credential ids and labels.
2. UI prompts for missing required credentials.
3. Credential store saves secret values under scoped keys.
4. Manifest runtime resolves placeholders at request time.
5. Missing required credentials produce a provider snapshot error that surfaces across all clients.

## Error Handling

Invalid package:

- Store the installed record, but mark it invalid.
- Do not register a provider for it.
- Show the validation error in the provider manager.

Missing required credential:

- Register the provider so it appears in surfaces.
- Polling returns a down snapshot with a missing credential error.
- Menubar and future surfaces show an actionable credential prompt.

Request or transform failure:

- Polling returns a down or degraded snapshot.
- Diagnostics should include a concise diagnosis and next step.
- Existing metrics may be omitted unless the runtime can safely map partial data.

Disabled provider:

- Keep installed metadata and credentials.
- Do not register the provider.
- Show it only in setup/manage surfaces, not the active menubar overview.

Removed provider:

- Remove installed metadata.
- Ask before deleting credentials. The first implementation may keep credentials unless the user explicitly clears them.

## Implementation Slices

1. Core installed provider store:
   - Persist local manifest package records.
   - Load, validate, enable/disable, and remove records.
   - Keep secrets out of the store.

2. Engine loading:
   - Add an injection point for installed manifest providers.
   - Merge installed providers with existing built-ins.
   - Preserve existing tests and behavior when no installed providers exist.

3. Credential setup support:
   - Provide missing credential summaries per manifest provider.
   - Save scoped credential values.
   - Surface missing credentials in snapshots and display models.

4. Provider manager UI:
   - Add local folder install.
   - Show manifest report, validation status, credentials, enabled state, and remove action.
   - Rebuild engine providers after changes.

5. Generic provider display model:
   - Move reusable display decisions into Core.
   - Update menubar generic detail to consume it.
   - Keep built-in provider detail views unchanged.

6. Manifest runtime expansion:
   - Add transform schema and tests.
   - Add layout hint schema and display model integration.
   - Add default alert declaration schema and compilation tests.

7. Examples and docs:
   - Add secure POST example manifest.
   - Add transform/layout/alert example manifest.
   - Document CLI credential flags and the provider manager flow.

## Testing

Core tests:

- Installed provider records persist and reload.
- Invalid packages are retained but not registered.
- Enabled providers load into Engine.
- Disabled providers do not load into Engine.
- Credentials are saved only through `CredentialStore`.
- Missing credentials produce stable snapshot errors.
- Transform mappings produce expected metric values.
- Manifest alert declarations compile to alert rules.

UI-adjacent tests:

- Display model summarizes healthy, degraded, down, missing-credential, and invalid-package states.
- Generic provider commands show labels, parameters, and confirmation requirements.
- Provider manager view model validates local package installs and saves credential updates.

Manual verification:

- Launch app with no installed providers: existing menubar behavior is unchanged.
- Install a local manifest provider and confirm it appears after restart.
- Install a provider with a required credential, observe missing credential prompt, save credential, and confirm polling uses it.
- Confirm CLI manifest validation and run paths still work.

## Non-Goals For This Pass

- Package registry or remote provider marketplace.
- Cloud sync of installed providers or credentials.
- Sandboxed JavaScript transforms.
- iOS, widget, or Dynamic Island implementation.
- Replacing built-in provider-specific views.
- Deep hardening of GL.iNet, Starlink, Speedify, EcoFlow, or VPN integrations.

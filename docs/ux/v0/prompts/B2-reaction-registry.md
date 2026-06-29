# Codex prompt — B2: Reaction registry

You are implementing phase **B2** of the Ambit engine-evolution plan. Read `docs/ux/v0/spec.md`
(Part B — "Reactions & commands", "Locked decisions (reactions)", "Engine phasing", and the B2
acceptance checklist) and `docs/ux/v0/schema.md` (§5 Reactions, §10 reconciliation) first.

**Prerequisite:** B1 (the `Condition` tree + evaluator) is merged. B2 generalizes the *then* side —
what happens when a condition fires — while keeping all existing notifications byte-identical.

## Gates carried over from the B1 review (must close in B2)

B1 landed the `Condition` tree but left it **dormant** — `AlertKindDeclaration.condition` is not yet
consumed by `MonitoringAlertStateMachine`. The moment B2 routes evaluation through `Condition`, these
three things must hold or alert behavior will silently drift:

1. **Make the parity test non-inert.** B1's `testMonitoringAlertOutputsRemainIdenticalWithCompiledConditionDeclarations`
   passes by construction because the engine ignores `.condition`. In B2, actually evaluate the compiled
   `Condition` in the production path for the kinds you touch, and prove byte-identical output against a
   golden produced by the *legacy* path — a test where flipping the engine to the Condition path is the only
   change. A test that still ignores `.condition` does not count.
2. **Resolve `metricThreshold` consecutive-sample semantics.** B1 maps `EntityAlertPolicy.consecutive` to
   `heldFor((n−1)·sampleInterval)`, which only equals the real consecutive-sample count under perfectly
   regular sampling, and is only tested at `consecutive: 1`. Before relying on it, either add a native
   `consecutiveSamples(n)` temporal op, or validate the held-for mapping against real (possibly irregular /
   gapped) sample timing — with tests at `consecutive > 1` and non-uniform timestamps — proving parity with
   today's count-based behavior.
3. **Converge on one dwell implementation.** B1 added a second dwell (`ConditionEvaluator.startedAt`) parallel
   to `MonitoringAlertStateMachine`/`SustainedAlertRule`. Use one, or prove equivalence under sleep/wake and
   irregular polling, so flap/dwell behavior does not diverge.

If any of these cannot be satisfied byte-identically, stop and report rather than changing behavior.

## Goal

Replace the current "the only reaction is an alert notification" model with a generic `Reaction`
registry: `Notify`, `MutateSurface`, `RunCommand`, `ApplyContext`. Existing built-in alerts must
compile to a `Notify` reaction that reproduces today's notifications exactly; the other reaction
kinds are additive and used only by new declarations.

## Background (confirm against HEAD — audit was a one-time read)

- Alert delivery today: `AlertEngine` emits `AlertEvent` with `phase: AlertEventPhase` (`.active` /
  `.recovered`) and `target: AlertTarget?`; `AlertTargetResolver` maps targets to entity IDs; the app
  delivers via `AlertNotificationService` and a `NotificationDelivering` / `MacNotificationDeliverer`.
- Commands already exist: `CommandDescriptor` + `CommandParameter` (`Provider.swift`), referenced from
  entities via `CommandRef`, executed by the provider's async `execute(commandID:arguments:context:)`.
- Surface presentation is produced by `SurfaceComposer` applying the existing presentation-override types.

## What to build

1. **`Reaction` enum** (`schema.md` §5):
   - `notify(NotifySpec)` — `NotifySpec` has `title`/`body` templates, `level` (maps to
     `UNNotificationInterruptionLevel`: passive/active/timeSensitive), `lifecycle`
     (`oneShot` | `boundToCondition`), and `actions: [CommandInvocation]`.
   - `mutateSurface(SurfaceMutation)` — set a settable surface property while the owning condition's
     `level` holds; revert on fall.
   - `runCommand(CommandInvocation)` — dispatch a declared command.
   - `applyContext(id:active:)` — **define the case now, stub the executor**; it is fully wired in B4
     when contexts exist.
   Make these `Codable`, `Equatable`, `Sendable`.

2. **Refactor alert delivery to emit `Reaction`s.** Built-in alert kinds compile to a single
   `notify` reaction:
   - A kind with recovery → `lifecycle: .boundToCondition` (post on the rising edge, clear on the
     falling edge — i.e. today's `.active` → post, `.recovered` → clear).
   - A kind without recovery → `lifecycle: .oneShot`.
   The rendered notification (title, body, level, grouping, target) must be **byte-identical** to today.

3. **Notification action buttons.** `NotifySpec.actions` render as `UNNotificationAction`s; activating
   one invokes its `CommandInvocation` through the provider's `execute(...)`. Enforce the command's
   `requiresConfirmation` / `ConfirmationPolicy` (consequential → confirm).

4. **`RunCommand` reaction** dispatches via the existing `execute(commandID:arguments:context:)`. Apply
   rate limiting and `ConfirmationPolicy` (per "Locked decisions (reactions)").

5. **`MutateSurface` reaction.** Introduce the minimal settable-property addressing needed to target a
   surface element (e.g. a menu-bar item's `icon` / `badge` / `color` / `visible`). The property is set
   while the condition holds and reverts on clear (the "persist until it stops raining" behavior). Full
   generic property addressing can expand later; scope B2 to what the rain example needs.

## Constraints (hard)

- **Existing notifications byte-identical.** New reaction kinds are additive; do not alter built-in
  alert output. Characterization/notification goldens must not change.
- **Do not edit** `~/src/pingscope` or `~/src/glinet-travel`.
- Ping-leak **grep-gate** stays green.
- No secrets / feed URLs / signing keys.
- `applyContext` executor is a stub in B2 (no contexts yet); the case must exist and be `Codable`.

## Tests (the acceptance gate)

- **Golden:** existing notifications byte-identical after the refactor (same corpus as today).
- **State-driven test for `boundToCondition`:** notification posts on the rising edge and is removed on
  the falling edge.
- **`MutateSurface` golden:** the targeted surface property is set while the condition holds and reverts
  on clear (assert on the resolved config / composed surface).
- **Action-button test:** activating a notification action invokes the right command via `execute(...)`,
  with confirmation enforced for consequential commands.
- **`RunCommand` test:** dispatch reaches `execute(...)` with correct arguments; rate limit + confirmation honored.

## Acceptance (B2 checklist — all must pass)

- [ ] `Reaction` enum (Notify{level, lifecycle, actions[]}, MutateSurface, RunCommand, ApplyContext) per §5.
- [ ] Alert delivery refactored to emit Reactions; existing notification output byte-identical (golden).
- [ ] RunCommand dispatches via the existing `execute(commandID:arguments:context:)`; `ConfirmationPolicy` enforced.
- [ ] Notification action buttons render and invoke their command.
- [ ] `boundToCondition`: posts on rising edge, clears on falling edge (state-driven test).
- [ ] MutateSurface applies and reverts a surface property while the condition holds (golden on resolved config).
- [ ] Goldens for existing notifications byte-identical; grep-gate green.

## Deliverables

A focused PR: the `Reaction` types, the alert-delivery refactor, action buttons, RunCommand + MutateSurface
executors (ApplyContext stub), and the tests above. PR description should state how `boundToCondition` maps
onto the old `.active`/`.recovered` phases and what settable-property surface targets were introduced.

## Workflow

Confirm the current `AlertEvent` / delivery signatures against HEAD before refactoring. Land the byte-identical
notification golden first, then add the new reaction kinds on top so regressions are caught immediately. If the
old phase model can't be mapped onto `oneShot`/`boundToCondition` without changing output, stop and report.

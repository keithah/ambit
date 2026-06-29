# Codex prompt — B3a: User-rule type + generic runner + versioned store + dwell convergence (no UI)

You are implementing phase **B3a** of the Ambit engine-evolution plan. Read `docs/ux/v0/spec.md`
(Part B — "Universal rule engine", "Persistence & migration", "Determinism & safety", "Locked
decisions", and the B3 acceptance checklist) and `docs/ux/v0/schema.md` (§4–§7, §10). Prereqs **B1**
(Condition tree + evaluator) and **B2** (Reaction registry, condition-backed alerts) are merged.

B3 is split into two PRs. **This is B3a: the engine and storage foundation, no UI.** B3b adds the
rule-builder UI on top. Built-in alert behavior must stay byte-identical; user rules are additive.

## Goal

Represent, persist, and run user-authored `Condition → [Reaction]` rules through the **same** engine
path as built-in alerts, and unify dwell/flap so built-in and user rules behave identically. Rules are
created programmatically in this phase (tests/fixtures); the visual builder is B3b.

## What to build

1. **`UserRule` declaration** — `id`, `displayName`, `condition: Condition`, `reactions: [Reaction]`,
   `enabled: Bool`, `source = .user`, `schemaVersion`. `Codable`, `Equatable`, `Sendable`. Reuse the
   B1/B2 `Condition` and `Reaction` types; do not fork them.

2. **A generic rule runner** — evaluates `[UserRule]` against current entity states/samples via the B1
   `ConditionEvaluator` and dispatches matched rules' reactions through the B2 reaction executor. Same
   path the built-ins use (see the dwell gate).

3. **Versioned, migratable store** — persist user rules (reuse the `UserDefaults`-backed pattern of
   `PresentationConfigStore`, or a dedicated file if volume warrants). Each persisted blob carries
   `schemaVersion`; an `IntegrationConfigMigrator`-style migrator applies per-version upgrade steps
   (this replaces today's silent field-drop). Corrupt/missing store → empty, never crash. Expose a
   simple API for create / update / delete / reorder (consumed by B3b).

## Gate carried over from the B2 review (the core of B3a)

**Converge on a single dwell/flap implementation.** B1 added `ConditionEvaluator`'s own dwell
(`heldFor` via `startedAt`, plus `consecutiveSamples`); built-in alerts flap/cooldown via
`MonitoringAlertStateMachine`. B2 kept `heldFor` off the production path, but user rules will use it, so
the two must not diverge. Establish one shared firing mechanism (condition eval + edge +
dwell/cooldown/flap) used by both built-in and user rules — or prove equivalence with tests under
**irregular polling and sleep/wake** (gaps, backoff, clock jumps). If unifying would change any built-in
output, unify the user-rule path onto the state machine's dwell/cooldown instead, and add the
equivalence tests. Do not leave two behaviors.

## Constraints (hard)

- **Built-in alert behavior byte-identical.** Existing characterization/notification goldens unchanged.
- Ping-leak **grep-gate** green — the runner is generic, no integration identifiers.
- Reuse existing types (`Condition`, `Reaction`, `ConditionEvaluator`, B2 executor,
  `PresentationConfigStore` pattern, `IntegrationConfigMigrator`); do not duplicate.
- No UI in this phase. `RunShortcut`/`RunAppIntent` out of scope (B6); `ApplyContext` stays a stub (B4).
- Do NOT edit `~/src/pingscope` or `~/src/glinet-travel`. No secrets / feed URLs / signing keys.
- Confirm current signatures against HEAD before building.

## Tests (the acceptance gate)

- **Shared-path test:** a user rule and an equivalent built-in declaration produce the same reaction
  outcome from identical inputs.
- **Persistence round-trip golden:** `UserRule` Codable fixtures per `schemaVersion`.
- **Migrator test:** a v(n−1) fixture upgrades to v(n) losslessly.
- **Store lifecycle test:** create / update / delete / reorder via the store API survive a simulated
  relaunch; corrupt store → empty, no crash.
- **Dwell-equivalence test (the gate):** a built-in `heldFor`/consecutive rule and a user `heldFor` rule
  flap/cooldown identically under irregular sample timing and a sleep/wake gap.
- **Byte-identical goldens:** existing built-in alert/notification output unchanged; grep-gate green.

## Acceptance (B3a — all must pass)

- [ ] `UserRule` type (Codable/Equatable/Sendable) reusing B1/B2 `Condition` + `Reaction`.
- [ ] Generic rule runner evaluates user rules through the same path as built-ins (shared-path test).
- [ ] Versioned store + migrator; round-trip golden fixtures; v(n−1)→v(n) lossless; corrupt → empty.
- [ ] Store API for create/update/delete/reorder, relaunch-safe.
- [ ] Single dwell/flap shared by built-in + user rules, with equivalence tests under irregular polling
      and sleep/wake; built-in goldens byte-identical; grep-gate green.
- [ ] No UI.

## Deliverables

A focused PR: `UserRule`, the runner, the versioned store + migrator, the dwell unification, and the
tests above. The PR description must state how dwell/flap was unified (shared mechanism vs.
proven-equivalent) and link the equivalence tests.

## Workflow

Write the shared-path and dwell-equivalence tests first — they are the riskiest part and gate everything
else. If unifying dwell changes any built-in output, stop and report before proceeding.

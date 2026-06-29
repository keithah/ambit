# Codex prompt — B3: User-authored rules + versioned store

You are implementing phase **B3** of the Ambit engine-evolution plan. Read `docs/ux/v0/spec.md`
(Part B — "Universal rule engine", "Persistence & migration", "Locked decisions", and the B3
acceptance checklist), `docs/ux/v0/schema.md` (§4–§7, §10), and the `picker` + Notifications screens
in `docs/ux/v0/mocks.html`. Prereqs **B1** (Condition tree + evaluator) and **B2** (Reaction registry,
condition-backed alerts) are merged.

This phase adds the first user-facing authoring: users create their own `Condition → [Reaction]` rules,
those rules persist (versioned + migratable), and they run through the **same** evaluation path as
built-in alerts. Built-in behavior stays byte-identical; user rules are additive.

## Goal

A user can author a rule ("When CPU load ≥ 90% for 5 min → Notify"), it is saved, survives relaunch,
and fires through the shared engine exactly as a provider-declared rule would.

## What to build

1. **`UserRule` declaration** — `id`, `displayName`, `condition: Condition`, `reactions: [Reaction]`,
   `enabled: Bool`, `source = .user`, and a `schemaVersion`. `Codable`, `Equatable`, `Sendable`.
   (Reuse the B1/B2 `Condition` and `Reaction` types; do not fork them.)

2. **A generic rule runner** — evaluates `[UserRule]` against current entity states/samples using the
   B1 `ConditionEvaluator` and dispatches matched rules' reactions through the B2 reaction executor.
   This is the same path built-ins use; see the dwell gate below for the unification requirement.

3. **Versioned, migratable store** — persist user rules (reuse the `UserDefaults`-backed pattern of
   `PresentationConfigStore`, or a dedicated file if volume warrants). Unlike today's silent
   forward-compatible-only decode, add explicit versioning: each persisted blob carries `schemaVersion`,
   and an `IntegrationConfigMigrator`-style migrator applies per-version upgrade steps. Corrupt/missing
   store → empty, never crash.

4. **Rule builder UI** — the condition picker + reaction palette from the `picker` mock; writes valid
   `UserRule` declarations. Per the locked decision, a rule lives under **Notifications** while its only
   reaction is Notify, and also appears under **Automations** once it uses RunCommand / MutateSurface /
   ApplyContext — one stored declaration, two views.

## Gate carried over from the B2 review (must close here)

**Converge on a single dwell/flap implementation.** B1 added `ConditionEvaluator`'s own dwell
(`heldFor` via `startedAt`, plus `consecutiveSamples`); built-in alerts still flap/cooldown via
`MonitoringAlertStateMachine`. B2 kept `heldFor` off the production path, but B3's user rules *will* use
`heldFor`, so the two must not diverge. Establish one shared firing mechanism (condition eval + edge +
dwell/cooldown/flap) used by both built-in and user rules — or prove equivalence with tests under
**irregular polling and sleep/wake** (gaps, backoff, clock jumps). If you cannot unify without changing
built-in output, unify the user-rule path onto the state machine's dwell/cooldown and add the
equivalence tests; do not leave two behaviors.

## Constraints (hard)

- **Built-in alert behavior byte-identical.** User rules are additive; existing characterization/
  notification goldens must not change.
- Ping-leak **grep-gate** stays green — the rule runner is generic, no integration identifiers.
- Reuse existing types (`Condition`, `Reaction`, `ConditionEvaluator`, the B2 executor,
  `PresentationConfigStore` pattern, `IntegrationConfigMigrator`); do not duplicate.
- `RunShortcut` / `RunAppIntent` are out of scope (B6); `ApplyContext` remains a stub until B4.
- Do NOT edit `~/src/pingscope` or `~/src/glinet-travel`. No secrets / feed URLs / signing keys.
- Confirm current signatures against HEAD before building.

## Tests (the acceptance gate)

- **Shared-path test:** a user rule and an equivalent built-in declaration produce the same reaction
  outcome from the same inputs (proves one engine path).
- **Persistence round-trip golden:** `UserRule` Codable fixtures per `schemaVersion`.
- **Migrator test:** a v(n−1) fixture upgrades to v(n) losslessly.
- **Lifecycle test:** create / edit / delete / reorder survive a simulated relaunch; corrupt store → empty, no crash.
- **Dwell-equivalence test (the gate):** a built-in `heldFor`/consecutive rule and a user `heldFor` rule
  flap/cooldown identically under irregular sample timing and a sleep/wake gap.
- **Byte-identical goldens:** existing built-in alert/notification output unchanged; grep-gate green.

## Acceptance (B3 checklist — all must pass)

- [ ] Versioned user-rule store (`schemaVersion`) + migrator; `Codable` round-trip golden fixtures.
- [ ] Rule builder UI (condition picker + reaction palette) writes valid declarations.
- [ ] User rules evaluate through the same engine path as built-ins (shared-path test).
- [ ] Create / edit / delete / reorder survive relaunch; corrupt store → empty, no crash.
- [ ] A v(n−1) fixture migrates to v(n) losslessly.
- [ ] Custom rules appear under Notifications; non-Notify ones also under Automations.
- [ ] (Gate) Single dwell/flap implementation shared by built-in + user rules, with equivalence tests
      under irregular polling and sleep/wake; built-in goldens byte-identical; grep-gate green.

## Deliverables

A PR (or a small stack: engine runner + store, then UI) containing the `UserRule` type, the generic
rule runner, the versioned store + migrator, the builder UI, and the tests above. The PR description must
state how the dwell/flap unification was done (shared mechanism vs. proven-equivalent) and link the
equivalence tests.

## Workflow

This phase is larger than B1/B2 (engine runner + persistence + UI) — consider landing the engine runner
+ store + dwell unification first (with tests), then the builder UI on top. Write the shared-path and
dwell-equivalence tests early; they are the riskiest part. If unifying dwell would change any built-in
output, stop and report before proceeding.

# Codex prompt — B1: Condition tree + evaluator (byte-identical generalization)

You are implementing phase **B1** of the Ambit engine-evolution plan. Read
`docs/ux/v0/spec.md` (Part B, the "Engine phasing" and "Per-phase acceptance checklists" sections)
and `docs/ux/v0/schema.md` (§4 Conditions, §10 reconciliation) before starting. This phase is a
pure-engine generalization with **no UI and no persisted-format change**, and it must be provably
**byte-identical** to today's behavior.

## Goal

Introduce a generic `Condition` expression tree and an evaluator, then express the existing fixed
alert triggers in terms of it — without changing any observable alert behavior. This lays the
foundation for user-authored rules (B3) and contexts (B4) while keeping the current alert outcomes
exactly the same.

## Background (confirm against HEAD — the audit below was a one-time read)

Today, alert triggers are a closed enum:

```swift
// Sources/AmbitCore/Monitoring/MonitoringVocabulary.swift
public enum AlertTriggerDeclaration {
    case healthTransition(to: HealthStatus)
    case diagnosisVerdict(MonitoringVerdict.Kind)
    case connectivityTransition(to: NetworkConnectivityStatus)
    case allMembersFailing(minimumCount: Int, ratio: Double)
    case metricThreshold(EntityAlertPolicy)
}
```

Supporting types that already exist and MUST be reused (do not duplicate):
`AlertComparison` (`eq/neq/lt/lte/gt/gte`), `AlertThreshold`, `EntityAlertPolicy` (`Sources/AmbitCore/Alerting/AlertPolicy.swift`),
the dwell/cooldown/recovery logic in `MonitoringAlertStateMachine` and `SustainedAlertRule.duration`
(`Sources/AmbitCore/AlertEngine.swift`), entity addressing via `EntityID` (`Identity.swift`).

## What to build

1. **`Condition` types** (`schema.md` §4): `Condition` (`comparison` / `all([Condition])` /
   `any([Condition])` / `not(Condition)` / `temporal(Temporal)`), `Comparison`, `Operand`
   (`.address(EntityID-or-field)` / `.literal(Value)`), `CompareOp`, `Temporal`
   (`heldFor` / `withinWindow` / `rateOfChange`) and `Edge` (`level` / `rising` / `falling`).
   Make them `Codable`, `Equatable`, `Sendable`. Reuse `AlertComparison` for `CompareOp` if it
   already covers the operators rather than adding a parallel enum.

2. **A `ConditionEvaluator`** that evaluates a `Condition` against the current entity state (and
   history where a `temporal` node needs it). `heldFor` must reuse the existing dwell semantics, and
   numeric comparison + consecutive-sample logic must match `EntityAlertPolicy` exactly.

3. **`compile()` from `AlertTriggerDeclaration` → `Condition`.** Recommended approach to stay
   byte-identical with minimal risk:
   - Decompose `.metricThreshold(EntityAlertPolicy)` into a real `comparison` (address + op + literal)
     wrapped in `temporal(.heldFor)` when the policy is sustained — this exercises the new algebra.
   - For the other four cases (`healthTransition`, `diagnosisVerdict`, `connectivityTransition`,
     `allMembersFailing`), wrap them in a faithful **predicate leaf** that delegates to the existing
     evaluation path, rather than re-deriving diagnosis/aggregate logic now. Decomposing those into
     pure comparisons is explicitly out of scope for B1.
   - The legacy enum stays the source of truth at call sites; `Condition` is produced via `compile()`
     and used only internally behind this shim in B1.

4. **Wire the evaluator behind the shim** so the alert engine can run on compiled `Condition`s while
   producing identical results (feature-flag or direct swap — your call, as long as the differential
   test passes).

## Constraints (hard)

- **Byte-identical behavior.** No change to emitted alerts, notifications, goldens, or persisted config.
- **Do not edit** `~/src/pingscope` or `~/src/glinet-travel` (read-only donor repos).
- The **ping-leak grep-gate** (`GenericMonitoringPingLeakGrepGateTests`) must stay green — no
  integration-specific identifiers in generic engine code.
- No new secrets, feed URLs, or signing keys.
- No UI changes. No new persisted format (do not serialize `Condition` to disk in B1).

## Tests (write these; they are the acceptance gate)

- **Differential test:** build a representative corpus of entity-state sequences; assert that evaluating
  each existing `AlertTriggerDeclaration` the legacy way produces the same alert outcomes as evaluating its
  compiled `Condition`. This is the core proof of byte-identical behavior.
- **Table-driven unit tests** for every operator (`eq/neq/lt/lte/gt/gte`, `all/any/not`) and every `Edge`
  mode (`level/rising/falling`) plus `heldFor` dwell.
- Existing characterization goldens unchanged; grep-gate green.

## Acceptance (B1 checklist — all must pass)

- [ ] `Condition`, `Operand`, `Value`, `Comparison`, `Temporal`, `Edge` added per `schema.md` §4; `Codable`.
- [ ] Evaluator computes truth over current `EntityState` (+ history for temporal); `heldFor` reuses existing dwell.
- [ ] Each `AlertTriggerDeclaration` case has a `compile()` to an equivalent `Condition`.
- [ ] Differential test passes: legacy eval == compiled-`Condition` eval, byte-identical alert outcomes.
- [ ] Table-driven unit tests for every operator and edge mode.
- [ ] No UI, no persisted-format change; characterization goldens + grep-gate green.

## Deliverables

A focused PR: the new `Condition` types + evaluator + `compile()`, the differential and unit tests, and a
short note in the PR description listing which trigger cases were decomposed vs. kept behind the predicate
leaf (and why). Keep the diff small and the legacy enum intact.

## Workflow

Explore the current code first to confirm the exact signatures above (they were read once during design and
may have drifted). Write the differential test early so "byte-identical" is enforced as you go. If a trigger
case cannot be made byte-identical via the predicate-leaf shim, stop and report rather than changing behavior.

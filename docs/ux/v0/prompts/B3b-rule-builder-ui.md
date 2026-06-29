# Codex prompt — B3b: Rule builder UI

You are implementing phase **B3b** of the Ambit engine-evolution plan. Read `docs/ux/v0/spec.md`
(Part B — "Locked decisions" re: one-store-two-views, and the B3 acceptance checklist),
`docs/ux/v0/schema.md` (§4–§7), and the **`picker`** and **Notifications** screens in
`docs/ux/v0/mocks.html`. Prereq **B3a** (the `UserRule` type, generic runner, and versioned store) is
merged. This phase is **UI only** — it authors declarations into the B3a store; it adds no new engine
behavior.

## Goal

A user can visually build, edit, reorder, and delete `Condition → [Reaction]` rules, and what they save
runs through the B3a runner exactly as a programmatically-created rule would.

## What to build

1. **Condition builder** — the `picker` mock made real: a registry-driven signal picker (every entity
   readout, generated from what's registered), comparison + value, and the temporal options
   (`heldFor` / `consecutiveSamples` / `withinWindow`), composed into the B1 `Condition` tree. Include
   the advanced **expression** view as a read-back of the same tree (editable raw form can be minimal).

2. **Reaction palette** — Notify (with level + lifecycle + optional action buttons from declared
   commands), MutateSurface, RunCommand. Greyed/disabled with a clear "coming later" affordance:
   `ApplyContext` (B4), `RunShortcut`/`RunAppIntent` (B6).

3. **Placement (locked decision):** a saved rule appears under **Notifications** while its only reaction
   is Notify, and *also* under **Automations** once it uses a non-Notify reaction — one stored
   declaration, two views. Create / edit / delete / reorder operate on the B3a store API.

4. **Validation** — the builder only ever writes declarations that decode and run; surface invalid
   states inline (e.g. missing threshold). Never persist a malformed `UserRule`.

## Constraints (hard)

- **Additive UI only.** No engine changes; built-in alert behavior and existing goldens unchanged.
- Use the B3a store + runner as the single source of truth; do not introduce a parallel rule path.
- Reuse existing settings UI patterns/components; match the rename/language map in `spec.md`
  (plain copy, no template tokens shown to users, no raw entity IDs).
- Ping-leak **grep-gate** green.
- Do NOT edit `~/src/pingscope` or `~/src/glinet-travel`. No secrets / feed URLs / signing keys.
- Confirm B3a's store API against HEAD before building.

## Tests (the acceptance gate)

- **Authoring round-trip:** building a rule in the UI produces a `UserRule` that persists, reloads, and
  fires through the B3a runner (integration test from UI model → store → runner).
- **Placement test:** a Notify-only rule shows under Notifications; adding a RunCommand reaction makes it
  also appear under Automations — same underlying declaration.
- **Lifecycle via UI:** create / edit / delete / reorder reflect in the store and survive relaunch.
- **Validation test:** the builder cannot save a malformed rule.
- Existing snapshot/UI tests updated; built-in goldens byte-identical; grep-gate green.

## Acceptance (B3b — all must pass)

- [ ] Condition builder (signal picker + comparison + temporal) writes a valid B1 `Condition`.
- [ ] Reaction palette (Notify / MutateSurface / RunCommand); ApplyContext + Shortcut/AppIntent greyed with rationale.
- [ ] Authoring round-trip: UI → store → runner fires the rule.
- [ ] Notifications/Automations two-views off one stored declaration (placement test).
- [ ] Create / edit / delete / reorder via UI persist and survive relaunch.
- [ ] Builder cannot persist a malformed rule.
- [ ] Built-in goldens byte-identical; grep-gate green.

## Deliverables

A focused UI PR built on B3a: the condition builder, reaction palette, Notifications/Automations
placement, and the tests above. PR description should include before/after screenshots of the builder
and the two placement views.

## Workflow

Confirm B3a's store + runner API first. Land the authoring round-trip test early so "UI writes something
the engine actually runs" is enforced throughout. Keep the expression view a faithful read-back of the
`Condition` tree, not a second source of truth.

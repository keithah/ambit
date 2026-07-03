# Ambit — universal engine declaration schema (v0 sketch)

Status: **implemented** (B1–B6, merged 2026-06-29) — kept as the design-history artifact behind the build.
The shipped types live in `Sources/AmbitCore/Monitoring/` (`Condition`, `Reaction`, `UserRule`, `Context`);
where names differ, the code is ground truth. Originally: design sketch to pin down the engine contract
before implementation. Swift-flavored pseudo-types,
in the style of the existing `AlertKindDeclaration` / `EntityDescriptor`. Names are provisional. This is the
"hand it to the implementer" artifact behind `spec.md` (Universal rule engine + Reactions & commands).

Guiding rule: the engine knows only entities, fields, conditions, reactions, and properties — all reached by
a uniform address. Everything else is a serializable declaration the engine interprets. No integration-specific
branches anywhere (the existing grep-gate stays green by construction).

## 1. Addressing

Every signal (a readout) and every control (a command or settable property) is reachable by a stable address.
Triggers reference readouts by address; reactions reference commands/properties by address.

```swift
/// "ping@1.1.1.1:443/latency_ms", "system/cpu.load", "surface:menubar/item.weather#icon",
/// "context:home#active", "weather@home/condition"
struct Address: Hashable, Codable {
    var entity: EntityID     // owner: a monitor instance, a surface element, a context, an app object
    var field: String        // readout key, property key, or command id
    // rendered form: "\(entity)/\(field)"  (surfaces use "#" for a settable property)
}

enum Operand: Codable {
    case address(Address)    // resolved against current state at evaluation time
    case literal(Value)
}

enum Value: Codable, Equatable {       // the one value type the engine moves around
    case number(Double, unit: Unit?)
    case string(String)
    case bool(Bool)
    case duration(TimeInterval)
    case timestamp(Date)
    case enumeration(String)           // a case from a declared enum
    case missing                       // unavailable-without-failure (idle, no reading yet)
}
```

## 2. Entities: readouts (read) + commands (write)

An entity gains a `commands` array alongside its readouts. Readouts may be flagged `settable`, which makes
them controls too (a `SettableProperty`). `monitoring` is the existing nested metadata, untouched.

```swift
struct EntityDescriptor: Codable {
    var id: EntityID
    var kind: String                     // provider-defined, opaque to engine: "ping.host", "system", "weather"
    var displayName: String
    var readouts: [ReadoutDeclaration]   // the signals (trigger sources)
    var commands: [CommandDeclaration]   // the controls (reaction targets)
    var monitoring: MonitoringMetadata?  // existing
}

struct ReadoutDeclaration: Codable {
    var key: String                      // field in Address
    var label: String                    // friendly, sentence-case
    var type: ValueType
    var settable: Bool                   // also a control? (e.g. a usage toggle, a threshold)
    var usages: [Usage]                  // surfaces this readout may participate in (the capability gate)
}

enum ValueType: Codable {
    case number(unit: Unit?)
    case string
    case bool
    case duration
    case timestamp
    case enumeration([String])           // closed set of cases, e.g. weather condition
}

enum Usage: String, Codable { case menuBar, popover, alerts, controlCenter, dynamicIsland, liveActivity }
```

## 3. Commands (actuation)

The new building block. A provider declares what it can *do*; the executor lives in the provider and is opaque
to the engine. The UI renders these as buttons (rule reactions and notification action buttons share the registry).

```swift
struct CommandDeclaration: Codable {
    var id: CommandID                    // field in an Address: "tesla@vin/closeWindows"
    var label: String                    // "Close windows"
    var icon: String?
    var parameters: [ParameterDeclaration]
    var confirmation: ConfirmationPolicy
    var consequential: Bool              // hint for default confirmation + App Intents
}

struct ParameterDeclaration: Codable {
    var key: String
    var label: String
    var type: ValueType
    var required: Bool
    var defaultValue: Value?
}

enum ConfirmationPolicy: String, Codable { case none, whenConsequential, always }
```

## 4. Conditions (an open expression tree)

A condition is a tree of arbitrary depth, not a fixed set of slots. Comparisons reference any address; boolean
nodes compose; a temporal node wraps a sub-condition with timing + edge semantics (this is where dwell /
hysteresis / flap-suppression live, reusing the existing alert state machine).

```swift
indirect enum Condition: Codable {
    case comparison(Comparison)
    case all([Condition])                // AND
    case any([Condition])                // OR
    case not(Condition)
    case temporal(Temporal)
}

struct Comparison: Codable {
    var lhs: Operand
    var op: CompareOp
    var rhs: Operand
}

enum CompareOp: String, Codable {
    case eq, neq, lt, lte, gt, gte
    case isIn            // value in a set/range
    case contains
    case changed         // any change since last sample
    case transitionedTo  // entered a specific value (edge into state)
}

struct Temporal: Codable {
    var condition: Condition
    var op: TemporalOp
    var edge: Edge                        // how the wrapped truth maps to firing
}

enum TemporalOp: Codable {
    case heldFor(TimeInterval)                       // dwell / hysteresis
    case withinWindow(TimeInterval)                  // true at some point in the last N
    case rateOfChange(per: TimeInterval, CompareOp, Value)
}

enum Edge: String, Codable {
    case level      // true while the condition holds (drives state-bound reactions)
    case rising     // on the transition into true
    case falling    // on the transition into false
}
```

## 5. Reactions (an open list from a registry)

The "then." New reaction kinds register without engine changes. `mutateSurface` and a context's overlay are the
same conditional-presentation primitive, keyed to different state.

```swift
enum Reaction: Codable {
    case notify(NotifySpec)
    case mutateSurface(SurfaceMutation)   // applied while the owning condition's level holds
    case runCommand(CommandInvocation)
    case applyContext(id: ContextID, active: Bool)
}

struct NotifySpec: Codable {
    var title: TemplateString             // tokens: {entity.displayName}, {field}, {value} ...
    var body: TemplateString?
    var level: InterruptionLevel          // .passive, .active, .timeSensitive
    var lifecycle: NotifyLifecycle
    var actions: [CommandInvocation]      // -> notification action buttons
}

enum NotifyLifecycle: String, Codable {
    case oneShot                          // post on the rising edge
    case boundToCondition                 // post on rise, update while level, auto-clear on fall ("persist")
}

struct SurfaceMutation: Codable {
    var target: Address                   // a settable surface property: "surface:menubar/item.weather#icon"
    var set: [String: Value]              // icon / color / badge / visible ...
}

struct CommandInvocation: Codable {
    var command: CommandRef               // .declared(Address) | .shortcut(name) | .appIntent(id) | .shell(String)
    var arguments: [String: Value]
}
```

## 6. Rules, contexts, overlays

A rule binds a condition to reactions. A context is the meta-rule: a stateful boolean entity (`context:home#active`)
whose reaction is "apply this overlay while active," carrying a priority for stacking.

```swift
struct RuleDeclaration: Codable {
    var id: RuleID
    var source: AuthorKind                // .builtIn(provider:) | .user
    var displayName: String
    var condition: Condition
    var reactions: [Reaction]
    var enabled: Bool
}

struct ContextDeclaration: Codable {
    var id: ContextID
    var displayName: String
    var icon: String?
    var condition: Condition              // when active (wrap in .temporal(.heldFor) for dwell)
    var priority: Int                     // higher wins on conflict
    var overlay: Overlay
    var manualOverride: ManualOverride?   // .pinnedActive | .pinnedInactive | nil (detection)
}

struct Overlay: Codable {
    var propertySets: [SurfaceMutation]   // visibility / presentation deltas, addressed
    var usageDeltas: [UsageDelta]         // enable/disable a readout's usage on a surface
    var ruleToggles: [RuleID: Bool]       // mute/enable other rules while active
}
```

## 7. Resolution (a pure function)

Presentation/enablement is resolved deterministically from the base config plus the active overlays, ordered by
priority. Pure and total → golden-testable like the rest of the composer.

```swift
/// Active contexts sorted by priority ascending; each overlay folds over the base; last write wins per address;
/// the base always sits underneath. Returns the config the SurfaceComposer renders from.
func resolve(base: Configuration, active: [ContextDeclaration]) -> Configuration
```

Determinism + safety requirements the engine must enforce (see spec §"Universal rule engine", invariant 6):

- Deterministic ordering of evaluation and of overlay application (priority, then stable declaration order).
- Write-conflict resolution when two overlays/reactions set the same `Address` (priority + last-wins, recorded
  for the inspector).
- Cycle detection: a rule that applies a context that toggles a rule that ... → break and report, never loop.
- Uniform dwell / flap-suppression on every condition (reuse the alert state machine).
- Rate limiting + `ConfirmationPolicy` gating on every `runCommand`.
- A "why" trace per resolved address: base → overlay(home) → reaction(rain rule) = final (feeds the inspector).

## 8. Worked example — "When it rains"

```text
Rule "when-it-rains":
  condition: temporal(
    comparison( lhs: address(weather@home/condition), op: transitionedTo, rhs: literal(.enumeration("rain")) ),
    op: heldFor(60s), edge: level )
  reactions:
    - mutateSurface(target: surface:menubar/item.weather#icon, set: { icon: "cloud-rain" })   // while raining
    - notify(
        title: "Rain at {entity.displayName}", level: .timeSensitive, lifecycle: .boundToCondition,
        actions: [ runCommand(.declared(tesla@vin/closeWindows)),
                   runCommand(.declared(skylight@id/close)) ] )
```

`boundToCondition` + `edge: level` means the icon reverts and the notification clears when it stops raining —
state, not a one-shot. The action buttons come straight from the providers' `CommandDeclaration`s.

## 9. What ships in v1 vs stays contract-only

v1 implements a curated subset — common readouts, `eq/lt/gt/transitionedTo` + `heldFor`, `notify` + `mutateSurface`,
and a handful of provider commands — on top of this interpreter. Everything else (full temporal algebra, App Intents
exposure, `runShortcut`/`runAppIntent`, richer overlays) is reachable by adding declarations and UI affordances,
never by changing the engine. The pickers are generated from the registries, so un-designed signals/controls appear
automatically; an advanced expression editor exposes the raw `Condition` tree and address space.

## 10. Reconciliation with the codebase (grounding)

A read of AmbitCore shows much of this already exists. The schema should *promote and extend* existing
types, not introduce parallel ones. Adopt the existing names.

### What already exists (reuse, don't reinvent)

- **Addressing** — `EntityID` (`Identity.swift`) already addresses signals (`<ProviderInstanceID>.<key>`).
  Use it. What's missing is addressing for *settable surface properties* — add a small `PropertyAddress`
  for things like `surface:menubar/item.weather#icon`.
- **Entities** — `EntityDescriptor` (`Entity.swift`) already carries `access: EntityAccess` (read/write),
  `command: CommandRef?`, `capability`, `options`, `range`, `stateClass`, plus presentation defaults. Note:
  the model is **one entity per readout**, not an `EntityDescriptor` with a `readouts[]` array — so drop the
  `readouts[]`/`commands[]` arrays from §2; a "metric" is an entity, and a command is a `CommandRef`.
- **Commands** — `CommandDescriptor` + `CommandParameter` (`Provider.swift`) already are our
  `CommandDeclaration`/`ParameterDeclaration` (`id`, `label`, `parameters`, `requiresConfirmation`). Providers
  implement `execute(commandID:arguments:context:)`. Only additions needed: `icon`, a `consequential` hint.
  → **Rename in this doc: `CommandDeclaration` → `CommandDescriptor`, `ParameterDeclaration` → `CommandParameter`.**
- **Alert kinds** — `AlertKindDeclaration` (`MonitoringVocabulary.swift`) already has templates, severity,
  `defaultEnabled`, `target`, `trigger`, `recovery`, `cooldown`. It is the closest thing to `RuleDeclaration`.
  → **Promote `AlertKindDeclaration` toward the generic rule shape rather than adding a new `RuleDeclaration`.**
- **Comparisons + dwell** — `AlertComparison` (`eq/neq/lt/lte/gt/gte`), `AlertThreshold`, `EntityAlertPolicy`
  (`AlertPolicy.swift`) and `SustainedAlertRule.duration` already give threshold comparison + held-for dwell.
  The `MonitoringAlertStateMachine` already does dwell + cooldown + recovery edges. Reuse all of it.
- **Overlays** — `EntityPresentationOverride`, `SlotPresentationOverride`, `IntegrationPresentationOverride`
  (`PresentationConfig.swift`) are the delta types; `SurfaceComposer` applies them. The `Overlay` here is a
  *priority-stacked bundle* of these existing deltas, not a new delta language.
- **Persistence** — `UserDefaultsPresentationConfigStore` persists `PresentationConfig` with
  forward-compatible decode. Reuse the store; see the migration note below.

### What is genuinely new (net engine work)

- **`Condition` expression tree** (large) — today triggers are a *fixed enum* `AlertTriggerDeclaration`
  (healthTransition / diagnosisVerdict / connectivityTransition / allMembersFailing / metricThreshold). There
  is no `all/any/not`, no temporal beyond `heldFor`, no `changed`/`transitionedTo`/edge. The recursive
  `Condition` + evaluator in §4 is the biggest new piece.
- **`Reaction` registry** (medium) — today the only reaction is alert delivery (`AlertEvent`, phases
  `.active`/`.recovered`). `MutateSurface`, `RunCommand` as a reaction, `ApplyContext`, notification action
  buttons, and the `oneShot`/`boundToCondition` lifecycle are all new.
- **Contexts** (medium) — no stateful boolean "context" entity, no priority stacking, no rule toggles. New.
- **User-authored rules + their persistence/migration** (medium) — alert rules today are regenerated from
  provider/manifest declarations each launch; only an enabled-toggle (`AlertKindOverride`) persists. User
  rules/contexts need their own versioned, migratable store. New.
- **Settable-property addressing** (medium), **cycle detection** (small), **resolution "why" trace** (small).

### Sequencing already charted

The existing specs `2026-06-27-notifications-and-alerts.md`, `-core-architecture-review.md`, and
`-overlay-generalization.md` already sequence: harden attention / status-view-model → entity-targeted alerts
→ notifications → contexts/overlays. Part B's phasing (in `spec.md`) should slot on top of that, not beside it.

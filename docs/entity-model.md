# Ambit — Provider & Entity Model (spec)

> **Ambit design docs — read together:**
> - **`HANDOFF.md`** — running project map & current build status; **`spec-v2.md`** — full synthesis.
> - **`integration-model.md`** — the installable unit: Integration → install → providers ("install gl.inet" ⇒ router + vpn).
> - **`provider-capability-model.md`** — grouping & membership (profiles + capabilities → surfaces).
> - **`entity-model.md`** (this doc) — the **Provider→Entity abstraction** (descriptors + per-snapshot state) integrations are authored against.
> - **`engine-topology.md`** — multi-engine & multi-instance: stable identity, ownership/lease, failover, check dedup.
>
> **This doc owns: the Entity abstraction and how an integration is authored.** Engine-independent identity and the descriptor/state split are defined here because they shape the abstraction; the *coordination* that uses them lives in `engine-topology.md`. Written against the real code in `Sources/AmbitCore` (file/line refs throughout); proposed changes are additive and called out.

**Status:** design, ready to implement.
**Goal:** nail the Provider/Entity contract so integrations are authored correctly and uniformly, with **stable identity that survives a provider going offline and survives moving between engines.**

---

## 1. The model in one paragraph

A `Provider` exposes four facets — **state** (`metrics` + `health`), **commands** (`CommandDescriptor`s), **configuration** (credentials + settings), **self-description** (`displayName`, `layout`, `profile`/`capabilities`). The Entity model projects them into **entities**, split into two halves: a **descriptor** (static identity + type metadata — exists even when the provider is offline) and a **state** (the per-snapshot value + availability). Identity is **engine-independent and instance-scoped**, so the same entity has the same address whether the Mac engine or the Linux engine is currently polling it, and whether it's online or not. Everything (menubar, surfaces, alerts, future iOS/relay/automation) consumes descriptor+state; one renderer per kind ⇒ new integrations need no new UI.

---

## 2. Current code (ground truth)

`Sources/AmbitCore/Provider.swift`:

```swift
public protocol Provider: Sendable {
    var id: ProviderID { get }                       // "router","speedify",… (ProviderIDs) — a TYPE id today
    var displayName: String { get }
    var pollInterval: TimeInterval { get }
    var layout: ProviderManifest.Layout? { get }     // icon, accent, primaryMetric (String?)
    var commands: [CommandDescriptor] { get }
    func poll(context: EnvironmentContext) async -> ProviderSnapshot
    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws
}
public struct ProviderSnapshot { var health: Health; var metrics: [Metric]; var detail: ProviderDetail?; var error: String?; var retryAfterSeconds: Int? }
public struct Metric { var id: String; var label: String; var value: MetricValue }   // ← gains classification (§6)
public enum MetricValue { case throughput(bitsPerSecond:Int), latency(ms:Double), percent(Double), level(Double), bool(Bool), text(String) }
public enum CommandParameterKind { case text, bool, option([String]), number }       // ← maps 1:1 to control kinds
```

Consumers this unifies: `ProviderDisplayModel.make(...)` (`ProviderDisplayModel.swift:65`), `ProviderMetricSection.sections(from:)` (`ProviderMetricSection.swift:12`, with the `id.contains("battery")` heuristic at `:40`), `ProviderSurfaceModel`/`SurfaceSnapshot`, `ProviderSetupSummary`. Engine state flows as `EngineSnapshot.providers: [ProviderID: SourceState<ProviderSnapshot>]` (`Provider.swift:245`).

**Today `ProviderID` is a provider *type* ("router").** Multi-instance requires separating *type* from *instance* (§3).

---

## 3. Identity (engine-independent, instance-scoped)

Identity never depends on which engine runs the check. The full hierarchy is owned by `integration-model.md`; the entity-relevant tail:

```swift
// Owned by integration-model.md:
//   IntegrationID         "glinet"               (the installable brand)
//   IntegrationInstanceID "glinet@192.168.8.1"   (one configured install; deterministic from target)
public typealias ProviderTypeID = String                  // "router","vpn","starlink" — a provider kind WITHIN an integration
public struct ProviderInstanceID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String   // "<IntegrationInstanceID>/<providerType>", e.g. "glinet@192.168.8.1/router"
}
public struct EntityID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String   // "<ProviderInstanceID>.<entityKey>", e.g. "glinet@192.168.8.1/vpn.connected"
}
public struct EngineID: RawRepresentable, Hashable, Sendable, Codable { public let rawValue: String } // node id; NEVER part of an entity/instance id
```

Rules:
- **`IntegrationInstanceID` (and therefore `ProviderInstanceID`) is deterministic from the install's target** (host / VIN / account), so two engines configured for the same install compute the **same** ids. (User may override with a stable assigned id.)
- **`ProviderInstanceID` is always scoped under its integration instance** (`<integrationInstanceID>/<providerType>`); a single-provider integration is the degenerate case (`speedify@<host>/speedify`).
- **`EntityID` is `providerInstanceID.entityKey`** — globally stable, engine-independent. A client failing over Mac→Linux reconciles by `EntityID`.
- **`EngineID` is for ownership/telemetry only** (`engine-topology.md`); never in an entity/instance id.
- Back-compat: today's built-ins map to default integration installs (gl.inet's `router`/`vpn` ⇒ integration `glinet`); `EngineSnapshot`/`StatusSnapshot` keying migrates `ProviderID` → `ProviderInstanceID`.

---

## 4. Entity = Descriptor + State (offline stability)

Split the entity so identity/metadata persists when the provider can't be reached.

```swift
/// STATIC. Exists as long as the instance is configured — even offline. Stable address + how to render/control.
public struct EntityDescriptor: Equatable, Identifiable, Sendable {
    public var id: EntityID
    public var instanceID: ProviderInstanceID
    public var name: String
    public var kind: EntityKind                       // sensor, binarySensor, toggle, select, number, button, text
    public var deviceClass: DeviceClass?
    public var category: EntityCategory               // primary | diagnostic | config
    public var capability: ProviderCapability?
    public var access: EntityAccess                   // read | write | readWrite
    public var unit: String?
    public var stateClass: StateClass?                // measurement | total | totalIncreasing (history hint)
    public var options: [EntityOption]?               // select
    public var range: ValueRange?                     // number
    public var command: CommandRef?                   // controllable kinds
    public var icon: String?
    public var metricID: String?                      // back-link to source Metric (sparkline/history)
}

/// DYNAMIC. The per-snapshot value + how trustworthy it is right now.
public struct EntityState: Equatable, Sendable {
    public var id: EntityID
    public var value: EntityValue?                    // .number/.bool/.text, nil if unknown/write-only
    public var availability: Availability             // .online | .stale | .unavailable
    public var lastUpdated: Date?
    public var error: String?
}
public enum Availability: String, Sendable, Codable { case online, stale, unavailable }

public enum EntityKind: String, Sendable, Codable { case sensor, binarySensor, toggle, select, number, button, text }
public enum EntityCategory: String, Sendable, Codable { case primary, diagnostic, config }
public enum EntityAccess: String, Sendable, Codable { case read, write, readWrite }
public enum StateClass: String, Sendable, Codable { case measurement, total, totalIncreasing }
public enum EntityValue: Equatable, Sendable, Codable { case number(Double), bool(Bool), text(String) }
public struct EntityOption: Equatable, Sendable, Codable { public var value: String; public var label: String }
public struct ValueRange: Equatable, Sendable, Codable { public var min: Double; public var max: Double; public var step: Double? }
public struct CommandRef: Equatable, Sendable {
    public var commandID: String
    public var argumentKey: String?                  // which CommandParameter this entity fills
    public var fixedArguments: [String: JSONValue]   // pre-bound args (EcoFlow ac toggle ⇒ target:"ac")
    public var requiresConfirmation: Bool
}
```

Consumers merge `descriptor + latest state`. **Offline behavior:** when a poll fails or the owning engine is gone, descriptors persist and states become `.unavailable` (or `.stale` past a freshness window) — the UI greys the entity instead of dropping it, alerts can fire on "went unavailable," and addresses stay valid for failover.

---

## 5. The Provider contract (descriptors + state)

```swift
public protocol Provider: Sendable {
    var integrationID: IntegrationID { get }              // which installable integration this provider belongs to
    var integrationInstanceID: IntegrationInstanceID { get }
    var typeID: ProviderTypeID { get }
    var instanceID: ProviderInstanceID { get }           // = "<integrationInstanceID>/<typeID>"
    var displayName: String { get }
    var pollInterval: TimeInterval { get }
    var profile: ProviderProfile { get }              // capability model
    var capabilities: Set<ProviderCapability> { get }

    /// STATIC entity descriptors for this instance. Stable across polls and offline. Default derives from metrics+commands+config.
    func entityDescriptors() -> [EntityDescriptor]

    /// DYNAMIC. poll() keeps returning a ProviderSnapshot; Core maps its metrics/health → [EntityID: EntityState] against the descriptors.
    func poll(context: EnvironmentContext) async -> ProviderSnapshot
    func execute(commandID: String, arguments: CommandArguments, context: EnvironmentContext) async throws
}

public extension Provider {
    func entityDescriptors() -> [EntityDescriptor] {
        EntityProjection.defaultDescriptors(provider: self)        // from commands + declared metric metadata + config
    }
}
```

`poll()` is unchanged in return type (stay green); Core derives `EntityState`s by matching the snapshot's metrics to descriptors via `metricID`, marking anything the descriptor expects but the poll didn't return as `.unavailable`. Authors override `entityDescriptors()` to declare the correct static shape (the "implement integrations correctly" work); the per-poll values keep flowing through `metrics`.

---

## 6. The one authoring enrichment (additive, kills the heuristic)

Classification on the authoring types so descriptors derive correctly:

```swift
public struct Metric { var id; var label; var value
    var deviceClass: DeviceClass?       // NEW optional
    var category: EntityCategory?       // NEW optional (default .primary)
    var capability: ProviderCapability? // NEW optional
}
```
…and the same three optional fields on the manifest `MetricMapping` (`ProviderManifest.swift`). All optional/default-nil ⇒ everything compiles unchanged. This **replaces** `ProviderMetricSection.Category.category(for:)`'s `id.contains("battery")` matching (`:40`) — grouping reads `deviceClass`/`category`.

---

## 7. Default projection & command fan-out

`EntityProjection.defaultDescriptors(provider:)` + `EntityProjection.states(snapshot:descriptors:)`:

- **Metrics → sensor/binarySensor descriptors** (deviceClass from the metric's class, else inferred from `MetricValue`); `metricID` set; states carry the value + availability.
- **health → a `binarySensor` descriptor**, `deviceClass=.connectivity`, `category=.diagnostic`.
- **Commands → controls** via `CommandParameterKind`: no-param on/off → `toggle`; momentary → `button`; one `.option` → `select`; one `.number` → `number`; **multi-param → `button` opening `ProviderDetail`** (never an auto form). **Fan-out:** a parameterized command can map to several descriptors via `CommandRef.fixedArguments` (EcoFlow's one `setOutput(target,state)` → three `toggle`s).
- **Config → `config`-category descriptors** projected from manifest `credentials` + `AppSettings`, reads/writes routed through existing `CredentialStore`/`SettingsStore`/`ProviderSetupSummary`. No second store.

---

## 8. Reconciliation with existing code (ONE projection)

- `EntityProjection` is the single interpreter of snapshot+commands+config.
- `ProviderMetricSection` → group sensor entities by `deviceClass`/`category`; delete the substring heuristic.
- `ProviderDisplayModel.make(...)` internals → built from descriptors+states (public shape may stay); `action:.configureCredentials` from config-entity completeness.
- `ProviderSurfaceModel`/`SurfaceSnapshot` unchanged in shape (build on `ProviderDisplayModel`).
- `AlertEngine` keeps watching metrics; entities carry `metricID`, and can now also alert on `availability` transitions (online→unavailable).
- `EngineSnapshot` keying migrates `ProviderID` → `ProviderInstanceID`.

Phase 1 changes nothing user-visible; the projection just becomes typed, single-sourced, and instance/offline-aware.

---

## 9. Capabilities vs entities

Capability = which providers a surface contains + which of their entities are relevant (filter by `entity.capability`). Entity kind+deviceClass = how each renders/controls. So there is **no `CapabilitySummary` type** — a uniform cross-vendor row is "render these entities."

---

## 10. Multi-engine note (see `engine-topology.md`)

This model is the half of the story that makes failover possible: because `EntityID`/`ProviderInstanceID` are engine-independent and deterministic, two engines describe the **same** entities with the **same** addresses, and a client (or aggregator) can merge their states by id. `engine-topology.md` owns the *coordination*: which engine currently **owns** (polls) each instance, eligibility (who can reach it), lease/failover, and check **dedup** (only the owner polls). The Provider/Entity model here must not encode an engine into any id — it doesn't.

---

## 11. Migration / phasing (stay green)

**Phase 1 — Core, additive, no UI change:**
1. Add identity types (§3): `ProviderTypeID`, `ProviderInstanceID`, `EntityID`; migrate `EngineSnapshot` keying to `ProviderInstanceID` (single-instance built-ins get a derived default instance id).
2. Add `EntityDescriptor`/`EntityState` (§4) + `EntityProjection`.
3. Add optional `deviceClass`/`category`/`capability` to `Metric` + `MetricMapping` (§6).
4. Add `entityDescriptors()` (default impl); **override for the eight built-ins** to declare correct descriptors (§13).
5. Re-express `ProviderMetricSection` grouping by `deviceClass`/`category`; delete the substring heuristic. (`ProviderDisplayModel.make` keeps its public shape and consumes this grouping; re-sourcing its internals from descriptors+states is deferred to Phase 2 — see below.)
6. Tests: per-built-in descriptor lists (EcoFlow→3 toggles + battery sensor; Speedify→bonding `select` SP/RD/STR; Starlink→obstruction `percent`); offline → descriptors persist, states `.unavailable`; config descriptors from credentials.

**Phase 2:** capability-grouped surfaces render from entities; `ProviderDisplayModel.make` internals re-sourced from descriptors+states (moved here from Phase 1 step 5 — it is behavior-neutral until an entity-driven surface drives the requirements). **Phase 3:** manifest `entities:` override; multi-engine coordination (`engine-topology.md`); history via `stateClass`.

---

## 12. Authoring recipe

Per provider instance, declare: (1) profile + capabilities; (2) **sensor descriptors** with `deviceClass`/`category`/`unit`/`capability`/`metricID`; (3) **control descriptors** with `CommandRef` (use `fixedArguments` to fan parameterized commands into clean controls); (4) **config descriptors** from credentials/settings (`category=.config`); (5) everything vendor-unique → `ProviderDetail`. Override `entityDescriptors()` when the default can't express it (parameterized commands, battery classification) — which is most built-ins.

---

## 13. Worked examples (real ids; `ProviderCommandCatalog`, `Provider.swift:25`)

**EcoFlow** `ecoflow@<sn>`: `…battery` sensor/`.battery`/primary (`capability:battery`); `…ac_output`/`…dc_output`/`…usb_output` toggles → `ecoflow.setOutput` with `fixedArguments:["target":"ac"|"dc"|"usb"]`, `argumentKey:"state"` (`capability:powerOutput`); `…input_watts` sensor/`.power`/diagnostic; `…time_remaining` sensor/`.duration`.

**Speedify** `speedify@<host>`: `…connected` toggle→`speedify.toggle` (`vpnClient`); `…bonding_mode` select[SP,RD,STR]→`speedify.setBondingMode` arg `mode` (`bonding`); `…download`/`…upload` sensor/`.throughput` (`tunnelStats`); `setNetworkPriority` (multi-param)→`button`→detail.

**GL.iNet** `glinet@<host>`: `…wan_up` binarySensor/`.connectivity` (`wan`), `…download`/`…upload` sensor/`.throughput` (`wan`), `…clients` sensor/`.count` (`clients`), `…vpn_connected` toggle→`vpn.toggle` (`vpnClient`), `…wan_ip` sensor/`.text`/diagnostic; config: host/password from credentials.

**Starlink** `starlink@<host>`: `…online` binarySensor/`.connectivity` (`uplink`), `…downlink`/`…uplink` sensor/`.throughput`, `…latency` sensor/`.latency`, `…obstruction` sensor/`.percent` (`obstruction`), `…outages` sensor/`.count`/diagnostic.

**ping/iperf3**: `ping@<host>.latency` sensor/`.latency` (`uplink`); `iperf3@<host>.run` button→`iperf3.run` arg `host`, results `…download`/`…upload` sensor/`.throughput`.

---

## 14. Non-goals

- No replacing `Metric`/`CommandDescriptor`/`ProviderDetail` — descriptors/states derive on top of them.
- No second config/credential store.
- No auto multi-field forms (multi-param → detail).
- No engine id baked into any entity/instance id.
- No UI redesign in Phase 1; no registry/store work; no history engine yet (only `stateClass`).
- No entity sprawl — `category` curates primary surfaces.

## 15. Resolved decisions

- **Descriptor/state split: adopted** (offline stability + failover).
- **Instance-scoped, deterministic, engine-independent ids: adopted** (multi-instance + multi-engine).
- **Integration layer above providers: adopted** — providers belong to an installable integration; `ProviderInstanceID` is scoped under the integration instance (`integration-model.md`).
- Multi-engine *coordination* (ownership/eligibility/failover/dedup): specified in `engine-topology.md`.

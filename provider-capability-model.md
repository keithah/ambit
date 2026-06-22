# Ambit — Provider Capability Model (spec)

> **Ambit design docs — read together:**
> - **`MIGRATION_PLAN.md`** — staged build path & current status.
> - **`integration-model.md`** — the installable unit: Integration → install → providers ("install gl.inet" ⇒ router + vpn).
> - **`provider-capability-model.md`** (this doc) — *grouping & membership*: profiles + capabilities decide which providers a surface contains.
> - **`entity-model.md`** — the Provider→Entity abstraction (descriptors + per-snapshot state) integrations are authored against.
> - **`engine-topology.md`** — multi-engine & multi-instance: stable identity, ownership/lease, failover, check dedup.
>
> **This doc owns: grouping & membership (profiles, capabilities, surface selection).** Rendering/control lives in `entity-model.md`. Where a sketch here conflicts with the actual code, the code is ground truth — these signatures are design intent.

**Status:** design, pre-implementation.
**Scope:** a Core-only abstraction layer that lets generic surfaces group and render heterogeneous providers by *what they can do*, while vendor-specific richness stays additive. No integration rewrites, no UI redesign, no registry/store work.

---

## 1. Why this exists

Providers are rarely one thing. GL.iNet is a router *and* WAN/Wi-Fi/clients *and* a VPN client/server. Speedify is a VPN *and* bonding/priority/failover. Starlink is an uplink *and* dish telemetry *and* a router. Pi-hole and AdGuard are both DNS/ad-blockers. An iStat replacement is a dozen system facets. Tesla is battery + climate + charging + location.

A single `providerType` enum can't express this — it forces one identity onto a multi-facet thing, and it makes generic surfaces (a "VPN" panel, a "Power" panel, a "DNS" panel) impossible to build without per-vendor special-casing.

The model has **three layers**, from most generic to most specific:

| Layer | Cardinality | Owner | Purpose |
|---|---|---|---|
| **Profile** | one per provider | Core (curated) | Primary identity: icon, label, sort, default surface |
| **Capabilities** | a set per provider | Core + manifests | What functional facets it exposes; drives surface membership |
| **Vendor detail** | per provider | the provider | Rich, vendor-only state and controls (unchanged) |

The rule that ties them together: **capabilities are the shared vocabulary that generic surfaces speak; vendor detail is the private vocabulary that only a provider's own view speaks.** Never push vendor specifics up into the capability taxonomy, and never make a generic surface read vendor detail to do its basic job.

This layer feeds the existing surface plumbing (`ProviderDisplayModel`, `ProviderSurfaceModel`, `SurfaceSnapshot`, `NotificationSurfaceModel`) — it decides *which* providers a surface contains and *which of their facets are relevant*; it does not replace those models. **How each member's facets are actually rendered and controlled is the job of the Entity Model (see `entity-model.md`)** — capabilities select, entities render. (Separately, every provider belongs to an installable **Integration** — `integration-model.md` — the packaging/install axis, orthogonal to profile/capability.)

---

## 2. Key design decisions (and rationale)

These are the opinionated calls. A few intentionally improve on the original handoff sketch; they're flagged so they can be overridden.

1. **Capabilities are an open, namespaced identifier — not a closed Swift enum.** *(Deviation from handoff, which proposed an enum.)* Ambit already has a manifest/package system for installed third-party providers. A closed `enum ProviderCapability` can't be extended by a manifest, so manifest providers could never advertise capabilities. Instead, model a capability as a string-backed value type with static constants for the curated core set — the same idiom as `Notification.Name`:

   ```swift
   public struct ProviderCapability: RawRepresentable, Hashable, Sendable, Codable {
       public let rawValue: String          // namespaced, e.g. "net.vpn.client"
       public init(rawValue: String) { self.rawValue = rawValue }
   }
   public extension ProviderCapability {
       static let vpnClient = ProviderCapability(rawValue: "net.vpn.client")
       static let battery    = ProviderCapability(rawValue: "power.battery")
       // … full core set in §4
   }
   ```

   Built-ins use the type-safe constants; manifests declare capability strings, validated against the known core set, with **vendor-namespaced** strings allowed for opt-in extensions (e.g. `"x.unifi.siteMagic"`). This keeps surface logic working on a stable core vocabulary while staying extensible.

2. **Capabilities are static per installed provider instance, not per-poll.** A provider advertises what it *can* do; whether a facet currently has data or is connected is **snapshot state**. GL.iNet always advertises `vpnClient`; whether the VPN is up right now is read from the snapshot. If a provider's capability set genuinely depends on discovery/setup (a generic SNMP box, a manifest with optional features), resolve it **once at construction/installation** and treat it as stable for the session. Rationale: if capabilities varied per poll, surface membership would flicker.

3. **Profile is single, coarse, and curated; capabilities are authoritative for surface logic.** Profile exists only to give a provider one stable identity (icon, label, default "home" surface, sort order) so surfaces don't have to infer "is this primarily a router or a VPN?". All *membership/grouping* decisions use capabilities. A provider declares its profile explicitly (Starlink's profile is `uplink` even though it has `routerStatus`).

4. **Shared capabilities over vendor-prefixed duplicates.** *(Deviation: handoff listed `vehicleBattery`.)* A single `power.battery` capability is reused by EcoFlow, a UPS, a laptop, and a Tesla — that's exactly what makes one "Power" surface possible across all of them. Don't mint `vehicleBattery` when `battery` already enables the cross-vendor surface. Vehicle-only facets (climate, charging session, location) stay vehicle capabilities.

5. **Surfaces are non-exclusive facets, not buckets.** A provider appears in *every* surface whose capability predicate it matches. GL.iNet shows up in Router **and** VPN (and DNS, if it ran DNS). Its profile decides where it "lives" by default; capabilities decide everywhere else it appears.

6. **Rendering is delegated to entities, not to bespoke summaries.** *(Reconciled with the Entity Model.)* Capabilities decide membership and which entities are relevant; the generic, uniform rendering of a member (a VPN row, a battery row) is produced by the **Entity Model** (`entity-model.md`) — a uniform VPN row is simply "render this provider's `vpnClient`-capability entities by kind." There is **no** separate `CapabilitySummary` type. Phase 1 still ships capability-tagged metrics (§6a); structured rendering arrives with entities, not summary structs. Vendor `detail` is never touched.

---

## 3. Profiles vs capabilities

**Profile** answers "what *is* this, at a glance?" — one value, used for identity and a default surface.

**Capability** answers "what facet does it expose?" — a set, used to decide surface membership and which of a provider's entities are relevant to a given surface.

A useful invariant: a provider's profile should correspond to one of its capabilities' domains, but the mapping is declared, not derived, to avoid ambiguity for hybrids.

---

## 4. Capability taxonomy v1

Grouped by domain. `rawValue` is the wire/manifest form; the Swift constant name is the ergonomic form.

**Networking — router**
- `routerStatus` — `net.router.status`
- `wan` — `net.wan`
- `wifi` — `net.wifi`
- `clients` — `net.clients`

**Networking — VPN / bonding**
- `vpnClient` — `net.vpn.client`
- `vpnServer` — `net.vpn.server`
- `bonding` — `net.bonding`
- `networkPriority` — `net.priority`
- `failover` — `net.failover`
- `tunnelStats` — `net.tunnel.stats`

**Uplink / ISP**
- `uplink` — `uplink.link` (ISP reachability/throughput as the internet-facing link)
- `dishTelemetry` — `uplink.dish`
- `obstruction` — `uplink.obstruction`

**DNS**
- `dnsResolver` — `dns.resolver`
- `adBlocking` — `dns.adblock`
- `queryStats` — `dns.queryStats`
- `blocklistControl` — `dns.blocklist`

**Host / infrastructure**
- `computeHost` — `host.compute`
- `storage` — `host.storage`

**Power**
- `battery` — `power.battery` *(shared: EcoFlow, UPS, laptop, Tesla)*
- `powerOutput` — `power.output`
- `ups` — `power.ups`

**System (iStat-style host telemetry)**
- `systemCPU` — `system.cpu`
- `systemMemory` — `system.memory`
- `systemDisk` — `system.disk`
- `systemNetwork` — `system.network` *(local NIC throughput, distinct from `wan`/`tunnelStats`)*
- `systemSensors` — `system.sensors`
- `fans` — `system.fans`

**Vehicle**
- `vehicleClimate` — `vehicle.climate`
- `vehicleCharging` — `vehicle.charging`
- `vehicleLocation` — `vehicle.location`

**Calendar / home / fallback**
- `calendarEvents` — `calendar.events`
- `homeBridge` — `home.bridge`

> Taxonomy is versioned. Adding a capability is additive; renaming/removing is a breaking change requiring a version bump and a manifest-compat shim.

### Profiles v1

`router`, `vpn`, `uplink`, `dns`, `system`, `power`, `vehicle`, `calendar`, `home`, `generic`.

Profile may be a closed enum (curated, changes rarely) with `.generic` as the explicit fallback. If third-party manifests ever need novel profiles, promote it to the same string-backed pattern as capabilities; not needed for v1.

---

## 5. How providers advertise

Extend the `Provider` protocol, with **protocol-extension defaults** so nothing breaks on day one:

```swift
public protocol Provider: Sendable {
    // … existing members …
    var profile: ProviderProfile { get }
    var capabilities: Set<ProviderCapability> { get }
}

public extension Provider {
    var profile: ProviderProfile { .generic }
    var capabilities: Set<ProviderCapability> { [] }
}
```

Existing built-ins compile unchanged; you then fill in real values per provider (§10, Phase 1).

**Manifest providers** declare the same two fields in the package schema:

```yaml
profile: dns
capabilities: [dns.resolver, dns.adblock, dns.queryStats, dns.blocklist]
```

Validation: each capability string must be in the core set or carry a vendor namespace (`x.<vendor>.<feature>`); unknown un-namespaced strings are a validation error. The installed-provider setup path resolves capabilities once and persists them with the installed instance.

---

## 6. Snapshot exposure

Two mechanisms, layered. **Phase 1 ships only the first.**

### 6a. Capability-tagged metrics (Phase 1 — cheap, additive)

Add an optional capability attribution to `Metric`:

```swift
public struct Metric: Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var value: MetricValue
    public var capability: ProviderCapability?   // NEW, optional
}
```

A surface can already do something useful with just this: "show every `throughput` metric tagged `uplink` across all members." No new summary types, no `detail` changes.

### 6b. Structured rendering → see the Entity Model

Uniform, structured cross-vendor rendering (a VPN row that looks identical for router-VPN, Speedify, and a future Tailscale; a battery row identical for EcoFlow, UPS, and Tesla) is **not** done with a `CapabilitySummary` type. It is produced by the **Entity Model** (`entity-model.md`): each provider projects to typed, addressable entities, and a surface renders the entities whose `capability` matches it, one generic view per entity kind. Capabilities select; entities render. *(This supersedes an earlier draft that proposed `CapabilitySummary` structs and a `ProviderSnapshot.summaries` field — neither is needed.)*

---

## 7. Generic surfaces: selection & grouping

A surface is defined by a capability predicate over membership:

```swift
public struct SurfaceDescriptor: Sendable {
    public var id: String
    public var title: String
    public var icon: String
    public var requires: CapabilityMatch       // .any([…]) or .all([…])
    // ordering / primary-summary hint …
}
public enum CapabilityMatch: Sendable { case any(Set<ProviderCapability>), all(Set<ProviderCapability>) }
```

Membership = provider's `capabilities` satisfies `requires` (most surfaces are `.any`). Each member is then rendered from its **entities** (see `entity-model.md`), filtered to those whose `capability` matches the surface, one generic view per entity kind. The provider's `ProviderDisplayModel`/detail remains the fallback for anything not yet projected to an entity.

This plugs into the existing `ProviderSurfaceModel`/`SurfaceSnapshot` — capabilities supply membership and facet selection; those models still do the actual view shaping.

### v1 built-in surfaces

| Surface | `requires` (any of) |
|---|---|
| Router | `routerStatus`, `wan`, `wifi`, `clients` |
| Internet / Uplink | `uplink`, `dishTelemetry`, `obstruction`, `wan` |
| VPN | `vpnClient`, `vpnServer`, `bonding`, `tunnelStats` |
| DNS | `dnsResolver`, `adBlocking`, `queryStats` |
| System | `systemCPU`, `systemMemory`, `systemDisk`, `systemNetwork`, `systemSensors`, `fans` |
| Power | `battery`, `powerOutput`, `ups` |
| Vehicle | `vehicleClimate`, `vehicleCharging`, `vehicleLocation` |
| Calendar | `calendarEvents` |
| Home | `homeBridge` |

The existing flat "all providers" menubar view is unchanged; surfaces are an additional lens, and a provider can appear in several.

---

## 8. Vendor-specific detail stays additive

`ProviderDetail` is untouched. It remains the home for everything vendor-only: Speedify bonding/priority controls, GL.iNet admin/firmware, Starlink dish specifics, Tesla command set. The handoff's "vendor extensions" (`glinetAdmin`, `speedifyServers`, `starlinkDish`, …) live in `detail`, **not** in the capability set.

Decision rule for "capability vs detail": if two different vendors could plausibly expose the same facet and a user would want them grouped, it's a **capability**. If it's vendor-unique controls or telemetry, it's **detail**. A vendor may *opt into* grouping for something genuinely shared via a vendor-namespaced capability string, but the default home for specifics is detail.

---

## 9. Migration path

**Phase 1 — the first PR (matches the requested "likely first implementation"; Core-only, additive):**
1. Add `ProviderProfile` and `ProviderCapability` (string-backed, with the §4 core constants).
2. Add `profile`/`capabilities` to `Provider` with default extension values (`.generic`, `[]`).
3. Assign profile + capabilities to each existing built-in (§11 mappings).
4. Add `Metric.capability` (optional) — wiring only where trivial; no detail changes.
5. Add `SurfaceDescriptor` + a pure grouping function `surfaces(for: [Provider]) -> [SurfaceDescriptor: [ProviderID]]`.
6. Tests: grouping/filtering correctness (VPN surface contains `vpn` + `speedify`; Power contains `ecoflow`; Router contains `router`; etc.).
- **Do not** rewrite provider detail models, snapshot structure, or any UI in Phase 1.

**Phase 2 (later):** wire one generic surface (VPN or Power) end-to-end through `ProviderSurfaceModel`, rendering its members from **entities** (`entity-model.md`) rather than any summary type.

**Phase 3+ (later):** remaining surfaces; manifest schema fields for profile/capabilities; new integrations (DNS, system, vehicle, calendar) authored directly against the model.

---

## 10. Existing built-ins → capability assignment (Phase 1)

| Provider | Profile | Capabilities |
|---|---|---|
| `router` (GL.iNet) | `router` | `routerStatus`, `wan`, `wifi`, `clients`, `vpnClient`, `vpnServer` |
| `vpn` (GL.iNet VPN) | `vpn` | `vpnClient`, `tunnelStats` |
| `reachability` | `uplink` | `uplink` |
| `speedify` | `vpn` | `vpnClient`, `bonding`, `networkPriority`, `failover`, `tunnelStats` |
| `starlink` | `uplink` | `uplink`, `dishTelemetry`, `obstruction`, `routerStatus` |
| `ecoflow` | `power` | `battery`, `powerOutput` |
| `ping` | `uplink` | `uplink` |
| `iperf3` | `uplink` | `uplink`, `tunnelStats` |

*(GL.iNet's router and the separate GL.iNet VPN provider both advertise `vpnClient`; that's fine — both legitimately appear in the VPN surface.)*

---

## 11. Worked examples

**GL.iNet** — profile `router`; capabilities `routerStatus, wan, wifi, clients, vpnClient, vpnServer`; detail: `glinetAdmin, glinetFirmware, glinetSpeedifyHost`. Appears in Router + VPN surfaces; in the VPN surface it renders its `vpnClient` entities (a `connected` toggle, etc.).

**VPN surface (consumer view)** — `requires .any(vpnClient, vpnServer, bonding, tunnelStats)`. Members: GL.iNet router VPN, GL.iNet VPN provider, Speedify, and any future WireGuard/Tailscale. Each renders via its `vpnClient`-capability **entities** (a `connected` toggle, a `server` select) — uniformly, regardless of vendor.

**Speedify** — profile `vpn`; capabilities `vpnClient, bonding, networkPriority, failover, tunnelStats`; detail: `speedifyServers, speedifySession` plus its bonding/priority controls. Shows in the VPN surface as a uniform row, but its rich bonding/priority UI stays in detail.

**Starlink** — profile `uplink`; capabilities `uplink, dishTelemetry, obstruction, routerStatus`; detail: `starlinkDish, starlinkRouter`. Appears in Internet/Uplink (primary) and Router surfaces.

**Pi-hole** — profile `dns`; capabilities `dnsResolver, adBlocking, queryStats, blocklistControl`; detail: Pi-hole specifics. Groups with AdGuard in the DNS surface.

**AdGuard Home** — profile `dns`; capabilities `dnsResolver, adBlocking, queryStats, blocklistControl`; detail: AdGuard specifics. Same DNS surface; both project identical entity shapes (`queries_today`, `blocked_pct`…), so the surface renders them identically.

**iStat replacement** — profile `system`; capabilities `systemCPU, systemMemory, systemDisk, systemNetwork, systemSensors, fans` (+ `battery` on a laptop, so it also surfaces in Power). Replaces iStat Menus via the System surface; battery shows in Power.

**Calendar** — profile `calendar`; capabilities `calendarEvents`; detail: event list/specifics. Calendar surface; an ambient "next event" notification model fits `NotificationSurfaceModel`.

**Tesla** — profile `vehicle`; capabilities `battery` (shared → appears in Power surface alongside EcoFlow/UPS), `vehicleClimate, vehicleCharging, vehicleLocation`; detail: command set, named-location, full vehicle state. Appears in Vehicle (primary) and Power surfaces.

---

## 12. Non-goals

- No rewrite of existing integrations or their `ProviderDetail` models.
- No UI redesign — capabilities feed existing surface models; views are unchanged in Phase 1.
- No registry/store work.
- No closed-enum capability type (it would break manifest providers).
- No runtime-varying capabilities (resolved once per installed instance).
- No folding vendor-specific facets into the shared taxonomy.

## 13. Open questions

- Should `profile` ever be multi-valued for true hybrids, or is "single profile + rich capabilities" always enough? (Current call: single is enough; capabilities carry the hybridness.)
- Do any capabilities need an associated **command** convention (e.g. `vpnClient` ⇒ a standard `toggle` command id) so generic surfaces can offer a control without vendor knowledge? Candidate for Phase 2.
- Capability **versioning** mechanics when the taxonomy evolves (coordinated with entity/device-class versioning in `entity-model.md`).

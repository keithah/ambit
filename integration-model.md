# Ambit — Integration Model (the installable unit)

> **Ambit design docs — read together:**
> - **`MIGRATION_PLAN.md`** — staged build path & current status.
> - **`integration-model.md`** (this doc) — the installable unit: Integration → install → providers ("install gl.inet" ⇒ router + vpn).
> - **`provider-capability-model.md`** — grouping & membership (profiles + capabilities → surfaces).
> - **`entity-model.md`** — the Provider→Entity abstraction (descriptors + per-snapshot state) integrations are authored against.
> - **`engine-topology.md`** — multi-engine & multi-instance: stable identity, ownership, failover, dedup.
>
> **This doc owns: the install/packaging layer above providers, and the identity hierarchy it implies.** It is the source of truth for `IntegrationID` / `IntegrationInstanceID` and how `ProviderInstanceID` is scoped under them; `entity-model.md` consumes those ids.

**Status:** design. **Phase 1 = identity + grouping labels only** (additive, ships with the entity-model Phase 1). The manifest-bundle and unified setup flow are explicitly later phases.

---

## 1. Why

Providers are deliberately fine-grained (gl.inet is a `router` provider **and** a `vpn` provider — see `provider-capability-model.md`). But a user doesn't install "a router provider"; they **install gl.inet**, and it sets up router *and* VPN functionality from one place, with one set of credentials. Ubiquiti is the same shape — one install, many providers (controller, clients, devices, …). The **Integration** is that branded, installable unit; **Provider**s are what it stands up.

This mirrors Home Assistant exactly: **Integration → config-entry (install) → devices → entities.**

---

## 2. The hierarchy

```
Integration            "glinet"                         ← installable, branded; declares which providers it stands up + shared setup
  └ IntegrationInstance "glinet@192.168.8.1"            ← one configured install: a target + its shared credentials
      ├ Provider inst.  "glinet@192.168.8.1/router"     ← profile: router   (capability model)
      └ Provider inst.  "glinet@192.168.8.1/vpn"        ← profile: vpn
          └ Entities    "glinet@192.168.8.1/vpn.connected", …   (entity model)
```

- **Integration** — the package/brand. 1..N providers. Shared credential schema + connection/target config + setup flow.
- **IntegrationInstance** — a configured install (multi-instance = multiple installs: two gl.inet routers = two instances). Owns the shared credentials/target; instantiates its providers.
- **Provider instance** — a provider within an integration instance; the unit entities hang off, and the unit `provider-capability-model.md` profiles/capabilities apply to.
- **Entity** — as in `entity-model.md`.

---

## 3. Identity (authoritative)

```swift
public struct IntegrationID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String          // "glinet","ubiquiti","tesla","speedify",…
}
public struct IntegrationInstanceID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String          // DETERMINISTIC from target/config: "glinet@192.168.8.1", "tesla@<vin>"
}
public struct ProviderInstanceID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String          // "<IntegrationInstanceID>/<providerType>": "glinet@192.168.8.1/router"
}
// EntityID = "<ProviderInstanceID>.<entityKey>"  →  "glinet@192.168.8.1/router.wan_up"   (entity-model.md)
```

Rules:
- `IntegrationInstanceID` is **deterministic from the install's target** (host / VIN / account), so two engines configured for the same install compute the same id — the property `engine-topology.md` needs for failover. User may override with a stable assigned id.
- `ProviderInstanceID` is **always scoped under an integration instance** (`<integrationInstanceID>/<providerType>`). A single-provider integration is the degenerate case (`speedify@<host>/speedify`).
- **No `EngineID` appears anywhere in these ids** (`engine-topology.md`).

---

## 4. What an Integration declares

```swift
public protocol Integration: Sendable {
    var id: IntegrationID { get }
    var displayName: String { get }                  // "GL.iNet"
    var providerTypes: [ProviderTypeID] { get }      // ["router","vpn"]
    var credentials: [CredentialSpec] { get }        // SHARED across the integration's providers
    // builds the provider instances for one configured install, sharing one connection/credential set
    func makeProviders(instance: IntegrationInstanceID, config: IntegrationConfig) -> [Provider]
}
```
Key property: providers built by one integration instance **share the connection/credentials** — this is what already exists informally as gl.inet's single-login + `GLiNetClientPool` (router + vpn authenticate once). The integration is where that sharing is made explicit.

---

## 5. Built-in grouping (Phase 1)

| Integration | Providers |
|---|---|
| `glinet` | `router`, `vpn` |
| `speedify` | `speedify` |
| `starlink` | `starlink` |
| `ecoflow` | `ecoflow` |
| `reachability` | `reachability` |
| `ping` | `ping` |
| `iperf3` | `iperf3` |

(`reachability`/`ping`/`iperf3` are diagnostic tools, kept as their own single-provider integrations for now; they could later be grouped under a "Network Tools" integration. Future vendor integrations like `ubiquiti` will have several providers from day one.)

---

## 6. Ownership unit (see `engine-topology.md`)

The unit of **eligibility and ownership** in multi-engine is the **IntegrationInstance**, not the individual provider instance: whichever engine owns `glinet@<host>` runs *all* its providers (router + vpn) so they share the one authenticated connection. Reachability/`needs` is declared at the integration-instance level (it has one target). This both respects single-login and matches the user's mental model ("gl.inet runs on the box").

---

## 7. Manifest bundling (LATER phase, not Phase 1)

Today a `ProviderManifest`/`ProviderManifestPackage` is **one provider**. The integration model needs a package that declares **several** providers plus the **shared** credentials/endpoint:

```yaml
integration: ubiquiti
displayName: Ubiquiti
credentials: [ {id: apiKey, ...} ]      # shared
endpoint: { baseURL: "https://{host}", ... }   # shared
providers:
  - { type: controller, metrics: [...], commands: [...] }
  - { type: clients,    metrics: [...] }
  - { type: devices,    metrics: [...] }
```
Back-compat: a single-provider integration is the degenerate case, so existing single-provider manifests keep working (wrap them as a one-provider integration). This is real work against the current manifest system — its own phase.

---

## 8. Unified setup flow (LATER phase, not Phase 1)

Today `ProviderSetupSummary` is per-provider. It becomes per-integration: **install gl.inet once**, enter the shared host/credentials, validate the integration, and all its providers become ready together (with optional per-provider enable toggles underneath). `ProviderSetupSummary` → `IntegrationSetupSummary` (reusing the existing credential-completeness/validation machinery). Its own phase.

---

## 9. Phasing

- **Phase 1 (now, with entity-model Phase 1):** identity + grouping **labels only**. Add `IntegrationID`/`IntegrationInstanceID`; scope `ProviderInstanceID` under the integration instance; add `integrationID` to providers; group the eight built-ins per §5. Data model shows router+vpn share integration `glinet`. Tests assert the grouping + scoped ids. **No new manifest schema, no new setup UI.**
- **Later — manifest bundling (§7):** one package → multiple providers + shared creds; back-compat with single-provider manifests.
- **Later — unified setup (§8):** per-integration install/validate; `IntegrationSetupSummary`.
- **Topology Phase 3:** ownership at integration-instance granularity (§6).

---

## 10. Non-goals

- Phase 1 changes **no** manifest schema, **no** setup UI, **no** entity rendering — it only adds the integration ids/labels and the built-in grouping.
- Not a new credential store — shared credentials still live in the existing `CredentialStore`.
- No `EngineID` in any id.

## 11. Open questions

- Whether diagnostic tools (`ping`/`iperf3`/`reachability`) should fold into one "Network Tools" integration or stay separate. (Lean: separate now, revisit.)
- Per-provider enable/disable *within* an installed integration — needed at install-UI time (§8), not Phase 1.
- Whether an integration instance can ever span providers with different reachability (e.g. a cloud + a LAN provider in one integration). Lean: no — an integration instance has one target; model such cases as two integrations. Confirm when a real one appears.

# Ambit — Engine Topology (multi-engine & multi-instance, peer-to-peer)

> **Ambit design docs — read together:**
> - **`HANDOFF.md`** — running project map & current build status; **`spec-v2.md`** — full synthesis.
> - **`integration-model.md`** — the installable unit: Integration → install → providers ("install gl.inet" ⇒ router + vpn).
> - **`provider-capability-model.md`** — grouping & membership (profiles + capabilities → surfaces).
> - **`entity-model.md`** — the Provider→Entity abstraction (descriptors + per-snapshot state).
> - **`engine-topology.md`** (this doc) — **peer-to-peer multi-engine coordination**: identity, eligibility, weighted ownership, single-runner handoff, failover.
>
> **This doc owns: how multiple engines cooperate — no central coordinator.** Depends on `entity-model.md`'s engine-independent identity (`ProviderInstanceID`/`EntityID`); does not change it. **Later-phase (Phase 3)**; the data model is built compatibly now.

**Status:** design, forward-looking (Phase 3).
**Goal:** several engines (a Mac, an always-on Linux box, occasionally a phone) run the same Ambit, with **at most one engine polling each provider instance** — a brief, *tunable* overlap during cutover is allowed (default a few seconds, configurable to zero) — automatic failover, and **no coordinator, no lease server, no cloud dependency.** Ownership concentrates on the most reliable engine; weaker engines (laptops, phones) only run what nothing better can.

---

## 1. Why & the core rules (from design decisions)

You may run a Mac engine (up when the laptop is awake), an always-on Linux box, and rarely a phone. The rules we settled:

1. **One steady-state owner; cutover overlap is tunable.** In steady state exactly one engine polls an instance. Handoff uses one of two policies set by `maxOverlap`: **make-before-break** (new owner comes up healthy, then old stops — gap-free, a brief bounded overlap; the default) or **strict stop-before-start** (`maxOverlap = 0` — no overlap, a brief gap). See §5 and Tuning.
2. **Concentrate on reliability, don't load-balance.** Ownership goes to the **highest-weight eligible** engine: class `always-on > laptop > phone`, longer continuous uptime breaks ties within a class. The box ends up owning everything it can reach; the Mac owns only what it's uniquely eligible for; the **phone is last resort**.
3. **You must be on the mesh to play.** An engine can own an instance only if it can reach the target **and** is present on the peer mesh (Tailscale/bus) to coordinate. An engine off the mesh doesn't participate at all — this is what makes split-brain a non-issue (no two engines can "own" without seeing each other). "Not connected ⇒ not running" is enforced by construction.
4. **Single engine ⇒ zero-config.** One engine owns everything it's eligible for; none of the machinery below runs.
5. **A brief gap *or* a brief overlap is acceptable — your call, tunable.** Ungraceful failover happens within `livenessTTL` (~30–60s). Whether cutover prefers a small gap (`maxOverlap = 0`) or a small overlap (`maxOverlap > 0`) is a knob; both are bounded.

### Tuning (all configurable; sane defaults)
```swift
public struct TopologyTuning: Sendable, Codable {
    public var maxOverlap: TimeInterval      // cutover: 0 = strict stop-before-start (brief gap); >0 = make-before-break, overlap capped here. default 30s
    public var livenessTTL: TimeInterval     // peer considered gone after this ⇒ ungraceful-failover window. default 45s
    public var beaconInterval: TimeInterval  // presence broadcast cadence. default 10s
    public var stabilityWindow: TimeInterval // a higher-weight engine must be present this long before initiating takeover (anti-flap). default 30s
}
```

---

## 2. Identity (unchanged, from `entity-model.md`)

`ProviderInstanceID` is deterministic from target config; `EntityID = instanceID.entityKey`; **no `EngineID` ever appears in either.** That's why ownership can move between engines invisibly — every engine names the same device and entities identically.

**The unit of eligibility and ownership here is the `IntegrationInstance`** (`integration-model.md`): an engine owns a whole install (e.g. `glinet@<host>`) and runs *all* its providers, so they share one authenticated connection (respects gl.inet single-login). Throughout this doc, "instance" means **integration instance**.

---

## 3. Engine, eligibility, weight

```swift
public enum EngineClass: Int, Sendable, Codable { case alwaysOn = 3, laptop = 2, phone = 1 }  // higher = preferred

public struct EngineDescriptor: Sendable, Codable {
    public var id: EngineID                  // stable per node ("linux-box","mac-studio","keith-iphone")
    public var displayName: String
    public var engineClass: EngineClass      // auto-detected (battery/lid/OS), user-overridable
    public var reach: Set<ReachTag>          // .localHost, .lan("192.168.8.0/24"), .internet, .has("grpcurl"), .has("iperf3")
    public var onMeshSince: Date             // continuous mesh presence → uptime tiebreak
}

public struct InstanceRequirements: Sendable, Codable {
    public var needs: Set<ReachTag>          // Starlink → .lan(dishSubnet); system metrics → .localHost; Tesla → .internet
    public var pinnedEngine: EngineID?       // optional hard override
}
```

**Eligible(engine, instance)** ⇔ `engine.reach` satisfies `instance.needs` **AND** engine is currently present on the mesh.
**Weight(engine)** = (`engineClass`, then `onMeshSince` — longer = higher). `phone` only wins when it's the *only* eligible engine.
Class auto-detection: no battery + no lid + stays up ⇒ `alwaysOn`; has battery/lid/sleeps ⇒ `laptop`; iOS/Android ⇒ `phone`. User can override.

---

## 4. Ownership is computed (no coordinator)

```swift
func owner(of instance: IntegrationInstanceID, req: InstanceRequirements, mesh: [EngineDescriptor]) -> EngineID? {
    if let pin = req.pinnedEngine, mesh.contains(where: { $0.id == pin && eligible($0, req) }) { return pin }
    return mesh.filter { eligible($0, req) }
               .max { weight($0) < weight($1) }?      // highest class, then longest uptime
               .id
}
```
Every engine runs this over its mesh view and **polls only the instances it computes itself to own.** Because eligibility requires mesh-presence, all engines that *could* contend for an instance can see each other — so they compute the same owner. Deterministic, no lease, no election. Adding the box online → it becomes the highest-weight owner of everything it's eligible for, triggering handoffs (§5). The box sleeping/leaving → next-highest takes over.

**Membership** = small presence beacons over the mesh; a peer is live if seen within `livenessTTL` (default ~30–60s ⇒ §1 rule 5). All-to-all broadcast is fine at this scale (a few engines).

---

## 5. Handoff (policy-driven: make-before-break by default, strict optional)

`maxOverlap` picks the cutover policy. Three cases:

**A. Planned takeover** — higher-weight engine `I` takes instance `X` from current owner `O` (after `I` has been present ≥ `stabilityWindow`):
- `I → O`: `RequestHandoff(X)` with proof of presence/eligibility.
- **make-before-break (`maxOverlap > 0`, default):** `O` keeps polling while `I` starts and begins publishing healthy state; once `I` is confirmed publishing (or `maxOverlap` elapses) `O` stops. Gap-free; overlap ≤ `maxOverlap`. If `I` doesn't come healthy within `maxOverlap`, abort — `O` keeps `X`.
- **strict (`maxOverlap == 0`):** `O` verifies `I` is fully present, `O` **stops**, releases, then `I` **starts**. No overlap, a brief gap; never release to a phantom.
If `O` vanishes mid-handshake, case C applies.

**B. Graceful shutdown** — `O` is going to sleep (laptop lid) and proactively hands off `X` to the next-best present engine `N`, using the same policy as A (make-before-break or strict). If no `N` is present, `O` just stops; `X` goes `.unavailable` until someone eligible appears.

**C. Ungraceful disappearance** — `O` crashes/sleeps without handing off. Peers notice `O` missing from the mesh within `livenessTTL`; the now-highest-weight eligible engine starts polling `X`. **No handshake needed — `O` is gone, so it isn't running.** Gap = the detection window (~30–60s, accepted).

No central authority anywhere — only direct pairwise messages and the deterministic `owner(...)` function.

---

## 6. Unified view & reconciliation

Each engine publishes descriptors+states only for instances it owns, stamped with an **ownership generation** (incremented on each takeover):
```swift
public struct PublishedEntityState: Sendable, Codable { public var state: EntityState; public var owner: EngineID; public var generation: UInt64 }
```
Consumers (any client, or the optional relay) merge by `EntityID`: the **newest** state per entity wins (by timestamp, tie-broken by `generation`). During a make-before-break overlap (≤ `maxOverlap`) both owners may publish briefly — newest-wins resolves it; in strict mode there's no overlap. `generation` also discards a departed owner's stale leftovers. An instance with no eligible+present owner ⇒ its entities are `.unavailable`.

---

## 7. How ownership lands in practice

- **Host-local metrics** (a Mac's CPU/mem/sensors) need `.localHost` ⇒ only that machine is ever eligible ⇒ it always owns its own system metrics regardless of class.
- **LAN devices** (Starlink dish, router) ⇒ eligible = engines on that LAN **and** on the mesh ⇒ highest-weight among them (usually the box if it's on that LAN, else the Mac).
- **Cloud APIs** (Tesla) ⇒ every mesh-present engine is eligible ⇒ the **always-on box** wins and owns them, concentrating cloud polling on the most reliable node.
- **Phone** ⇒ owns an instance only when it's the *sole* eligible+present engine (e.g. it's the only thing on a cellular link reaching something), and even then best-effort given iOS background limits.

---

## 8. Interaction with the rest of Ambit

- **Product tiers** (`product-spec`/`pitch`): the embedded Mac engine and the dedicated box are two peers; iOS is a **client** that may act as a last-resort engine; the **Pro relay is an optional aggregator + remote viewport + off-LAN transport**, never the owner of truth. Local multi-engine works with no relay and no cloud.
- **Entity model:** unchanged — engine-independent ids + descriptor/state make `.unavailable` and handoff work on top of it.
- **Capability model:** unaffected; grouping is over the merged entity set.

---

## 9. Recommended build & phasing

- **Single engine (ships first / today):** owns all eligible instances; no beacons, no handoff.
- **Two+ engines (Phase 3):** presence beacons + `owner(...)` computation + the §5 handshake + §6 aggregation. Transport = the existing mesh/bus. Class auto-detect + manual override.
- **Defer:** weighted intra-class load-spreading (we explicitly don't want it), automatic class re-detection mid-session, cross-engine history merge.

---

## 10. Non-goals / risks

- **No coordinator, lease server, leader election, or consensus framework.** Ownership = weighted `owner(...)` over mesh membership; transitions = pairwise handshake.
- **No engine id in any entity/instance id** (`entity-model.md`).
- **Split-brain is designed out**, not tolerated: ownership requires mesh-presence, so two engines can never both "own" without seeing each other. (The pathological "reaches the device but not the mesh" engine simply doesn't participate; the instance is owned by a mesh-present engine or is `.unavailable`.)
- **Coordinated cutover overlap** (`maxOverlap`) is a *bounded, intentional* brief double-run during handoff — distinct from split-brain (designed out). Strict mode (`maxOverlap = 0`) trades it for a brief gap.
- **Watch:** class/uptime flapping → ownership churn (mitigate with `stabilityWindow` before a newly-arrived engine triggers takeover); a laptop that sleeps for seconds repeatedly (debounce via `livenessTTL`); false failover from brief mesh blips (the ~30–60s TTL is the buffer).

## 11. Open questions

- **Uptime metric:** continuous mesh-presence time (proposed) vs since-boot. Leaning mesh-presence — it's what predicts "won't drop the instance."
- **Stability window before takeover:** how long a higher-weight engine must be present before it initiates a handoff (avoid moving everything to a box that's about to reboot). Propose a few × `beaconInterval`; tune against real behavior.
- **Class auto-detection heuristics** per OS (battery/lid/thermal/power-source signals) and when to surface the manual override.
- **Beacon/handshake transport guarantees** the mesh must provide for `livenessTTL`/handshake acks to be reliable; define defaults against the real transport.

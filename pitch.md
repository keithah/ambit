# Ambit — the pitch

**Every connected thing, one click away in your menubar and on your phone.**

Think **iStat Menus you can extend** — the same ambient, glanceable menubar you already love, but open to anything: your routers, ISP, Starlink, VPNs, EV, power stations, smart-home gear. Monitor what matters and fire one action without launching a vendor app. **Delete 15 single-purpose apps.**

---

### The problem

Every device ships a bloated app that jails one useful action behind a full launch — opening MyQ just to close the garage, the Tesla app just to precondition. There's no single ambient place to glance at state or act. The tools that come close each miss:

- **iStat Menus** nails the ambient glance, but it's closed and can't be extended to *your* stuff.
- **Home Assistant** can integrate anything, but it's a destination you *visit* and a project to run — a box, containers, YAML, a dashboard you have to build.

Nobody has combined iStat's polish with arbitrary extensibility and a genuinely good cross-platform notification layer.

### Who it's for

The **Mac user next to the self-hoster** — knows the person running 200 containers, wants the *outcomes* of self-hosting without Proxmox, docker-compose, or a YAML hobby. The 95% who want what tooling produces, not the tooling itself. (The same productize-the-outcome move Plex made over "run a media server" and Obsidian made over "live in a text editor.")

### The lineage

We're standing on three proven models, not inventing from scratch:

- **iStat Menus** — the ambient menubar surface we extend.
- **Raycast** — closed, polished app; open, community-written extensions; a store; a Pro tier. The exact open/closed shape that built a real ecosystem people pay for.
- **Plex** — a self-hosted engine most users don't even realize they're running, that quietly graduates power users to a dedicated box, monetized by the one hard-to-self-host feature.

Home Assistant is the powerful-but-it's-a-project foil — and can simply be one of our integrations. (The current rush to cram every capability into an AI chatbox is our opening, not our model: for a *known* action, a button beats "please close my garage" and hoping an agent picks the right tool. AI belongs *behind* the controls, not in front.)

---

## How it works — the engine

The whole product is one idea: **an engine that normalizes your connected things, and thin native faces that surface them.**

**Engine + thin clients.** A single headless engine holds credentials, runs the poll/subscribe loops, normalizes everything into a common model, and runs the alerting. The menubar app, the iOS app, and any future client are thin faces that just render what the engine exposes and send it commands. This is Home Assistant's *shape* — a core plus clients — without the destination-dashboard UX.

**One data model: state + commands.** Every device — gl.inet, Ubiquiti, Tesla, Starlink, a ping target — collapses to the same shape: something that polls or subscribes, emits **typed state** (metrics you read), and optionally exposes **commands** (actions you fire). Monitoring and control are the same primitive seen from two sides. Widgets bind to state; alerts watch state; neither knows or cares what produced it. That decoupling *is* the platform.

**Plex-style progressive disclosure — the engine moves without a rewrite.** v1, the engine runs invisibly *inside* the Mac app: double-click, sign into your devices, done — it watches while your Mac is awake. The moment you want 24/7, the same engine lifts onto an always-on box (a spare Mac, a Linux server) with no code change — the menubar app just points at it instead of itself. Most people never know they're "hosting" anything until they choose to graduate. On iOS the engine runs best-effort for a few modules; reliable always-on watching comes from the box or the relay (and that limit is exactly what makes the relay worth paying for).

**Extensions: declarative first, code as escape hatch.** An integration is ~90% a manifest — endpoint, auth, poll interval, which fields map to which metrics, the widget layout, the default alerts. Only the occasional gnarly transform needs a small sandboxed JS function. Two payoffs: anyone can write one without Swift, and because it's data + JS (not compiled native), **the same extension runs on macOS and iOS from one definition.** Extensions span the spectrum from a one-button micro-integration ("close the garage") to a full Starlink monitoring panel.

**Credentials are the host's job.** The painful 80% of any integration is auth — OAuth, local pairing, token refresh, 2FA quirks. The engine owns a reusable credential system that extensions just declare against. This removes the hardest part of contributing and is where trust lives: scoped per-module, local-first, auditable.

**Transport is a message bus, not a VPN.** It's just small messages, so the phone and the engine each connect *out* to a lightweight broker with end-to-end-encrypted payloads — which sails through home NATs with no port-forwarding and lets the broker see only ciphertext. (A self-hosted mesh-VPN option exists for power users who want to reach their whole box, but the product doesn't need it.)

**The notification engine is the real product.** A rules layer over the metric streams — thresholds, rate-of-change, state transitions, sustained-for-N — shared across every platform, with natural-language rule authoring. "Tune notifications far better than iStat or HA," *reliably*, is the thing people will actually pay for. AI also works behind the scenes: anomaly detection, and generating new integration manifests straight from a vendor's API docs.

**Metering, built in from day one.** Per-module usage is measured both to budget against iOS's battery limits and as the unit the business model is priced on.

---

### Business model (Obsidian / Raycast / Plex)

Open engine + open extensions; closed, polished native apps. Free local tier where your creds never leave your hardware. **Pro = the 24/7 cloud relay that watches your stuff and pings you** — the single thing that's genuinely hard to self-host, so it's a fair trade, not a paywall on basics.

### Moat

Not the integrations — those are commodity and community-owned on purpose. The platform is the moat: the engine, the cross-platform notification engine, the trust model (scoped creds, local-first, auditable, *you* press the button), and the UX. Give the integrations away; own the platform.

### v1 (ruthless)

macOS app + embedded engine + **10 integrations on stable/local APIs** (gl.inet, Ubiquiti, Starlink, Tesla, EcoFlow, ping) at 100% polish. Ten flawless beat fifty flaky — the category's graveyard is full of frameworks that did everything at 70%. Then iOS + the relay. The likely failure mode is scope, not skill.

### The real risks

Vendor hostility (MyQ-style cutoffs — bias the spine toward local/stable APIs you can't be evicted from), the endless O(N) maintenance of integrations that break forever, solo scope across what is really ~5 products, and a cold-start with no Plex-style social virality (device control is solo — nobody shares "my Tesla and my router"). None fatal, all worth designing around early.

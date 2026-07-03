# Ambit — Product Spec

**Name:** Ambit — the scope of what's yours, glanceable and in reach. (Ships as `ambit.app`; B2B namesakes exist but none in-category, no App Store clash.)
**Tagline:** Everything within your ambit.
**Subtitle:** Ambient device control & monitoring platform.
**Status:** Early ideation, pre-build. Captured from initial brainstorming.
**Author:** k
**Date:** 2026-06-19

---

## One-liner

A self-hosted engine plus polished, closed-source native apps that let you **monitor and control all your connected things — routers, ISPs, VPNs, EVs, power stations, smart-home gear — from ambient surfaces (menubar, Lock Screen, widgets) instead of fifteen separate vendor apps.** Deterministic and direct, not conversational and agentic.

The shortest framing reached in ideation: **"OpenClaw for your devices, minus the chat and minus the autonomy you didn't ask for."**

---

## Problem

Every connected device and cloud service ships its own bloated app, and each one jails a single useful action behind a full app launch. Opening the MyQ app just to close a garage door. The Tesla app just to precondition. A separate app per router, per VPN, per power station. The pain is twofold: too many single-purpose apps, and no single ambient place to glance at state or fire one action.

Existing menubar utilities (iStat Menus) nail the *ambient glance* but are closed and inextensible. Self-hosting platforms (Home Assistant) are powerful but are a *project* — a box, containers, YAML, a dashboard you have to lovingly build and then *visit*. There is no tool that combines iStat's ambient polish with arbitrary extensibility and a genuinely good cross-platform notification layer, aimed at people who want the *outcomes* of self-hosting without the sysadmin lifestyle.

Prior art that proves the appetite: the author has already built **pingscope** (network/ping monitoring) and **glinet-travel** (gl.inet + Starlink + Speedify + EcoFlow in one menubar app). The framework is the pattern those two share, written a third time deliberately.

---

## Target user (ICP)

The **technical prosumer adjacent to a self-hoster** — the Mac user who knows the person running 200 dashboards and containers, wants to simplify their connected life, but does **not** want to run Proxmox, learn docker-compose, or spend their life on tooling. They feel the "fifteen vendor apps" pain acutely and would happily pay to delete those apps and never touch a compose file.

This is a wide, underserved middle. The enthusiast who loves tooling for its own sake is ~5% of the people who want what tooling *produces*. We serve the other 95%. (Reference pattern: Plex over "run a media server," Tailscale over "configure WireGuard," Obsidian over "live in a text editor" — productize the prosumer outcome.)

Marketable promise: **"Delete 15 single-purpose apps."**

---

## Positioning & competitive landscape

The moat is **never the integrations** — those are commodity and will be community-owned by design. The moat is the platform: the engine, the cross-platform notification engine, the ambient UX, and the trust model. Give the integrations away; own the platform.

**Home Assistant** — a *destination you visit*; home-automation-shaped (lights/locks/rooms); a project to run. We are *ambient* (live where you already are), infra/mobility-shaped (networking, ISPs, VPNs, EVs, power), and an *app* not a project. Do **not** try to out-breadth HA — that race is lost. HA can even be one of our integrations.

**Raycast** — owns "icon + dropdown of info + quick action, with a store" (Menu Bar Commands, MIT-licensed open extensions, closed app). But its menubar is a *menu, not a widget* (no custom canvas/sparklines), its background refresh is ephemeral and coarse (not a real engine), and **extensions don't run on iOS at all** — the iOS app only Cloud-Syncs a few data types. No always-on engine, no cross-platform integration execution.

**SwiftBar / xbar** — free, open-source, extensible menubar with a plugin community (the exact "extensible menubar + store" pitch). But it's a *script-runner*, not an engine: every plugin re-invents auth/polling statelessly on a coarse interval; text/menu output not rich widgets; Mac-only; built *for* the tooling person — the opposite of our ICP. Cautionary tale: it's existed for years, free, and stayed a developer niche. **Extensibility itself is not a product or a moat.**

**Homey** — the established commercial "HA without the project," app store and polish, but hub-shaped (a box / an app), not an ambient cross-platform surface.

**OpenClaw (formerly Clawdbot → Moltbot)** — viral (86k+ stars in months) self-hosted, local-first autonomous assistant that connects AI to your existing *messaging apps* and acts on your behalf. **Validates our architecture** (self-hosted engine that "actually does things" has explosive demand) but is our exact **interface foil**: it routes everything through chat + autonomous tool-picking — the latency / ambiguity / wrong-tool failure mode we reject. Security researchers (Resecurity, Palo Alto) are already calling the autonomous-agent-with-broad-access model a looming security crisis — which is a tailwind for our scoped, deterministic, human-in-control model.

**Apple (Shortcuts / Home / Matter / Control Center controls / Action button)** — the platform owner is walking into this lane. Real Sherlock risk. We win on extensibility, rich ambient widgets, a real engine, and cross-platform breadth Apple won't prioritize.

**The wedge that no incumbent holds:** rich glanceable widgets + a genuine always-on engine + cross-platform native surfaces + a great notification engine + deterministic (not agentic) control. The always-on cross-platform engine is the unbuilt piece nobody touches — see Architecture and Risks for *why*.

---

## Design tenets

1. **Direct over indirect.** For *known* actions, an LLM between intent and action is pure downside (latency, ambiguity, wrong-tool failure). A garage button beats "please close my garage." Anti-chat-*default*, not anti-AI.
2. **AI behind the controls, not in front.** Use AI where the indirection earns its risk: anomaly detection, natural-language *authoring* of alert rules, open-ended queries ("was my Starlink worse this week?"), and — critically — **AI-assisted module authoring** (point a model at a vendor's API docs, get a manifest), which attacks the O(N) maintenance treadmill.
3. **Local-first, self-hosted.** Credentials stay on the user's hardware. Trust is the product when you hold keys to someone's car, home, and network.
4. **Deterministic & scoped.** Each control fires exactly one known action with one module's scoped credentials. The human acts. This is the structural security advantage over autonomous agents.
5. **Ambient, not a destination.** Live in the menubar, Lock Screen, widgets, Control Center — where the user already is. A dashboard-you-open is the HA model we reject.
6. **Open interface, not federation.** Open protocol so third-party clients/engines interoperate. We explicitly do **not** want Matrix-style server-to-server federation — the engine is single-user; that complexity buys us nothing.
7. **Integrations are commodity; the platform is the moat.** Open the engine and extension format; the value is the apps, the relay, the brand, the notification engine.

---

## Architecture

### Engine + thin clients

One headless **engine** holds credentials, runs the poll/subscribe loops, normalizes data, and runs the alerting engine. Everything else is a **thin client** (Mac menubar, iOS app, future Windows tray, etc.) that talks to the engine over a defined interface. (This is the Home Assistant *shape* — core + thin clients — without the destination-dashboard UX.)

**Design principle from day one:** the engine is a *separable module* even while embedded. v1 ships with the engine running in-process inside the Mac app (double-click, zero setup), but it talks across a clean boundary so it can later be lifted into a standalone daemon **with no rewrite**. Fusing the engine into AppKit UI would be the cardinal mistake.

### Three deployment tiers (one engine, "Plex" progressive disclosure)

Most users won't know they're "hosting" anything — like Plex users who never realize they run a server until they graduate to a NAS.

- **Tier 0 — Embedded in the Mac app.** Invisible engine, runs while the Mac is awake. Zero-friction on-ramp. (Caveat: polling stops when the Mac sleeps — which is itself the nudge toward Tier 1.)
- **Tier 1 — Dedicated always-on box.** The "Plex-NAS moment." Reliable 24/7. Graduating here is a *migration*, not a rebuild.
- **Tier 2 — iOS as best-effort lightweight engine** when no box is present. **Hard-limited by Apple, not by us** — no real background execution; only opportunistic refresh + foreground polling. We *lean into* the limitation as the upsell boundary, never overselling that the phone watches everything in the background (that's churn for an alerting product).

### Transport — a message bus, not a VPN

It's just message passing (small JSON, no media), so a full mesh VPN is overkill. Preferred v1: engine and client both make **outbound** connections to a lightweight broker (MQTT / WebSocket / NATS) with **end-to-end-encrypted payloads** — outbound traversal sidesteps NAT entirely, the broker sees only ciphertext, and it's cheap to run. WireGuard is *not* the easy path: its data plane is trivial but the control plane (NAT traversal, key distribution, peer discovery, relay fallback) is the actual work. Offer a mesh-VPN option — ideally **Headscale** (self-hosted Tailscale control server; the magic without the vendor bill, possibly embeddable via `tsnet`) — as the *power-user* tier for people who also want to reach arbitrary services on their box. **Message bus for the product; optional mesh VPN for tinkerers.**

### Normalized data model

Everything (gl.inet, Ubiquiti, Tesla, Starlink, ping) collapses to one shape: a thing that polls/subscribes, emits **typed state/metrics**, and optionally exposes **commands/actions**. Widgets bind to metrics; alerts watch metrics; neither knows or cares what produced them. That decoupling is the product.

**Harvest the abstraction, don't predict it.** Write 5–10 integrations the dumb, hardcoded way first (two data points already exist in pingscope + glinet-travel), then extract the framework from what actually repeats. Predicted abstractions leak; harvested ones fit.

### Credential / auth framework (host-owned)

The painful 80% of every integration is auth — OAuth, local pairing, token refresh, 2FA quirks. The *host* provides a reusable credential/auth system extensions declare against. This removes the hardest part of contributing and is where trust lives.

### Metering

Per-module usage metering, built early. Double duty: (1) budgeting work against iOS's battery/background limits, and (2) the **monetization unit** (free = N module-units; Pro = more / hosted relay). Retrofitting a meter later is miserable.

---

## Extensibility model

**Declarative-first, code-as-escape-hatch.** Most integrations are ~90% declarative: endpoint, auth, poll interval, field→metric mapping, widget layout, default alerts — a *manifest*, not a program. A small **sandboxed JS** function is available only when a transform is too gnarly for declarative mapping. The host provides capabilities (HTTP, storage, render, notify); extensions can't reach outside them.

This wins three things at once: contributors write YAML not Swift (community), it runs identically on iOS and macOS via JavaScriptCore (cross-platform — precedent: Scriptable), and it threads the App Store rule against downloading feature-changing code (extensions call documented host APIs, not arbitrary native code).

**Spectrum of extension size:** from a one-button micro-extension ("close MyQ garage") up to a full Starlink monitoring panel. Lower barrier = more community.

**Compiled native is rejected** as the extension format — it would mean first-party-only, which is a roadmap, not an ecosystem. Swift is the *shell*, not the extension language.

**Why not just port Raycast extensions?** They're TS/React against `@raycast/api`, not declarative config — porting means building a compatibility shim and rewriting UI. But the MIT-licensed repo is an invaluable **reference library** for *how to auth and talk to hundreds of services* — read it as documentation-by-example, not a parts bin.

### The open / closed line

Mirrors Raycast (open extensions / closed app), Beeper (open Matrix protocol / closed client), Obsidian, Plex.

- **Open:** engine core, extension format/SDK, possibly one reference client (so the protocol is real and auditable — auditability is a *trust* feature when we hold device credentials).
- **Closed:** all native apps, the hosted Pro relay, the curated module registry.

Risk to respect: open-sourcing the engine commoditizes it. The moat *must* be the apps + relay + brand + curation. Don't open-source so much (e.g. an excellent free web client) that there's no reason to pay or to choose our app over a forker's.

---

## Alerting / notification engine

Arguably the real product and the place we beat everyone. A rules engine over metric streams, shared across platforms: thresholds, rate-of-change, state transitions, sustained-for-N-duration, and AI-assisted/natural-language rule authoring. "Tune notifications far greater" than iStat or HA — and reliably, via the always-on engine, is the thing people will pay for.

---

## Surfaces

- **macOS (v1):** menubar widgets (rich, glanceable — the iStat aesthetic) + quick actions + command palette.
- **iOS (v2):** app + Home Screen widgets + Lock Screen controls + Control Center + Action button + Live Activities. Best-effort engine; reliable monitoring comes from the box/relay.
- **Web (later, narrow role):** onboarding/config + remote read-only viewport only. **Never the hero** — a web dashboard is the HA "destination" model we differentiate against, and over-investing here reinvents worse-HA and gives it away free.
- **Windows tray / Android (future):** new thin clients against the same engine; **every existing integration works for free** because integrations are JS/manifest. The engine is trivially portable; only the native ambient *faces* are per-platform work.

---

## Business model

Hybrid of **Obsidian / Raycast / Plex**: open engine + extensions, closed apps, free local tier, paid Pro.

- **Free:** local engine (embedded in Mac app), N module-units, your-creds-stay-home.
- **Pro:** hosted cloud relay (24/7 watching for users without a box), remote alerting/push, more module-units, cross-device sync. The thing people pay for is "watch my stuff 24/7 and ping me" — the hardest thing to self-host, so it's a fair trade, not a paywall on basics.
- **Metering** is the paywall unit (see Architecture).
- **Funnel:** Plex-style *gateway drug* — start with 5 invisible-engine integrations on the Mac → more modules → a dedicated box → Pro relay.

**Honest gap:** Plex had built-in *social* virality (share your library). Device control is solo — nobody shares "my Tesla and my router." Our funnel is a *depth* funnel (more modules → box → Pro), which is slower and quieter, with no free word-of-mouth. Open question: is there *any* social/discovery vector (public module registry to browse, shareable dashboard configs, household/multi-user)?

---

## Trust & security model

Trust is the central challenge — the value requires the user's *most* sensitive credentials (car, home, network). Our structural advantages vs. the autonomous-agent model (OpenClaw):

- **Scoped, per-module credentials** — not one agent with the keys to everything.
- **Deterministic actions** — each control does one known thing; the human initiates. No LLM deciding what to do with broad access.
- **Local-first** — creds on the user's hardware; nothing in our cloud in the free/self-hosted tier.
- **Open, auditable engine** — you can read exactly what touches your tokens.
- **Action guardrails** — confirmation on consequential commands (fire a Tesla command, open a garage).

The industry's emerging "autonomous AI butler is a security crisis" narrative is a leading indicator *for* this positioning: "scoped, deterministic, you're always the one acting" looks like the adults arriving.

---

## Roadmap & sequencing

**v1 (focus, ruthlessly scoped):** macOS app with embedded engine; ~10 integrations on *stable/local* APIs; a few hero rich widgets; the credential framework; basic alerting; metering built in. Ship the engine behind a clean boundary.

**v2:** iOS client (widgets / Lock Screen / Control Center / Live Activities); the hosted Pro relay; remote alerting.

**v3:** standalone daemon for the dedicated box (Headscale/mesh option); open the extension SDK + curated registry/store; AI-assisted module authoring.

**Later:** Windows tray / Android clients; optional web viewport.

**Explicit v1 non-goals:** federation; a great free web client; Windows/Android; cloud-hosted execution of others' code; breadth-racing Home Assistant; agentic/chat interface.

**v1 discipline:** 10 integrations at 100% polish beats 50 at 70%. The category's graveyard is full of frameworks that did everything at 70%. The likely failure mode is *scope*, not skill.

---

## Candidate first integrations

Bias hard toward **stable or local APIs that can't lock us out**:

- gl.inet (local API)
- Ubiquiti / UniFi (local API)
- Starlink (local endpoint)
- Tesla (real API)
- EcoFlow
- Speedify / generic VPN
- Ping / network monitoring (pingscope)
- Home Assistant bridge (sit on top of the HA crowd)
- Pi-hole / AdGuard, Proxmox, NAS, UPS — natural self-hoster-adjacent additions

**Second tier / "nice when it works" / PR spikes only:** hostile cloud-only vendors (MyQ being the canonical example — Chamberlain has repeatedly cut off third parties). Never load-bearing for a demo. A doomed hostile integration can be worth building purely as a *publicity* play (cf. Beeper Mini's shutdown generating the attention that contributed to acquisition) — but as a spike, never the spine.

---

## Risks & open questions

**Risks**
- **Vendor hostility / API rot** (MyQ, Beeper Mini killed by Apple). Mitigation: local/stable APIs as the spine.
- **O(N) maintenance treadmill** — integrations break forever; this is the real lifetime cost, not the framework architecture.
- **Cold-start with no social virality** — every user is a paid acquisition; depth funnel only.
- **Apple Sherlock risk** — the platform owner is in this lane.
- **Solo scope** — this is potentially five products (Mac, iOS, engine, auth framework, notification engine, relay, store). Being mediocre at all of them loses to focused incumbents. Sequence brutally.
- **"Empty room" ambiguity** — incumbents avoid the always-on engine because for *them* it's a money-losing, off-strategy, liability-heavy cost center (hosting everyone's creds + running their code centrally). The *only* configuration where the unit economics close is **self-hosted-first** (the user's box pays for the polling). Drifting toward "we host everyone's stuff" turns us into the bad business they correctly declined.
- **Fighting the tide vs. early** — the ICP is *currently* enchanted by the chat-agent paradigm (OpenClaw) we bet against. The wager: chat-agent fatigue + the emerging security backlash swing people back toward deterministic, ambient control. A real bet, made on purpose.

**Open questions / pending decisions**
- Product **name**.
- Exact **open/closed line** (how much of the engine, which reference client).
- Transport: **BYO-Tailscale account vs. hosted broker vs. Headscale** for v1.
- Any **social/discovery vector** to offset the solo cold-start.
- The single **hero demo** to build everything around (candidate: glance at menubar → Starlink degradation alert → one-click failover; or close the garage from the Lock Screen without ever opening the vendor app).
- Whether to **validate as a parasite first** (a Raycast extension pack / SwiftBar plugins) before committing to the full platform — if it can't get traction renting an ecosystem, that's signal.

---

## Decision log (settled in ideation)

- Engine + thin-client architecture; engine separable from day one, embedded in the Mac app for v1.
- Three deployment tiers (embedded Mac / dedicated box / best-effort iOS), Plex-style progressive disclosure.
- Extension format is **declarative-first manifest + sandboxed JS escape hatch**, runs cross-platform via JSC. Compiled-native rejected.
- Open engine + extensions / closed apps + relay + registry (Raycast/Beeper/Obsidian model).
- Business model: free local tier, Pro = hosted relay + remote alerting + more module-units; metering as the unit.
- Transport: message bus (E2E-encrypted broker) as default; mesh VPN/Headscale as power-user option. No federation.
- Positioning: ambient + deterministic + cross-platform; *not* a destination dashboard, *not* a chat/agent. "OpenClaw for devices, minus the chat and the unwanted autonomy."
- macOS first, then iOS. Integrations biased to stable/local APIs.
- Author writes the first ~20–50 integrations to prove the format.

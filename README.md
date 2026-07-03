# Ambit

**An extensible, self-hosted monitoring/control engine + polished native apps** that put every connected
thing — routers, ISPs, Starlink, VPNs, power stations, local system stats — into ambient, glanceable
surfaces (macOS menu bar today; iOS widgets/Live Activity later) instead of one vendor app per device.
*"iStat Menus you can extend" / "Homebridge meets Raycast."* Deterministic buttons over chatboxes; AI
behind the controls, never in front. See `docs/pitch.md` and `docs/product-spec.md` for the full framing.

## State of the code (2026-07-03)

**Working today:** a macOS menu-bar app (macOS 13+, Swift 6, SwiftPM-only) with two live integrations —
`ping` (multi-host TCP/UDP/ICMP latency monitoring with topology diagnosis, PingScope parity) and
`system` (iStat-class CPU/memory/disk/network/battery/processes/sensors dashboard) — rendering entirely
through a **generic entity → attention → card-vocabulary pipeline with zero integration-specific UI**
(enforced by a grep-gate test). Slot-driven menu-bar items with attention-ranked readouts, popovers,
floating overlay, SQLite history with honest failure-aware graphs and export, entity-targeted quiet-by-
default notifications, and a full **automation engine**: generic condition trees, reactions (notify /
mutate-surface / run-command / Shortcuts / App Intents), user-authored rules, and stackable **contexts**
(Home/Work/Travel-style overlays driven by SSID, location, calendar, and Focus signals). Behavior is
locked by ~745 test functions including frozen golden fixtures, differential and migration tests.

**Seeded but disabled, pending rebuild against the proven generic shape:** glinet, speedify, starlink,
ecoflow, reachability, iperf3 (all blocked on a secure-credential config field).

**Designed, not built:** the Settings UX redesign (`docs/ux/v0/spec.md` Part A), multi-engine topology
(`docs/engine-topology.md`), Sparkle auto-update, iOS.

All documentation lives in `docs/`. The single best entry point is **`docs/spec-v2.md`** — a comprehensive
synthesis of the product, the domain model, every implemented behavior, known architectural debt, and
rearchitecture guidance. `docs/HANDOFF.md` is the running project map.

## Layout

| Target | What |
|---|---|
| `AmbitCore` | UI-free engine (Linux-capable): identity, entity model, registry, poll loop, history, alerting, condition/reaction/rule/context engines, attention, surface composer, manifest providers |
| `AmbitUI` | SwiftUI card vocabulary + chrome (iOS-ready) |
| `AmbitMenuBar` → `Ambit` | the menu-bar app: status items, popovers, overlay, settings, notifications, App Intents |
| `AmbitCheck` → `ambit-check` | headless CLI: probes, manifest validation/execution, usage metering; proves Core is UI-free |

## Build & run

```sh
swift build && swift test          # the gate; must stay green after every step
bash .claude/skills/run-ambit/launch.sh   # build, bundle, codesign, open Ambit.app
```

`swift run Ambit` **crashes by design** (no app bundle ⇒ UNUserNotificationCenter fails) — always use the
launch script, which also sets `LSUIElement`, `NSAppSleepDisabled` (App Nap otherwise freezes polling),
privacy entitlements (location-gated SSID on macOS 14.4+, calendars, network), and the App Intents
metadata pass. Set `AMBIT_CODESIGN_IDENTITY` for a stable signing identity so TCC grants survive rebuilds.
See `.claude/skills/run-ambit/SKILL.md` for verification recipes and gotchas.

## Conventions

Green after every step, one small commit per step; AmbitCore stays UI-free; no `EngineID` in any
entity/instance ID; no integration-specific UI (gaps become new generic primitives); never edit the donor
repos (`~/src/pingscope`, `~/src/glinet-travel`); harvest from shipped code, don't design in the abstract.
Full list in `docs/HANDOFF.md` §8.

# Evaluation of Ambit v0

Audit date 2026-11-20. Subject: branch `archive/v0` (commit `de3db56`), 352 commits from 2026-06-19 to
2026-07-03, 44.6k lines of Swift (26.5k source, ~18k tests), ~14k lines of planning docs, zero releases.
Seven independent reviews: product, architecture, UX, engine code, app and ship-readiness, history, market.

## Verdict

v0 is a well-tested generic monitoring framework with two integrations (ping, system stats) that free or
already-shipped apps cover, and no way to reach a user. It is a parts bin. Restarting is correct.

## Why it did not ship

1. **No release milestone ever existed.** The roadmap has 14 completed items; none is a release. Sparkle sat
   last in every sequencing list.
2. **Generality became the goal.** On day 2 the app had seven working device integrations seeded from
   `glinet-travel`. On day 4 all were disabled "to be rebuilt against the proven generic shape". Their UI
   (3,182 lines) was deleted. They never came back.
3. **A one-field blocker was skipped five times.** Device integrations needed a secret config field. It was
   flagged on 06-27 and still open on 07-03, while rules, contexts and App Intents were built. Three of the
   six disabled integrations needed no secret at all.
4. **Product identity changed four times:** device control app, PingScope clone, iStat clone, automation
   platform.
5. **Parity and purity work looked like progress.** One 23-commit milestone moved ping logic into generic
   engines with byte-identical fixtures and a grep gate; user-visible gain was zero.
6. **The stated v1 was too big:** "10 integrations at 100% polish" for a solo developer.

The docs predicted this: "The likely failure mode is scope, not skill" (`docs/pitch.md` in the archive).

## Product

- Twenty-one distinct promises, from menu-bar monitoring to a cloud relay, iOS, a store and AI features.
- Three different things are named "the real product": notifications, the state/command model, attention.
- The stated user refuses YAML; the extension model was YAML. Users and authors were never separated.
- The business model (free app, paid cloud relay) needs four unbuilt products before any revenue.
- No price, launch definition, distribution channel or success metric anywhere.
- No evidence of any external user.

## Architecture

| Area | Finding | v1 |
|---|---|---|
| Descriptor/state split, stale-is-not-down, probe timeouts | Real correctness wins | Keep the ideas |
| Five-level deterministic IDs | Bent around unbuilt multi-engine failover; editing a host orphans its history | Opaque UUIDs |
| Capability taxonomy (~35 kinds) | No consumers | Cut |
| Generic card composer | "600-line rule engine" with name-token matching | Cut; hand-built views |
| Alerting | Four coexisting stacks | One |
| Rules, contexts, reactions | 3.5k lines; built before an add-host button | Cut |
| JSON manifests | 1.4k lines; zero app call sites | Cut |
| Multi-engine, relay, metering | Designed only, but constrains IDs and layering | Cut |
| Linux-capable core | Does not compile on Linux | Drop the claim |

About 80% of the 17.6k-line engine is framework for integrations that were switched off.

## Code and ship-readiness

- `swift build` clean, zero warnings. `swift test`: 696 run, 16 fail on a clean machine (a Starlink test
  needs Homebrew `grpcurl`). The README claimed ~745 green.
- Zero external dependencies; honest Swift 6 concurrency. Good.
- God objects: `StatusViewModel.swift` 1,803 lines, `AmbitSettings.swift` 2,053, `Engine.swift` 828 with a
  19-parameter init.
- Bugs: CPU % is the average since boot (no delta); popover controls are wired to no-op closures; the poll
  loop is sequential, so one slow device delays all.
- Security: router password passed on `openssl` argv (visible in `ps`); manifests could send credentials to
  any URL; Keychain service still named after the donor app.
- Shippable checklist: about 3 of 30. Missing: Release build, Developer ID signing, hardened runtime,
  notarization, DMG, Sparkle, icon, version numbers, CI, onboarding, light mode, accessibility,
  `NSLocalNetworkUsageDescription`.

## UX

- First run is the best part: data in seconds with zero steps.
- There is no "+" anywhere. Adding a host means overwriting an existing host's form and pressing "Add".
- Engine vocabulary leaks: slots, entities, primary, pin/show/visibility, dwell, contexts, raw IDs.
- Alerts are configured in four places; visibility in three.
- Dark-only popover, no design language, no app icon.

## Market (web research, 2026-11-20)

- System stats: Stats is free (43.5k stars), iStat Menus is $11.99. Not a wedge.
- Ping in the menu bar: many $0-5 apps with no visible traction. A feature, not a product.
- Extensible platforms (xbar, SwiftBar, Raycast): free and developer-only; nobody earns from platform alone.
- Single-device apps exist and charge: StarBar ($19/yr), Glint for GL.iNet ($9.99). No app combines dish,
  router and power in one view. Demand for that combined view is plausible but unverified.
- Mac App Store is a poor fit (sandbox blocks `/sbin/ping`, Homebrew tools, SMC). Direct distribution.

## What carries forward

About 2,100 lines of engine code and 1,000 lines of UI code are worth copying, plus device clients as
protocol references. See [06-harvest.md](06-harvest.md).

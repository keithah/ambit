# Product spec: Ambit v1

## One sentence

Ambit puts your dish, router and battery in the Mac menu bar and tells you which one is the problem.

## User

Someone who works from a Mac behind a self-assembled connection: Starlink (often Mini), a GL.iNet travel
router, a battery. RV, van, boat, cabin, field work, or a house on Starlink. Today they open three vendor
apps or web pages to answer one question. The first user is Keith; v1 is done when strangers with the same
kit can install it.

## Job

"Tell me at a glance whether I am online, through what, how good it is, how long the power lasts, and when
something breaks, which box to blame."

## v1 scope (frozen 2026-11-20)

| Area | In v1 |
|---|---|
| Diagnosis | Latency to Wi-Fi gateway, router, internet targets; verdict naming the failing hop; 24 h history |
| Starlink | Online state, down/up throughput, latency, obstruction, outages; reboot, stow/unstow |
| GL.iNet | Reachability, client count, WAN type, VPN state; VPN on/off |
| PeakDo LinkPower | Battery %, in/out watts, time left; DC and USB-C output on/off (Bluetooth) |
| Ping targets | User-added hosts feeding the diagnosis |
| Alerts | Offline for 30 s (names the hop), back online, low battery. Toggles only |
| Menu bar | One combined item by default; any device can be pinned as its own item |
| Setup | Auto-discovery of devices on the LAN and nearby; add-device sheet; password in Keychain |
| Release | Signed, notarized DMG; Sparkle auto-update; GitHub Releases; MIT source |

Controls are limited to the toggles above, each behind a confirmation.

## Non-goals for v1

System stats, Tesla, Speedify, EcoFlow, UniFi, plugins or any extension API, user-authored rules, contexts,
Shortcuts/App Intents, floating overlay, history export, iOS, widgets, cloud relay, accounts, payments,
Mac App Store, localization.

## After v1 (ordered, each its own release)

1. v1.1: "This Mac" section (CPU, memory, disk, network, battery), compact.
2. v1.2: Tesla via a user-supplied Tessie token.
3. Then by user request: Speedify, EcoFlow, UniFi, Peplink.
4. Pricing decision once there are 50 weekly active installs. Extension API only after three outside
   requests to add a device.

## Positioning

- Not a system monitor (Stats and iStat Menus own that).
- Not a ping tool (PingScope is Keith's own; Ambit's diagnosis is one row, not the product).
- Not a platform. Devices are first-party Swift.
- The claim: the only app showing dish, router and battery together, with fault location.

## Distribution and price

Free during beta. Direct download from GitHub Releases, Sparkle updates. Bundle ID `com.hadm.ambit`.
macOS 14 or later, Apple silicon and Intel.

## Success measures

- 2026-12-20: v1.0.0 public, installable by a stranger in under two minutes.
- Three people who are not Keith running it by end of week 2.
- 30 days after launch: 25 installs still checking the appcast weekly (the only telemetry: appcast hits).

## Risks

| Risk | Response |
|---|---|
| LinkPower 3 firmware deviates from the documented BLE protocol | One-day GATT check in week 1; if it fails, LinkPower slips to v1.1 |
| Starlink needs gRPC without Homebrew `grpcurl` | Week-1 spike with grpc-swift; fallback is bundling a signed `grpcurl` |
| macOS Local Network permission is flaky | Prime before the prompt; show a clear "permission needed" state |
| Small market | Accepted. v1 exists to ship and learn |
| Scope creep | Guardrails in `CLAUDE.md`; weekly releases; kill criteria in the plan |

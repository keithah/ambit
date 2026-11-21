# Project plan: Ambit v1

Start Monday 2026-11-23. Public v1.0.0 on Sunday 2026-12-20. Every week ends with a tagged, notarized,
auto-updating release. Scope is in [02-product.md](02-product.md); rules are in `../CLAUDE.md`.

## Week 1 (Nov 23-29): pipeline first, then diagnosis. Release v0.1.0

| # | Task | Done when |
|---|---|---|
| 1.1 | Xcode app target + `AmbitKit` package, `make build/test`, GitHub Actions | CI green on push |
| 1.2 | **Release pipeline**: Developer ID sign, notarize, DMG, Sparkle appcast on GitHub Pages, `make release` | An empty menu-bar app updates itself from 0.0.1 to 0.0.2 on a second Mac |
| 1.3 | Spike A (half day): LinkPower 3 GATT dump against the documented protocol | Yes/no recorded in decisions.md |
| 1.4 | Spike B (one day): Starlink status over grpc-swift, no `grpcurl` | Dish status printed from a test |
| 1.5 | Diagnosis: probes, hop model, verdict, SQLite history, popover header + graph | Popover says "Online" or names the failing hop |
| 1.6 | Offline / back-online alerts | Pulling the WAN cable produces one correct notification |

Tasks 1.1 and 1.2 come before any feature code. Keith: confirm the Developer ID certificate is in the
login keychain, create an app-specific password for `notarytool`, enable GitHub Pages.

## Week 2 (Nov 30-Dec 6): Starlink and GL.iNet. Release v0.2.0

| # | Task | Done when |
|---|---|---|
| 2.1 | Starlink client, row, detail view, reboot and stow with confirmation | Matches the Starlink app's numbers |
| 2.2 | Keychain store + GL.iNet client (in-process password hash), row, detail, VPN toggle | VPN toggles from the popover |
| 2.3 | Add-device sheet with discovery and password entry | Both devices added without typing an address |
| 2.4 | Device states: stale, unreachable, wrong password, permission needed | Each state reachable by hand and readable |
| 2.5 | **Three outside users** install v0.2.0 | Three names in decisions.md |

## Week 3 (Dec 7-13): LinkPower, menu bar, alerts. Release v0.3.0

| # | Task | Done when |
|---|---|---|
| 3.1 | LinkPower over CoreBluetooth: battery, watts, time left, output toggles | Readings match the PeakDo web app |
| 3.2 | Menu bar readout picker; pin a device as its own item | Combined and split both work across relaunch |
| 3.3 | Low-battery alert; "Copy report"; "Mute 1 hour" | Report pastes as readable text |
| 3.4 | Settings window (General, Devices, Alerts) | No setting exists anywhere else |
| 3.5 | Fix what the three outside users reported | Their top issue each is closed |

If spike A failed, 3.1 is replaced by fixing user-reported issues and LinkPower moves to v1.1.

## Week 4 (Dec 14-20): finish. Release v1.0.0

| # | Task | Done when |
|---|---|---|
| 4.1 | First-run card and permission priming | Clean Mac to working popover in under two minutes |
| 4.2 | App icon, menu-bar glyph, light/dark pass, VoiceOver pass | Checked on both appearances |
| 4.3 | Landing page on GitHub Pages: one screenshot, one sentence, download button | Page live |
| 4.4 | README with screenshots, privacy note, known limits | Published |
| 4.5 | Feature freeze Thursday Dec 17; bug fixes only after | v1.0.0 tagged Dec 20 |
| 4.6 | Announce: GL.iNet forum, r/Starlink, r/StarlinkMini | Posts live |

## Kill criteria

- A week ends without a tagged release: stop feature work, cut that week's remaining scope, release what
  works within 48 hours.
- A device is not working by the end of its week: it moves to a point release. The date does not move.
- Any task grows past three days: split it or drop it, and write one line in decisions.md.
- Urge to build something on the banned list: write it in "After v1" instead.

## After v1

v1.1 "This Mac" stats (one week). v1.2 Tesla via Tessie token (one week). Then devices by request.
Revisit pricing at 50 weekly active installs.

## What Keith owns

Developer ID and notarization credentials, physical device testing (Starlink, GL.iNet, LinkPower 3),
recruiting three outside users by Dec 6, launch posts.

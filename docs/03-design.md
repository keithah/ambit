# UX and design: Ambit v1

Mockups for every screen below were reviewed on 2026-11-20. This page is the written contract.

## Principles

1. **Answer first.** The top line of the popover is a sentence: "Online via Starlink", "Your ISP is the
   problem". Numbers support it.
2. **Zero-setup first run.** Diagnosis works with no configuration. Devices are discovered, not typed in.
3. **Plain words.** The user never sees engine terms.
4. **One place per job.** One way to add a device, one place for alerts, one visibility switch.
5. **Native and quiet.** System materials, system colors, light and dark. Color only for status.

## Vocabulary

| Use | Never |
|---|---|
| Device | integration, provider, instance |
| Reading | entity, metric, signal |
| In menu bar | slot, pin, primary, surface |
| Alert | rule, automation, reaction |
| Wi-Fi / Router / Internet | hop, tier, gateway (except as an address label) |

## Screens

**1. Menu bar item.** Status dot plus up to three readouts chosen in Settings (default: uplink name,
latency, battery %). Variable width. Dot colors: green online, amber degraded, red offline, grey unknown.
Any device can be pinned as its own item (icon plus one reading); pinned items open the same popover scrolled
to that device.

**2. Main popover** (about 340 pt wide, height fits content).
- Header: verdict sentence, settings gear.
- Hop line: "Wi-Fi 3 ms · Router 4 ms · Internet 38 ms", then a 30-minute latency graph.
- When degraded or offline the header becomes a tinted banner: what is wrong, since when, and two actions
  ("Copy report", "Mute 1 hour").
- One row per device: icon, name, one-line summary, primary reading or primary toggle. Click opens detail.
- Footer: "Add device", last-updated time.

**3. Device detail** (pushes inside the popover, back chevron). Hand-built per device.
- Starlink: down/up/ping tiles, obstruction, outages in 24 h, dish power, Reboot, Stow.
- GL.iNet: WAN type and IP, clients, VPN profile and state, VPN toggle, link to router admin page.
- LinkPower: battery %, time left, in/out watts, per-port state, DC and USB-C toggles.
- Every detail has an "In menu bar" checkbox and "Remove device".

**4. Add device** (sheet). List of discovered devices with "Add" or "Pair"; GL.iNet expands to a password
field with "Stored in your Mac's Keychain."; "Ping target" row for a manual host. Undiscovered devices can be
added by address.

**5. Settings** (one window, three tabs).
- General: open at login, menu bar readouts, updates, version.
- Devices: list, reorder, remove, re-enter password.
- Alerts: offline (on, after 30 s), back online (on), low battery (on, below 20%). Toggles and one number each.

**6. First run.** Popover opens once on launch with diagnosis already running, plus a single card:
"Found Starlink and a GL.iNet router. Add them?" Permission prompts (Local Network, Bluetooth,
Notifications) are each preceded by one sentence saying why, and only when the feature is first used.

## States every device row must have

Loading, online, stale ("Last seen 2 min ago", never shown as down), unreachable, permission needed, wrong
password. Each with one sentence and one action.

## Visual rules

- SF Pro at system sizes: 13 pt body, 11 pt secondary, 15 pt semibold for the verdict, 20 pt for tile values.
- SF Symbols for all icons. Graphs via Swift Charts.
- System semantic colors only (`.primary`, `.secondary`, `.green`, `.orange`, `.red`); popover uses the
  standard material. Must be correct in light and dark.
- 8 pt grid; rows 44 pt minimum; hairline separators.
- VoiceOver label on every reading and control. Honor Reduce Motion.
- Confirmation dialog before Reboot, Stow, and any output toggle.

## Copy

Sentence case. No exclamation marks. Errors say what happened and what to do: "Can't reach the router.
Check that you're on its Wi-Fi."

## Open design items

- App icon and menu-bar glyph (week 4).
- Exact report text for "Copy report" (week 3).

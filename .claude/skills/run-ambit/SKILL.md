---
name: run-ambit
description: Build, launch, and observe the Ambit macOS menu-bar app (run / start / launch / screenshot Ambit). Use when asked to run Ambit, see a change working in the real app, or compare its menu-bar UI against the pingscope oracle. macOS only.
---

# Run Ambit (macOS menu-bar app)

Ambit (`AmbitMenuBar`, product `Ambit`) is an `NSApplication` **menu-bar accessory** — no
dock icon, no window; it lives as a status-bar glyph and opens an `NSPopover`. It polls its
providers (ping hosts, etc.) on a timer and writes samples to a local SQLite history store.

**Driving it:** there is no easy programmatic GUI handle for a menu-bar popover, so the agent
path is **launch via the driver, then observe behavior through the history store** (which is
how the poll loop, latency values, and staleness were diagnosed). Visual checks are
human-driven: click the menu-bar glyph.

Paths below are relative to the repo root.

## Prerequisites

- macOS (darwin) with the Swift toolchain / Xcode command-line tools (`swift`, `codesign`, `open`, `sqlite3` — all preinstalled on a dev Mac).
- No Xcode project exists in this repo — it's a SwiftPM package. Do **not** look for `.xcodeproj`.

## Run (agent path)

```bash
bash .claude/skills/run-ambit/launch.sh
```

This builds `Ambit`, wraps the binary in `.build/bundle/Ambit.app` (Info.plist with privacy usage
strings + codesign with the dev entitlements), kills any prior instance, and `open`s it.
By default the signature is ad-hoc so launch never depends on keychain state. Set
`AMBIT_CODESIGN_IDENTITY` explicitly to use a stable Apple Development identity for TCC-sensitive
checks such as Wi-Fi SSID/BSSID reads on macOS 14.4+.
The glyph appears in the menu bar.

Stop it:

```bash
pkill -f 'Ambit.app/Contents/MacOS/Ambit'
```

### Observe / verify it's working

The app persists samples to `~/Library/Application Support/Ambit/history.sqlite`
(table `history_samples(entity_id, timestamp, value, ok, metadata)`; `timestamp` is unix epoch
seconds). Confirm the poll loop is alive and dense:

```bash
DB="$HOME/Library/Application Support/Ambit/history.sqlite"; NOW=$(date +%s)
# newest sample should be a few seconds old; many samples in the last 30s
sqlite3 "$DB" "SELECT ROUND($NOW-MAX(timestamp),1) || 's ago' FROM history_samples;"
sqlite3 -header -column "$DB" \
  "SELECT entity_id, COUNT(*) n, SUM(ok) oks, ROUND(AVG(value),1) avg_ms \
   FROM history_samples WHERE timestamp>=$NOW-60 GROUP BY entity_id ORDER BY n DESC;"
```

A *growing* "newest sample age" with the process alive = the poll loop stalled (see Gotchas: App Nap).

## Run (human path)

Same `launch.sh`, then **click the menu-bar glyph** (top-right) to open the popover: host
selector, range picker, latency graph, per-host stats, diagnosis banner. There is no useful
headless screenshot — the popover only renders on a real click.

`swift run Ambit` is **not** a working path — see Gotchas.

## Test

```bash
swift test    # full XCTest suite (AmbitCore + AmbitUI)
```

## Gotchas (battle scars, all hit this session)

- **`swift run Ambit` crashes immediately** with
  `NSInternalInconsistencyException … bundleProxyForCurrentProcess is nil` from
  `UNUserNotificationCenter`. The bare SwiftPM binary has no app bundle; the notification
  center requires one. → must run from the `.app` bundle the driver builds. Don't try to
  "just `swift run`".
- **App Nap freezes the poll loop.** As a backgrounded `LSUIElement` accessory, macOS App-Naps
  the app when idle and suspends its timer — samples stop, the popover shows `--ms` / "No Data",
  and the diagnoser then falsely reports "Local network down" (it's reading a stale, empty
  window, not a real outage). The process stays alive at ~0% CPU. → the driver sets
  `NSAppSleepDisabled` in the Info.plist to opt out. If you see stale data with the process
  alive, this is the cause.
- **The history DB persists across runs** (`~/Library/Application Support/Ambit/…`). On a fresh
  launch the graph/readout draw from *old* samples before the first live poll completes, so you
  may briefly see a value with a "No Data" status — it self-heals after one poll.
- **Wi-Fi SSID/BSSID on macOS 14.4+ needs Location authorization and a stable code identity.** The
  launcher does not auto-select a certificate because that can depend on locked keychains or
  ambiguous renewed certificates. Set `AMBIT_CODESIGN_IDENTITY` to the exact identity you want;
  otherwise the ad-hoc fallback launches reliably but TCC may not retain the grant across rebuilds.
- **App Intents metadata needs const-values output.** The launcher invokes
  `appintentsmetadataprocessor` when `.swiftconstvalues` files exist, but plain SwiftPM builds do
  not currently emit them. Shortcuts/Spotlight indexing therefore needs the documented Xcode
  packaging pass with `SWIFT_ENABLE_EMIT_CONST_VALUES=YES`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `bundleProxyForCurrentProcess is nil` crash | You ran the bare binary; use `launch.sh` (bundled). |
| Menu graph stuck on "No Data" / "Local network down", process alive at 0% CPU | App Nap — relaunch via `launch.sh` (sets `NSAppSleepDisabled`); confirm with the observe query. |
| Glyph doesn't appear | `pkill -f 'Ambit.app/Contents/MacOS/Ambit'` then rerun `launch.sh`; check it's not already running. |

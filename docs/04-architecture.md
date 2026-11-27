# Architecture: Ambit v1

Small on purpose. Target: under 6,000 lines of Swift at v1.0.

## Shape

One macOS app process. No helper, no XPC, no daemon, no server.

```
Ambit.app (Xcode app target, SwiftUI + a little AppKit for status items)
 └─ AmbitKit (local Swift package, no UI imports)
     ├─ Core        Device protocol, Monitor (poll scheduler), Reading types, Health
     ├─ Diagnosis   probes (ICMP/TCP), hop model, verdict
     ├─ Devices     Starlink/, GLiNet/, LinkPower/   one folder each: client + model
     ├─ Store       SQLite history, config file, Keychain
     └─ Alerts      one evaluator
```

Project: a thin Xcode app target (generated with XcodeGen from `project.yml`) depending on the `AmbitKit`
package. This gives asset catalogs, entitlements, Info.plist and archiving without the v0 launch-script
workarounds. macOS 14+, Swift 6, universal binary.

## Core types

```swift
protocol Device: Sendable {
    associatedtype State: Sendable            // typed per device, e.g. StarlinkState
    var id: UUID { get }                      // opaque, stable; never derived from an address
    func poll() async throws -> State         // BLE devices push instead via an AsyncStream
}

enum Health { case online, degraded, offline, stale, needsAttention(String) }
```

- Each device has its own typed state struct and its own SwiftUI view. No generic entity model, no
  capability taxonomy, no card composer.
- Each device declares a small `Summary` (health, one-line text, primary reading) for the popover row and
  the menu bar, and a list of numeric series to record.
- Commands are plain async methods on the concrete client (`starlink.reboot()`), called from that device's
  view after a confirmation.

## Monitor

- One `Task` per device, concurrent; a slow device never delays another.
- Each poll has a timeout; a timed-out poll marks the device stale, not offline. Offline needs N consecutive
  failures.
- Pauses on sleep, polls immediately on wake and on network change.
- Publishes an `@Observable` app model on the main actor; views read it directly.

## Diagnosis

Probes to: Wi-Fi gateway, router (if distinct), two internet targets, one DNS lookup. ICMP via `/sbin/ping`
(arguments validated; no leading `-`), TCP via `NWConnection`. A pure function maps the latest probe window to
a verdict (`wifi`, `router`, `isp`, `dns`, `ok`). The v0 `network_diagnosis_matrix.json` is the test spec.

## Devices

| Device | Transport | Notes |
|---|---|---|
| Starlink | gRPC-Web over HTTP to `192.168.100.1:9201` | URLSession plus a small protobuf reader (`ProtoWire`); no dependency. Unverified on hardware as of 2026-11-21; fallback is grpc-swift on port 9200 |
| GL.iNet | JSON-RPC over HTTP(S) to the router | Password from Keychain; hashing in-process (no `openssl` argv) |
| LinkPower 3 | Wi-Fi/LAN if the spike finds a local interface; else CoreBluetooth, service `0x5301` | BLE: notify on `0x4303` (battery), commands on `0x4302`, per `keithah/openwrt-wattline` docs; reimplemented, not copied (AGPL). Wi-Fi protocol undocumented as of 2026-11-20 |

Discovery: probe the well-known Starlink address, the default gateway for GL.iNet's RPC endpoint, and a BLE
scan for the LinkPower service.

## Storage

- **History:** one SQLite file, table `sample(device, series, ts, value)`, kept 25 hours at full
  resolution; a missing value is a probe with no reply. See decisions.md, 2026-11-22.
- **Config:** one JSON file in Application Support (devices, menu-bar choices, alert settings). One store.
- **Secrets:** Keychain generic passwords, service `com.hadm.ambit`, account = device UUID.

## Alerts

One evaluator over the app model: offline for 30 s (message names the failing hop), recovery, battery below
threshold. Cooldown per alert. Delivered with `UNUserNotificationCenter`. No rule engine.

## Dependencies

Sparkle 2. Nothing else without a decision-log entry.

## Permissions

Local Network (`NSLocalNetworkUsageDescription`), Bluetooth (`NSBluetoothAlwaysUsageDescription`),
Notifications. Not sandboxed; hardened runtime on. No location, no calendar.

## Release pipeline (built in week 1, before features)

`make release VERSION=x.y.z`: archive Release universal, sign with Developer ID (hardened runtime,
timestamp), build DMG, `notarytool submit --wait`, staple, generate Sparkle appcast with the EdDSA key,
upload DMG to GitHub Releases, publish appcast to GitHub Pages. GitHub Actions runs build and tests on every
push; releases are cut locally until signing secrets are in CI.

## Testing

Unit tests for: device response parsers (recorded fixtures), BLE frame codec, diagnosis matrix, health
transitions, alert evaluator, history pruning. No UI snapshot tests, no golden parity fixtures.

## Explicitly not built

Plugin/manifest runtime, rules, contexts, multi-engine, relay, Linux support, App Intents, generic settings
renderer, migration framework.

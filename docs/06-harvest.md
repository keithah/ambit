# Harvest list from `archive/v0`

Copy files out with `git show archive/v0:<path> > <new path>`. Simplify on arrival. Do not bring a file's
tests unless listed. Line counts are from the 2026-11-20 audit.

## Copy nearly verbatim

| v0 path | Lines | Use | Fix on arrival |
|---|---|---|---|
| `Sources/AmbitCore/Ping/ICMPProbe.swift`, `TCPProbe.swift`, `Probes.swift`, `ProbeFactory.swift` | 231 | Diagnosis probes | Reject hosts starting with `-` |
| `Sources/AmbitCore/Ping/PingDomain.swift` | 204 | Host/health model | Trim to what diagnosis uses |
| `Sources/AmbitCore/System/ProcessRunner.swift` | 165 | Running `/sbin/ping` | none |
| `Sources/AmbitCore/System/SystemNetworkProvider.swift`, `SystemNetworkInfoReading.swift` | 322 | Gateway detection, interface info | Drop provider wrapper |
| `Sources/AmbitCore/History/` (`SQLiteHistoryStore`, `HistoryStore`, `SampleSeries`, `HistoryService`) | 254 | History | Add batching and a prune index |
| `Sources/AmbitCore/Health/HealthModel.swift` | 88 | Thresholds, consecutive-failure logic | Merge into one `Health` enum |
| `Sources/AmbitCore/CredentialStore.swift` | 120 | Keychain | Service name `com.hadm.ambit` |
| `Sources/AmbitCore/Presentation/Staleness.swift` | 29 | Stale-is-not-down | none |
| `Sources/AmbitMenuBar/AppLifecycleServices.swift` | 87 | Login item, single instance | none |
| `Sources/AmbitMenuBar/MacNotificationDeliverer.swift`, `NetworkChangeSource.swift` | 114 | Notifications, network-change events | none |
| Status-item reconciler in `Sources/AmbitMenuBar/App.swift` | ~120 | Multiple status items | Decouple from slots |
| `Tests/AmbitCoreTests/Fixtures/GenericMonitoringParity/network_diagnosis_matrix.json` | n/a | Diagnosis test spec | none |
| Tests: `PingProbesTests`, `SQLiteHistoryStoreTests`, `HealthModelTests` | n/a | Keep with their code | Remove app-target dependency |

## Use as protocol reference, rewrite the code

| v0 path | Why rewrite |
|---|---|
| `Sources/AmbitCore/StarlinkClient.swift` (153) | Shells Homebrew `grpcurl`; keep the field parsing, replace transport with grpc-swift |
| `Sources/AmbitCore/GLiNetClient.swift` (209), `JSONRPC.swift` (131) | Tangled with `Engine`; `PasswordHasher` puts the password on `openssl` argv |
| `Sources/AmbitCore/Monitoring/TopologyDiagnosisEngine.swift` (199) | Generic-clothing version of ping logic; rewrite as a pure function over hops |
| `Sources/AmbitUI/Cards/HistoryGraphCard.swift`, `Sources/AmbitUI/GraphGeometry.swift` | Use Swift Charts; keep the failure-bar idea |

## For later releases

| v0 path | Release |
|---|---|
| `Sources/AmbitCore/System/DarwinSystemMetricsReader.swift`, `SystemMetricsSnapshot.swift` | v1.1 (fix CPU %: needs tick deltas, currently average since boot) |
| `Sources/AmbitCore/RouterSpeedifyClient.swift`, Speedify CLI client | On request |

## Leave behind

Everything else, in particular: `Engine.swift`, `Provider.swift`, entity/descriptor/identity model,
`Presentation/` (composer, attention, slots), `Monitoring/` rules, contexts, conditions and reactions,
`AlertEngine.swift`, manifest runtime, registry, usage metering, `StatusViewModel.swift`,
`AmbitSettings.swift`, `Theme.swift`, App Intents bridge, calendar/location/focus providers, parity fixtures,
grep-gate tests, `.claude/skills/run-ambit/launch.sh` (reference only for gotchas: App Nap, bundle needed
for notifications).

## External reference

`keithah/openwrt-wattline` `docs/API.md` and `bcorazza/linkpower-free` `PROTOCOL.md` for the LinkPower BLE
protocol. Wattline is AGPL-3.0: read the protocol, write new Swift.

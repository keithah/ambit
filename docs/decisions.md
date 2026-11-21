# Decision log

One line per decision. Newest at the bottom. Scope changes need a line here from Keith.

| Date | Decision | Who |
|---|---|---|
| 2026-11-20 | Restart from an empty `main`. v0 preserved on `archive/v0`, tag `v0-archive`. | Keith |
| 2026-11-20 | v1 = uplink bar (devices) with fault diagnosis inside it. | Keith |
| 2026-11-20 | "Shipped" = public, free, signed, notarized download with auto-update. | Keith |
| 2026-11-20 | Four weeks: v1.0.0 on 2026-12-20, a release every week. | Keith |
| 2026-11-20 | v1 devices: Starlink, GL.iNet, PeakDo LinkPower 3 (replaces EcoFlow). Speedify and EcoFlow dropped from v1. | Keith |
| 2026-11-20 | System stats ("This Mac") after v1, as v1.1. | Keith |
| 2026-11-20 | Tesla via Tessie token, after v1, as v1.2. | Keith |
| 2026-11-20 | Controls: a few safe toggles only (VPN, Starlink reboot/stow, LinkPower outputs), each confirmed. | Keith |
| 2026-11-20 | Each device gets hand-built UI. The v0 "no integration-specific UI" rule is revoked. | Keith |
| 2026-11-20 | Menu bar: combined item by default, user may pin devices as separate items. | Keith |
| 2026-11-20 | Open source, MIT. | Keith |
| 2026-11-20 | Distribution via GitHub Releases and Pages; Developer ID is available. No Mac App Store. | Keith |
| 2026-11-20 | Defaults chosen without asking: macOS 14+, Xcode app target + `AmbitKit` package (XcodeGen), Sparkle 2, no extension API in v1, alerts are fixed toggles, LinkPower over Bluetooth only, bundle ID `com.hadm.ambit`. Object to any of these by adding a line. | Claude |
| 2026-11-20 | "User chooses" menu bar is implemented as per-device pinning, not the v0 slot system. | Claude |
| 2026-11-20 | LinkPower 3 has Wi-Fi (Keith). Its Wi-Fi protocol is undocumented; the week-1 spike checks LAN first, Bluetooth as fallback. | Keith / Claude |
| 2026-11-20 | Week-1 diagnosis keeps history in memory (30 min). SQLite history moves to the first device week, when there is more than one series to store. | Claude |
| 2026-11-21 | Release credentials are file-based so the pipeline runs headless: dedicated signing keychain and App Store Connect API key (shared with the overhear project's kit in `~/.config/overhear-signing/`), and a Sparkle ed25519 key file in `~/.config/ambit-signing/`. Requested by Keith ("I want you to run them"). | Keith / Claude |
| 2026-11-21 | Starlink transport: gRPC-Web over HTTP on port 9201 with a hand-written protobuf reader, replacing the planned grpc-swift + SwiftProtobuf dependencies. Decoder is tested against `protoc`-encoded fixtures from the published dish schema. NOT yet run against a dish; if 9201 does not answer, fall back to grpc-swift on 9200. | Claude |
| 2026-11-21 | Spikes 1.3 (LinkPower) and 1.4 (Starlink on hardware) are blocked: neither device is on the development LAN (Keith). Verify with `swift run ambit-probe starlink` when on the dish's network. | Keith / Claude |

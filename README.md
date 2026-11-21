# Ambit

Your whole connection stack in the Mac menu bar: Starlink, travel router, battery, and a plain answer to
"is it my Wi-Fi, my router, or my ISP?"

**Status (2026-11-20):** week 1 in progress. The app runs and diagnoses the connection; no release yet. v1 ships 2026-12-20 as a free, signed, notarized,
auto-updating download. The plan is in [docs/05-plan.md](docs/05-plan.md).

## What v1 is

One menu-bar app for people who run their internet from a dish, a travel router and a battery.

- **Diagnosis:** hop-by-hop latency (Wi-Fi, router, internet) with a verdict naming the failing hop.
- **Starlink:** throughput, latency, obstruction, outages; reboot and stow.
- **GL.iNet router:** clients, WAN, VPN state; VPN on/off.
- **PeakDo LinkPower:** battery %, watts, time left; output on/off (Bluetooth).
- **Quiet alerts:** offline (says which hop), low battery.

Not in v1: system stats (v1.1), Tesla via Tessie (v1.2), plugins, rules, iOS, cloud relay.

## Documents

| Doc | What |
|---|---|
| [docs/01-evaluation.md](docs/01-evaluation.md) | Audit of the first attempt (v0) and why it did not ship |
| [docs/02-product.md](docs/02-product.md) | Product spec: user, job, scope, non-goals |
| [docs/03-design.md](docs/03-design.md) | UX: screens, vocabulary, visual rules |
| [docs/04-architecture.md](docs/04-architecture.md) | Technical design |
| [docs/05-plan.md](docs/05-plan.md) | Four-week plan, weekly releases, kill criteria |
| [docs/06-harvest.md](docs/06-harvest.md) | What to lift from the v0 archive |
| [docs/decisions.md](docs/decisions.md) | Dated decision log |
| [docs/releasing.md](docs/releasing.md) | Release setup and steps |

## Build

Needs Xcode 16 or later and `brew install xcodegen`.

```sh
make test   # unit tests
make run    # build and launch the menu-bar app
```

## The v0 archive

The first attempt (352 commits, 44.6k lines of Swift, never released) is preserved on branch
[`archive/v0`](https://github.com/keithah/ambit/tree/archive/v0), tag `v0-archive`. It is a parts bin, not a
base: see [docs/06-harvest.md](docs/06-harvest.md).

## License

MIT. See [LICENSE](LICENSE).

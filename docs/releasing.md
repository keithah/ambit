# Releasing

## Each release

```sh
make release VERSION=0.1.0             # test, build universal, sign, notarize, DMG, appcast in dist/
PUBLISH=1 make release VERSION=0.1.0   # the same, then tag, GitHub release, push appcast to gh-pages
```

- `SKIP_NOTARIZE=1` stops after signing, to test the pipeline without Apple's service.
- The build number is the commit's time in UTC (`YYYYMMDDHHMM`); `make build` uses the current time. The
  working tree must be clean.
- The version stays at 0.1.0 until Keith calls a release. The build number tells builds apart. Until
  then nothing new can be published: `PUBLISH=1` with 0.1.0 reuses the DMG already on GitHub, and
  the `v0.1.0` tag is on an older commit. Local builds (`make release VERSION=0.1.0`) still work.
- `PUBLISH=1` requires `HEAD` to equal `origin/main`.
- A failed publish can be re-run. A version whose DMG is already on GitHub is never rebuilt; the
  retry reuses the published bytes and only finishes the missing steps.

## Credentials

The script works without a GUI session (SSH, CI, agents), where the login keychain is unusable.
It reads the locations of its credentials from a private file, `~/.config/ambit-signing/release.env`
(override with `AMBIT_RELEASE_ENV`). That file holds paths only:

| Variable | What it points to |
|---|---|
| `AMBIT_SIGNING_KEYCHAIN` | A dedicated keychain holding the "Developer ID Application" identity |
| `AMBIT_SIGNING_KEYCHAIN_PASSWORD_FILE` | File with that keychain's password (sent to `security` on stdin) |
| `AMBIT_NOTARY_ENV` | File defining `KEY` (App Store Connect API `.p8` path), `KEY_ID`, `ISSUER` |
| `AMBIT_SPARKLE_KEY_FILE` | Sparkle ed25519 private key (base64 of the 32-byte seed) |

Without the env file the script falls back to the interactive setup: identity in the login keychain,
`xcrun notarytool store-credentials ambit`, and Sparkle's key in the login keychain.

On the current release Mac the signing keychain and notary key are the ones in
`~/.config/overhear-signing/`, shared with another project of the same developer account.

## The Sparkle key

- Private key: `~/.config/ambit-signing/sparkle_ed25519.key`. **Back it up.** If it is lost, installed
  copies can never be updated again, because they only accept updates signed by it.
- Public key: `SPARKLE_PUBLIC_KEY` in `project.yml` (safe to commit).

## GitHub Pages

The appcast is served from the `gh-pages` branch at `https://keithah.github.io/ambit/appcast.xml`.
The first `PUBLISH=1` run creates the branch; Pages must then be enabled for it (Settings, Pages,
deploy from branch `gh-pages`, root).

## Verifying a release

- `spctl --assess --type open --context context:primary-signature -v dist/Ambit-x.y.z.dmg` says `accepted`.
- Install the previous version on another Mac, choose "Check for updates…", confirm it updates.

## Status

2026-11-21: v0.1.0 published with `PUBLISH=1` from `main`. The DMG on GitHub is universal, signed with
Developer ID and hardened runtime, notarized (`Accepted`), stapled, and accepted by Gatekeeper after
download. Pages serves the appcast (GitHub enabled it when `gh-pages` was first pushed). Not yet done:
an update from one installed version to the next, which needs a second published release under a new version.

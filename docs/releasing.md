# Releasing

## One-time setup (Keith, on the release Mac)

1. **Unlock the login keychain** and confirm the certificate:
   `security find-identity -v -p codesigning | grep "Developer ID Application"`
2. **Notary credentials** (needs an app-specific password from appleid.apple.com):
   `xcrun notarytool store-credentials ambit --apple-id <apple id> --team-id <team id>`
3. **Sparkle key** (private key is stored in the login keychain; back it up):
   `make build && build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`
   Copy the printed public key into `SPARKLE_PUBLIC_KEY` in `project.yml` and commit.
4. **GitHub Pages**: repo Settings, Pages, deploy from branch `gh-pages`, root. The first
   `PUBLISH=1` release creates the branch. The appcast is served at
   `https://keithah.github.io/ambit/appcast.xml`.

## Each release

```sh
make release VERSION=0.1.0             # test, build universal, sign, notarize, DMG, appcast in dist/
PUBLISH=1 make release VERSION=0.1.0   # the same, then tag, GitHub release, push appcast
```

`SKIP_NOTARIZE=1` stops after signing, to test the pipeline without Apple's service.

The build number is the commit count. The working tree must be clean.

## Verifying a release

- `spctl --assess --type open --context context:primary-signature -v dist/Ambit-x.y.z.dmg` says `accepted`.
- Install the previous version on another Mac, choose "Check for updates…", confirm it updates.

## Status

As of 2026-11-20 the script is written but has not completed a run: the login keychain was locked in
the session that wrote it, and steps 2 to 4 above are not done.

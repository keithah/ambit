# B6 App Intents Packaging Notes

Ambit now compiles the App Intents bridge in `AmbitMenuBar`. The development launcher builds a
signed app bundle with privacy usage strings and entitlements, and it runs App Intents metadata
extraction when Swift const-values metadata is available.

Deploy checklist for the app-bundle pipeline:

- Build the signed `Ambit.app` bundle with the `AmbitMenuBar` target that contains
  `AppEntity`, `AppIntent`, and `AppShortcutsProvider` declarations.
- Ensure the app bundle's Info.plist is generated for the final bundle identifier used at
  launch (`com.hadm.ambit` for the development bundle); stale `/private/tmp/Ambit.app` bundles
  may not be indexed.
- Include these Info.plist privacy strings in the signed bundle:
  `NSLocationWhenInUseUsageDescription`, `NSCalendarsUsageDescription`, and
  `NSCalendarsFullAccessUsageDescription`. The location prompt also gates CoreWLAN SSID reads on
  current macOS.
- Sign with the Ambit entitlements file used by `.claude/skills/run-ambit/launch.sh`:
  `com.apple.security.personal-information.location`,
  `com.apple.security.personal-information.calendars`, and `com.apple.security.network.client`.
  The dev bundle remains unsandboxed to avoid changing existing local storage and network behavior.
- Wi-Fi SSID/BSSID reads additionally require Apple's restricted
  `com.apple.developer.networking.wifi-info` entitlement in a provisioning profile for
  `com.hadm.ambit`. The launcher keeps that entitlement out of the default ad-hoc path because
  signing with an unauthorized restricted entitlement causes macOS to reject the app at launch.
  For a provisioned local build, create/download a macOS development profile with the Wi-Fi
  Information capability enabled, then run:
  `AMBIT_CODESIGN_IDENTITY="Apple Development: ..." AMBIT_ENTITLEMENTS=.claude/skills/run-ambit/Ambit.provisioned.entitlements AMBIT_PROVISIONING_PROFILE=/path/to/profile.mobileprovision .claude/skills/run-ambit/launch.sh`.
- Run the App Intents metadata extraction step as part of packaging so Shortcuts can discover
  `Refresh Ambit`, context activation/deactivation, entity queries, and command intents.
  The metadata processor needs Swift compiler const-values output. In an Xcode packaging target,
  set `SWIFT_ENABLE_EMIT_CONST_VALUES=YES`; then run `appintentsmetadataprocessor` with the
  generated `.swiftconstvalues` file list. The SwiftPM-only launcher attempts this step when those
  files exist and prints a clear warning when SwiftPM did not produce them.
- No secrets, feed URLs, signing keys, or provider credentials are required by B6.
- `Reaction.runShortcut` is wired through an injectable runner. The real runner belongs in the
  signed app adapter that invokes the user's named Shortcut at runtime.
- `Reaction.runAppIntent` has a Codable shape and executor seam; arbitrary external App Intent
  invocation is deferred until a reliable public macOS API is selected.

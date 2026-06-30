# B6 App Intents Packaging Notes

Ambit now compiles the App Intents bridge in `AmbitMenuBar`, but live Shortcuts and Spotlight
indexing require the signed app bundle to be produced with App Intents metadata extraction.

Deploy checklist for the app-bundle pipeline:

- Build the signed `Ambit.app` bundle with the `AmbitMenuBar` target that contains
  `AppEntity`, `AppIntent`, and `AppShortcutsProvider` declarations.
- Ensure the app bundle's Info.plist is generated for the final bundle identifier used at
  launch (`tv.kodi.ambit` for the development bundle); stale `/private/tmp/Ambit.app` bundles
  may not be indexed.
- Run the standard Xcode/App Intents metadata extraction step as part of packaging so Shortcuts
  can discover `Refresh Ambit`, context activation/deactivation, entity queries, and command
  intents.
- No secrets, feed URLs, signing keys, or provider credentials are required by B6.
- `Reaction.runShortcut` is wired through an injectable runner. The real runner belongs in the
  signed app adapter that invokes the user's named Shortcut at runtime.
- `Reaction.runAppIntent` has a Codable shape and executor seam; arbitrary external App Intent
  invocation is deferred until a reliable public macOS API is selected.


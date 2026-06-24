#!/usr/bin/env bash
# Build, bundle, ad-hoc sign, and launch the Ambit menu-bar app on macOS.
#
# Why a bundle (not `swift run Ambit`): Ambit is an NSApplication menu-bar
# accessory that calls UNUserNotificationCenter. `swift run` produces a bare
# binary with no app bundle, so that call throws
# `bundleProxyForCurrentProcess is nil` and the app crashes on first poll.
# A minimal .app bundle (Info.plist + ad-hoc codesign) fixes it.
#
# Why NSAppSleepDisabled: as a backgrounded .accessory (LSUIElement) app, macOS
# App-Naps it when idle and freezes its 2s poll loop's timer — the menu graphs
# go stale ("No Data", false "Local network down"). The plist key opts out so it
# keeps polling while idle.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "==> swift build --product Ambit"
swift build --product Ambit
BIN="$(swift build --product Ambit --show-bin-path)/Ambit"
[ -x "$BIN" ] || { echo "build produced no Ambit binary at $BIN" >&2; exit 1; }

APP="${AMBIT_APP:-.build/bundle/Ambit.app}"
echo "==> bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Ambit"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Ambit</string>
  <key>CFBundleIdentifier</key><string>tv.kodi.ambit</string>
  <key>CFBundleName</key><string>Ambit</string>
  <key>CFBundleDisplayName</key><string>Ambit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>dev</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppSleepDisabled</key><true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --sign - "$APP" >/dev/null

# Replace any previous instance so the menu-bar item reflects this build.
pkill -f "Ambit.app/Contents/MacOS/Ambit" 2>/dev/null || true

echo "==> open $APP"
open "$APP"
echo "Ambit launched. Look for the latency glyph in the menu bar (top-right)."
echo "Stop with: pkill -f 'Ambit.app/Contents/MacOS/Ambit'"

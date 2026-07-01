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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

write_app_intents_metadata() {
  local app="$1"
  local metadata_dir="$app/Contents/Resources/Metadata.appintents"
  local work_dir=".build/appintents-metadata"
  local source_list="$work_dir/source-files.txt"
  local const_values_list="$work_dir/swift-const-values.txt"
  local metadata_file_list="$work_dir/metadata-files.txt"
  local static_metadata_file_list="$work_dir/static-metadata-files.txt"
  local dependency_file="$work_dir/appintents.d"
  local stringsdata_file="$work_dir/appintents.stringsdata"
  local sdk_root toolchain_dir xcode_version arch target_triple

  mkdir -p "$work_dir" "$app/Contents/Resources"
  find Sources/AmbitMenuBar -name '*.swift' | sort > "$source_list"
  find .build -name '*.swiftconstvalues' | sort > "$const_values_list"
  : > "$metadata_file_list"
  : > "$static_metadata_file_list"

  if [ ! -s "$const_values_list" ]; then
    cat >&2 <<'WARN'
==> App Intents metadata skipped
    SwiftPM did not emit any .swiftconstvalues files. Shortcuts/Spotlight indexing needs an
    Xcode packaging pass with SWIFT_ENABLE_EMIT_CONST_VALUES=YES, then appintentsmetadataprocessor.
    See docs/ux/v0/b6-app-intents-packaging.md for the exact deploy step.
WARN
    return 0
  fi

  sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
  toolchain_dir="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain"
  xcode_version="$(xcodebuild -version | awk '/Build version/{print $3}')"
  arch="$(uname -m)"
  target_triple="${arch}-apple-macosx13.0"

  echo "==> appintentsmetadataprocessor"
  xcrun appintentsmetadataprocessor \
    --output "$metadata_dir" \
    --toolchain-dir "$toolchain_dir" \
    --module-name AmbitMenuBar \
    --sdk-root "$sdk_root" \
    --xcode-version "$xcode_version" \
    --platform-family macOS \
    --deployment-target 13.0 \
    --target-triple "$target_triple" \
    --dependency-file "$dependency_file" \
    --stringsdata-file "$stringsdata_file" \
    --source-file-list "$source_list" \
    --metadata-file-list "$metadata_file_list" \
    --static-metadata-file-list "$static_metadata_file_list" \
    --swift-const-vals-list "$const_values_list" \
    --force \
    --force-metadata-output \
    --quiet-warnings
}

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
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>Ambit uses your location only to match user-defined places and to allow macOS to expose the current Wi-Fi SSID for local context rules.</string>
  <key>NSLocationUsageDescription</key>
  <string>Ambit uses your location only to match user-defined places and to allow macOS to expose the current Wi-Fi SSID for local context rules.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Ambit reads your calendar availability locally so user-authored contexts and rules can react to busy or upcoming events.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Ambit reads your calendar availability locally so user-authored contexts and rules can react to busy or upcoming events.</string>
</dict>
</plist>
PLIST

write_app_intents_metadata "$APP"

echo "==> ad-hoc codesign"
codesign --force --sign - --entitlements "$SCRIPT_DIR/Ambit.entitlements" "$APP" >/dev/null

# Replace any previous instance so the menu-bar item reflects this build.
pkill -f "Ambit.app/Contents/MacOS/Ambit" 2>/dev/null || true

echo "==> open $APP"
open "$APP"
echo "Ambit launched. Look for the latency glyph in the menu bar (top-right)."
echo "Stop with: pkill -f 'Ambit.app/Contents/MacOS/Ambit'"

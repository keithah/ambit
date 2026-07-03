#!/usr/bin/env bash
# Build, bundle, sign, and launch the Ambit menu-bar app on macOS.
#
# Why a bundle (not `swift run Ambit`): Ambit is an NSApplication menu-bar
# accessory that calls UNUserNotificationCenter. `swift run` produces a bare
# binary with no app bundle, so that call throws
# `bundleProxyForCurrentProcess is nil` and the app crashes on first poll.
# A minimal .app bundle (Info.plist + codesign) fixes it.
#
# Why NSAppSleepDisabled: as a backgrounded .accessory (LSUIElement) app, macOS
# App-Naps it when idle and freezes its 2s poll loop's timer — the menu graphs
# go stale ("No Data", false "Local network down"). The plist key opts out so it
# keeps polling while idle.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN=""

build_ambit_product() {
  local xcode_log=".build/appintents-metadata/xcodebuild.log"
  if [ "${AMBIT_XCODE_APPINTENTS:-1}" = "1" ]; then
    mkdir -p "$(dirname "$xcode_log")"
    echo "==> xcodebuild -scheme Ambit (App Intents const values)"
    rm -rf .build/xcode-appintents
    if ! xcodebuild \
      -scheme Ambit \
      -destination 'generic/platform=macOS' \
      -derivedDataPath .build/xcode-appintents \
      SWIFT_ENABLE_EMIT_CONST_VALUES=YES \
      CODE_SIGNING_ALLOWED=NO \
      build >"$xcode_log" 2>&1
    then
      cat >&2 <<WARN
==> xcodebuild failed
    See $xcode_log for the full log.
    Set AMBIT_XCODE_APPINTENTS=0 to use the SwiftPM fallback, which launches the app
    without App Intents / Shortcuts metadata.
WARN
      tail -n 80 "$xcode_log" >&2
      exit 1
    fi
    BIN=".build/xcode-appintents/Build/Products/Debug/Ambit"
    [ -x "$BIN" ] || { echo "xcodebuild produced no Ambit binary at $BIN" >&2; exit 1; }
    return 0
  fi

  echo "==> swift build --product Ambit"
  swift build --product Ambit
  BIN="$(swift build --product Ambit --show-bin-path)/Ambit"
  [ -x "$BIN" ] || { echo "build produced no Ambit binary at $BIN" >&2; exit 1; }
}

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
  local processor_log="$work_dir/appintentsmetadataprocessor.log"
  local sdk_root toolchain_dir xcode_version arch target_triple

  mkdir -p "$work_dir" "$app/Contents/Resources"
  find Sources/AmbitMenuBar -name '*.swift' | sort > "$source_list"
  find .build/xcode-appintents -name '*.swiftconstvalues' | sort > "$const_values_list" 2>/dev/null || true
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
  if ! xcrun appintentsmetadataprocessor \
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
    --quiet-warnings 2>&1 | tee "$processor_log"
  then
    echo "appintentsmetadataprocessor failed; see $processor_log" >&2
    exit 1
  fi
  if grep -q "error:" "$processor_log"; then
    echo "appintentsmetadataprocessor reported errors; see $processor_log" >&2
    exit 1
  fi
}

sign_ambit_app() {
  local app="$1"
  local identity="${AMBIT_CODESIGN_IDENTITY:-}"
  local provision_profile="${AMBIT_PROVISIONING_PROFILE:-}"
  local entitlements="${AMBIT_ENTITLEMENTS:-$SCRIPT_DIR/Ambit.entitlements}"

  if [ -z "$identity" ]; then
    identity="-"
  fi

  if [ -n "$provision_profile" ]; then
    [ -f "$provision_profile" ] || { echo "AMBIT_PROVISIONING_PROFILE does not exist: $provision_profile" >&2; exit 1; }
    cp "$provision_profile" "$app/Contents/embedded.provisionprofile"
  fi

  if [ "$identity" = "-" ]; then
    echo "==> ad-hoc codesign (set AMBIT_CODESIGN_IDENTITY for stable TCC identity)"
  else
    echo "==> codesign ($identity)"
  fi

  codesign --force --sign "$identity" --entitlements "$entitlements" "$app" >/dev/null
}

build_ambit_product

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
  <key>CFBundleIdentifier</key><string>com.hadm.ambit</string>
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
sign_ambit_app "$APP"

# Replace any previous instance so the menu-bar item reflects this build.
pkill -f "Ambit.app/Contents/MacOS/Ambit" 2>/dev/null || true

echo "==> open $APP"
open "$APP"
echo "Ambit launched. Look for the latency glyph in the menu bar (top-right)."
echo "Stop with: pkill -f 'Ambit.app/Contents/MacOS/Ambit'"

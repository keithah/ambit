#!/bin/bash
# Build, sign, notarize and package Ambit. Usage: scripts/release.sh 0.1.0
#
# One-time setup (see docs/releasing.md):
#   - "Developer ID Application" certificate in the login keychain
#   - xcrun notarytool store-credentials ambit
#   - Sparkle generate_keys, then put the public key in SPARKLE_PUBLIC_KEY (project.yml)
#
# Environment:
#   AMBIT_SIGN_IDENTITY   codesign identity (default: first "Developer ID Application")
#   AMBIT_NOTARY_PROFILE  notarytool keychain profile (default: ambit)
#   PUBLISH=1             also create the GitHub release and push the appcast to gh-pages
#   SKIP_NOTARIZE=1       stop after signing (for testing the pipeline)
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh VERSION}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be x.y.z"; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DERIVED="$ROOT/build"
DIST="$ROOT/dist"
APP="$DERIVED/Build/Products/Release/Ambit.app"
DMG="$DIST/Ambit-$VERSION.dmg"
PROFILE="${AMBIT_NOTARY_PROFILE:-ambit}"
REPO="keithah/ambit"
BUILD_NUMBER="$(git rev-list --count HEAD)"

IDENTITY="${AMBIT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found."; exit 1; }
TEAM="$(sed -E 's/.*\(([A-Z0-9]+)\)$/\1/' <<<"$IDENTITY")"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit first so the release matches a commit."; exit 1
fi

echo "==> Tests"
swift test

echo "==> Build $VERSION ($BUILD_NUMBER), universal, Release"
xcodegen generate --quiet
xcodebuild -project Ambit.xcodeproj -scheme Ambit -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet build

echo "==> Re-sign Sparkle helpers with hardened runtime, inside out"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [[ -z "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null)" ]]; then
  echo "SUPublicEDKey is empty: this build cannot auto-update. Set SPARKLE_PUBLIC_KEY in project.yml."; exit 1
fi

echo "==> DMG"
mkdir -p "$DIST"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Ambit" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
  echo "Signed, not notarized: $DMG"; exit 0
fi

echo "==> Notarize"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "==> Appcast"
"$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  -o "$DIST/appcast.xml" "$DIST"

if [[ "${PUBLISH:-0}" != "1" ]]; then
  echo "Built $DMG and $DIST/appcast.xml. Re-run with PUBLISH=1 to upload."; exit 0
fi

echo "==> Publish"
git tag -a "v$VERSION" -m "Ambit $VERSION"
git push origin "v$VERSION"
gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "Ambit $VERSION" --generate-notes

PAGES="$(mktemp -d)"
if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
  git worktree add "$PAGES" gh-pages
else
  git worktree add --orphan -b gh-pages "$PAGES"
fi
cp "$DIST/appcast.xml" "$PAGES/appcast.xml"
git -C "$PAGES" add appcast.xml
git -C "$PAGES" commit -m "Appcast for $VERSION"
git -C "$PAGES" push origin gh-pages
git worktree remove "$PAGES"
echo "Released v$VERSION"

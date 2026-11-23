#!/bin/bash
# Build, sign, notarize and package Ambit. Usage: scripts/release.sh 0.1.0
#
# Works in two settings (see docs/releasing.md):
#   - Headless (SSH, CI, agents): credentials come from files named in a private env file,
#     because the login keychain cannot be used without a GUI session.
#   - Interactive: Developer ID identity in the login keychain, a notarytool keychain profile,
#     and Sparkle's key in the login keychain.
#
# Environment (may be set in $AMBIT_RELEASE_ENV, default ~/.config/ambit-signing/release.env):
#   AMBIT_SIGNING_KEYCHAIN                keychain holding the Developer ID identity
#   AMBIT_SIGNING_KEYCHAIN_PASSWORD_FILE  file holding that keychain's password
#   AMBIT_NOTARY_ENV                      file defining KEY (.p8 path), KEY_ID and ISSUER
#   AMBIT_SPARKLE_KEY_FILE                Sparkle ed25519 private key file
#   AMBIT_SIGN_IDENTITY                   codesign identity (default: first "Developer ID Application")
#   AMBIT_NOTARY_PROFILE                  notarytool keychain profile (default: ambit)
#   PUBLISH=1                             also create the GitHub release and push the appcast
#   SKIP_NOTARIZE=1                       stop after signing (for testing the pipeline)
#
# Never run this script with tracing (bash -x): it reads a keychain password.
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
# The build number is the time of the commit being released, in UTC, as YYYYMMDDHHMM. It is what
# Sparkle compares, so it must only go up; the version string may stay the same between builds.
BUILD_NUMBER="$(TZ=UTC0 git log -1 --format=%cd --date=format-local:%Y%m%d%H%M HEAD)"
[[ "$BUILD_NUMBER" =~ ^[0-9]{12}$ ]] || { echo "Could not read the commit time for the build number."; exit 1; }

RELEASE_ENV="${AMBIT_RELEASE_ENV:-$HOME/.config/ambit-signing/release.env}"
if [[ -r "$RELEASE_ENV" ]]; then
  # shellcheck disable=SC1090
  set -a; . "$RELEASE_ENV"; set +a
fi
KEYCHAIN="${AMBIT_SIGNING_KEYCHAIN:-}"
KEYCHAIN_ARGS=()
if [[ -n "$KEYCHAIN" ]]; then
  PASSWORD_FILE="${AMBIT_SIGNING_KEYCHAIN_PASSWORD_FILE:?set AMBIT_SIGNING_KEYCHAIN_PASSWORD_FILE}"
  [[ -f "$KEYCHAIN" && -r "$PASSWORD_FILE" ]] || { echo "Signing keychain or its password file is missing."; exit 1; }
  KEYCHAIN_PASSWORD="$(<"$PASSWORD_FILE")"
  case "$KEYCHAIN_PASSWORD$KEYCHAIN" in
    *\"*|*\\*|*$'\n'*) unset KEYCHAIN_PASSWORD; echo "Keychain path or password has a quote, backslash or newline."; exit 1 ;;
  esac
  # The password goes to `security` on stdin, never on a command line.
  printf 'unlock-keychain -p "%s" "%s"\n' "$KEYCHAIN_PASSWORD" "$KEYCHAIN" | security -i >/dev/null \
    || { unset KEYCHAIN_PASSWORD; echo "Could not unlock $KEYCHAIN"; exit 1; }
  unset KEYCHAIN_PASSWORD
  KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
fi

IDENTITY="${AMBIT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning ${KEYCHAIN:+"$KEYCHAIN"} | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application identity found."; exit 1; }
TEAM="$(sed -E 's/.*\(([A-Z0-9]+)\)$/\1/' <<<"$IDENTITY")"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is dirty. Commit first so the release matches a commit."; exit 1
fi

# The highest build number in an appcast, read from the named file or from standard input.
feed_build() { sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<\/sparkle:version>.*/\1/p' "$@" | sort -n | tail -1; }

# A version whose DMG is already published is never rebuilt: its bytes are what the appcast
# signature must match. A retry reuses the published DMG and only finishes the missing steps.
ASSET="Ambit-$VERSION.dmg"
REUSE=0
mkdir -p "$DIST"
if [[ "${PUBLISH:-0}" == "1" ]] && gh release view "v$VERSION" --repo "$REPO" --json assets \
     --jq '.assets[].name' 2>/dev/null | grep -qx "$ASSET"; then
  echo "==> v$VERSION is already published; reusing its DMG"
  REUSE=1
  gh release download "v$VERSION" --repo "$REPO" --pattern "$ASSET" --dir "$DIST" --clobber
  # Only a DMG that is notarized and signed by this team gets an appcast entry.
  spctl --assess --type open --context context:primary-signature "$DMG"
  SIGNED_BY="$(codesign -dv "$DMG" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
  [[ "$SIGNED_BY" == "$TEAM" ]] || { echo "Published DMG is not signed by team $TEAM."; exit 1; }
elif [[ "${PUBLISH:-0}" == "1" ]]; then
  # A new published build must be exactly what is on origin/main; the build number (commit
  # time) only goes up along main. A retry of an already published version skips this,
  # because main may have moved on since.
  git fetch --quiet origin main
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || { echo "PUBLISH=1 requires HEAD to equal origin/main."; exit 1; }
  # Installed copies are only offered a build number higher than their own. A second version cut
  # from a commit that is already released, or a commit whose time is not later, would publish
  # an update nobody receives. Checked here, before anything is built, tagged or uploaded.
  if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
    git fetch --quiet origin gh-pages
    LIVE_BUILD="$(git show origin/gh-pages:appcast.xml 2>/dev/null | feed_build || true)"
    if [[ -n "$LIVE_BUILD" && "$BUILD_NUMBER" -le "$LIVE_BUILD" ]]; then
      echo "Build $BUILD_NUMBER is not newer than published build $LIVE_BUILD. Release from a newer commit."; exit 1
    fi
  fi
fi

STAGE="$(mktemp -d)"
FEED="$(mktemp -d)"
PAGES="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$FEED"; git worktree remove --force "$PAGES" 2>/dev/null || true; rm -rf "$PAGES"' EXIT

xcodegen generate --quiet

if [[ "$REUSE" == "0" ]]; then
  echo "==> Tests"
  swift test

  echo "==> Build $VERSION ($BUILD_NUMBER), universal, Release"
  xcodebuild -project Ambit.xcodeproj -scheme Ambit -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" -quiet build

  # The build is ad-hoc signed; every Mach-O is then signed here with Developer ID, hardened
  # runtime and a secure timestamp, innermost first.
  echo "==> Sign with Developer ID, inside out"
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  sign() { codesign --force --options runtime --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$@"; }
  sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  sign "$SPARKLE/Versions/B/Autoupdate"
  sign "$SPARKLE/Versions/B/Updater.app"
  sign "$SPARKLE"
  sign "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
    echo "The app is signed with get-task-allow; notarization would reject it."; exit 1
  fi
  lipo -archs "$APP/Contents/MacOS/Ambit" | grep -q x86_64 && lipo -archs "$APP/Contents/MacOS/Ambit" | grep -q arm64 \
    || { echo "The app is not a universal binary."; exit 1; }

  if [[ -z "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null)" ]]; then
    echo "SUPublicEDKey is empty: this build cannot auto-update. Set SPARKLE_PUBLIC_KEY in project.yml."; exit 1
  fi

  echo "==> DMG"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "Ambit" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  codesign --force --timestamp ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$DMG"

  if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "Signed, not notarized: $DMG"; exit 0
  fi

  echo "==> Notarize"
  if [[ -n "${AMBIT_NOTARY_ENV:-}" ]]; then
    NOTARY_ARGS="$( set -a; . "$AMBIT_NOTARY_ENV"; set +a
      [[ -n "${KEY:-}" && -n "${KEY_ID:-}" && -n "${ISSUER:-}" && -r "${KEY:-}" ]] || exit 1
      printf '%s\n%s\n%s\n' "$KEY" "$KEY_ID" "$ISSUER" )" \
      || { echo "AMBIT_NOTARY_ENV must define KEY (readable .p8), KEY_ID and ISSUER."; exit 1; }
    { read -r N_KEY; read -r N_KEY_ID; read -r N_ISSUER; } <<<"$NOTARY_ARGS"
    xcrun notarytool submit "$DMG" --key "$N_KEY" --key-id "$N_KEY_ID" --issuer "$N_ISSUER" --wait
  else
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  fi
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
else
  xcodebuild -project Ambit.xcodeproj -scheme Ambit -derivedDataPath "$DERIVED" \
    -resolvePackageDependencies -quiet
fi

echo "==> Appcast"
# The feed is generated from a directory holding only this release's DMG, so stale archives in
# dist/ can never be advertised under this version's download URL.
cp "$DMG" "$FEED/"
SPARKLE_KEY_ARGS=()
[[ -n "${AMBIT_SPARKLE_KEY_FILE:-}" ]] && SPARKLE_KEY_ARGS=(--ed-key-file "$AMBIT_SPARKLE_KEY_FILE")
"$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
  ${SPARKLE_KEY_ARGS[@]+"${SPARKLE_KEY_ARGS[@]}"} \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  --maximum-deltas 0 \
  -o "$FEED/appcast.xml" "$FEED"
# generate_appcast writes an unsigned entry when it cannot reach the Sparkle private key; such a
# feed would be rejected by every installed copy.
grep -q 'sparkle:edSignature="' "$FEED/appcast.xml" \
  || { echo "Appcast entry is not signed. Is the Sparkle private key in the keychain?"; exit 1; }
cp "$FEED/appcast.xml" "$DIST/appcast.xml"

if [[ "${PUBLISH:-0}" != "1" ]]; then
  echo "Built $DMG and $DIST/appcast.xml. Re-run with PUBLISH=1 to upload."; exit 0
fi

echo "==> Publish"
if [[ "$REUSE" == "0" ]]; then
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    [[ "$(git rev-parse "v$VERSION^{commit}")" == "$(git rev-parse HEAD)" ]] \
      || { echo "Tag v$VERSION exists on a different commit."; exit 1; }
  else
    git tag -a "v$VERSION" -m "Ambit $VERSION"
  fi
  git push origin "v$VERSION"
  if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$DMG" --repo "$REPO"
  else
    gh release create "v$VERSION" "$DMG" --repo "$REPO" --title "Ambit $VERSION" --generate-notes
  fi
fi

if git ls-remote --exit-code --heads origin gh-pages >/dev/null 2>&1; then
  git fetch --quiet origin gh-pages
  rmdir "$PAGES"
  git worktree add -B gh-pages "$PAGES" origin/gh-pages
else
  rmdir "$PAGES"
  git worktree add --orphan -B gh-pages "$PAGES"
fi
# A retry of an older version must never replace a feed that already offers a newer build.
if [[ -f "$PAGES/appcast.xml" ]]; then
  PUBLISHED_BUILD="$(feed_build "$PAGES/appcast.xml")"
  CANDIDATE_BUILD="$(feed_build "$DIST/appcast.xml")"
  [[ -n "$CANDIDATE_BUILD" ]] || { echo "Could not read the build number from the new appcast."; exit 1; }
  if [[ -n "$PUBLISHED_BUILD" && "$PUBLISHED_BUILD" -gt "$CANDIDATE_BUILD" ]]; then
    echo "Published feed already offers build $PUBLISHED_BUILD (newer than $CANDIDATE_BUILD); leaving it."; exit 1
  fi
fi
cp "$DIST/appcast.xml" "$PAGES/appcast.xml"
git -C "$PAGES" add appcast.xml
git -C "$PAGES" diff --cached --quiet || git -C "$PAGES" commit -m "Appcast for $VERSION"
git -C "$PAGES" push origin gh-pages
echo "Released v$VERSION"

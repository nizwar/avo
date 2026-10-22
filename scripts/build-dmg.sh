#!/usr/bin/env bash
# Builds a Release Avo.app and packs it into a disk image.
#
#   scripts/build-dmg.sh --version 0.1.0 --build 32 [--out DIR] [--identity ID [--notarize]]
#
#     --version    CFBundleShortVersionString (MARKETING_VERSION)
#     --build      CFBundleVersion (CURRENT_PROJECT_VERSION); Sparkle compares it
#     --out        where Avo-<version>-b<build>.dmg goes (default: build/)
#     --identity   code signing identity (default: "-", ad hoc), for example
#                  "Developer ID Application: Name (TEAMID)": then every piece
#                  gets the hardened runtime and a secure timestamp
#     --notarize   with a Developer ID: notarizes the app and staples it, then
#                  the signed disk image too. Apple ID and app-specific
#                  password from APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD
#                  (never printed); the team from the identity
#
# Steps:
#   1. the GPU renderer, scripts/build-gfxstream.sh, and Android's Bluetooth
#      controller, scripts/build-bluetooth.sh (each only when its pinned
#      versions changed: build/gfxstream, build/bluetooth);
#   2. xcodebuild, Release, into build/DerivedData-release (needs the
#      generated project, `make project`, and Rust for avo-vmm);
#   3. a staged copy re-signed inside out, each item with its own
#      entitlements (the renderer's libraries and the Bluetooth controller
#      too); avo-vmm keeps the
#      signature its build phase gave it (hardened runtime and the
#      hypervisor entitlement);
#   4. dmgbuild with scripts/dmg/settings.py (a virtual environment with
#      dmgbuild is created in build/dmg-venv when none is there);
#   5. checks: the image verifies and the app inside it still validates.
#
# An ad hoc build makes testers confirm the first open in System Settings ›
# Privacy & Security. A Developer ID build, notarized, opens like any app
# (docs/releasing.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
BUILD=""
OUT="$ROOT/build"
IDENTITY="-"
NOTARIZE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "usage: $0 --version X.Y.Z --build N [--out DIR] [--identity ID [--notarize]]" >&2; exit 2; }
if [[ "$IDENTITY" == "-" ]]; then
  SIGN_FLAGS=(--timestamp=none)
else
  # Notarization needs both on every piece of code.
  SIGN_FLAGS=(--options runtime --timestamp)
fi
TEAM="$(printf '%s' "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')"
if [[ "$NOTARIZE" == 1 ]]; then
  [[ -n "$TEAM" ]] || { echo "--notarize needs a Developer ID identity with its team: \"Developer ID Application: Name (TEAMID)\"" >&2; exit 2; }
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] \
    || { echo "--notarize needs APPLE_ID and APPLE_APP_SPECIFIC_PASSWORD in the environment" >&2; exit 2; }
fi

DERIVED="$ROOT/build/DerivedData-release"
STAGE="$ROOT/build/release-stage"
DMG="$OUT/Avo-$VERSION-b$BUILD.dmg"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
export PATH="$HOME/.cargo/bin:$PATH"
mkdir -p "$OUT"

echo "== GPU renderer"
# Built once, then only when its pinned versions change (build/gfxstream).
"$ROOT/scripts/build-gfxstream.sh"

echo "== Bluetooth controller"
# The same (build/bluetooth).
"$ROOT/scripts/build-bluetooth.sh"

echo "== build $VERSION ($BUILD)"
xcodebuild -project "$ROOT/host/Avo.xcodeproj" -scheme Avo -configuration Release \
  -derivedDataPath "$DERIVED" CURRENT_PROJECT_VERSION="$BUILD" MARKETING_VERSION="$VERSION" \
  build > "$OUT/build-$BUILD.log" 2>&1 || { grep -E "error:" "$OUT/build-$BUILD.log" | sort -u | head -20; echo "build failed (log: $OUT/build-$BUILD.log)"; exit 1; }

echo "== stage and sign ($IDENTITY)"
rm -rf "$STAGE"
mkdir -p "$STAGE/entitlements"
ditto "$DERIVED/Build/Products/Release/Avo.app" "$STAGE/Avo.app"
APP="$STAGE/Avo.app"
sign() {
  local path="$1" name="$2" plist="$STAGE/entitlements/$2.plist"
  codesign -d --entitlements - --xml "$path" > "$plist" 2>/dev/null || true
  if [[ -s "$plist" ]]; then
    codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" --entitlements "$plist" "$path"
  else
    codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$path"
  fi
}
# What Xcode makes of the AvoKit package carries SwiftPM's identifiers
# (avokit.AvoHostKit, avokit.AvoKit.resources): Avo's own code goes under
# Avo's domain like the rest (the resource bundles are sealed with their app).
plist_id() { /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $2" "$1"; }
plist_id "$APP/Contents/Frameworks/AvoHostKit.framework/Versions/A/Resources/Info.plist" com.avodroid.AvoHostKit
for resources in "$APP/Contents/Resources/AvoKit_AvoKit.bundle" \
                 "$APP/Contents/Library/Helpers/AvoDaemon.app/Contents/Resources/AvoKit_AvoKit.bundle"; do
  [[ -f "$resources/Contents/Info.plist" ]] && plist_id "$resources/Contents/Info.plist" com.avodroid.AvoKit.resources
done
# A tool or library has no Info.plist to name it: its signature gets one,
# keeping its entitlements and hardened runtime.
sign_as() {
  codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" --identifier "$2" \
    --preserve-metadata=entitlements,flags,runtime "$1"
}
# Sparkle's inner pieces, inside out, before the framework (docs/releasing.md).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE" ]]; then
  for piece in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    [[ -e "$SPARKLE/$piece" ]] && codesign --force "${SIGN_FLAGS[@]}" --sign "$IDENTITY" \
      --preserve-metadata=entitlements "$SPARKLE/$piece"
  done
fi
for framework in "$APP"/Contents/Frameworks/*.framework; do sign "$framework" "$(basename "$framework")"; done
# The GPU renderer avo-vmm loads (build-gfxstream.sh): no release without it.
[[ -f "$APP/Contents/Resources/gfxstream/.stamp" ]] || { echo "Avo.app has no GPU renderer (Resources/gfxstream)"; exit 1; }
for lib in "$APP"/Contents/Resources/gfxstream/lib64/*.dylib "$APP"/Contents/Resources/gfxstream/lib64/vulkan/*.dylib; do
  sign "$lib" "gfxstream-$(basename "$lib")"
done
# Android's Bluetooth controller (build-bluetooth.sh): no release without it either.
[[ -x "$APP/Contents/Resources/bluetooth/rootcanal" ]] || { echo "Avo.app has no Bluetooth controller (Resources/bluetooth)"; exit 1; }
sign_as "$APP/Contents/Resources/bluetooth/rootcanal" com.avodroid.rootcanal
[[ -d "$APP/Contents/Library/Shim/AvoShim.app" ]] && sign "$APP/Contents/Library/Shim/AvoShim.app" shim
sign "$APP/Contents/Library/Helpers/AvoDaemon.app" daemon
sign_as "$APP/Contents/MacOS/avoctl" com.avodroid.avoctl
sign_as "$APP/Contents/MacOS/avo-vmm" com.avodroid.avo-vmm
sign "$APP" app
codesign --verify --deep --strict "$APP"
echo "signed: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist"))"

# Apple's notary service, waiting for its verdict; on a rejection its log
# says why (notary-<build>.json next to the disk image).
notarize() {
  local result status id
  result="$(xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --team-id "$TEAM" --wait --timeout 1h --output-format json 2>/dev/null)" || true
  status="$(printf '%s' "$result" | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("status", ""))' 2>/dev/null || true)"
  id="$(printf '%s' "$result" | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("id", ""))' 2>/dev/null || true)"
  echo "   $(basename "$1"): ${status:-no answer} ${id:+($id)}"
  if [[ "$status" != "Accepted" ]]; then
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" --apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --team-id "$TEAM" "$OUT/notary-$BUILD.json" >/dev/null 2>&1 && echo "   log: $OUT/notary-$BUILD.json"
    fi
    exit 1
  fi
}
if [[ "$NOTARIZE" == 1 ]]; then
  echo "== notarize the app"
  rm -f "$STAGE/Avo.zip"
  ditto -c -k --keepParent "$APP" "$STAGE/Avo.zip"
  notarize "$STAGE/Avo.zip"
  xcrun stapler staple -q "$APP"
  codesign --verify --deep --strict "$APP"
fi

echo "== disk image"
VENV="$ROOT/build/dmg-venv"
if [[ ! -x "$VENV/bin/dmgbuild" ]]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet dmgbuild
fi
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg/settings.py" -D app="$APP" \
  -D background="$ROOT/scripts/dmg/background.tiff" "Avo $VERSION" "$DMG"
hdiutil verify "$DMG" > /dev/null
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [[ "$NOTARIZE" == 1 ]]; then
  echo "== notarize the disk image"
  notarize "$DMG"
  xcrun stapler staple -q "$DMG"
  xcrun stapler validate -q "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
fi
MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
codesign --verify --deep --strict "$MOUNT/Avo.app"
if [[ "$NOTARIZE" == 1 ]]; then
  # What Gatekeeper says to a download: "Notarized Developer ID".
  spctl --assess --type execute -vv "$MOUNT/Avo.app" 2>&1 | sed 's/^/   /'
fi
hdiutil detach "$MOUNT" -quiet

# Launch Services would otherwise keep the build copies as candidates for
# com.avodroid.emulator next to the installed app.
for app in "$DERIVED/Build/Products" "$STAGE"; do
  find "$app" -name "*.app" -type d -prune -exec "$LSREGISTER" -u {} \; 2>/dev/null || true
done

shasum -a 256 "$DMG"
ls -lh "$DMG"

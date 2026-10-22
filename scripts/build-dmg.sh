#!/usr/bin/env bash
# Builds a Release Avo.app and packs it into a disk image.
#
#   scripts/build-dmg.sh --version 0.1.0 --build 32 [--out DIR] [--identity ID]
#
#     --version    CFBundleShortVersionString (MARKETING_VERSION)
#     --build      CFBundleVersion (CURRENT_PROJECT_VERSION); Sparkle compares it
#     --out        where Avo-<version>-b<build>.dmg goes (default: build/)
#     --identity   code signing identity (default: "-", ad hoc)
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
# Ad hoc signing is what preview builds use: testers confirm the first open in
# System Settings › Privacy & Security. Public releases need a Developer ID
# signature and notarization (docs/releasing.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
BUILD=""
OUT="$ROOT/build"
IDENTITY="-"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$VERSION" && -n "$BUILD" ]] || { echo "usage: $0 --version X.Y.Z --build N [--out DIR] [--identity ID]" >&2; exit 2; }

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
    codesign --force --timestamp=none --sign "$IDENTITY" --entitlements "$plist" "$path"
  else
    codesign --force --timestamp=none --sign "$IDENTITY" "$path"
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
  codesign --force --timestamp=none --sign "$IDENTITY" --identifier "$2" \
    --preserve-metadata=entitlements,flags,runtime "$1"
}
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
MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
codesign --verify --deep --strict "$MOUNT/Avo.app"
hdiutil detach "$MOUNT" -quiet

# Launch Services would otherwise keep the build copies as candidates for
# com.avodroid.emulator next to the installed app.
for app in "$DERIVED/Build/Products" "$STAGE"; do
  find "$app" -name "*.app" -type d -prune -exec "$LSREGISTER" -u {} \; 2>/dev/null || true
done

shasum -a 256 "$DMG"
ls -lh "$DMG"

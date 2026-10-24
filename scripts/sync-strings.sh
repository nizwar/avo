#!/usr/bin/env bash
# Updates the String Catalogs from the strings the compiler saw in the last
# build (SWIFT_EMIT_LOC_STRINGS writes one .stringsdata file per source file).
# Xcode does this by itself when you build in the IDE; run this after building
# from the command line:
#
#   make build && scripts/sync-strings.sh [DerivedData]
#
# New strings arrive untranslated; strings no longer in the code are marked
# stale. Translate in Xcode's catalog editor or edit the JSON directly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${1:-$ROOT/build/DerivedData}"
INTERMEDIATES="$DERIVED/Build/Intermediates.noindex"
[[ -d "$INTERMEDIATES" ]] || { echo "no build in $DERIVED; run make build first" >&2; exit 1; }

# sync <catalog> <directory with the target's .stringsdata files>...
sync() {
  local catalog="$1"; shift
  local files=()
  while IFS= read -r file; do files+=(--stringsdata "$file"); done < <(
    find "$@" -name '*.stringsdata' ! -name 'ExtractedAppShortcutsMetadata.stringsdata' \
      ! -name 'GeneratedStringSymbols_*.stringsdata' | sort)
  [[ ${#files[@]} -gt 0 ]] || { echo "no strings for $catalog" >&2; exit 1; }
  xcrun xcstringstool sync "$ROOT/$catalog" "${files[@]}"
  echo "synced $catalog ($(( ${#files[@]} / 2 )) source files)"
}

APP="$INTERMEDIATES/Avo.build/Debug"
sync host/Avo/Localizable.xcstrings "$APP/Avo.build"
sync host/AvoDaemon/Localizable.xcstrings "$APP/AvoDaemon.build"
sync host/AvoWindowHost/Localizable.xcstrings "$APP/AvoWindowHost.build"
sync host/AvoShim/Localizable.xcstrings "$APP/AvoShim.build"

# Every module of the AvoKit package shares one catalog (Bundle.avoKit).
PKG="$INTERMEDIATES/AvoKit.build/Debug"
sync host/AvoKit/Sources/AvoKit/Resources/Localizable.xcstrings \
  "$PKG"/AvoKit-t.build "$PKG"/AvoPackages-t.build \
  "$PKG"/AvoDaemonCore-t.build "$PKG"/AvoShimKit-t.build

# avo_kit (vendor/avo_kit), shared with Avo Hub, has one catalog of its own
# (Bundle.avoSharedKit): commit what this changes there, in avo_kit.
KIT="$INTERMEDIATES/avo_kit.build/Debug"
sync vendor/avo_kit/Sources/AvoKitResources/Resources/Localizable.xcstrings \
  "$KIT"/AvoKeymap-t.build "$KIT"/AvoKeymapUI-t.build "$KIT"/AvoHazeUI-t.build \
  "$KIT"/AvoKitResources-t.build "$KIT"/AvoScreen-t.build "$KIT"/AvoInput-t.build

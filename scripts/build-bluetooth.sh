#!/usr/bin/env bash
# Builds Android's Bluetooth controller from source into build/bluetooth:
#
#   rootcanal          Root Canal, the virtual Bluetooth controller Android's
#                      Cuttlefish uses (and the Android Emulator's netsimd has
#                      inside), from github.com/google/rootcanal, which
#                      follows AOSP's packages/modules/Bluetooth/tools/rootcanal
#   source.properties  what this is, its revision
#   licenses/          the licences of what it contains
#
# avo-vmm starts it for Android's Bluetooth (engine/hvf/vmm/src/bluetooth.rs)
# and bridges /dev/hvc5 to its HCI port; the daemon's proxy chips for the
# Mac's Bluetooth devices connect to the same port (MacBluetoothBridge.swift).
# All of it is Apache 2.0 (fmt: MIT; protobuf, gflags: BSD), so Avo ships it:
# users need no Android Studio or Android Emulator for Bluetooth.
#
# Root Canal gets Avo's patches (scripts/bluetooth-patches, in name order):
#
#   0001-apple-support-toolchain    Apple's C++ toolchain, which knows
#                                   Xcode's SDK (Bazel's default one stops
#                                   at SDKSettings.json)
#   0002-listen-on-localhost        its ports take connections from this Mac
#                                   only, not the network
#   0003-exit-with-parent           it ends with avo-vmm, however avo-vmm
#                                   ends
#
# Rust is built unstripped: macOS 27's dyld refuses the proc-macro libraries
# rustc's own stripping leaves ("mis-aligned LINKEDIT string pool"); the
# binary is stripped at the end instead. It runs on the macOS Avo runs on.
#
#   scripts/build-bluetooth.sh [--force]
#
# Sources are kept in build/rootcanal-src (Bazel's own cache is its usual
# one); nothing happens when build/bluetooth is already this version.
# ROOTCANAL_SRC and BLUETOOTH_OUT name other folders. The Xcode build copies
# build/bluetooth into Avo.app/Contents/Resources/bluetooth;
# scripts/build-dmg.sh runs this first. Needs git and bazelisk
# (brew install bazelisk); Bazel fetches its own Rust and C++ dependencies.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${BLUETOOTH_OUT:-$ROOT/build/bluetooth}"
SRC="${ROOTCANAL_SRC:-$ROOT/build/rootcanal-src}"
PATCHES="$ROOT/scripts/bluetooth-patches"
# Avo's (host/Config/Base.xcconfig MACOSX_DEPLOYMENT_TARGET).
MACOS_MINIMUM=15.0

# google/rootcanal main: "Sync with aosp main" (2026-10-02).
ROOTCANAL_COMMIT=574dc62546e0adcfacb6d6df4776f9d4f24d32d8
# The Bazel its MODULE.bazel was made with (rules_rust 0.68, protobuf 33).
BAZEL_VERSION=8.8.2
# Bump with any change above.
REVISION=avo.1

PATCH_SUM="$(cat "$PATCHES"/*.patch | shasum -a 256 | cut -c 1-12)"
STAMP="$REVISION $ROOTCANAL_COMMIT $BAZEL_VERSION $MACOS_MINIMUM $PATCH_SUM"
if [[ "${1:-}" != "--force" && -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$STAMP" ]]; then
  echo "${OUT#"$ROOT"/} is up to date ($REVISION)"
  exit 0
fi
for tool in git bazelisk; do
  command -v "$tool" >/dev/null || { echo "$tool is needed (brew install $tool)" >&2; exit 1; }
done

echo "== Root Canal $ROOTCANAL_COMMIT"
if [[ ! -d "$SRC/.git" ]]; then
  git clone --quiet https://github.com/google/rootcanal.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$ROOTCANAL_COMMIT"
git -C "$SRC" checkout --quiet --force "$ROOTCANAL_COMMIT"
git -C "$SRC" submodule update --quiet --init --recursive
for patch in "$PATCHES"/*.patch; do
  echo "   patch $(basename "$patch")"
  git -C "$SRC" apply "$patch"
done

echo "== building (bazel $BAZEL_VERSION, optimized, macOS $MACOS_MINIMUM)"
FLAGS=(--compilation_mode=opt "--macos_minimum_os=$MACOS_MINIMUM"
       --@rules_rust//rust/settings:extra_rustc_flag=-Cstrip=none
       --@rules_rust//rust/settings:extra_exec_rustc_flag=-Cstrip=none)
(cd "$SRC" && USE_BAZEL_VERSION="$BAZEL_VERSION" bazelisk build "${FLAGS[@]}" //:rootcanal)
BINARY="$(cd "$SRC" && USE_BAZEL_VERSION="$BAZEL_VERSION" bazelisk cquery "${FLAGS[@]}" --output=files //:rootcanal 2>/dev/null)"

rm -rf "$OUT"
mkdir -p "$OUT/licenses"
install -m 755 "$SRC/$BINARY" "$OUT/rootcanal"
strip -x "$OUT/rootcanal"
# A check that it runs at all (gflags' help ends with status 1).
("$OUT/rootcanal" --help 2>&1 || true) | grep -q hci_port || { echo "the built rootcanal does not run" >&2; exit 1; }
cp "$SRC/LICENSE" "$OUT/licenses/rootcanal-LICENSE"
cp "$SRC/third_party/fmtlib/LICENSE"* "$OUT/licenses/fmt-LICENSE" 2>/dev/null || true
cp "$SRC/third_party/pdl/LICENSE" "$OUT/licenses/pdl-LICENSE" 2>/dev/null || true
EXTERNAL="$(cd "$SRC" && USE_BAZEL_VERSION="$BAZEL_VERSION" bazelisk info output_base 2>/dev/null)/external"
for external in protobuf gflags openssl abseil-cpp; do
  for licence in "$EXTERNAL"/*"$external"*/LICENSE* "$EXTERNAL"/*"$external"*/COPYING*; do
    [[ -f "$licence" ]] && cp "$licence" "$OUT/licenses/$external-$(basename "$licence")" && break
  done
done
# The Rust crates it compiles in (MIT or Apache 2.0).
mkdir -p "$OUT/licenses/rust"
for crate in "$EXTERNAL"/*crate+crates__*; do
  for licence in "$crate"/LICENSE*; do
    [[ -f "$licence" ]] && cp "$licence" "$OUT/licenses/rust/$(basename "$crate" | sed 's/.*crates__//')-$(basename "$licence")"
  done
done
cat > "$OUT/source.properties" <<EOF
Pkg.Desc = Root Canal, Android's virtual Bluetooth controller, built from source for Avo
Pkg.Revision = $REVISION
RootCanal.Commit = $ROOTCANAL_COMMIT
EOF
echo "$STAMP" > "$OUT/.stamp"
echo "== ${OUT#"$ROOT"/}: $(du -sh "$OUT" | cut -f1)"

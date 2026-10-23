#!/usr/bin/env bash
# Builds Avo's GPU renderer from source into build/gfxstream, in the Android
# Emulator's layout that avo-vmm loads (docs/engine.md, "GPU (gfxstream)"):
#
#   lib64/libgfxstream_backend.dylib    gfxstream's host renderer (AOSP), the
#                                       snapshot the Android Emulator 37.1 has
#   lib64/vulkan/libvulkan.dylib        the Khronos Vulkan loader
#   lib64/vulkan/libMoltenVK.dylib      MoltenVK (Khronos release binary)
#   lib64/vulkan/MoltenVK_icd.json
#   source.properties                   what this is (Pkg.Desc), its revision
#   licenses/                           the licences of what it contains
#
# gfxstream gets Avo's patches (scripts/gfxstream-patches, in name order):
#
#   0001-sequence-gate                  a guest process's commands keep their
#                                       order; with AVO_GFXSTREAM_SEQNO_SKIP_MS
#                                       set, numbers guest threads took and
#                                       never sent (the guest driver's lock)
#                                       no longer stop the process. Off by
#                                       default: Avo's guest layer keeps that
#                                       deadlock away, and a host too busy to
#                                       pick a sent number up in time would
#                                       run commands out of order
#   0002-hide-linear-astc-sampling      the guest no longer sees the linear
#                                       ASTC sampling Avo's Mac layer reports
#
# With them and avo-vmm's Vulkan layer (engine/hvf/vmm/layer), a guest could
# run without Avo's guest layer; source.properties says so
# (Avo.HostGfxsync=1). The daemon does not read it yet and still gives the
# guest its layer (in its Vulkan driver, or in /data/local/debug).
#
# All of it is Apache 2.0 (headers it compiles in: MIT and alike), unlike the
# emulator's prebuilt libraries, which the Android SDK licence keeps Avo from
# shipping. Users need no Android Studio for the GPU.
#
#   scripts/build-gfxstream.sh [--force]
#
# Sources and builds are kept in build/gfxstream-src; nothing happens when
# build/gfxstream is already this version. GFXSTREAM_SRC and GFXSTREAM_OUT
# name other folders for both (a build beside the one Xcode copies). The
# Xcode build copies build/gfxstream into Avo.app/Contents/Resources/gfxstream;
# scripts/build-dmg.sh runs this first.
# Needs git, cmake, ninja and Xcode's command line tools.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${GFXSTREAM_OUT:-$ROOT/build/gfxstream}"
SRC="${GFXSTREAM_SRC:-$ROOT/build/gfxstream-src}"
PATCHES="$ROOT/scripts/gfxstream-patches"

# gfxstream, emu-main-dev: "Snap for 15813814 ... to emu-37-1-release".
GFXSTREAM_COMMIT=ec3143b4ac345af198b3f5690bfc79c728128704
VULKAN_VERSION=v1.4.365
MOLTENVK_VERSION=v1.4.0
MOLTENVK_SHA256=f4feaf6a4988352de8e6d49874ccc1cd6a45021e3cb476e8531bef7ecc73e93a
# Bump with any change above or below: it keys avo-vmm's GPU shader cache.
REVISION=avo.2

PATCH_SUM="$(cat "$PATCHES"/*.patch | shasum -a 256 | cut -c 1-12)"
STAMP="$REVISION $GFXSTREAM_COMMIT $VULKAN_VERSION $MOLTENVK_VERSION $PATCH_SUM"
if [[ "${1:-}" != "--force" && -f "$OUT/.stamp" && "$(cat "$OUT/.stamp")" == "$STAMP" ]]; then
  echo "${OUT#"$ROOT"/} is up to date ($REVISION)"
  exit 0
fi
for tool in git cmake ninja; do
  command -v "$tool" >/dev/null || { echo "$tool is needed (brew install $tool)" >&2; exit 1; }
done
mkdir -p "$SRC"
CMAKE_COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0)

# fetch <dir> <url> <commit or tag>: that commit alone, kept between runs.
fetch() {
  local dir="$1" url="$2" ref="$3"
  [[ -d "$dir/.git" ]] || { git init -q "$dir"; git -C "$dir" remote add origin "$url"; }
  if ! git -C "$dir" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
    git -C "$dir" fetch -q --depth 1 origin "$ref"
  fi
  git -C "$dir" -c advice.detachedHead=false checkout -q --force FETCH_HEAD 2>/dev/null \
    || git -C "$dir" -c advice.detachedHead=false checkout -q --force "$ref"
}

echo "== gfxstream ${GFXSTREAM_COMMIT:0:12}"
fetch "$SRC/gfxstream" https://android.googlesource.com/platform/hardware/google/gfxstream "$GFXSTREAM_COMMIT"
# The checkout is the commit's again; files a patch added last time go first.
git -C "$SRC/gfxstream" clean -fdq
for patch in "$PATCHES"/*.patch; do
  git -C "$SRC/gfxstream" apply --whitespace=nowarn "$patch" || { echo "$patch does not apply" >&2; exit 1; }
done
# Its Cocoa window code uses NSOpenGLView, deprecated: not an error here.
cmake -S "$SRC/gfxstream" -B "$SRC/gfxstream-build" "${CMAKE_COMMON[@]}" \
  -DBUILD_STANDALONE=ON -DDEPENDENCY_RESOLUTION=AOSP \
  -DCMAKE_CXX_FLAGS=-Wno-error=deprecated-declarations \
  -DCMAKE_OBJCXX_FLAGS=-Wno-error=deprecated-declarations > "$SRC/gfxstream-cmake.log"
cmake --build "$SRC/gfxstream-build" --target gfxstream_backend > "$SRC/gfxstream-build.log" \
  || { grep -E "error:" "$SRC/gfxstream-build.log" | head -20; exit 1; }

echo "== Vulkan loader $VULKAN_VERSION"
fetch "$SRC/Vulkan-Headers" https://github.com/KhronosGroup/Vulkan-Headers "refs/tags/$VULKAN_VERSION"
fetch "$SRC/Vulkan-Loader" https://github.com/KhronosGroup/Vulkan-Loader "refs/tags/$VULKAN_VERSION"
cmake -S "$SRC/Vulkan-Headers" -B "$SRC/headers-build" -G Ninja > "$SRC/headers.log"
cmake --install "$SRC/headers-build" --prefix "$SRC/headers" >> "$SRC/headers.log"
cmake -S "$SRC/Vulkan-Loader" -B "$SRC/loader-build" "${CMAKE_COMMON[@]}" \
  -DVULKAN_HEADERS_INSTALL_DIR="$SRC/headers" -DBUILD_TESTS=OFF > "$SRC/loader-cmake.log"
cmake --build "$SRC/loader-build" > "$SRC/loader-build.log" \
  || { grep -E "error:" "$SRC/loader-build.log" | head -20; exit 1; }

echo "== MoltenVK $MOLTENVK_VERSION"
TAR="$SRC/MoltenVK-$MOLTENVK_VERSION-macos.tar"
if [[ ! -f "$TAR" ]]; then
  curl -fsSL -o "$TAR.part" "https://github.com/KhronosGroup/MoltenVK/releases/download/$MOLTENVK_VERSION/MoltenVK-macos.tar"
  mv "$TAR.part" "$TAR"
fi
[[ "$(shasum -a 256 "$TAR" | cut -d ' ' -f 1)" == "$MOLTENVK_SHA256" ]] || { echo "$TAR is not the MoltenVK $MOLTENVK_VERSION release" >&2; exit 1; }
rm -rf "$SRC/moltenvk"
mkdir -p "$SRC/moltenvk"
tar -xf "$TAR" -C "$SRC/moltenvk"
MVK="$SRC/moltenvk/MoltenVK/MoltenVK/dynamic/dylib/macOS"

echo "== ${OUT#"$ROOT"/}"
rm -rf "$OUT.new"
mkdir -p "$OUT.new/lib64/vulkan" "$OUT.new/licenses/gfxstream"
cp "$SRC/gfxstream-build/libgfxstream_backend.dylib" "$OUT.new/lib64/"
# Avo runs on Apple silicon only.
cp "$(readlink -f "$SRC/loader-build/loader/libvulkan.dylib")" "$OUT.new/lib64/vulkan/libvulkan.dylib"
lipo "$MVK/libMoltenVK.dylib" -thin arm64 -output "$OUT.new/lib64/vulkan/libMoltenVK.dylib" 2>/dev/null \
  || cp "$MVK/libMoltenVK.dylib" "$OUT.new/lib64/vulkan/libMoltenVK.dylib"
cp "$MVK/MoltenVK_icd.json" "$OUT.new/lib64/vulkan/"
strip -x "$OUT.new/lib64/libgfxstream_backend.dylib" "$OUT.new/lib64/vulkan/libvulkan.dylib"
# Stripping and thinning drop the linker's signature; Xcode's build and
# build-dmg.sh sign them again with Avo's identity.
for lib in "$OUT.new"/lib64/*.dylib "$OUT.new"/lib64/vulkan/*.dylib; do codesign --force --sign - "$lib" 2>/dev/null; done
cp "$SRC/gfxstream/LICENSE" "$OUT.new/licenses/gfxstream/LICENSE"
for dep in drm glm opengl renderdoc stb vulkan x11 xcb; do
  [[ -f "$SRC/gfxstream/third_party/$dep/LICENSE" ]] && cp "$SRC/gfxstream/third_party/$dep/LICENSE" "$OUT.new/licenses/gfxstream/third_party-$dep-LICENSE"
done
cp "$SRC/Vulkan-Loader/LICENSE.txt" "$OUT.new/licenses/Vulkan-Loader-LICENSE.txt"
cp "$SRC/moltenvk/MoltenVK/LICENSE" "$OUT.new/licenses/MoltenVK-LICENSE"
cat > "$OUT.new/source.properties" <<EOF
Pkg.Desc=Avo GPU renderer: gfxstream, the Vulkan loader and MoltenVK, built from source
Pkg.Revision=$REVISION
Pkg.BuildId=gfxstream-${GFXSTREAM_COMMIT:0:12}.vulkan-loader-$VULKAN_VERSION.moltenvk-$MOLTENVK_VERSION.avo-patches-$PATCH_SUM
Avo.HostGfxsync=1
EOF
echo "$STAMP" > "$OUT.new/.stamp"
rm -rf "$OUT"
mv "$OUT.new" "$OUT"
du -sh "$OUT" | awk -v out="${OUT#"$ROOT"/}" '{print "done: " out " (" $1 ")"}'

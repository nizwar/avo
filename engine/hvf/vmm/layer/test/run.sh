#!/usr/bin/env bash
# Tests Avo's Mac-side Vulkan layer (../native_astc.c) the way gfxstream uses
# it: through a renderer's Vulkan loader and MoltenVK (Avo's own build,
# build/gfxstream, unless a renderer folder is given).
# - provoking: without the layer MoltenVK has no VK_EXT_provoking_vertex and a
#   device asking for it fails; with it, ANGLE's way through works (extension,
#   provokingVertexLast, device, a pipeline asking for the last vertex), and
#   an instance of another engine is offered the extension too (the guest
#   driver keeps one extension list per process for every instance).
# - each shader of the guest layer's test (guest/gfxsync/test/shaders):
#   "unsplit fails" ones still make no pipeline without the layer; through
#   the layer, with no split of the test's own, each draws what that test
#   expects, from a module and, where the driver has VK_KHR_maintenance5,
#   from inline SPIR-V; "unchanged" ones are left alone.
#
#   ANDROID_HOME=~/Library/Android/sdk ./run.sh [renderer dir]
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../../.." && pwd)"
RENDERER="${1:-$ROOT/build/gfxstream}"
LOADER="$RENDERER/lib64/vulkan/libvulkan.dylib"
ICD="$RENDERER/lib64/vulkan/MoltenVK_icd.json"
SHADERS="$ROOT/guest/gfxsync/test/shaders"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/$(ls "$SDK/ndk" | sort -V | tail -1)}"
TOOLS="$NDK/shader-tools/$(ls "$NDK/shader-tools" | head -1)"
SYSROOT="$NDK/toolchains/llvm/prebuilt/$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)/sysroot"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# The layer as build.rs builds it, with the manifest astc.rs writes.
mkdir -p "$OUT/layer"
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror -fvisibility=hidden -dynamiclib -arch arm64 \
    -install_name @rpath/libVkLayer_avo_native_astc.dylib -o "$OUT/layer/libVkLayer_avo_native_astc.dylib" \
    "$HERE/../native_astc.c" "$ROOT/guest/gfxsync/src/frag_outputs.c"
MANIFEST_LINE="$(grep -o 'r#"{{"file_format_version.*}}}}"#' "$HERE/../../src/virtio/gpu/astc.rs")"
echo "$MANIFEST_LINE" | sed -e 's/^r#"//' -e 's/"#$//' -e 's/{{/{/g' -e 's/}}/}/g' \
    -e 's/{LAYER}/VK_LAYER_AVO_native_astc/' -e 's/{LIBRARY}/libVkLayer_avo_native_astc.dylib/' \
    > "$OUT/layer/VkLayer_avo_native_astc.json"
python3 -I -c 'import json, sys; json.load(open(sys.argv[1]))' "$OUT/layer/VkLayer_avo_native_astc.json"

# The NDK's Vulkan headers, after the Mac's own (its libc headers are Android's).
clang -std=c11 -O1 -Wall -Wextra -Werror -idirafter "$SYSROOT/usr/include" -o "$OUT/layer_test" "$HERE/layer_test.c"
"$TOOLS/glslc" -o "$OUT/vert.spv" "$SHADERS/fullscreen.vert"
"$TOOLS/glslc" -o "$OUT/plain.spv" "$SHADERS/plain.frag"

export VK_DRIVER_FILES="$ICD" VK_ICD_FILENAMES="$ICD"
without() { env -u VK_INSTANCE_LAYERS -u VK_ADD_LAYER_PATH "$OUT/layer_test" "$LOADER" "$@"; }
with() { VK_ADD_LAYER_PATH="$OUT/layer" VK_INSTANCE_LAYERS=VK_LAYER_AVO_native_astc "$OUT/layer_test" "$LOADER" "$@"; }

failures=0
fail() {
    echo "FAIL $1: $2"
    failures=$((failures + 1))
}

without provoking "$OUT/vert.spv" "$OUT/plain.spv" >"$OUT/provoking.without" 2>&1 || true
if grep -q "extension missing" "$OUT/provoking.without" && grep -q "^device -7" "$OUT/provoking.without"; then
    echo "ok   provoking, without the layer: no extension, and the device fails"
else
    fail "provoking without the layer" "MoltenVK has it now? $(tr '\n' ' ' <"$OUT/provoking.without")"
fi
if with provoking "$OUT/vert.spv" "$OUT/plain.spv" >"$OUT/provoking.with" 2>&1; then
    echo "ok   provoking, with the layer: $(grep -E '^(extension|features|properties|device|pipeline) ' "$OUT/provoking.with" | tr '\n' ' ')"
else
    fail "provoking with the layer" "$(tr '\n' ' ' <"$OUT/provoking.with")"
fi

if [ "$(with extension AppEngine 2>/dev/null)" != "extension missing" ]; then
    echo "ok   provoking, with the layer: another engine's instance is offered it too"
else
    fail "provoking with the layer" "another engine's instance is not offered VK_EXT_provoking_vertex"
fi

for shader in "$SHADERS"/*.frag; do
    name="$(basename "$shader" .frag)"
    before=$failures
    target="$(sed -n 's|^// target \(.*\)|\1|p' "$shader")"
    target="${target:-vulkan1.0}"
    "$TOOLS/glslc" --target-env="$target" -o "$OUT/$name.spv" "$shader"

    if grep -q '^// unsplit fails' "$shader"; then
        if without draw "$OUT/vert.spv" "$OUT/$name.spv" 1 >/dev/null 2>"$OUT/$name.log"; then
            fail "$name" "made a pipeline without the layer (the bug is gone?)"
        elif ! grep -q "must be made explicit" "$OUT/$name.log"; then
            fail "$name" "failed without the layer, but not with the MoltenVK bug: $(tail -3 "$OUT/$name.log")"
        fi
    fi
    if grep -q '^// unchanged' "$shader"; then
        with draw "$OUT/vert.spv" "$OUT/$name.spv" 1 >/dev/null 2>"$OUT/$name.log" || true
        if grep -q "^\[gpu\] split" "$OUT/$name.log"; then fail "$name" "the layer rewrote it"; fi
    fi

    while read -r attachments expected; do
        for way in module inline; do
            flag=""
            [ "$way" = inline ] && flag="--inline"
            status=0
            actual="$(with draw "$OUT/vert.spv" "$OUT/$name.spv" "$attachments" $flag 2>"$OUT/$name.$way.log")" || status=$?
            if [ "$status" -eq 3 ]; then
                echo "skip $name ($way): the driver has no VK_KHR_maintenance5"
                continue
            fi
            if [ "$status" -ne 0 ]; then
                fail "$name" "$way, $attachments attachments: $(tail -5 "$OUT/$name.$way.log")"
                continue
            fi
            [ "$actual" = "$expected" ] || fail "$name" "$way, $attachments attachments: drew $actual, expected $expected"
        done
    done < <(sed -n 's|^// expect \([0-9]*\): \(.*\)|\1 \2|p' "$shader")
    [ "$failures" -eq "$before" ] && echo "ok   $name"
done

if [ "$failures" -gt 0 ]; then
    echo "$failures failed"
    exit 1
fi
echo "all passed"

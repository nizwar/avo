#!/usr/bin/env bash
# Tests Avo's gfxstream patches on the Mac, without Android:
# - sequence_gate_test: SequenceGate (0001) on its own, also under
#   ThreadSanitizer: commands in order, the guest-lock deadlock let go after
#   the wait, numbers a decoder holds never skipped, a long command no gap.
# - renderer_smoke: the built renderer starts as avo-vmm starts it, with
#   avo-vmm's Vulkan layer named to the loader, and offers its capability sets.
#
#   scripts/gfxstream-patches/tests/run.sh [gfxstream source dir] [renderer dir]
#
# Defaults: build/gfxstream-src/gfxstream and build/gfxstream (after
# scripts/build-gfxstream.sh has applied the patches and built them).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
GFXSTREAM="${1:-$ROOT/build/gfxstream-src/gfxstream}"
RENDERER="${2:-$ROOT/build/gfxstream}"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

[[ -f "$GFXSTREAM/host/common/include/gfxstream/host/sequence_gate.h" ]] || { echo "$GFXSTREAM has no patched sources" >&2; exit 1; }
grep -q '^Avo.HostGfxsync=1$' "$RENDERER/source.properties" || { echo "$RENDERER is not a patched renderer" >&2; exit 1; }

echo "== sequence gate"
clang++ -std=c++17 -O2 -Wall -Wextra -Werror -pthread -I "$GFXSTREAM/host/common/include" \
    -o "$OUT/sequence_gate_test" "$HERE/sequence_gate_test.cpp"
"$OUT/sequence_gate_test"
clang++ -std=c++17 -O1 -g -fsanitize=thread -pthread -I "$GFXSTREAM/host/common/include" \
    -o "$OUT/sequence_gate_tsan" "$HERE/sequence_gate_test.cpp"
"$OUT/sequence_gate_tsan" >"$OUT/tsan.log" 2>&1 || { cat "$OUT/tsan.log"; exit 1; }
if grep -q "ThreadSanitizer" "$OUT/tsan.log"; then cat "$OUT/tsan.log"; exit 1; fi
echo "ok   no data races (ThreadSanitizer)"

echo "== renderer"
# avo-vmm's layer and manifest (build.rs, astc.rs).
mkdir -p "$OUT/layer"
/usr/bin/clang -std=c11 -O2 -Wall -Wextra -Werror -fvisibility=hidden -dynamiclib -arch arm64 \
    -install_name @rpath/libVkLayer_avo_native_astc.dylib -o "$OUT/layer/libVkLayer_avo_native_astc.dylib" \
    "$ROOT/engine/hvf/vmm/layer/native_astc.c" "$ROOT/guest/gfxsync/src/frag_outputs.c"
grep -o 'r#"{{"file_format_version.*}}}}"#' "$ROOT/engine/hvf/vmm/src/virtio/gpu/astc.rs" \
    | sed -e 's/^r#"//' -e 's/"#$//' -e 's/{{/{/g' -e 's/}}/}/g' \
          -e 's/{LAYER}/VK_LAYER_AVO_native_astc/' -e 's/{LIBRARY}/libVkLayer_avo_native_astc.dylib/' \
    > "$OUT/layer/VkLayer_avo_native_astc.json"
clang -std=c11 -O1 -Wall -Wextra -Werror -I "$GFXSTREAM/host/include" -o "$OUT/renderer_smoke" "$HERE/renderer_smoke.c"
if VK_ADD_LAYER_PATH="$OUT/layer" VK_INSTANCE_LAYERS=VK_LAYER_AVO_native_astc \
    "$OUT/renderer_smoke" "$RENDERER" >"$OUT/smoke.out" 2>"$OUT/smoke.err" \
    && grep -q "Gfxstream initialized successfully" "$OUT/smoke.err" \
    && grep -q "VulkanQueueSubmitWithCommands: enabled" "$OUT/smoke.err"; then
    echo "ok   starts with the layer: $(tr '\n' ' ' <"$OUT/smoke.out")(sequence numbers in use)"
else
    cat "$OUT/smoke.out"
    grep -v "mvk-info" "$OUT/smoke.err" | tail -20
    exit 1
fi
echo "all passed"

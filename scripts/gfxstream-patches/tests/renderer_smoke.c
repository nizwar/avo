// Starts a renderer folder's gfxstream the way avo-vmm does (gfxstream.rs:
// the same flags, features and environment) with no guest, reads the two
// capability sets avo-vmm offers, and stops it. Exit status 0 when both are
// there. run.sh names Avo's Mac-side layer to the loader as avo-vmm does.
//
//   renderer_smoke <renderer dir>
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <gfxstream/virtio-gpu-gfxstream-renderer.h>
#include <gfxstream/virtio-gpu-gfxstream-renderer-unstable.h>

static void fence_callback(void* user, struct stream_renderer_fence* fence) {
    (void)user;
    (void)fence;
}

static void debug_callback(void* user, struct stream_renderer_debug* debug) {
    (void)user;
    fprintf(stderr, "[gfxstream %u] %s\n", debug->debug_type, debug->message);
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <renderer dir>\n", argv[0]);
        return 1;
    }
    char path[4096];
    setenv("ANDROID_EMULATOR_LAUNCHER_DIR", argv[1], 1);
    snprintf(path, sizeof path, "%s/lib64/vulkan/libvulkan.dylib", argv[1]);
    setenv("ANDROID_EMU_VK_LOADER_PATH", path, 1);
    setenv("ANDROID_EMU_VK_ICD", "moltenvk", 0);
    setenv("ANDROID_EMU_HEADLESS", "1", 0);

    snprintf(path, sizeof path, "%s/lib64/libgfxstream_backend.dylib", argv[1]);
    void* backend = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!backend) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    int (*init)(struct stream_renderer_param*, uint64_t) = (int (*)(struct stream_renderer_param*, uint64_t))dlsym(backend, "stream_renderer_init");
    void (*get_cap_set)(uint32_t, uint32_t*, uint32_t*) = (void (*)(uint32_t, uint32_t*, uint32_t*))dlsym(backend, "stream_renderer_get_cap_set");
    void (*teardown)(void) = (void (*)(void))dlsym(backend, "stream_renderer_teardown");
    if (!init || !get_cap_set || !teardown) {
        fprintf(stderr, "the backend lacks a stream_renderer_ function\n");
        return 1;
    }

    // avo-vmm's: Vulkan, surfaceless; async composition pinned off.
    static int user;
    struct stream_renderer_param params[] = {
        {STREAM_RENDERER_PARAM_USER_DATA, (uint64_t)(uintptr_t)&user},
        {STREAM_RENDERER_PARAM_RENDERER_FLAGS, STREAM_RENDERER_FLAGS_USE_SURFACELESS_BIT | STREAM_RENDERER_FLAGS_USE_VK_BIT},
        {STREAM_RENDERER_PARAM_FENCE_CALLBACK, (uint64_t)(uintptr_t)fence_callback},
        {STREAM_RENDERER_PARAM_DEBUG_CALLBACK, (uint64_t)(uintptr_t)debug_callback},
        {STREAM_RENDERER_PARAM_WIN0_WIDTH, 720},
        {STREAM_RENDERER_PARAM_WIN0_HEIGHT, 1280},
        {STREAM_RENDERER_PARAM_RENDERER_FEATURES, (uint64_t)(uintptr_t)"AsyncComposeSupport:disabled"},
    };
    int result = init(params, sizeof params / sizeof params[0]);
    printf("init %d\n", result);
    if (result != 0) return 1;
    int failures = 0;
    // gfxstream-vulkan and gfxstream-composer.
    const uint32_t sets[] = {3, 9};
    for (size_t i = 0; i < sizeof sets / sizeof sets[0]; i++) {
        uint32_t version = 0, size = 0;
        get_cap_set(sets[i], &version, &size);
        printf("capset %u: %u bytes\n", sets[i], size);
        if (!size) failures++;
    }
    teardown();
    printf("teardown\n");
    return failures ? 1 : 0;
}

// libVkLayer_avo_gfxstream_sync.so (VK_LAYER_AVO_gfxstream_sync): keeps the
// guest gfxstream Vulkan driver (vulkan.ranchu, AOSP's Mesa gfxstream) from
// deadlocking a process that uses Vulkan on several threads, such as Flutter
// (Impeller) next to HWUI (ANGLE). It also rewrites the shaders that MoltenVK,
// which runs the driver's commands on the Mac, cannot make pipelines from.
//
// The deadlock, in that driver:
// - Every command carries a process-wide sequence number, and the host runs
//   commands strictly in that order (VulkanQueueSubmitWithCommands).
// - vkDestroy*(), vkFreeMemory() and vkFreeCommandBuffers() take their number,
//   then the driver's one lock (ResourceTracker::mLock, in
//   DestroyMapping::mapHandles_*), and only then send the command. So do
//   vkFreeDescriptorSets() and vkResetDescriptorPool(), which destroy sets
//   when the driver batches descriptor updates.
// - A queue submission that signals a semaphore with a sync fd keeps that
//   lock while it waits for the host to answer vkQueueWaitIdle()
//   (on_vkQueueSubmitTemplate). Every present does this:
//   QueueSignalReleaseImageANDROID signals such a semaphore.
// A destroy that took its number just before a present took the lock never
// sends it, so the host never reaches the present's wait: both threads, and
// every other thread that needs the lock, stop for good (an ANR).
//
// What this layer does, for devices of the gfxstream driver:
// - vkQueuePresentKHR waits for the present's semaphores and for the queue
//   itself (vkQueueSubmit + vkQueueWaitIdle, which hold no lock in the
//   driver), then presents with no semaphores. QueueSignalReleaseImageANDROID
//   then has nothing to submit or wait for, and returns no fence: the image is
//   already finished. The driver did the same wait inside its lock.
// - A submission that signals a semaphore with a sync fd (one created
//   exportable, or imported) still waits inside the lock, so it runs while no
//   destroy is inside the driver, and the other way round (a reader-writer
//   lock: such submissions write, destroys and presents read; libvulkan's
//   swapchain code destroys images during presents and swapchain changes).
//   Every device and instance of the driver takes part, compute-only ones
//   without a swapchain too: the lock and the command order are the
//   process's.
// - vkCreateShaderModule gives each element of a fragment output array its
//   own output (frag_outputs.c), which MoltenVK needs to make pipelines from
//   shaders such as ANGLE's gl_FragData[8] when a subpass has fewer colour
//   attachments. vkCreateGraphicsPipelines does the same for a fragment
//   stage that brings its SPIR-V inline (VK_KHR_maintenance5).
// - ANGLE's own instance sees VK_EXT_provoking_vertex (provokingVertexLast),
//   which neither the driver nor MoltenVK has. ANGLE builds from mid-2025 on
//   offer no OpenGL ES above 2.0 without it ("required for flat shading");
//   older ones offered ES 3.1 regardless. The layer takes the extension, its
//   feature structure and the pipelines' provoking-vertex state out again
//   before the driver sees them, so flat varyings keep the driver's
//   convention: the first vertex of each primitive, where OpenGL ES takes the
//   last. Apps' own Vulkan instances do not see the extension.
// - OpenGL ES 3.2, which ANGLE otherwise caps at 3.1: of the twenty-four
//   extensions OpenGL ES 3.2 asks for, only geometry shaders are missing —
//   Metal has no such stage (the limits read zero), and no layer can add a
//   GPU stage to one. Border-colour samplers the layer stands in for (the
//   next bullet), so twenty-three work: advanced blend equations ANGLE
//   emulates itself on Android through framebuffer fetch, which Apple GPUs
//   do (raster order); tessellation, cube map arrays, sample shading,
//   GPUShader5 and the rest are the hardware's. The layer turns on ANGLE's
//   exposeES32ForTesting, which raises the cap without geometry shaders: an
//   app gets an ES 3.2 context, and one that asks for them finds their
//   limits at zero (the constructor at "ES 3.2" below).
// - VK_EXT_custom_border_color, which the driver has not (Metal's samplers
//   take one of six fixed border colours): the layer offers the extension
//   to ANGLE alone and answers its features, and when ANGLE makes a
//   sampler with a custom border colour, the layer takes the colour to the
//   nearest fixed one — GLES's own default (0,0,0,1) and the black and
//   white corners are exact — so the driver never sees the custom one
//   (below, "Border colours").
// - Settings' "OpenGL ES version" (debug.avo.gl.max): below 3.2 the layer
//   leaves ANGLE's exposeES32ForTesting out; at 3.0 and 2.0 it takes the
//   requirements ANGLE checks away — ES 3.1's storage-buffer count
//   (vkGetPhysicalDeviceProperties2 answers fewer), ES 3.0's
//   VK_EXT_provoking_vertex (no longer offered) — so every context stops
//   at the chosen version (below, "The GLES version Avo offers").
// - Images of the compressed formats gfxstream emulates (ASTC on the Mac):
//   the host refills the uncompressed copy that shaders sample only in
//   vkCmdPipelineBarrier, so after a vkCmdPipelineBarrier2 or vkCmdWaitEvents
//   that moves one from an upload into a sampled layout, the layer adds a
//   vkCmdPipelineBarrier that leaves the layout as it is, and it turns
//   vkCmdCopyBufferToImage2 into vkCmdCopyBufferToImage, whose data the host
//   does not lose (see "Emulated compressed textures").
// - Format queries hide sampled linear tiling for ASTC: Avo's layer on the
//   Mac reports it so that gfxstream stops emulating ASTC (an emulated ASTC
//   texture takes 5-17x the memory), but Metal cannot sample linear ASTC.
// Other drivers, and everything else, pass straight through.
//
// HostAgent installs it in /data/local/debug/vulkan and lists it in
// debug.vulkan.layer.9 (GuestGfxstreamSync in AvoDaemonCore), or Avo's
// driver wrapper (guest/vkwrap) runs it inside the Vulkan driver, below
// libvulkan. There presents arrive as libvulkan's swapchain code makes them,
// QueueSignalReleaseImageANDROID per image, and a new handle still holds the
// driver's loader magic when the layer sees it: libvulkan writes its dispatch
// pointer there only after the create call returns (`instance_for_key`).
#include <android/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/system_properties.h>
#include <vulkan/vulkan.h>

#include "frag_outputs.h"

#define EXPORT __attribute__((visibility("default")))
#define LAYER_NAME "VK_LAYER_AVO_gfxstream_sync"
#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "AvoGfxSync", __VA_ARGS__)

// MARK: The GLES version Avo offers

// Settings' "OpenGL ES version" for this start: 20, 30, 31 or 32, and 3.2
// when the property is unset. Read once; every process loads this layer
// long after init put the property there (the daemon's identity file,
// which the engine hands to Android before anything reads it).
static int the_gles_max;

static void read_gles_max(void) {
    char value[PROP_VALUE_MAX];
    __system_property_get("debug.avo.gl.max", value);
    the_gles_max =
        strcmp(value, "2.0") == 0 ? 20 : strcmp(value, "3.0") == 0 ? 30 : strcmp(value, "3.1") == 0 ? 31 : 32;
}

static int gles_max(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, read_gles_max);
    return the_gles_max;
}

// MARK: ES 3.2

// ANGLE reads its feature overrides from ANGLE_FEATURE_OVERRIDES_ENABLED or
// debug.angle.feature_overrides_enabled, and takes the variable alone when
// both are there. The property is full (91 bytes, the two overrides Avo's
// bootconfig sets; engine/hvf/vmm/src/virtio/gpu/guest.rs) and the variable
// has no such limit, so the layer writes the variable. The instance that
// loads this library is made before ANGLE reads either — its renderer comes
// with the physical device, after the driver is in — and whatever the
// property, or a developer's own variable, named rides along.
#define AVO_FEATURES_ENV "ANGLE_FEATURE_OVERRIDES_ENABLED"
#define AVO_FEATURES_PROPERTY "debug.angle.feature_overrides_enabled"
#define AVO_ES32_FEATURE "exposeES32ForTesting"

// Whether `name` is one of the ':'-separated names in `list`.
static bool feature_named(const char* list, const char* name) {
    size_t length = strlen(name);
    while (list && *list) {
        const char* separator = strchr(list, ':');
        size_t item = separator ? (size_t)(separator - list) : strlen(list);
        if (item == length && memcmp(list, name, length) == 0) return true;
        list = separator ? separator + 1 : NULL;
    }
    return false;
}

__attribute__((constructor)) static void expose_es_3_2(void) {
    char property[PROP_VALUE_MAX];
    __system_property_get(AVO_FEATURES_PROPERTY, property);
    // Settings' "OpenGL ES version" below 3.2 keeps ANGLE's cap where it is.
    char merged[512] = "";
    if (gles_max() >= 32) strcat(merged, AVO_ES32_FEATURE);
    const char* lists[] = {getenv(AVO_FEATURES_ENV), property};
    for (size_t i = 0; i < sizeof lists / sizeof *lists; i++) {
        for (const char* list = lists[i]; list && *list;) {
            const char* separator = strchr(list, ':');
            size_t length = separator ? (size_t)(separator - list) : strlen(list);
            if (length >= sizeof merged - strlen(merged) - 1) break;  // no room for more
            if (length) {
                char name[64];
                if (length < sizeof name) {
                    memcpy(name, list, length);
                    name[length] = '\0';
                    if (!feature_named(merged, name)) {
                        if (merged[0]) strcat(merged, ":");
                        strcat(merged, name);
                    }
                }
            }
            list = separator ? separator + 1 : NULL;
        }
    }
    if (!merged[0]) return;
    setenv(AVO_FEATURES_ENV, merged, 1);
    LOG("OpenGL ES %d.%d: ANGLE's feature overrides are '%s'", gles_max() / 10, gles_max() % 10, merged);
}

// The loader's link structures (Android's vulkan/vk_layer_interface.h).
enum { LAYER_LINK_INFO = 0 };
typedef struct InstanceLink {
    struct InstanceLink* next;
    PFN_vkGetInstanceProcAddr next_get_instance_proc_addr;
} InstanceLink;
typedef struct {
    VkStructureType sType;
    const void* pNext;
    int function;
    union {
        InstanceLink* layer_info;
        void* set_loader_data;
    } u;
} InstanceCreateInfo;
typedef struct DeviceLink {
    struct DeviceLink* next;
    PFN_vkGetInstanceProcAddr next_get_instance_proc_addr;
    PFN_vkGetDeviceProcAddr next_get_device_proc_addr;
} DeviceLink;
typedef struct {
    VkStructureType sType;
    const void* pNext;
    int function;
    union {
        DeviceLink* layer_info;
        void* set_loader_data;
    } u;
} DeviceCreateInfo;

// A device, its queues and its command buffers share the loader's dispatch
// pointer, the first word of the handle.
static void* key_of(const void* handle) { return *(void* const*)handle; }

// MARK: The lock between destroys and waiting submissions

static pthread_mutex_t gate_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gate_changed = PTHREAD_COND_INITIALIZER;
static int gate_readers, gate_writing, gate_writers_waiting;

static void read_begin(void) {
    pthread_mutex_lock(&gate_lock);
    while (gate_writing || gate_writers_waiting) pthread_cond_wait(&gate_changed, &gate_lock);
    gate_readers++;
    pthread_mutex_unlock(&gate_lock);
}

static void read_end(void) {
    pthread_mutex_lock(&gate_lock);
    if (--gate_readers == 0) pthread_cond_broadcast(&gate_changed);
    pthread_mutex_unlock(&gate_lock);
}

static void write_begin(void) {
    pthread_mutex_lock(&gate_lock);
    gate_writers_waiting++;
    while (gate_writing || gate_readers) pthread_cond_wait(&gate_changed, &gate_lock);
    gate_writers_waiting--;
    gate_writing = 1;
    pthread_mutex_unlock(&gate_lock);
}

static void write_end(void) {
    pthread_mutex_lock(&gate_lock);
    gate_writing = 0;
    pthread_cond_broadcast(&gate_changed);
    pthread_mutex_unlock(&gate_lock);
}

// MARK: What the layer knows

typedef struct Instance {
    struct Instance* next;
    void* key;
    VkInstance handle;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkDestroyInstance destroy;
    // The gfxstream driver: the instance's destroys take a read hold of the gate.
    bool gfxstream;
    PFN_vkDestroyDebugUtilsMessengerEXT destroy_messenger;
    PFN_vkDestroyDebugReportCallbackEXT destroy_report_callback;
    // Format queries, which hide the host's linear ASTC (gfxstream only).
    PFN_vkGetPhysicalDeviceFormatProperties format_properties;
    PFN_vkGetPhysicalDeviceFormatProperties2 format_properties2;
    PFN_vkGetPhysicalDeviceFormatProperties2KHR format_properties2_khr;
    // ANGLE's instance on the gfxstream driver: it sees VK_EXT_provoking_vertex.
    bool angle;
    PFN_vkEnumerateDeviceExtensionProperties enumerate_extensions;
    PFN_vkGetPhysicalDeviceFeatures2 features2;
    PFN_vkGetPhysicalDeviceFeatures2KHR features2_khr;
    // The GLES version clamp answers through these (Settings' "OpenGL ES version").
    PFN_vkGetPhysicalDeviceProperties2 properties2;
    PFN_vkGetPhysicalDeviceProperties2KHR properties2_khr;
} Instance;

// The device functions the layer wraps, in the order of `wrapped` below.
enum {
    F_QueueSubmit,
    F_QueueSubmit2,
    F_QueueSubmit2KHR,
    F_QueuePresentKHR,
    F_QueueSignalReleaseImageANDROID,
    F_QueueWaitIdle,
    F_CreateSemaphore,
    F_ImportSemaphoreFdKHR,
    F_CreateSwapchainKHR,
    F_DestroySwapchainKHR,
    F_CreateShaderModule,
    F_CreateGraphicsPipelines,
    F_CreateSampler,
    F_FreeMemory,
    F_FreeCommandBuffers,
    F_FreeDescriptorSets,
    F_ResetDescriptorPool,
    F_DestroyBuffer,
    F_DestroyBufferView,
    F_DestroyCommandPool,
    F_DestroyDescriptorPool,
    F_DestroyDescriptorSetLayout,
    F_DestroyDescriptorUpdateTemplate,
    F_DestroyDescriptorUpdateTemplateKHR,
    F_DestroyEvent,
    F_DestroyFence,
    F_DestroyFramebuffer,
    F_DestroyImage,
    F_DestroyImageView,
    F_DestroyPipeline,
    F_DestroyPipelineCache,
    F_DestroyPipelineLayout,
    F_DestroyPrivateDataSlot,
    F_DestroyPrivateDataSlotEXT,
    F_DestroyQueryPool,
    F_DestroyRenderPass,
    F_DestroySampler,
    F_DestroySamplerYcbcrConversion,
    F_DestroySamplerYcbcrConversionKHR,
    F_DestroySemaphore,
    F_DestroyShaderModule,
    F_CreateImage,
    F_CmdPipelineBarrier,
    F_CmdPipelineBarrier2,
    F_CmdPipelineBarrier2KHR,
    F_CmdWaitEvents,
    F_CmdWaitEvents2,
    F_CmdWaitEvents2KHR,
    F_CmdCopyBufferToImage,
    F_CmdCopyBufferToImage2,
    F_CmdCopyBufferToImage2KHR,
    F_COUNT
};

typedef struct Device {
    struct Device* next;
    void* key;
    VkDevice handle;
    PFN_vkGetDeviceProcAddr gdpa;
    PFN_vkDestroyDevice destroy;
    // The gfxstream driver: the layer changes presents and submissions.
    bool gfxstream;
    // MoltenVK runs it on the Mac: the layer changes shaders.
    bool moltenvk;
    // ANGLE enabled the layer's VK_EXT_provoking_vertex: pipelines lose their
    // provoking-vertex state.
    bool provoking_vertex;
    // ANGLE enabled the layer's VK_EXT_custom_border_color: samplers get
    // their custom border colour taken to a fixed one.
    bool border_colors;
    PFN_vkVoidFunction fn[F_COUNT];
    // Semaphores that carry a sync fd in the driver (exportable as one, or
    // imported from one): signalling them makes a submission wait in the lock.
    pthread_mutex_t semaphores_lock;
    VkSemaphore* semaphores;
    size_t semaphore_count, semaphore_capacity;
} Device;

static pthread_mutex_t lists_lock = PTHREAD_MUTEX_INITIALIZER;
static Instance* instances;
static Device* devices;

// The record for `key`, with lists_lock held. A record keeps the key its
// handle had when the layer made it; below libvulkan that is the driver's
// loader magic, the same for every handle, until libvulkan puts its own
// dispatch pointer there. A lookup that misses takes the record whose handle
// carries `key` by now, and keys it so.
static Instance* instance_for_key(void* key) {
    for (Instance* instance = instances; instance; instance = instance->next) {
        if (instance->key == key) return instance;
    }
    for (Instance* instance = instances; instance; instance = instance->next) {
        if (key_of(instance->handle) == key) {
            instance->key = key;
            return instance;
        }
    }
    return NULL;
}

// The same for devices (their queues and command buffers carry the device's key).
static Device* device_for_key(void* key) {
    for (Device* device = devices; device; device = device->next) {
        if (device->key == key) return device;
    }
    for (Device* device = devices; device; device = device->next) {
        if (key_of(device->handle) == key) {
            device->key = key;
            return device;
        }
    }
    return NULL;
}

static Instance* find_instance(void* key) {
    pthread_mutex_lock(&lists_lock);
    Instance* found = instance_for_key(key);
    pthread_mutex_unlock(&lists_lock);
    return found;
}

static Device* find_device(void* key) {
    pthread_mutex_lock(&lists_lock);
    Device* found = device_for_key(key);
    pthread_mutex_unlock(&lists_lock);
    return found;
}

// A physical device carries its instance's dispatch pointer (libvulkan's
// driver.cpp); the newest instance stands in should that ever change.
static Instance* instance_of(VkPhysicalDevice physical) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance) {
        pthread_mutex_lock(&lists_lock);
        instance = instances;
        pthread_mutex_unlock(&lists_lock);
    }
    return instance;
}

// The gfxstream driver serves this process: Android loads vulkan.<ro.hardware.vulkan>.so.
static bool gfxstream_driver(void) {
    char value[PROP_VALUE_MAX] = {0};
    __system_property_get("ro.hardware.vulkan", value);
    return strcmp(value, "ranchu") == 0;
}

static void remember_semaphore(Device* device, VkSemaphore semaphore) {
    pthread_mutex_lock(&device->semaphores_lock);
    for (size_t i = 0; i < device->semaphore_count; i++) {
        if (device->semaphores[i] == semaphore) {
            pthread_mutex_unlock(&device->semaphores_lock);
            return;
        }
    }
    if (device->semaphore_count == device->semaphore_capacity) {
        size_t capacity = device->semaphore_capacity ? device->semaphore_capacity * 2 : 16;
        VkSemaphore* grown = realloc(device->semaphores, capacity * sizeof *grown);
        if (!grown) {
            pthread_mutex_unlock(&device->semaphores_lock);
            return;
        }
        device->semaphores = grown;
        device->semaphore_capacity = capacity;
    }
    device->semaphores[device->semaphore_count++] = semaphore;
    pthread_mutex_unlock(&device->semaphores_lock);
}

static void forget_semaphore(Device* device, VkSemaphore semaphore) {
    pthread_mutex_lock(&device->semaphores_lock);
    for (size_t i = 0; i < device->semaphore_count; i++) {
        if (device->semaphores[i] == semaphore) {
            device->semaphores[i] = device->semaphores[--device->semaphore_count];
            break;
        }
    }
    pthread_mutex_unlock(&device->semaphores_lock);
}

static bool has_sync_fd(Device* device, VkSemaphore semaphore) {
    bool found = false;
    pthread_mutex_lock(&device->semaphores_lock);
    for (size_t i = 0; i < device->semaphore_count && !found; i++) found = device->semaphores[i] == semaphore;
    pthread_mutex_unlock(&device->semaphores_lock);
    return found;
}

#define NEXT(device, name) ((PFN_vk##name)(device)->fn[F_##name])

// VK_ANDROID_native_buffer (Android's vk_android_native_buffer.h, not in the NDK).
typedef VkResult(VKAPI_PTR* PFN_vkQueueSignalReleaseImageANDROID)(VkQueue queue, uint32_t waitSemaphoreCount,
                                                                   const VkSemaphore* pWaitSemaphores, VkImage image,
                                                                   int* pNativeFenceFd);

// MARK: Presents and submissions

// Waits for a present's semaphores, then for the queue: vkQueueSubmit and
// vkQueueWaitIdle hold no lock in the driver. The caller holds a read hold of
// the gate.
static VkResult wait_outside_lock(Device* device, VkQueue queue, uint32_t count, const VkSemaphore* semaphores) {
    VkPipelineStageFlags stages_on_stack[16];
    VkPipelineStageFlags* stages = stages_on_stack;
    if (count > 16 && !(stages = malloc(count * sizeof *stages))) return VK_ERROR_OUT_OF_HOST_MEMORY;
    for (uint32_t i = 0; i < count; i++) stages[i] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    const VkSubmitInfo wait = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = count,
        .pWaitSemaphores = semaphores,
        .pWaitDstStageMask = stages,
    };
    VkResult result = NEXT(device, QueueSubmit)(queue, 1, &wait, VK_NULL_HANDLE);
    if (result == VK_SUCCESS) result = NEXT(device, QueueWaitIdle)(queue);
    if (stages != stages_on_stack) free(stages);
    return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR* info) {
    Device* device = find_device(key_of(queue));
    if (!device) return VK_ERROR_DEVICE_LOST;
    if (!device->gfxstream || !device->fn[F_QueueWaitIdle] || info->waitSemaphoreCount == 0) {
        read_begin();
        VkResult result = NEXT(device, QueuePresentKHR)(queue, info);
        read_end();
        return result;
    }
    VkPresentInfoKHR present = *info;
    present.waitSemaphoreCount = 0;
    present.pWaitSemaphores = NULL;
    read_begin();
    VkResult result = wait_outside_lock(device, queue, info->waitSemaphoreCount, info->pWaitSemaphores);
    if (result == VK_SUCCESS) result = NEXT(device, QueuePresentKHR)(queue, &present);
    read_end();
    return result;
}

// Below libvulkan (Avo's driver wrapper, guest/vkwrap) no vkQueuePresentKHR
// arrives: libvulkan's swapchain code releases each presented image to the
// driver with the present's semaphores. The same as QueuePresentKHR above:
// the wait happens outside the driver's lock, and the driver gets no
// semaphores, so it has nothing to submit or wait for (the image is finished).
static atomic_flag release_logged = ATOMIC_FLAG_INIT;

static VKAPI_ATTR VkResult VKAPI_CALL QueueSignalReleaseImageANDROID(VkQueue queue, uint32_t count,
                                                                     const VkSemaphore* semaphores, VkImage image,
                                                                     int* fence) {
    Device* device = find_device(key_of(queue));
    if (!device) return VK_ERROR_DEVICE_LOST;
    VkResult result = VK_SUCCESS;
    read_begin();
    if (device->gfxstream && device->fn[F_QueueWaitIdle] && count > 0) {
        if (!atomic_flag_test_and_set(&release_logged)) {
            LOG("presents reach the driver as image releases: their semaphores are waited for outside its lock");
        }
        result = wait_outside_lock(device, queue, count, semaphores);
        count = 0;
        semaphores = NULL;
    }
    if (result == VK_SUCCESS) result = NEXT(device, QueueSignalReleaseImageANDROID)(queue, count, semaphores, image, fence);
    read_end();
    return result;
}

static bool signals_sync_fd(Device* device, uint32_t count, const VkSubmitInfo* submits) {
    for (uint32_t i = 0; i < count; i++) {
        for (uint32_t j = 0; j < submits[i].signalSemaphoreCount; j++) {
            if (has_sync_fd(device, submits[i].pSignalSemaphores[j])) return true;
        }
    }
    return false;
}

static bool signals_sync_fd2(Device* device, uint32_t count, const VkSubmitInfo2* submits) {
    for (uint32_t i = 0; i < count; i++) {
        for (uint32_t j = 0; j < submits[i].signalSemaphoreInfoCount; j++) {
            if (has_sync_fd(device, submits[i].pSignalSemaphoreInfos[j].semaphore)) return true;
        }
    }
    return false;
}

static VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit(VkQueue queue, uint32_t count, const VkSubmitInfo* submits, VkFence fence) {
    Device* device = find_device(key_of(queue));
    if (!device) return VK_ERROR_DEVICE_LOST;
    if (!device->gfxstream || !signals_sync_fd(device, count, submits)) {
        return NEXT(device, QueueSubmit)(queue, count, submits, fence);
    }
    write_begin();
    VkResult result = NEXT(device, QueueSubmit)(queue, count, submits, fence);
    write_end();
    return result;
}

static VkResult submit2(Device* device, PFN_vkQueueSubmit2 next, VkQueue queue, uint32_t count,
                        const VkSubmitInfo2* submits, VkFence fence) {
    if (!device->gfxstream || !signals_sync_fd2(device, count, submits)) return next(queue, count, submits, fence);
    write_begin();
    VkResult result = next(queue, count, submits, fence);
    write_end();
    return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit2(VkQueue queue, uint32_t count, const VkSubmitInfo2* submits, VkFence fence) {
    Device* device = find_device(key_of(queue));
    return device ? submit2(device, NEXT(device, QueueSubmit2), queue, count, submits, fence) : VK_ERROR_DEVICE_LOST;
}

static VKAPI_ATTR VkResult VKAPI_CALL QueueSubmit2KHR(VkQueue queue, uint32_t count, const VkSubmitInfo2* submits, VkFence fence) {
    Device* device = find_device(key_of(queue));
    return device ? submit2(device, (PFN_vkQueueSubmit2)device->fn[F_QueueSubmit2KHR], queue, count, submits, fence)
                  : VK_ERROR_DEVICE_LOST;
}

// MARK: Semaphores with sync fds

static VKAPI_ATTR VkResult VKAPI_CALL CreateSemaphore(VkDevice handle, const VkSemaphoreCreateInfo* info,
                                                      const VkAllocationCallbacks* allocator, VkSemaphore* semaphore) {
    Device* device = find_device(key_of(handle));
    if (!device) return VK_ERROR_DEVICE_LOST;
    VkResult result = NEXT(device, CreateSemaphore)(handle, info, allocator, semaphore);
    if (result != VK_SUCCESS || !device->gfxstream) return result;
    for (const VkBaseInStructure* s = info->pNext; s; s = s->pNext) {
        if (s->sType == VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO
            && (((const VkExportSemaphoreCreateInfo*)s)->handleTypes & VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT)) {
            remember_semaphore(device, *semaphore);
        }
    }
    return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL ImportSemaphoreFdKHR(VkDevice handle, const VkImportSemaphoreFdInfoKHR* info) {
    Device* device = find_device(key_of(handle));
    if (!device) return VK_ERROR_DEVICE_LOST;
    VkResult result = NEXT(device, ImportSemaphoreFdKHR)(handle, info);
    if (result == VK_SUCCESS && device->gfxstream && (info->handleType & VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT)) {
        remember_semaphore(device, info->semaphore);
    }
    return result;
}

// MARK: Destroys (readers)

// Each wrapper runs the next layer's function with a read hold of the gate.
#define READER(name, params, args)                                         \
    static VKAPI_ATTR void VKAPI_CALL name params {                        \
        Device* device = find_device(key_of(handle));                     \
        if (!device) return;                                               \
        if (!device->gfxstream) {                                          \
            NEXT(device, name) args;                                       \
            return;                                                        \
        }                                                                  \
        read_begin();                                                      \
        NEXT(device, name) args;                                           \
        read_end();                                                        \
    }

READER(FreeMemory, (VkDevice handle, VkDeviceMemory object, const VkAllocationCallbacks* a), (handle, object, a))
READER(FreeCommandBuffers, (VkDevice handle, VkCommandPool pool, uint32_t count, const VkCommandBuffer* buffers),
       (handle, pool, count, buffers))
READER(DestroyBuffer, (VkDevice handle, VkBuffer object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyBufferView, (VkDevice handle, VkBufferView object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyCommandPool, (VkDevice handle, VkCommandPool object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyDescriptorPool, (VkDevice handle, VkDescriptorPool object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyDescriptorSetLayout, (VkDevice handle, VkDescriptorSetLayout object, const VkAllocationCallbacks* a),
       (handle, object, a))
READER(DestroyDescriptorUpdateTemplate, (VkDevice handle, VkDescriptorUpdateTemplate object, const VkAllocationCallbacks* a),
       (handle, object, a))
READER(DestroyDescriptorUpdateTemplateKHR, (VkDevice handle, VkDescriptorUpdateTemplate object, const VkAllocationCallbacks* a),
       (handle, object, a))
READER(DestroyEvent, (VkDevice handle, VkEvent object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyFence, (VkDevice handle, VkFence object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyFramebuffer, (VkDevice handle, VkFramebuffer object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyImageView, (VkDevice handle, VkImageView object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyPipeline, (VkDevice handle, VkPipeline object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyPipelineCache, (VkDevice handle, VkPipelineCache object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyPipelineLayout, (VkDevice handle, VkPipelineLayout object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyPrivateDataSlot, (VkDevice handle, VkPrivateDataSlot object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyPrivateDataSlotEXT, (VkDevice handle, VkPrivateDataSlot object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyQueryPool, (VkDevice handle, VkQueryPool object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroyRenderPass, (VkDevice handle, VkRenderPass object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroySampler, (VkDevice handle, VkSampler object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroySamplerYcbcrConversion, (VkDevice handle, VkSamplerYcbcrConversion object, const VkAllocationCallbacks* a),
       (handle, object, a))
READER(DestroySamplerYcbcrConversionKHR, (VkDevice handle, VkSamplerYcbcrConversion object, const VkAllocationCallbacks* a),
       (handle, object, a))
READER(DestroyShaderModule, (VkDevice handle, VkShaderModule object, const VkAllocationCallbacks* a), (handle, object, a))
READER(DestroySwapchainKHR, (VkDevice handle, VkSwapchainKHR object, const VkAllocationCallbacks* a), (handle, object, a))

// The same for those that return a result.
#define READER_RESULT(name, params, args)                                  \
    static VKAPI_ATTR VkResult VKAPI_CALL name params {                    \
        Device* device = find_device(key_of(handle));                     \
        if (!device) return VK_ERROR_DEVICE_LOST;                          \
        if (!device->gfxstream) return NEXT(device, name) args;            \
        read_begin();                                                      \
        VkResult result = NEXT(device, name) args;                         \
        read_end();                                                        \
        return result;                                                     \
    }

READER_RESULT(FreeDescriptorSets, (VkDevice handle, VkDescriptorPool pool, uint32_t count, const VkDescriptorSet* sets),
              (handle, pool, count, sets))
READER_RESULT(ResetDescriptorPool, (VkDevice handle, VkDescriptorPool pool, VkDescriptorPoolResetFlags flags),
              (handle, pool, flags))

static VKAPI_ATTR void VKAPI_CALL DestroySemaphore(VkDevice handle, VkSemaphore semaphore, const VkAllocationCallbacks* a) {
    Device* device = find_device(key_of(handle));
    if (!device) return;
    if (!device->gfxstream) {
        NEXT(device, DestroySemaphore)(handle, semaphore, a);
        return;
    }
    forget_semaphore(device, semaphore);
    read_begin();
    NEXT(device, DestroySemaphore)(handle, semaphore, a);
    read_end();
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateSwapchainKHR(VkDevice handle, const VkSwapchainCreateInfoKHR* info,
                                                         const VkAllocationCallbacks* a, VkSwapchainKHR* swapchain) {
    Device* device = find_device(key_of(handle));
    if (!device) return VK_ERROR_DEVICE_LOST;
    if (!device->gfxstream) return NEXT(device, CreateSwapchainKHR)(handle, info, a, swapchain);
    // Retiring the old swapchain destroys its images.
    read_begin();
    VkResult result = NEXT(device, CreateSwapchainKHR)(handle, info, a, swapchain);
    read_end();
    return result;
}

// MARK: Emulated compressed textures

// gfxstream emulates ASTC on the Mac, where MoltenVK offers it for optimal
// tiling only (and ETC2/EAC on hosts without them): what shaders sample is
// an uncompressed copy of the image, which the host fills from the
// compressed data that uploads write only inside vkCmdPipelineBarrier, at an
// image barrier into a readable layout (decompressIfNeeded,
// compressed_image_info.cpp). Its vkCmdPipelineBarrier2 and
// vkCmdWaitEvents(2) go straight to the driver, so whatever is uploaded
// behind one of those is never decompressed: shaders sample zeros, or what
// the last vkCmdPipelineBarrier left. Its vkCmdCopyBufferToImage2 passes the
// copy on with an uninitialised buffer and layout, so that data is lost.
// The image's ANGLE moves textures into sampled layouts with
// vkCmdPipelineBarrier and copies with vkCmdCopyBufferToImage (it waits for
// events only on the way out of them, and maps RGBA ASTC to the SFLOAT
// formats the host leaves to MoltenVK); a Vulkan app need not.
//
// So, for images of those formats: after a vkCmdPipelineBarrier2 or
// vkCmdWaitEvents(2) barrier from a layout uploads write into one shaders
// read, the layer records a vkCmdPipelineBarrier on the same range that keeps
// the new layout, with the same stages and accesses: the host decompresses
// there. (Moving the barrier out of the call instead would break
// vkCmdWaitEvents2's rule that its dependencies match vkCmdSetEvent2's.)
// vkCmdCopyBufferToImage2 becomes vkCmdCopyBufferToImage.
static bool emulated_format(VkFormat format) {
    // ETC2, EAC, and ASTC UNORM/SRGB (the host passes ASTC SFLOAT through).
    return format >= VK_FORMAT_ETC2_R8G8B8_UNORM_BLOCK && format <= VK_FORMAT_ASTC_12x12_SRGB_BLOCK;
}

// The images of those formats: a set of handles (open addressing; 0 marks an
// empty slot, 1 a removed one, and no handle is either).
static pthread_mutex_t images_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t* images;
static size_t image_capacity, image_slots_used;

static size_t image_slot(uint64_t handle, size_t capacity) {
    handle ^= handle >> 33;
    handle *= 0xff51afd7ed558ccdull;
    return (size_t)(handle ^ handle >> 33) & (capacity - 1);
}

// Where `handle` is in the table, or the empty slot where it would go.
static size_t find_image_slot(uint64_t handle) {
    size_t at = image_slot(handle, image_capacity);
    while (images[at] && images[at] != handle) at = (at + 1) & (image_capacity - 1);
    return at;
}

static void remember_image(VkImage image) {
    pthread_mutex_lock(&images_lock);
    if ((image_slots_used + 1) * 2 > image_capacity) {
        // Grow (or just drop the removed slots) to at most a quarter full.
        size_t live = 0, capacity = 256;
        for (size_t i = 0; i < image_capacity; i++) live += images[i] > 1;
        while ((live + 1) * 4 > capacity) capacity *= 2;
        uint64_t* table = calloc(capacity, sizeof *table);
        if (!table) {
            pthread_mutex_unlock(&images_lock);
            return;
        }
        uint64_t* old = images;
        size_t old_capacity = image_capacity;
        images = table;
        image_capacity = capacity;
        for (size_t i = 0; i < old_capacity; i++) {
            if (old[i] > 1) images[find_image_slot(old[i])] = old[i];
        }
        image_slots_used = live;
        free(old);
    }
    size_t at = find_image_slot((uint64_t)image);
    if (!images[at]) {
        images[at] = (uint64_t)image;
        image_slots_used++;
    }
    pthread_mutex_unlock(&images_lock);
}

static void forget_image(VkImage image) {
    pthread_mutex_lock(&images_lock);
    if (image_capacity) {
        size_t at = find_image_slot((uint64_t)image);
        if (images[at]) images[at] = 1;
    }
    pthread_mutex_unlock(&images_lock);
}

static bool emulated_image(VkImage image) {
    pthread_mutex_lock(&images_lock);
    bool found = image_capacity && images[find_image_slot((uint64_t)image)];
    pthread_mutex_unlock(&images_lock);
    return found;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateImage(VkDevice handle, const VkImageCreateInfo* info,
                                                  const VkAllocationCallbacks* a, VkImage* image) {
    Device* device = find_device(key_of(handle));
    if (!device) return VK_ERROR_DEVICE_LOST;
    VkResult result = NEXT(device, CreateImage)(handle, info, a, image);
    if (result == VK_SUCCESS && device->gfxstream && emulated_format(info->format)) remember_image(*image);
    return result;
}

static VKAPI_ATTR void VKAPI_CALL DestroyImage(VkDevice handle, VkImage image, const VkAllocationCallbacks* a) {
    Device* device = find_device(key_of(handle));
    if (!device) return;
    if (!device->gfxstream) {
        NEXT(device, DestroyImage)(handle, image, a);
        return;
    }
    // Before the driver frees the handle for a new image to take.
    if (image != VK_NULL_HANDLE) forget_image(image);
    read_begin();
    NEXT(device, DestroyImage)(handle, image, a);
    read_end();
}

// vkCmdPipelineBarrier's stages and accesses for synchronization2's: the same
// bits below 32, the copy, clear and vertex-input stages above them.
static VkPipelineStageFlags legacy_stages(VkPipelineStageFlags2 stages) {
    VkPipelineStageFlags legacy = (VkPipelineStageFlags)(stages & 0xffffffffu);
    if (stages & (VK_PIPELINE_STAGE_2_COPY_BIT | VK_PIPELINE_STAGE_2_RESOLVE_BIT | VK_PIPELINE_STAGE_2_BLIT_BIT
                  | VK_PIPELINE_STAGE_2_CLEAR_BIT)) {
        legacy |= VK_PIPELINE_STAGE_TRANSFER_BIT;
    }
    if (stages & (VK_PIPELINE_STAGE_2_INDEX_INPUT_BIT | VK_PIPELINE_STAGE_2_VERTEX_ATTRIBUTE_INPUT_BIT)) {
        legacy |= VK_PIPELINE_STAGE_VERTEX_INPUT_BIT;
    }
    if (stages & VK_PIPELINE_STAGE_2_PRE_RASTERIZATION_SHADERS_BIT) legacy |= VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT;
    if ((stages >> 32) & ~(uint64_t)0x7f) legacy |= VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    return legacy;
}

static VkAccessFlags legacy_access(VkAccessFlags2 access) {
    VkAccessFlags legacy = (VkAccessFlags)(access & 0xffffffffu);
    if (access & (VK_ACCESS_2_SHADER_SAMPLED_READ_BIT | VK_ACCESS_2_SHADER_STORAGE_READ_BIT)) {
        legacy |= VK_ACCESS_SHADER_READ_BIT;
    }
    if (access & VK_ACCESS_2_SHADER_STORAGE_WRITE_BIT) legacy |= VK_ACCESS_SHADER_WRITE_BIT;
    return legacy;
}

static atomic_flag decompress_logged = ATOMIC_FLAG_INIT;

// After an app's barrier on `image` from `from` to `to`: the
// vkCmdPipelineBarrier that has the host decompress it, if it needs one.
static void decompress(Device* device, VkCommandBuffer cb, VkImage image, VkImageLayout from, VkImageLayout to,
                       const VkImageSubresourceRange* range, VkPipelineStageFlags src, VkAccessFlags src_access,
                       VkPipelineStageFlags dst, VkAccessFlags dst_access) {
    bool uploaded = from == VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL || from == VK_IMAGE_LAYOUT_GENERAL;
    bool sampled = to == VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL || to == VK_IMAGE_LAYOUT_GENERAL
        || to == VK_IMAGE_LAYOUT_READ_ONLY_OPTIMAL;
    if (!uploaded || !sampled || !device->fn[F_CmdPipelineBarrier] || !emulated_image(image)) return;
    const VkImageMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = src_access,
        .dstAccessMask = dst_access,
        .oldLayout = to,
        .newLayout = to,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = *range,
    };
    src &= ~(VkPipelineStageFlags)VK_PIPELINE_STAGE_HOST_BIT;
    NEXT(device, CmdPipelineBarrier)(cb, src ? src : VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                     dst ? dst : VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
    if (!atomic_flag_test_and_set(&decompress_logged)) {
        LOG("an emulated compressed image reached a sampled layout without vkCmdPipelineBarrier: added one, where "
            "gfxstream decompresses it (first in this process)");
    }
}

static void decompress_dependency(Device* device, VkCommandBuffer cb, const VkDependencyInfo* info) {
    for (uint32_t i = 0; i < info->imageMemoryBarrierCount; i++) {
        const VkImageMemoryBarrier2* b = &info->pImageMemoryBarriers[i];
        decompress(device, cb, b->image, b->oldLayout, b->newLayout, &b->subresourceRange, legacy_stages(b->srcStageMask),
                   legacy_access(b->srcAccessMask), legacy_stages(b->dstStageMask), legacy_access(b->dstAccessMask));
    }
}

static VKAPI_ATTR void VKAPI_CALL CmdPipelineBarrier2(VkCommandBuffer cb, const VkDependencyInfo* info) {
    Device* device = find_device(key_of(cb));
    if (!device) return;
    NEXT(device, CmdPipelineBarrier2)(cb, info);
    decompress_dependency(device, cb, info);
}

static VKAPI_ATTR void VKAPI_CALL CmdPipelineBarrier2KHR(VkCommandBuffer cb, const VkDependencyInfo* info) {
    Device* device = find_device(key_of(cb));
    if (!device) return;
    ((PFN_vkCmdPipelineBarrier2)device->fn[F_CmdPipelineBarrier2KHR])(cb, info);
    decompress_dependency(device, cb, info);
}

static VKAPI_ATTR void VKAPI_CALL CmdWaitEvents(VkCommandBuffer cb, uint32_t count, const VkEvent* events,
                                                VkPipelineStageFlags src, VkPipelineStageFlags dst, uint32_t memory_count,
                                                const VkMemoryBarrier* memory, uint32_t buffer_count,
                                                const VkBufferMemoryBarrier* buffers, uint32_t image_count,
                                                const VkImageMemoryBarrier* barriers) {
    Device* device = find_device(key_of(cb));
    if (!device) return;
    NEXT(device, CmdWaitEvents)(cb, count, events, src, dst, memory_count, memory, buffer_count, buffers, image_count,
                                barriers);
    for (uint32_t i = 0; i < image_count; i++) {
        const VkImageMemoryBarrier* b = &barriers[i];
        decompress(device, cb, b->image, b->oldLayout, b->newLayout, &b->subresourceRange, src, b->srcAccessMask, dst,
                   b->dstAccessMask);
    }
}

static VKAPI_ATTR void VKAPI_CALL CmdWaitEvents2(VkCommandBuffer cb, uint32_t count, const VkEvent* events,
                                                 const VkDependencyInfo* infos) {
    Device* device = find_device(key_of(cb));
    if (!device) return;
    NEXT(device, CmdWaitEvents2)(cb, count, events, infos);
    for (uint32_t i = 0; i < count; i++) decompress_dependency(device, cb, &infos[i]);
}

static VKAPI_ATTR void VKAPI_CALL CmdWaitEvents2KHR(VkCommandBuffer cb, uint32_t count, const VkEvent* events,
                                                    const VkDependencyInfo* infos) {
    Device* device = find_device(key_of(cb));
    if (!device) return;
    ((PFN_vkCmdWaitEvents2)device->fn[F_CmdWaitEvents2KHR])(cb, count, events, infos);
    for (uint32_t i = 0; i < count; i++) decompress_dependency(device, cb, &infos[i]);
}

static void copy_buffer_to_image2(Device* device, PFN_vkCmdCopyBufferToImage2 next, VkCommandBuffer cb,
                                  const VkCopyBufferToImageInfo2* info) {
    bool legacy = !info->pNext && device->fn[F_CmdCopyBufferToImage] && emulated_image(info->dstImage);
    for (uint32_t i = 0; legacy && i < info->regionCount; i++) legacy = !info->pRegions[i].pNext;
    VkBufferImageCopy on_stack[16];
    VkBufferImageCopy* regions = on_stack;
    if (legacy && info->regionCount > 16 && !(regions = malloc(info->regionCount * sizeof *regions))) legacy = false;
    if (!legacy) {
        next(cb, info);
        return;
    }
    for (uint32_t i = 0; i < info->regionCount; i++) {
        const VkBufferImageCopy2* r = &info->pRegions[i];
        regions[i] = (VkBufferImageCopy){r->bufferOffset, r->bufferRowLength, r->bufferImageHeight, r->imageSubresource,
                                         r->imageOffset, r->imageExtent};
    }
    NEXT(device, CmdCopyBufferToImage)(cb, info->srcBuffer, info->dstImage, info->dstImageLayout, info->regionCount,
                                       regions);
    if (regions != on_stack) free(regions);
}

static VKAPI_ATTR void VKAPI_CALL CmdCopyBufferToImage2(VkCommandBuffer cb, const VkCopyBufferToImageInfo2* info) {
    Device* device = find_device(key_of(cb));
    if (device) copy_buffer_to_image2(device, NEXT(device, CmdCopyBufferToImage2), cb, info);
}

static VKAPI_ATTR void VKAPI_CALL CmdCopyBufferToImage2KHR(VkCommandBuffer cb, const VkCopyBufferToImageInfo2* info) {
    Device* device = find_device(key_of(cb));
    if (device) {
        copy_buffer_to_image2(device, (PFN_vkCmdCopyBufferToImage2)device->fn[F_CmdCopyBufferToImage2KHR], cb, info);
    }
}

// MARK: Shaders

static atomic_flag split_logged = ATOMIC_FLAG_INIT;

static VKAPI_ATTR VkResult VKAPI_CALL CreateShaderModule(VkDevice handle, const VkShaderModuleCreateInfo* info,
                                                         const VkAllocationCallbacks* a, VkShaderModule* module) {
    Device* device = find_device(key_of(handle));
    if (!device) return VK_ERROR_DEVICE_LOST;
    size_t words = 0;
    uint32_t* split = device->moltenvk ? avo_split_output_arrays(info->pCode, info->codeSize / 4, &words) : NULL;
    if (!split) return NEXT(device, CreateShaderModule)(handle, info, a, module);
    VkShaderModuleCreateInfo copy = *info;
    copy.codeSize = words * sizeof *split;
    copy.pCode = split;
    VkResult result = NEXT(device, CreateShaderModule)(handle, &copy, a, module);
    free(split);
    if (!atomic_flag_test_and_set(&split_logged)) {
        LOG("split a fragment output array into separate outputs for MoltenVK (first in this process: %zu words, %d)",
            words, result);
    }
    return result;
}

// Memory for one call's copies, freed together after it.
typedef struct Kept {
    struct Kept* next;
    max_align_t data[];
} Kept;

static void* keep(Kept** kept, size_t size) {
    Kept* block = malloc(sizeof *block + size);
    if (!block) return NULL;
    block->next = *kept;
    *kept = block;
    return block->data;
}

static void release(Kept* kept) {
    while (kept) {
        Kept* next = kept->next;
        free(kept);
        kept = next;
    }
}

// The structures Vulkan allows beside VkShaderModuleCreateInfo in a stage's
// chain, by size, so that those ahead of it can be copied; 0 for any other.
static size_t stage_struct_size(VkStructureType type) {
    switch (type) {
    case VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT:
        return sizeof(VkDebugUtilsObjectNameInfoEXT);
    case VK_STRUCTURE_TYPE_PIPELINE_ROBUSTNESS_CREATE_INFO_EXT:
        return sizeof(VkPipelineRobustnessCreateInfoEXT);
    case VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_REQUIRED_SUBGROUP_SIZE_CREATE_INFO:
        return sizeof(VkPipelineShaderStageRequiredSubgroupSizeCreateInfo);
    case VK_STRUCTURE_TYPE_SHADER_MODULE_VALIDATION_CACHE_CREATE_INFO_EXT:
        return sizeof(VkShaderModuleValidationCacheCreateInfoEXT);
    default:
        return 0;
    }
}

// A fragment stage that brings its SPIR-V inline (a VkShaderModuleCreateInfo
// in its chain, no module) with an output array to split: `*out` becomes a
// copy of the stage whose chain runs through copies of the structures ahead
// of that info to a copy of it with the split code, then on into the
// caller's chain. False leaves the stage as it is.
static bool split_inline_stage(const VkPipelineShaderStageCreateInfo* stage, VkPipelineShaderStageCreateInfo* out,
                               Kept** kept) {
    if (stage->stage != VK_SHADER_STAGE_FRAGMENT_BIT || stage->module != VK_NULL_HANDLE) return false;
    size_t ahead = 0;
    const VkBaseInStructure* at = stage->pNext;
    for (; at && at->sType != VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO; at = at->pNext) {
        size_t size = stage_struct_size(at->sType);
        if (!size) return false;
        ahead += size;
    }
    if (!at) return false;
    const VkShaderModuleCreateInfo* info = (const VkShaderModuleCreateInfo*)at;
    size_t words = 0;
    uint32_t* split = avo_split_output_arrays(info->pCode, info->codeSize / 4, &words);
    if (!split) return false;
    // The structures, the info, then the code: every structure holds
    // pointers, so its size keeps the next one aligned.
    unsigned char* place = keep(kept, ahead + sizeof *info + words * sizeof *split);
    if (!place) {
        free(split);
        return false;
    }
    *out = *stage;
    VkBaseOutStructure* last = (VkBaseOutStructure*)out;
    for (const VkBaseInStructure* s = stage->pNext; s != at; s = s->pNext) {
        size_t size = stage_struct_size(s->sType);
        memcpy(place, s, size);
        last->pNext = (VkBaseOutStructure*)place;
        last = last->pNext;
        place += size;
    }
    VkShaderModuleCreateInfo* copy = (VkShaderModuleCreateInfo*)place;
    *copy = *info;
    copy->codeSize = words * sizeof *split;
    copy->pCode = memcpy(place + sizeof *copy, split, copy->codeSize);
    last->pNext = (VkBaseOutStructure*)copy;
    free(split);
    return true;
}

// The pipelines as the driver gets them: copies where a fragment stage's
// inline SPIR-V was split, `infos` itself where none was. Short of memory a
// pipeline keeps its shaders as they are, as vkCreateShaderModule does.
static const VkGraphicsPipelineCreateInfo* split_inline_shaders(const VkGraphicsPipelineCreateInfo* infos,
                                                                 uint32_t count, Kept** kept) {
    VkGraphicsPipelineCreateInfo* copies = NULL;
    for (uint32_t i = 0; i < count; i++) {
        VkPipelineShaderStageCreateInfo* stages = NULL;
        for (uint32_t j = 0; infos[i].pStages && j < infos[i].stageCount; j++) {
            VkPipelineShaderStageCreateInfo stage;
            if (!split_inline_stage(&infos[i].pStages[j], &stage, kept)) continue;
            if (!copies && (copies = keep(kept, count * sizeof *copies))) memcpy(copies, infos, count * sizeof *copies);
            if (!stages && copies && (stages = keep(kept, infos[i].stageCount * sizeof *stages))) {
                memcpy(stages, infos[i].pStages, infos[i].stageCount * sizeof *stages);
                copies[i].pStages = stages;
            }
            if (stages) stages[j] = stage;
        }
    }
    return copies ? copies : infos;
}

static atomic_flag inline_split_logged = ATOMIC_FLAG_INIT;

// Frees one call's copies; the first split in the process goes to the log.
static VkResult pipelines_made(Kept* kept, VkResult result) {
    if (kept && !atomic_flag_test_and_set(&inline_split_logged)) {
        LOG("split a fragment output array in a pipeline's inline SPIR-V for MoltenVK (first in this process: %d)",
            result);
    }
    release(kept);
    return result;
}

// MARK: Provoking vertex (ANGLE's instance)

// A structure taken out of a pNext chain for the length of one call: the
// caller's chain is whole again once it is put back.
typedef struct {
    VkBaseOutStructure* before;
    VkBaseOutStructure* taken;
} Unlinked;

static Unlinked unlink_struct(const void* head, VkStructureType type) {
    for (VkBaseOutStructure* at = (VkBaseOutStructure*)head; at && at->pNext; at = at->pNext) {
        if (at->pNext->sType == type) {
            Unlinked unlinked = {at, at->pNext};
            at->pNext = unlinked.taken->pNext;
            return unlinked;
        }
    }
    return (Unlinked){NULL, NULL};
}

static void relink(Unlinked unlinked) {
    if (unlinked.taken) unlinked.before->pNext = unlinked.taken;
}

// The driver's own device extensions, with room for two more; NULL on failure.
static VkExtensionProperties* driver_extensions(Instance* instance, VkPhysicalDevice physical, uint32_t* count,
                                                VkResult* result) {
    *count = 0;
    *result = instance->enumerate_extensions(physical, NULL, count, NULL);
    if (*result != VK_SUCCESS) return NULL;
    VkExtensionProperties* all = calloc(*count + 2, sizeof *all);
    if (!all) {
        *result = VK_ERROR_OUT_OF_HOST_MEMORY;
        return NULL;
    }
    *result = instance->enumerate_extensions(physical, NULL, count, all);
    if (*result == VK_INCOMPLETE) *result = VK_SUCCESS;
    if (*result != VK_SUCCESS) {
        free(all);
        return NULL;
    }
    return all;
}

static bool has_extension(const VkExtensionProperties* all, uint32_t count, const char* name) {
    for (uint32_t i = 0; i < count; i++) {
        if (strcmp(all[i].extensionName, name) == 0) return true;
    }
    return false;
}

// Whether the layer stands in for VK_EXT_provoking_vertex on this physical
// device: ANGLE's instance, and a driver without it. (Unknown means no.)
static bool stands_in_for_provoking_vertex(Instance* instance, VkPhysicalDevice physical) {
    if (!instance || !instance->angle) return false;
    uint32_t count;
    VkResult result;
    VkExtensionProperties* all = driver_extensions(instance, physical, &count, &result);
    if (!all) return false;
    bool native = has_extension(all, count, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME);
    free(all);
    return !native;
}

// Whether the layer stands in for VK_EXT_custom_border_color here: ANGLE's
// instance, and a driver without it. (Unknown means no.)
static bool stands_in_for_border_colors(Instance* instance, VkPhysicalDevice physical) {
    if (!instance || !instance->angle) return false;
    uint32_t count;
    VkResult result;
    VkExtensionProperties* all = driver_extensions(instance, physical, &count, &result);
    if (!all) return false;
    bool native = has_extension(all, count, VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME);
    free(all);
    return !native;
}

static VkResult device_extensions(Instance* instance, VkPhysicalDevice physical, uint32_t* count,
                                  VkExtensionProperties* properties) {
    if (!instance->angle) return instance->enumerate_extensions(physical, NULL, count, properties);
    uint32_t have;
    VkResult result;
    VkExtensionProperties* all = driver_extensions(instance, physical, &have, &result);
    if (!all) return result;
    if (gles_max() > 20 && !has_extension(all, have, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME)) {
        snprintf(all[have].extensionName, sizeof all[have].extensionName, "%s", VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME);
        all[have++].specVersion = VK_EXT_PROVOKING_VERTEX_SPEC_VERSION;
    }
    if (!has_extension(all, have, VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME)) {
        snprintf(all[have].extensionName, sizeof all[have].extensionName, "%s", VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME);
        all[have++].specVersion = VK_EXT_CUSTOM_BORDER_COLOR_SPEC_VERSION;
    }
    if (!properties) {
        *count = have;
        free(all);
        return VK_SUCCESS;
    }
    uint32_t written = *count < have ? *count : have;
    memcpy(properties, all, written * sizeof *all);
    *count = written;
    free(all);
    return written < have ? VK_INCOMPLETE : VK_SUCCESS;
}

static void physical_features2(VkPhysicalDevice physical, VkPhysicalDeviceFeatures2* features, bool khr) {
    Instance* instance = instance_of(physical);
    PFN_vkGetPhysicalDeviceFeatures2 next = !instance ? NULL : khr ? instance->features2_khr : instance->features2;
    if (!next) return;
    // Both stand-ins go out of the chain for the call: the driver has
    // neither, and ANGLE's answers come from the layer.
    Unlinked provoking = {NULL, NULL}, border = {NULL, NULL};
    if (instance->angle && gles_max() > 20) {
        provoking = unlink_struct(features, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT);
        if (provoking.taken && !stands_in_for_provoking_vertex(instance, physical)) {
            relink(provoking);
            provoking.taken = NULL;
        }
    }
    if (instance->angle) {
        border = unlink_struct(features, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_FEATURES_EXT);
    }
    next(physical, features);
    relink(provoking);
    relink(border);
    if (provoking.taken) {
        VkPhysicalDeviceProvokingVertexFeaturesEXT* out = (VkPhysicalDeviceProvokingVertexFeaturesEXT*)provoking.taken;
        out->provokingVertexLast = VK_TRUE;
        out->transformFeedbackPreservesProvokingVertex = VK_FALSE;
    }
    if (border.taken) {
        VkPhysicalDeviceCustomBorderColorFeaturesEXT* out = (VkPhysicalDeviceCustomBorderColorFeaturesEXT*)border.taken;
        out->customBorderColors = VK_TRUE;
        out->customBorderColorWithoutFormat = VK_TRUE;
    }
}

// Settings' "OpenGL ES version" at 3.0 or 2.0: ES 3.1 asks ANGLE for more
// storage buffers per stage than this answers, and every context stops at
// 3.0. Apps' own instances see the driver's number unchanged.
static void physical_properties2(VkPhysicalDevice physical, VkPhysicalDeviceProperties2* properties, bool khr) {
    Instance* instance = instance_of(physical);
    PFN_vkGetPhysicalDeviceProperties2 next = !instance ? NULL : khr ? instance->properties2_khr : instance->properties2;
    if (!next) return;
    next(physical, properties);
    if (instance->angle && gles_max() <= 30) properties->properties.limits.maxPerStageDescriptorStorageBuffers = 4;
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties2(VkPhysicalDevice physical,
                                                               VkPhysicalDeviceProperties2* properties) {
    physical_properties2(physical, properties, false);
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties2KHR(VkPhysicalDevice physical,
                                                                  VkPhysicalDeviceProperties2* properties) {
    physical_properties2(physical, properties, true);
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceFeatures2(VkPhysicalDevice physical, VkPhysicalDeviceFeatures2* features) {
    physical_features2(physical, features, false);
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceFeatures2KHR(VkPhysicalDevice physical,
                                                              VkPhysicalDeviceFeatures2* features) {
    physical_features2(physical, features, true);
}

// MARK: Linear ASTC (the host's)

// Avo's layer on the Mac (engine/hvf/vmm/layer/native_astc.c) reports
// sampled, linear-filtered linear tiling for ASTC, so that gfxstream hands
// ASTC to Metal instead of decompressing it into far larger RGBA8 images.
// Metal has no linear compressed images: apps must not see those two bits.
static void hide_linear_astc(VkFormat format, VkFormatProperties* properties, void* chain) {
    if (format < VK_FORMAT_ASTC_4x4_UNORM_BLOCK || format > VK_FORMAT_ASTC_12x12_SRGB_BLOCK) return;
    const VkFormatFeatureFlags sampled = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    properties->linearTilingFeatures &= ~sampled;
    for (VkBaseOutStructure* s = chain; s; s = s->pNext) {
        if (s->sType == VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_3) {
            ((VkFormatProperties3*)s)->linearTilingFeatures &= ~(VkFormatFeatureFlags2)sampled;
        }
    }
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceFormatProperties(VkPhysicalDevice physical, VkFormat format,
                                                                   VkFormatProperties* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance) return;
    instance->format_properties(physical, format, properties);
    hide_linear_astc(format, properties, NULL);
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceFormatProperties2(VkPhysicalDevice physical, VkFormat format,
                                                                    VkFormatProperties2* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance) return;
    instance->format_properties2(physical, format, properties);
    hide_linear_astc(format, &properties->formatProperties, properties->pNext);
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceFormatProperties2KHR(VkPhysicalDevice physical, VkFormat format,
                                                                       VkFormatProperties2* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance) return;
    instance->format_properties2_khr(physical, format, properties);
    hide_linear_astc(format, &properties->formatProperties, properties->pNext);
}

static atomic_flag provoking_logged = ATOMIC_FLAG_INIT;

static VKAPI_ATTR VkResult VKAPI_CALL CreateGraphicsPipelines(VkDevice handle, VkPipelineCache cache, uint32_t count,
                                                              const VkGraphicsPipelineCreateInfo* infos,
                                                              const VkAllocationCallbacks* a, VkPipeline* pipelines) {
    Device* device = find_device(key_of(handle));
    if (!device) return VK_ERROR_DEVICE_LOST;
    Kept* kept = NULL;
    if (device->moltenvk) infos = split_inline_shaders(infos, count, &kept);
    if (!device->provoking_vertex) {
        return pipelines_made(kept, NEXT(device, CreateGraphicsPipelines)(handle, cache, count, infos, a, pipelines));
    }
    Unlinked on_stack[8];
    Unlinked* unlinked = on_stack;
    if (count > 8 && !(unlinked = malloc(count * sizeof *unlinked))) {
        release(kept);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    bool any = false;
    for (uint32_t i = 0; i < count; i++) {
        unlinked[i] = infos[i].pRasterizationState
            ? unlink_struct(infos[i].pRasterizationState,
                            VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT)
            : (Unlinked){NULL, NULL};
        any = any || unlinked[i].taken;
    }
    VkResult result = NEXT(device, CreateGraphicsPipelines)(handle, cache, count, infos, a, pipelines);
    // Backwards, in case two pipelines share a rasterization state.
    for (uint32_t i = count; i-- > 0;) relink(unlinked[i]);
    if (unlinked != on_stack) free(unlinked);
    if (any && !atomic_flag_test_and_set(&provoking_logged)) {
        LOG("ANGLE pipelines draw flat varyings from the first vertex (the layer stands in for VK_EXT_provoking_vertex)");
    }
    return pipelines_made(kept, result);
}

// MARK: Border colours

// Metal's samplers take one of six fixed border colours. ANGLE sends a
// custom one (VK_EXT_custom_border_color, which the layer stands in for);
// the exact corners stay what they are, and any other colour becomes the
// nearest corner — a border colour a game reads back would differ, nothing
// else does.
static VkBorderColor nearest_border_color(bool is_float, const VkClearColorValue* color, bool* rounded) {
    static const VkBorderColor float_corners[3] = {
        VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK, VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK, VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE};
    static const VkBorderColor int_corners[3] = {
        VK_BORDER_COLOR_INT_TRANSPARENT_BLACK, VK_BORDER_COLOR_INT_OPAQUE_BLACK, VK_BORDER_COLOR_INT_OPAQUE_WHITE};
    *rounded = false;
    if (is_float) {
        const float* c = color->float32;
        if (c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 0) return float_corners[0];
        if (c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 1.0f) return float_corners[1];
        if (c[0] == 1.0f && c[1] == 1.0f && c[2] == 1.0f && c[3] == 1.0f) return float_corners[2];
        *rounded = true;
        int best = 0;
        float best_distance = 0;
        for (int corner = 0; corner < 3; corner++) {
            float distance = 0;
            for (int i = 0; i < 4; i++) {
                float side = c[i] - (corner == 2 ? 1.0f : i == 3 ? corner : 0.0f);
                distance += side * side;
            }
            if (corner == 0 || distance < best_distance) {
                best = corner;
                best_distance = distance;
            }
        }
        return float_corners[best];
    }
    const int32_t* c = color->int32;
    if (c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 0) return int_corners[0];
    if (c[0] == 0 && c[1] == 0 && c[2] == 0 && c[3] == 1) return int_corners[1];
    if (c[0] == 1 && c[1] == 1 && c[2] == 1 && c[3] == 1) return int_corners[2];
    *rounded = true;
    int best = 0;
    long best_distance = 0;
    for (int corner = 0; corner < 3; corner++) {
        long distance = 0;
        for (int i = 0; i < 4; i++) {
            long side = c[i] - (corner == 2 ? 1 : i == 3 ? corner : 0);
            distance += side * side;
        }
        if (corner == 0 || distance < best_distance) {
            best = corner;
            best_distance = distance;
        }
    }
    return int_corners[best];
}

static atomic_flag border_rounded_logged = ATOMIC_FLAG_INIT;

// ANGLE's samplers with CLAMP_TO_BORDER carry VK_BORDER_COLOR_*_CUSTOM_EXT
// and the colour in a pNext the driver has no extension for: the layer
// swaps in the nearest fixed colour and takes the pNext out. The caller's
// chain is whole again on return.
static VKAPI_ATTR VkResult VKAPI_CALL CreateSampler(VkDevice handle, const VkSamplerCreateInfo* info,
                                                    const VkAllocationCallbacks* a, VkSampler* out) {
    Device* device = find_device(key_of(handle));
    if (!device) return VK_ERROR_DEVICE_LOST;
    if (info->borderColor != VK_BORDER_COLOR_FLOAT_CUSTOM_EXT && info->borderColor != VK_BORDER_COLOR_INT_CUSTOM_EXT) {
        return NEXT(device, CreateSampler)(handle, info, a, out);
    }
    const VkSamplerCustomBorderColorCreateInfoEXT* custom = NULL;
    for (const VkBaseInStructure* at = info->pNext; at; at = at->pNext) {
        if (at->sType == VK_STRUCTURE_TYPE_SAMPLER_CUSTOM_BORDER_COLOR_CREATE_INFO_EXT) {
            custom = (const VkSamplerCustomBorderColorCreateInfoEXT*)at;
        }
    }
    if (!custom) return VK_ERROR_INITIALIZATION_FAILED;
    bool is_float = info->borderColor == VK_BORDER_COLOR_FLOAT_CUSTOM_EXT;
    bool rounded = false;
    VkSamplerCreateInfo copy = *info;
    Unlinked unlinked = unlink_struct(&copy, VK_STRUCTURE_TYPE_SAMPLER_CUSTOM_BORDER_COLOR_CREATE_INFO_EXT);
    copy.borderColor = nearest_border_color(is_float, &custom->customBorderColor, &rounded);
    VkResult result = NEXT(device, CreateSampler)(handle, &copy, a, out);
    relink(unlinked);
    if (result == VK_SUCCESS && rounded && !atomic_flag_test_and_set(&border_rounded_logged)) {
        LOG("a custom border colour was taken to the nearest fixed one (%d %d %d %d)",
            custom->customBorderColor.int32[0], custom->customBorderColor.int32[1], custom->customBorderColor.int32[2],
            custom->customBorderColor.int32[3]);
    }
    return result;
}

static const struct {
    const char* name;
    PFN_vkVoidFunction function;
} wrapped[F_COUNT] = {
#define W(name) [F_##name] = {"vk" #name, (PFN_vkVoidFunction)name}
    W(QueueSubmit),
    W(QueueSubmit2),
    W(QueueSubmit2KHR),
    W(QueuePresentKHR),
    W(QueueSignalReleaseImageANDROID),
    [F_QueueWaitIdle] = {"vkQueueWaitIdle", NULL},
    W(CreateSampler),
    W(CreateSemaphore),
    W(ImportSemaphoreFdKHR),
    W(CreateSwapchainKHR),
    W(DestroySwapchainKHR),
    W(CreateShaderModule),
    W(CreateGraphicsPipelines),
    W(FreeMemory),
    W(FreeCommandBuffers),
    W(FreeDescriptorSets),
    W(ResetDescriptorPool),
    W(DestroyBuffer),
    W(DestroyBufferView),
    W(DestroyCommandPool),
    W(DestroyDescriptorPool),
    W(DestroyDescriptorSetLayout),
    W(DestroyDescriptorUpdateTemplate),
    W(DestroyDescriptorUpdateTemplateKHR),
    W(DestroyEvent),
    W(DestroyFence),
    W(DestroyFramebuffer),
    W(DestroyImage),
    W(DestroyImageView),
    W(DestroyPipeline),
    W(DestroyPipelineCache),
    W(DestroyPipelineLayout),
    W(DestroyPrivateDataSlot),
    W(DestroyPrivateDataSlotEXT),
    W(DestroyQueryPool),
    W(DestroyRenderPass),
    W(DestroySampler),
    W(DestroySamplerYcbcrConversion),
    W(DestroySamplerYcbcrConversionKHR),
    W(DestroySemaphore),
    W(DestroyShaderModule),
    W(CreateImage),
    [F_CmdPipelineBarrier] = {"vkCmdPipelineBarrier", NULL},
    W(CmdPipelineBarrier2),
    W(CmdPipelineBarrier2KHR),
    W(CmdWaitEvents),
    W(CmdWaitEvents2),
    W(CmdWaitEvents2KHR),
    [F_CmdCopyBufferToImage] = {"vkCmdCopyBufferToImage", NULL},
    W(CmdCopyBufferToImage2),
    W(CmdCopyBufferToImage2KHR),
#undef W
};

// The layer's function for `name` when the next layer has one for this device.
static PFN_vkVoidFunction wrapper(Device* device, const char* name) {
    for (int i = 0; i < F_COUNT; i++) {
        if (i == F_CreateGraphicsPipelines && !device->provoking_vertex && !device->moltenvk) continue;
        if (i == F_CreateSampler && !device->border_colors) continue;
        // Emulated compressed textures: the gfxstream driver's devices only.
        if (i >= F_CreateImage && !device->gfxstream) continue;
        if (wrapped[i].function && strcmp(wrapped[i].name, name) == 0) {
            return device->fn[i] ? wrapped[i].function : NULL;
        }
    }
    return NULL;
}

// MARK: Devices

static VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
                                                   const VkAllocationCallbacks* allocator, VkDevice* out) {
    DeviceCreateInfo* link = (DeviceCreateInfo*)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && link->function == LAYER_LINK_INFO)) {
        link = (DeviceCreateInfo*)link->pNext;
    }
    if (!link || !link->u.layer_info) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.layer_info->next_get_instance_proc_addr;
    PFN_vkGetDeviceProcAddr gdpa = link->u.layer_info->next_get_device_proc_addr;
    link->u.layer_info = link->u.layer_info->next;
    Instance* instance = instance_of(physical);
    PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(instance ? instance->handle : VK_NULL_HANDLE, "vkCreateDevice");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;

    // The layer's VK_EXT_provoking_vertex and VK_EXT_custom_border_color go
    // no further: neither the extensions, nor their feature structures.
    VkDeviceCreateInfo copy = *info;
    const char** names = NULL;
    Unlinked features[2] = {{NULL, NULL}, {NULL, NULL}};
    bool provoking_vertex = false, border_colors = false;
    for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
        if (strcmp(info->ppEnabledExtensionNames[i], VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME) == 0) provoking_vertex = true;
        if (strcmp(info->ppEnabledExtensionNames[i], VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME) == 0) border_colors = true;
    }
    provoking_vertex = provoking_vertex && stands_in_for_provoking_vertex(instance, physical);
    border_colors = border_colors && stands_in_for_border_colors(instance, physical);
    if (provoking_vertex || border_colors) {
        if (!(names = malloc(info->enabledExtensionCount * sizeof *names))) return VK_ERROR_OUT_OF_HOST_MEMORY;
        copy.enabledExtensionCount = 0;
        for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
            const char* name = info->ppEnabledExtensionNames[i];
            if (provoking_vertex && strcmp(name, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME) == 0) continue;
            if (border_colors && strcmp(name, VK_EXT_CUSTOM_BORDER_COLOR_EXTENSION_NAME) == 0) continue;
            names[copy.enabledExtensionCount++] = name;
        }
        copy.ppEnabledExtensionNames = names;
        if (provoking_vertex) {
            features[0] = unlink_struct(&copy, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT);
        }
        if (border_colors) {
            features[1] = unlink_struct(&copy, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_CUSTOM_BORDER_COLOR_FEATURES_EXT);
        }
    }
    VkResult result = create(physical, &copy, allocator, out);
    relink(features[0]);
    relink(features[1]);
    free(names);
    if (result != VK_SUCCESS) return result;

    Device* device = calloc(1, sizeof *device);
    if (!device) {
        // The layer would hand out no functions for it: no device.
        PFN_vkDestroyDevice destroy = (PFN_vkDestroyDevice)gdpa(*out, "vkDestroyDevice");
        bool gate = gfxstream_driver();
        if (gate) read_begin();
        if (destroy) destroy(*out, allocator);
        if (gate) read_end();
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    device->handle = *out;
    device->key = key_of(*out);
    device->gdpa = gdpa;
    device->destroy = (PFN_vkDestroyDevice)gdpa(*out, "vkDestroyDevice");
    pthread_mutex_init(&device->semaphores_lock, NULL);
    for (int i = 0; i < F_COUNT; i++) device->fn[i] = gdpa(*out, wrapped[i].name);
    bool gfxstream = gfxstream_driver();
    // Every device of the driver, compute-only ones too (no swapchain): the
    // driver's lock and command order are the process's. Presents also need
    // vkQueueWaitIdle (QueuePresentKHR).
    device->gfxstream = gfxstream && device->fn[F_QueueSubmit];
    device->moltenvk = gfxstream && device->fn[F_CreateShaderModule];
    device->provoking_vertex = provoking_vertex && device->fn[F_CreateGraphicsPipelines];
    device->border_colors = border_colors && device->fn[F_CreateSampler];
    if (device->gfxstream) {
        LOG("gfxstream device %p: %sdestroys are kept apart from submissions that signal sync fds, fragment output "
            "arrays are split for MoltenVK",
            (void*)*out,
            (device->fn[F_QueuePresentKHR] || device->fn[F_QueueSignalReleaseImageANDROID]) && device->fn[F_QueueWaitIdle]
                ? "presents wait outside the driver lock, "
                : "");
    } else if (device->moltenvk) {
        LOG("gfxstream device %p: fragment output arrays are split for MoltenVK", (void*)*out);
    }
    if (device->provoking_vertex) {
        LOG("gfxstream device %p: ANGLE's VK_EXT_provoking_vertex is the layer's (flat varyings from the first vertex)",
            (void*)*out);
    }
    pthread_mutex_lock(&lists_lock);
    device->next = devices;
    devices = device;
    pthread_mutex_unlock(&lists_lock);
    return result;
}

static VKAPI_ATTR void VKAPI_CALL DestroyDevice(VkDevice handle, const VkAllocationCallbacks* allocator) {
    if (!handle) return;
    pthread_mutex_lock(&lists_lock);
    Device* device = device_for_key(key_of(handle));
    for (Device** link = &devices; device && *link; link = &(*link)->next) {
        if (*link == device) {
            *link = device->next;
            break;
        }
    }
    pthread_mutex_unlock(&lists_lock);
    if (!device) return;
    if (device->gfxstream) read_begin();
    device->destroy(handle, allocator);
    if (device->gfxstream) read_end();
    pthread_mutex_destroy(&device->semaphores_lock);
    free(device->semaphores);
    free(device);
}

// MARK: Instances

static VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo* info, const VkAllocationCallbacks* allocator,
                                                     VkInstance* out) {
    InstanceCreateInfo* link = (InstanceCreateInfo*)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && link->function == LAYER_LINK_INFO)) {
        link = (InstanceCreateInfo*)link->pNext;
    }
    if (!link || !link->u.layer_info) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.layer_info->next_get_instance_proc_addr;
    link->u.layer_info = link->u.layer_info->next;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(info, allocator, out);
    if (result != VK_SUCCESS) return result;

    Instance* instance = calloc(1, sizeof *instance);
    if (!instance) {
        PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)gipa(*out, "vkDestroyInstance");
        bool gate = gfxstream_driver();
        if (gate) read_begin();
        if (destroy) destroy(*out, allocator);
        if (gate) read_end();
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    instance->handle = *out;
    instance->key = key_of(*out);
    instance->gipa = gipa;
    instance->destroy = (PFN_vkDestroyInstance)gipa(*out, "vkDestroyInstance");
    instance->gfxstream = gfxstream_driver();
    instance->destroy_messenger = (PFN_vkDestroyDebugUtilsMessengerEXT)gipa(*out, "vkDestroyDebugUtilsMessengerEXT");
    instance->destroy_report_callback =
        (PFN_vkDestroyDebugReportCallbackEXT)gipa(*out, "vkDestroyDebugReportCallbackEXT");
    instance->format_properties = (PFN_vkGetPhysicalDeviceFormatProperties)gipa(*out, "vkGetPhysicalDeviceFormatProperties");
    instance->format_properties2 = (PFN_vkGetPhysicalDeviceFormatProperties2)gipa(*out, "vkGetPhysicalDeviceFormatProperties2");
    instance->format_properties2_khr =
        (PFN_vkGetPhysicalDeviceFormatProperties2KHR)gipa(*out, "vkGetPhysicalDeviceFormatProperties2KHR");
    instance->enumerate_extensions =
        (PFN_vkEnumerateDeviceExtensionProperties)gipa(*out, "vkEnumerateDeviceExtensionProperties");
    instance->features2 = (PFN_vkGetPhysicalDeviceFeatures2)gipa(*out, "vkGetPhysicalDeviceFeatures2");
    instance->features2_khr = (PFN_vkGetPhysicalDeviceFeatures2KHR)gipa(*out, "vkGetPhysicalDeviceFeatures2KHR");
    instance->properties2 = (PFN_vkGetPhysicalDeviceProperties2)gipa(*out, "vkGetPhysicalDeviceProperties2");
    instance->properties2_khr = (PFN_vkGetPhysicalDeviceProperties2KHR)gipa(*out, "vkGetPhysicalDeviceProperties2KHR");
    // ANGLE names itself as the engine (and HWUI shares its instance).
    const VkApplicationInfo* app = info->pApplicationInfo;
    instance->angle = gfxstream_driver() && instance->enumerate_extensions && app && app->pEngineName
        && strcmp(app->pEngineName, "ANGLE") == 0;
    pthread_mutex_lock(&lists_lock);
    instance->next = instances;
    instances = instance;
    pthread_mutex_unlock(&lists_lock);
    return result;
}

static VKAPI_ATTR void VKAPI_CALL DestroyInstance(VkInstance handle, const VkAllocationCallbacks* allocator) {
    if (!handle) return;
    pthread_mutex_lock(&lists_lock);
    Instance* instance = instance_for_key(key_of(handle));
    for (Instance** link = &instances; instance && *link; link = &(*link)->next) {
        if (*link == instance) {
            *link = instance->next;
            break;
        }
    }
    pthread_mutex_unlock(&lists_lock);
    if (!instance) return;
    if (instance->gfxstream) read_begin();
    if (instance->destroy) instance->destroy(handle, allocator);
    if (instance->gfxstream) read_end();
    free(instance);
}

// The instance's other destroys, handed out for the gfxstream driver only.
static VKAPI_ATTR void VKAPI_CALL DestroyDebugUtilsMessengerEXT(VkInstance handle, VkDebugUtilsMessengerEXT messenger,
                                                                const VkAllocationCallbacks* a) {
    Instance* instance = find_instance(key_of(handle));
    if (!instance) return;
    read_begin();
    instance->destroy_messenger(handle, messenger, a);
    read_end();
}

static VKAPI_ATTR void VKAPI_CALL DestroyDebugReportCallbackEXT(VkInstance handle, VkDebugReportCallbackEXT callback,
                                                                const VkAllocationCallbacks* a) {
    Instance* instance = find_instance(key_of(handle));
    if (!instance) return;
    read_begin();
    instance->destroy_report_callback(handle, callback, a);
    read_end();
}

// MARK: Entry points

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice handle, const char* name) {
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)DestroyDevice;
    Device* device = handle ? find_device(key_of(handle)) : NULL;
    if (!device) return NULL;
    PFN_vkVoidFunction own = wrapper(device, name);
    return own ? own : device->gdpa(handle, name);
}

EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance handle, const char* name) {
    if (strcmp(name, "vkGetInstanceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
    if (strcmp(name, "vkCreateInstance") == 0) return (PFN_vkVoidFunction)CreateInstance;
    if (strcmp(name, "vkDestroyInstance") == 0) return (PFN_vkVoidFunction)DestroyInstance;
    if (strcmp(name, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)CreateDevice;
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)DestroyDevice;
    Instance* instance = handle ? find_instance(key_of(handle)) : NULL;
    if (!instance) return NULL;
    if (instance->gfxstream) {
        if (strcmp(name, "vkDestroyDebugUtilsMessengerEXT") == 0 && instance->destroy_messenger) {
            return (PFN_vkVoidFunction)DestroyDebugUtilsMessengerEXT;
        }
        if (strcmp(name, "vkDestroyDebugReportCallbackEXT") == 0 && instance->destroy_report_callback) {
            return (PFN_vkVoidFunction)DestroyDebugReportCallbackEXT;
        }
        if (strcmp(name, "vkGetPhysicalDeviceFormatProperties") == 0 && instance->format_properties) {
            return (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties;
        }
        if (strcmp(name, "vkGetPhysicalDeviceFormatProperties2") == 0 && instance->format_properties2) {
            return (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties2;
        }
        if (strcmp(name, "vkGetPhysicalDeviceFormatProperties2KHR") == 0 && instance->format_properties2_khr) {
            return (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties2KHR;
        }
    }
    if (instance->angle) {
        if (strcmp(name, "vkEnumerateDeviceExtensionProperties") == 0) {
            return (PFN_vkVoidFunction)vkEnumerateDeviceExtensionProperties;
        }
        if (strcmp(name, "vkGetPhysicalDeviceFeatures2") == 0 && instance->features2) {
            return (PFN_vkVoidFunction)GetPhysicalDeviceFeatures2;
        }
        if (strcmp(name, "vkGetPhysicalDeviceFeatures2KHR") == 0 && instance->features2_khr) {
            return (PFN_vkVoidFunction)GetPhysicalDeviceFeatures2KHR;
        }
        if (strcmp(name, "vkGetPhysicalDeviceProperties2") == 0 && instance->properties2) {
            return (PFN_vkVoidFunction)GetPhysicalDeviceProperties2;
        }
        if (strcmp(name, "vkGetPhysicalDeviceProperties2KHR") == 0 && instance->properties2_khr) {
            return (PFN_vkVoidFunction)GetPhysicalDeviceProperties2KHR;
        }
    }
    return instance->gipa(handle, name);
}

static const VkLayerProperties layer_properties = {
    .layerName = LAYER_NAME,
    .specVersion = VK_MAKE_API_VERSION(0, 1, 3, 0),
    .implementationVersion = 1,
    .description = "Avo: keeps gfxstream from deadlocking, works around MoltenVK",
};

static VkResult one_layer(uint32_t* count, VkLayerProperties* properties) {
    if (!properties) {
        *count = 1;
        return VK_SUCCESS;
    }
    if (*count < 1) return VK_INCOMPLETE;
    properties[0] = layer_properties;
    *count = 1;
    return VK_SUCCESS;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceLayerProperties(uint32_t* count, VkLayerProperties* properties) {
    return one_layer(count, properties);
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceLayerProperties(VkPhysicalDevice physical, uint32_t* count,
                                                                     VkLayerProperties* properties) {
    (void)physical;
    return one_layer(count, properties);
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(const char* layer_name, uint32_t* count,
                                                                           VkExtensionProperties* properties) {
    (void)properties;
    if (!layer_name || strcmp(layer_name, LAYER_NAME) != 0) return VK_ERROR_LAYER_NOT_PRESENT;
    *count = 0;
    return VK_SUCCESS;
}

EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceExtensionProperties(VkPhysicalDevice physical, const char* layer_name,
                                                                         uint32_t* count, VkExtensionProperties* properties) {
    if (layer_name && strcmp(layer_name, LAYER_NAME) == 0) {
        *count = 0;
        return VK_SUCCESS;
    }
    Instance* instance = physical ? find_instance(key_of(physical)) : NULL;
    if (!instance || !instance->enumerate_extensions) return VK_ERROR_LAYER_NOT_PRESENT;
    if (!layer_name) return device_extensions(instance, physical, count, properties);
    return instance->enumerate_extensions(physical, layer_name, count, properties);
}

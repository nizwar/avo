// VK_LAYER_AVO_native_astc: a Vulkan layer between gfxstream and MoltenVK on
// the Mac (avo-vmm loads it through the Vulkan loader; astc.rs).
//
// gfxstream decompresses ASTC textures itself, into RGBA8 with compute
// shaders, whenever the driver lacks sampled, linear-filtered *linear* tiling
// for ASTC (needEmulatedAstc). Metal has no linear compressed textures, so
// MoltenVK never reports it, and every guest ASTC texture is emulated although
// the Mac's GPU samples ASTC natively. An emulated texture takes its RGBA8
// image plus all its compressed levels: about 5x the memory of ASTC 4x4, 10x
// of 6x6 and 17x of 8x8. Games size their texture streaming by those numbers
// and drop mip levels within a second (Delta Force: sharp, then blurry).
//
// This layer adds SAMPLED_IMAGE and SAMPLED_IMAGE_FILTER_LINEAR to the linear
// tiling features of ASTC LDR formats wherever optimal tiling has them, so
// gfxstream passes ASTC straight to MoltenVK. Avo's guest layer
// (guest/gfxsync) takes the two bits away again, so apps never try a linear
// ASTC image. Everything else passes straight through.
//
// With AVO_VK_TRACE=1 or ~/Library/Logs/Avo/vk-trace.on at the start, it also
// writes to the engine's log, each kind once with the time, what the guest's
// renderers ask MoltenVK for: images (format, size class, mips, layers, usage,
// flags), views that read an image in another format, samplers, descriptor and
// pipeline layouts that pass Metal's 16 samplers a stage, and every pipeline,
// image or image-format query that fails. It is for finding what a game does
// that the Mac's GPU path gets wrong, from the Mac's side only.
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>

// The few Vulkan types the layer needs (vulkan_core.h, vk_layer.h), so it
// builds with nothing but the Mac's clang.
typedef int32_t VkResult;
typedef int32_t VkStructureType;
typedef int32_t VkFormat;
typedef uint32_t VkFlags;
typedef struct VkInstance_T* VkInstance;
typedef struct VkPhysicalDevice_T* VkPhysicalDevice;
typedef struct VkDevice_T* VkDevice;
typedef struct VkImage_T* VkImage;
typedef struct VkImageView_T* VkImageView;
typedef struct VkSampler_T* VkSampler;
typedef struct VkDescriptorSetLayout_T* VkDescriptorSetLayout;
typedef struct VkPipelineLayout_T* VkPipelineLayout;
typedef struct VkPipelineCache_T* VkPipelineCache;
typedef struct VkPipeline_T* VkPipeline;
typedef uint32_t VkBool32;
typedef void (*PFN_vkVoidFunction)(void);
typedef PFN_vkVoidFunction (*PFN_vkGetInstanceProcAddr)(VkInstance, const char*);
typedef PFN_vkVoidFunction (*PFN_vkGetDeviceProcAddr)(VkDevice, const char*);
typedef PFN_vkVoidFunction (*PFN_GetPhysicalDeviceProcAddr)(VkInstance, const char*);

enum {
    VK_SUCCESS = 0,
    VK_ERROR_OUT_OF_HOST_MEMORY = -1,
    VK_ERROR_INITIALIZATION_FAILED = -3,
    VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO = 47,
    VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO = 48,
    VK_LAYER_LINK_INFO = 0,
    LAYER_NEGOTIATE_INTERFACE_STRUCT = 1,
    VK_FORMAT_ASTC_4x4_UNORM_BLOCK = 157,
    VK_FORMAT_ASTC_12x12_SRGB_BLOCK = 184,
    VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT = 0x1,
    VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT = 0x1000,
};

typedef struct {
    VkFlags linearTilingFeatures;
    VkFlags optimalTilingFeatures;
    VkFlags bufferFeatures;
} VkFormatProperties;

typedef struct {
    VkStructureType sType;
    void* pNext;
    VkFormatProperties formatProperties;
} VkFormatProperties2;

typedef struct VkLayerInstanceLink {
    struct VkLayerInstanceLink* pNext;
    PFN_vkGetInstanceProcAddr pfnNextGetInstanceProcAddr;
    PFN_GetPhysicalDeviceProcAddr pfnNextGetPhysicalDeviceProcAddr;
} VkLayerInstanceLink;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    int32_t function;
    union {
        VkLayerInstanceLink* pLayerInfo;
        void* other;
    } u;
} VkLayerInstanceCreateInfo;

typedef struct VkLayerDeviceLink {
    struct VkLayerDeviceLink* pNext;
    PFN_vkGetInstanceProcAddr pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr pfnNextGetDeviceProcAddr;
} VkLayerDeviceLink;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    int32_t function;
    union {
        VkLayerDeviceLink* pLayerInfo;
        void* other;
    } u;
} VkLayerDeviceCreateInfo;

typedef struct {
    int32_t sType;
    void* pNext;
    uint32_t loaderLayerInterfaceVersion;
    PFN_vkGetInstanceProcAddr pfnGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr pfnGetDeviceProcAddr;
    PFN_GetPhysicalDeviceProcAddr pfnGetPhysicalDeviceProcAddr;
} VkNegotiateLayerInterface;

typedef struct {
    VkStructureType sType;
    const void* pNext;
} VkBaseStructure;

typedef struct { uint32_t width, height, depth; } VkExtent3D;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    int32_t imageType;
    VkFormat format;
    VkExtent3D extent;
    uint32_t mipLevels;
    uint32_t arrayLayers;
    int32_t samples;
    int32_t tiling;
    VkFlags usage;
    int32_t sharingMode;
    uint32_t queueFamilyIndexCount;
    const uint32_t* pQueueFamilyIndices;
    int32_t initialLayout;
} VkImageCreateInfo;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    VkImage image;
    int32_t viewType;
    VkFormat format;
    int32_t components[4];
    VkFlags aspectMask;
    uint32_t baseMipLevel, levelCount, baseArrayLayer, layerCount;
} VkImageViewCreateInfo;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    int32_t magFilter, minFilter, mipmapMode;
    int32_t addressModeU, addressModeV, addressModeW;
    float mipLodBias;
    VkBool32 anisotropyEnable;
    float maxAnisotropy;
    VkBool32 compareEnable;
    int32_t compareOp;
    float minLod, maxLod;
    int32_t borderColor;
    VkBool32 unnormalizedCoordinates;
} VkSamplerCreateInfo;

typedef struct {
    uint32_t binding;
    int32_t descriptorType;
    uint32_t descriptorCount;
    VkFlags stageFlags;
    const VkSampler* pImmutableSamplers;
} VkDescriptorSetLayoutBinding;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    uint32_t bindingCount;
    const VkDescriptorSetLayoutBinding* pBindings;
} VkDescriptorSetLayoutCreateInfo;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    uint32_t setLayoutCount;
    const VkDescriptorSetLayout* pSetLayouts;
    uint32_t pushConstantRangeCount;
    const void* pPushConstantRanges;
} VkPipelineLayoutCreateInfo;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFormat format;
    int32_t type;
    int32_t tiling;
    VkFlags usage;
    VkFlags flags;
} VkPhysicalDeviceImageFormatInfo2;

typedef VkResult (*PFN_vkCreateInstance)(const void*, const void*, VkInstance*);
typedef void (*PFN_vkDestroyInstance)(VkInstance, const void*);
typedef VkResult (*PFN_vkCreateDevice)(VkPhysicalDevice, const void*, const void*, VkDevice*);
typedef void (*PFN_vkDestroyDevice)(VkDevice, const void*);
typedef void (*PFN_vkGetPhysicalDeviceFormatProperties)(VkPhysicalDevice, VkFormat, VkFormatProperties*);
typedef void (*PFN_vkGetPhysicalDeviceFormatProperties2)(VkPhysicalDevice, VkFormat, VkFormatProperties2*);
typedef VkResult (*PFN_vkGetPhysicalDeviceImageFormatProperties)(VkPhysicalDevice, VkFormat, int32_t, int32_t, VkFlags, VkFlags, void*);
typedef VkResult (*PFN_vkGetPhysicalDeviceImageFormatProperties2)(VkPhysicalDevice, const VkPhysicalDeviceImageFormatInfo2*, void*);
typedef VkResult (*PFN_vkCreateImage)(VkDevice, const VkImageCreateInfo*, const void*, VkImage*);
typedef VkResult (*PFN_vkCreateImageView)(VkDevice, const VkImageViewCreateInfo*, const void*, VkImageView*);
typedef VkResult (*PFN_vkCreateSampler)(VkDevice, const VkSamplerCreateInfo*, const void*, VkSampler*);
typedef VkResult (*PFN_vkCreateDescriptorSetLayout)(VkDevice, const VkDescriptorSetLayoutCreateInfo*, const void*, VkDescriptorSetLayout*);
typedef VkResult (*PFN_vkCreatePipelineLayout)(VkDevice, const VkPipelineLayoutCreateInfo*, const void*, VkPipelineLayout*);
typedef VkResult (*PFN_vkCreatePipelines)(VkDevice, VkPipelineCache, uint32_t, const void*, const void*, VkPipeline*);

#define EXPORT __attribute__((visibility("default")))

// The first word of an instance, physical device or device handle: the
// loader's dispatch table, the same for an instance and its physical devices.
static void* key_of(const void* handle) { return *(void* const*)handle; }

// MARK: Instances and devices

typedef struct Instance {
    struct Instance* next;
    void* key;
    VkInstance handle;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkDestroyInstance destroy;
    PFN_vkGetPhysicalDeviceFormatProperties format_properties;
    PFN_vkGetPhysicalDeviceFormatProperties2 format_properties2;
    PFN_vkGetPhysicalDeviceFormatProperties2 format_properties2_khr;
    PFN_vkGetPhysicalDeviceImageFormatProperties image_format_properties;
    PFN_vkGetPhysicalDeviceImageFormatProperties2 image_format_properties2;
    PFN_vkGetPhysicalDeviceImageFormatProperties2 image_format_properties2_khr;
} Instance;

typedef struct Device {
    struct Device* next;
    void* key;
    PFN_vkGetDeviceProcAddr gdpa;
    PFN_vkDestroyDevice destroy;
    // The driver's, for the trace.
    PFN_vkCreateImage create_image;
    PFN_vkCreateImageView create_image_view;
    PFN_vkCreateSampler create_sampler;
    PFN_vkCreateDescriptorSetLayout create_set_layout;
    PFN_vkCreatePipelineLayout create_pipeline_layout;
    PFN_vkCreatePipelines create_graphics_pipelines;
    PFN_vkCreatePipelines create_compute_pipelines;
} Device;

static pthread_mutex_t lists_lock = PTHREAD_MUTEX_INITIALIZER;
static Instance* instances;
static Device* devices;

// The instance of `key`, or the newest one should a physical device's key
// ever differ from its instance's.
static Instance* find_instance(void* key) {
    pthread_mutex_lock(&lists_lock);
    Instance* found = instances;
    while (found && found->key != key) found = found->next;
    if (!found) found = instances;
    pthread_mutex_unlock(&lists_lock);
    return found;
}

static Device* find_device(void* key) {
    pthread_mutex_lock(&lists_lock);
    Device* found = devices;
    while (found && found->key != key) found = found->next;
    pthread_mutex_unlock(&lists_lock);
    return found;
}

// MARK: Format properties

static atomic_flag announced = ATOMIC_FLAG_INIT;

static void add_linear(VkFormat format, VkFormatProperties* properties) {
    const VkFlags sampled = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    if (format < VK_FORMAT_ASTC_4x4_UNORM_BLOCK || format > VK_FORMAT_ASTC_12x12_SRGB_BLOCK) return;
    if ((properties->optimalTilingFeatures & sampled) != sampled) return;
    properties->linearTilingFeatures |= sampled;
    if (!atomic_flag_test_and_set(&announced)) {
        fprintf(stderr, "[gpu] ASTC goes to Metal natively (no gfxstream decompression)\n");
    }
}

static void GetPhysicalDeviceFormatProperties(VkPhysicalDevice physical, VkFormat format, VkFormatProperties* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->format_properties) return;
    instance->format_properties(physical, format, properties);
    add_linear(format, properties);
}

static void GetPhysicalDeviceFormatProperties2(VkPhysicalDevice physical, VkFormat format, VkFormatProperties2* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->format_properties2) return;
    instance->format_properties2(physical, format, properties);
    add_linear(format, &properties->formatProperties);
}

static void GetPhysicalDeviceFormatProperties2KHR(VkPhysicalDevice physical, VkFormat format, VkFormatProperties2* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->format_properties2_khr) return;
    instance->format_properties2_khr(physical, format, properties);
    add_linear(format, &properties->formatProperties);
}

// MARK: Trace

static atomic_int trace_state; // 0 not decided, 1 off, 2 on

static int tracing(void) {
    int state = atomic_load(&trace_state);
    if (state) return state == 2;
    const char* env = getenv("AVO_VK_TRACE");
    int on = env && *env && strcmp(env, "0") != 0;
    const char* home = getenv("HOME");
    char path[1024];
    if (!on && home && snprintf(path, sizeof path, "%s/Library/Logs/Avo/vk-trace.on", home) < (int)sizeof path) {
        on = access(path, F_OK) == 0;
    }
    int expected = 0;
    if (atomic_compare_exchange_strong(&trace_state, &expected, on ? 2 : 1) && on) {
        fprintf(stderr, "[vk-trace] on: images, views, samplers, layouts past 16 samplers a stage, and failures, each kind once\n");
    }
    return atomic_load(&trace_state) == 2;
}

// Each kind of line once: a set of their hashes (FNV-1a).
#define SEEN_SLOTS 16384
static _Atomic uint64_t seen[SEEN_SLOTS];

static int first_time(const char* line) {
    uint64_t hash = 1469598103934665603ull;
    for (const char* c = line; *c; c++) hash = (hash ^ (unsigned char)*c) * 1099511628211ull;
    if (!hash) hash = 1;
    for (uint32_t probe = 0; probe < 64; probe++) {
        _Atomic uint64_t* slot = &seen[(hash + probe) & (SEEN_SLOTS - 1)];
        uint64_t current = atomic_load(slot);
        if (current == hash) return 0;
        if (current == 0) {
            uint64_t empty = 0;
            if (atomic_compare_exchange_strong(slot, &empty, hash)) return 1;
            if (empty == hash) return 0;
        }
    }
    return 0;
}

static void trace(const char* format, ...) {
    char line[512];
    va_list args;
    va_start(args, format);
    vsnprintf(line, sizeof line, format, args);
    va_end(args);
    if (!first_time(line)) return;
    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    fprintf(stderr, "[vk-trace %02d:%02d:%02d] %s\n", local.tm_hour, local.tm_min, local.tm_sec, line);
}

// The size class of an image: its largest side, rounded up to a power of two.
static uint32_t size_class(VkExtent3D e) {
    uint32_t side = e.width > e.height ? e.width : e.height;
    if (e.depth > side) side = e.depth;
    uint32_t class = 1;
    while (class < side) class <<= 1;
    return class;
}

// Each image's format, for views that read it in another one.
#define IMAGE_SLOTS 65536
static _Atomic uintptr_t image_keys[IMAGE_SLOTS];
static _Atomic int32_t image_formats[IMAGE_SLOTS];

static void remember_format(VkImage image, VkFormat format) {
    uintptr_t key = (uintptr_t)image;
    if (!key) return;
    for (uint32_t probe = 0; probe < 32; probe++) {
        uint32_t slot = (uint32_t)((key >> 4) + probe) & (IMAGE_SLOTS - 1);
        uintptr_t current = atomic_load(&image_keys[slot]);
        if (current == key || current == 0) {
            uintptr_t expected = current;
            if (current == key || atomic_compare_exchange_strong(&image_keys[slot], &expected, key) || expected == key) {
                atomic_store(&image_formats[slot], format);
                return;
            }
        }
    }
}

static VkFormat format_of(VkImage image) {
    uintptr_t key = (uintptr_t)image;
    for (uint32_t probe = 0; key && probe < 32; probe++) {
        uint32_t slot = (uint32_t)((key >> 4) + probe) & (IMAGE_SLOTS - 1);
        uintptr_t current = atomic_load(&image_keys[slot]);
        if (current == key) return atomic_load(&image_formats[slot]);
        if (current == 0) return 0;
    }
    return 0;
}

// Samplers (combined or alone) and sampled images per stage of each
// descriptor set layout, for the pipeline layouts built from them.
enum { STAGE_VERTEX, STAGE_FRAGMENT, STAGE_COMPUTE, STAGES };
typedef struct { uint32_t samplers[STAGES], images[STAGES]; } Counts;
#define LAYOUT_SLOTS 16384
static _Atomic uintptr_t layout_keys[LAYOUT_SLOTS];
static Counts layout_counts[LAYOUT_SLOTS];

static Counts* counts_slot(VkDescriptorSetLayout layout, int insert) {
    uintptr_t key = (uintptr_t)layout;
    for (uint32_t probe = 0; key && probe < 32; probe++) {
        uint32_t slot = (uint32_t)((key >> 4) + probe) & (LAYOUT_SLOTS - 1);
        uintptr_t current = atomic_load(&layout_keys[slot]);
        if (current == key) return &layout_counts[slot];
        if (current == 0) {
            if (!insert) return NULL;
            uintptr_t expected = 0;
            if (atomic_compare_exchange_strong(&layout_keys[slot], &expected, key) || expected == key) return &layout_counts[slot];
        }
    }
    return NULL;
}

static const char* const stage_names[STAGES] = {"vertex", "fragment", "compute"};
static const VkFlags stage_bits[STAGES] = {0x1, 0x10, 0x20};

static Device* device_of(VkDevice handle) { return find_device(key_of(handle)); }

static VkResult CreateImage(VkDevice handle, const VkImageCreateInfo* info, const void* allocator, VkImage* out) {
    Device* device = device_of(handle);
    VkResult result = device->create_image(handle, info, allocator, out);
    if (result == VK_SUCCESS) remember_format(*out, info->format);
    char failed[32] = "";
    if (result != VK_SUCCESS) snprintf(failed, sizeof failed, " FAILED with %d", result);
    trace("image format %d type %d size %u mips %s layers %u samples %d tiling %d usage 0x%x flags 0x%x%s", info->format,
          info->imageType, size_class(info->extent), info->mipLevels > 1 ? "many" : "1", info->arrayLayers, info->samples,
          info->tiling, info->usage, info->flags, failed);
    return result;
}

static VkResult CreateImageView(VkDevice handle, const VkImageViewCreateInfo* info, const void* allocator, VkImageView* out) {
    Device* device = device_of(handle);
    VkResult result = device->create_image_view(handle, info, allocator, out);
    VkFormat image = format_of(info->image);
    if (image && image != info->format) trace("view of a format %d image as format %d (type %d)", image, info->format, info->viewType);
    if (info->components[0] | info->components[1] | info->components[2] | info->components[3]) {
        trace("view format %d swizzle %d %d %d %d", info->format, info->components[0], info->components[1], info->components[2], info->components[3]);
    }
    if (result != VK_SUCCESS) trace("view format %d type %d FAILED with %d", info->format, info->viewType, result);
    return result;
}

static VkResult CreateSampler(VkDevice handle, const VkSamplerCreateInfo* info, const void* allocator, VkSampler* out) {
    Device* device = device_of(handle);
    VkResult result = device->create_sampler(handle, info, allocator, out);
    trace("sampler filter %d/%d mip %d address %d %d %d aniso %d x%.0f compare %d op %d lod %.1f..%.1f border %d unnormalized %d%s",
          info->magFilter, info->minFilter, info->mipmapMode, info->addressModeU, info->addressModeV, info->addressModeW,
          info->anisotropyEnable, info->maxAnisotropy, info->compareEnable, info->compareOp, info->minLod, info->maxLod,
          info->borderColor, info->unnormalizedCoordinates, result == VK_SUCCESS ? "" : " FAILED");
    return result;
}

static VkResult CreateDescriptorSetLayout(VkDevice handle, const VkDescriptorSetLayoutCreateInfo* info, const void* allocator,
                                          VkDescriptorSetLayout* out) {
    Device* device = device_of(handle);
    VkResult result = device->create_set_layout(handle, info, allocator, out);
    Counts counts = {{0}, {0}};
    for (uint32_t b = 0; b < info->bindingCount; b++) {
        const VkDescriptorSetLayoutBinding* binding = &info->pBindings[b];
        // 0 sampler, 1 combined image sampler, 2 sampled image.
        for (int stage = 0; stage < STAGES; stage++) {
            if (!(binding->stageFlags & stage_bits[stage])) continue;
            if (binding->descriptorType == 0 || binding->descriptorType == 1) counts.samplers[stage] += binding->descriptorCount;
            if (binding->descriptorType == 1 || binding->descriptorType == 2) counts.images[stage] += binding->descriptorCount;
        }
    }
    if (result == VK_SUCCESS) {
        Counts* slot = counts_slot(*out, 1);
        if (slot) *slot = counts;
    } else {
        trace("descriptor set layout of %u bindings FAILED with %d", info->bindingCount, result);
    }
    for (int stage = 0; stage < STAGES; stage++) {
        if (counts.samplers[stage] > 16) trace("descriptor set layout: %u samplers for the %s stage", counts.samplers[stage], stage_names[stage]);
    }
    return result;
}

static VkResult CreatePipelineLayout(VkDevice handle, const VkPipelineLayoutCreateInfo* info, const void* allocator, VkPipelineLayout* out) {
    Device* device = device_of(handle);
    VkResult result = device->create_pipeline_layout(handle, info, allocator, out);
    Counts sum = {{0}, {0}};
    for (uint32_t i = 0; i < info->setLayoutCount; i++) {
        Counts* counts = counts_slot(info->pSetLayouts[i], 0);
        for (int stage = 0; counts && stage < STAGES; stage++) {
            sum.samplers[stage] += counts->samplers[stage];
            sum.images[stage] += counts->images[stage];
        }
    }
    for (int stage = 0; stage < STAGES; stage++) {
        if (sum.samplers[stage] > 16) {
            trace("pipeline layout: %u samplers and %u sampled images for the %s stage (Metal: 16 samplers)%s", sum.samplers[stage],
                  sum.images[stage], stage_names[stage], result == VK_SUCCESS ? "" : " FAILED");
        }
    }
    if (result != VK_SUCCESS) trace("pipeline layout of %u sets FAILED with %d", info->setLayoutCount, result);
    return result;
}

static VkResult CreateGraphicsPipelines(VkDevice handle, VkPipelineCache cache, uint32_t count, const void* infos, const void* allocator,
                                        VkPipeline* out) {
    Device* device = device_of(handle);
    VkResult result = device->create_graphics_pipelines(handle, cache, count, infos, allocator, out);
    if (result != VK_SUCCESS) trace("graphics pipelines FAILED with %d", result);
    return result;
}

static VkResult CreateComputePipelines(VkDevice handle, VkPipelineCache cache, uint32_t count, const void* infos, const void* allocator,
                                       VkPipeline* out) {
    Device* device = device_of(handle);
    VkResult result = device->create_compute_pipelines(handle, cache, count, infos, allocator, out);
    if (result != VK_SUCCESS) trace("compute pipelines FAILED with %d", result);
    return result;
}

static VkResult GetPhysicalDeviceImageFormatProperties(VkPhysicalDevice physical, VkFormat format, int32_t type, int32_t tiling,
                                                       VkFlags usage, VkFlags flags, void* properties) {
    Instance* instance = find_instance(key_of(physical));
    VkResult result = instance->image_format_properties(physical, format, type, tiling, usage, flags, properties);
    if (result != VK_SUCCESS) {
        trace("image format query: format %d type %d tiling %d usage 0x%x flags 0x%x is %d", format, type, tiling, usage, flags, result);
    }
    return result;
}

static VkResult image_format_properties2(PFN_vkGetPhysicalDeviceImageFormatProperties2 next, VkPhysicalDevice physical,
                                         const VkPhysicalDeviceImageFormatInfo2* info, void* properties) {
    VkResult result = next(physical, info, properties);
    if (result != VK_SUCCESS) {
        trace("image format query: format %d type %d tiling %d usage 0x%x flags 0x%x is %d", info->format, info->type, info->tiling,
              info->usage, info->flags, result);
    }
    return result;
}

static VkResult GetPhysicalDeviceImageFormatProperties2(VkPhysicalDevice physical, const VkPhysicalDeviceImageFormatInfo2* info,
                                                        void* properties) {
    return image_format_properties2(find_instance(key_of(physical))->image_format_properties2, physical, info, properties);
}

static VkResult GetPhysicalDeviceImageFormatProperties2KHR(VkPhysicalDevice physical, const VkPhysicalDeviceImageFormatInfo2* info,
                                                           void* properties) {
    return image_format_properties2(find_instance(key_of(physical))->image_format_properties2_khr, physical, info, properties);
}

// The trace's function for `name` when tracing and the driver has it, or NULL.
static PFN_vkVoidFunction traced_device_function(const Device* device, const char* name) {
    if (!device || !tracing()) return NULL;
    if (strcmp(name, "vkCreateImage") == 0 && device->create_image) return (PFN_vkVoidFunction)CreateImage;
    if (strcmp(name, "vkCreateImageView") == 0 && device->create_image_view) return (PFN_vkVoidFunction)CreateImageView;
    if (strcmp(name, "vkCreateSampler") == 0 && device->create_sampler) return (PFN_vkVoidFunction)CreateSampler;
    if (strcmp(name, "vkCreateDescriptorSetLayout") == 0 && device->create_set_layout) return (PFN_vkVoidFunction)CreateDescriptorSetLayout;
    if (strcmp(name, "vkCreatePipelineLayout") == 0 && device->create_pipeline_layout) return (PFN_vkVoidFunction)CreatePipelineLayout;
    if (strcmp(name, "vkCreateGraphicsPipelines") == 0 && device->create_graphics_pipelines) return (PFN_vkVoidFunction)CreateGraphicsPipelines;
    if (strcmp(name, "vkCreateComputePipelines") == 0 && device->create_compute_pipelines) return (PFN_vkVoidFunction)CreateComputePipelines;
    return NULL;
}

// MARK: Chain

static VkResult CreateInstance(const VkBaseStructure* info, const void* allocator, VkInstance* out) {
    VkLayerInstanceCreateInfo* link = (VkLayerInstanceCreateInfo*)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO)) {
        link = (VkLayerInstanceCreateInfo*)link->pNext;
    }
    if (!link || !link->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(info, allocator, out);
    if (result != VK_SUCCESS) return result;

    Instance* instance = calloc(1, sizeof *instance);
    PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)gipa(*out, "vkDestroyInstance");
    if (!instance) {
        if (destroy) destroy(*out, allocator);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    instance->handle = *out;
    instance->key = key_of(*out);
    instance->gipa = gipa;
    instance->destroy = destroy;
    instance->format_properties = (PFN_vkGetPhysicalDeviceFormatProperties)gipa(*out, "vkGetPhysicalDeviceFormatProperties");
    instance->format_properties2 = (PFN_vkGetPhysicalDeviceFormatProperties2)gipa(*out, "vkGetPhysicalDeviceFormatProperties2");
    instance->format_properties2_khr = (PFN_vkGetPhysicalDeviceFormatProperties2)gipa(*out, "vkGetPhysicalDeviceFormatProperties2KHR");
    instance->image_format_properties = (PFN_vkGetPhysicalDeviceImageFormatProperties)gipa(*out, "vkGetPhysicalDeviceImageFormatProperties");
    instance->image_format_properties2 = (PFN_vkGetPhysicalDeviceImageFormatProperties2)gipa(*out, "vkGetPhysicalDeviceImageFormatProperties2");
    instance->image_format_properties2_khr = (PFN_vkGetPhysicalDeviceImageFormatProperties2)gipa(*out, "vkGetPhysicalDeviceImageFormatProperties2KHR");
    pthread_mutex_lock(&lists_lock);
    instance->next = instances;
    instances = instance;
    pthread_mutex_unlock(&lists_lock);
    return result;
}

static void DestroyInstance(VkInstance handle, const void* allocator) {
    if (!handle) return;
    void* key = key_of(handle);
    pthread_mutex_lock(&lists_lock);
    Instance** link = &instances;
    while (*link && (*link)->key != key) link = &(*link)->next;
    Instance* instance = *link;
    if (instance) *link = instance->next;
    pthread_mutex_unlock(&lists_lock);
    if (!instance) return;
    if (instance->destroy) instance->destroy(handle, allocator);
    free(instance);
}

static VkResult CreateDevice(VkPhysicalDevice physical, const VkBaseStructure* info, const void* allocator, VkDevice* out) {
    VkLayerDeviceCreateInfo* link = (VkLayerDeviceCreateInfo*)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO)) {
        link = (VkLayerDeviceCreateInfo*)link->pNext;
    }
    if (!link || !link->u.pLayerInfo) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    PFN_vkGetDeviceProcAddr gdpa = link->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    Instance* instance = find_instance(key_of(physical));
    PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(instance ? instance->handle : NULL, "vkCreateDevice");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(physical, info, allocator, out);
    if (result != VK_SUCCESS) return result;

    Device* device = calloc(1, sizeof *device);
    PFN_vkDestroyDevice destroy = (PFN_vkDestroyDevice)gdpa(*out, "vkDestroyDevice");
    if (!device) {
        if (destroy) destroy(*out, allocator);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    device->key = key_of(*out);
    device->gdpa = gdpa;
    device->destroy = destroy;
    device->create_image = (PFN_vkCreateImage)gdpa(*out, "vkCreateImage");
    device->create_image_view = (PFN_vkCreateImageView)gdpa(*out, "vkCreateImageView");
    device->create_sampler = (PFN_vkCreateSampler)gdpa(*out, "vkCreateSampler");
    device->create_set_layout = (PFN_vkCreateDescriptorSetLayout)gdpa(*out, "vkCreateDescriptorSetLayout");
    device->create_pipeline_layout = (PFN_vkCreatePipelineLayout)gdpa(*out, "vkCreatePipelineLayout");
    device->create_graphics_pipelines = (PFN_vkCreatePipelines)gdpa(*out, "vkCreateGraphicsPipelines");
    device->create_compute_pipelines = (PFN_vkCreatePipelines)gdpa(*out, "vkCreateComputePipelines");
    pthread_mutex_lock(&lists_lock);
    device->next = devices;
    devices = device;
    pthread_mutex_unlock(&lists_lock);
    return result;
}

static void DestroyDevice(VkDevice handle, const void* allocator) {
    if (!handle) return;
    void* key = key_of(handle);
    pthread_mutex_lock(&lists_lock);
    Device** link = &devices;
    while (*link && (*link)->key != key) link = &(*link)->next;
    Device* device = *link;
    if (device) *link = device->next;
    pthread_mutex_unlock(&lists_lock);
    if (!device) return;
    if (device->destroy) device->destroy(handle, allocator);
    free(device);
}

// MARK: Entry points

EXPORT PFN_vkVoidFunction vkGetDeviceProcAddr(VkDevice handle, const char* name) {
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)DestroyDevice;
    Device* device = handle ? find_device(key_of(handle)) : NULL;
    PFN_vkVoidFunction traced = traced_device_function(device, name);
    if (traced) return traced;
    return device ? device->gdpa(handle, name) : NULL;
}

EXPORT PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance handle, const char* name) {
    if (strcmp(name, "vkGetInstanceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
    if (strcmp(name, "vkCreateInstance") == 0) return (PFN_vkVoidFunction)CreateInstance;
    if (strcmp(name, "vkDestroyInstance") == 0) return (PFN_vkVoidFunction)DestroyInstance;
    if (strcmp(name, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)CreateDevice;
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)DestroyDevice;
    Instance* instance = handle ? find_instance(key_of(handle)) : NULL;
    if (!instance) return NULL;
    // Ours only where the driver has the function too.
    if (strcmp(name, "vkGetPhysicalDeviceFormatProperties") == 0) {
        return instance->format_properties ? (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceFormatProperties2") == 0) {
        return instance->format_properties2 ? (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties2 : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceFormatProperties2KHR") == 0) {
        return instance->format_properties2_khr ? (PFN_vkVoidFunction)GetPhysicalDeviceFormatProperties2KHR : NULL;
    }
    if (tracing() && strcmp(name, "vkGetPhysicalDeviceImageFormatProperties") == 0 && instance->image_format_properties) {
        return (PFN_vkVoidFunction)GetPhysicalDeviceImageFormatProperties;
    }
    if (tracing() && strcmp(name, "vkGetPhysicalDeviceImageFormatProperties2") == 0 && instance->image_format_properties2) {
        return (PFN_vkVoidFunction)GetPhysicalDeviceImageFormatProperties2;
    }
    if (tracing() && strcmp(name, "vkGetPhysicalDeviceImageFormatProperties2KHR") == 0 && instance->image_format_properties2_khr) {
        return (PFN_vkVoidFunction)GetPhysicalDeviceImageFormatProperties2KHR;
    }
    return instance->gipa(handle, name);
}

EXPORT VkResult vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface* interface) {
    if (!interface || interface->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT) return VK_ERROR_INITIALIZATION_FAILED;
    if (interface->loaderLayerInterfaceVersion > 2) interface->loaderLayerInterfaceVersion = 2;
    interface->pfnGetInstanceProcAddr = vkGetInstanceProcAddr;
    interface->pfnGetDeviceProcAddr = vkGetDeviceProcAddr;
    interface->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}

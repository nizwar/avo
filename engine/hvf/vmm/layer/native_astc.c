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
// gfxstream passes ASTC straight to MoltenVK. Avo's own gfxstream build
// (scripts/gfxstream-patches) or Avo's guest layer (guest/gfxsync) takes the
// two bits away again, so apps never try a linear ASTC image.
// AVO_NATIVE_ASTC=0 leaves them out, to compare.
//
// It also hides MoltenVK's lazily allocated memory type (Metal's memoryless
// storage, the last type) from gfxstream and so from the guest. MoltenVK
// gives it only to transient attachments that are not input attachments, and
// ANGLE's implicit multisampled images (GL's multisampled render to texture)
// are both whenever a lazily allocated type exists: each such color image
// found no memory (VK_ERROR_FEATURE_NOT_PRESENT from ANGLE's allocator) and
// the game drew garbage there (PUBG's WebView pages, its end screen). Without
// the type ANGLE gives them ordinary device memory.
//
// Two jobs of Avo's guest layer happen here too, so that a guest without that
// layer gets them (apps that kill themselves when a library from /data/local
// loads into them need that):
// - vkCreateShaderModule, and vkCreateGraphicsPipelines for a fragment stage
//   with inline SPIR-V, give each element of a fragment output array its own
//   output (guest/gfxsync/src/frag_outputs.c, compiled in): MoltenVK cannot
//   make a pipeline from ANGLE's gl_FragData[8] when the subpass has fewer
//   colour attachments.
// - VK_EXT_provoking_vertex (provokingVertexLast), which MoltenVK lacks and
//   the image's ANGLE needs for anything above OpenGL ES 2.0: the layer
//   reports the extension and the feature, and takes the extension, its
//   feature structure and the pipelines' provoking-vertex state out again
//   before MoltenVK sees them, so flat varyings keep coming from the first
//   vertex. Every instance is offered it, not only ANGLE's: the guest driver
//   keeps the first extension list it gets in a process, so where an app's
//   own instance (or HWUI's) asked first, ANGLE got that list and the app's
//   GL stayed at ES 2.0. An app's own Vulkan that turns provokingVertexLast
//   on gets flat varyings from the first vertex too, as ANGLE does; few do
//   (console emulators, mostly), and the picture differs only in the colour
//   of flat-shaded faces. The loader accepts the extension because the
//   layer's manifest names it (astc.rs).
// Both stand aside where the driver has what they add. Everything else
// passes straight through.
//
// With AVO_VK_TRACE=1 or ~/Library/Logs/Avo/vk-trace.on at the start, it also
// writes to the engine's log, each kind once with the time, what the guest's
// renderers ask MoltenVK for: images (format, size class, mips, layers, usage,
// flags), views that read an image in another format, samplers, descriptor and
// pipeline layouts that pass Metal's 16 samplers a stage, the device's memory
// types and the memory allocated (type, size class, dedicated), and every
// pipeline, image, image-format query, allocation or image binding that
// fails. It is for finding what a game does that the Mac's GPU path gets
// wrong, from the Mac's side only.
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

#include "../../../../guest/gfxsync/src/frag_outputs.h"

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
typedef struct VkDeviceMemory_T* VkDeviceMemory;
typedef uint64_t VkDeviceSize;
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

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkDeviceSize allocationSize;
    uint32_t memoryTypeIndex;
} VkMemoryAllocateInfo;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkImage image;
    VkDeviceMemory memory;
    VkDeviceSize memoryOffset;
} VkBindImageMemoryInfo;

typedef struct { VkFlags propertyFlags; uint32_t heapIndex; } VkMemoryType;
typedef struct { VkDeviceSize size; VkFlags flags; } VkMemoryHeap;
typedef struct {
    uint32_t memoryTypeCount;
    VkMemoryType memoryTypes[32];
    uint32_t memoryHeapCount;
    VkMemoryHeap memoryHeaps[16];
} VkPhysicalDeviceMemoryProperties;

typedef struct {
    VkStructureType sType;
    void* pNext;
    VkPhysicalDeviceMemoryProperties memoryProperties;
} VkPhysicalDeviceMemoryProperties2;

typedef struct {
    VkDeviceSize size;
    VkDeviceSize alignment;
    uint32_t memoryTypeBits;
} VkMemoryRequirements;

typedef struct {
    VkStructureType sType;
    void* pNext;
    VkMemoryRequirements memoryRequirements;
} VkMemoryRequirements2;

// VkMemoryMetalHandlePropertiesEXT.
typedef struct {
    VkStructureType sType;
    void* pNext;
    uint32_t memoryTypeBits;
} VkMemoryMetalHandleProperties;

typedef VkResult (*PFN_vkAllocateMemory)(VkDevice, const VkMemoryAllocateInfo*, const void*, VkDeviceMemory*);
typedef VkResult (*PFN_vkBindImageMemory)(VkDevice, VkImage, VkDeviceMemory, VkDeviceSize);
typedef VkResult (*PFN_vkBindImageMemory2)(VkDevice, uint32_t, const VkBindImageMemoryInfo*);
typedef void (*PFN_vkGetPhysicalDeviceMemoryProperties)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties*);
typedef void (*PFN_vkGetPhysicalDeviceMemoryProperties2)(VkPhysicalDevice, VkPhysicalDeviceMemoryProperties2*);
typedef void (*PFN_vkGetImageMemoryRequirements)(VkDevice, VkImage, VkMemoryRequirements*);
// vkGetImageMemoryRequirements2 and vkGetDeviceImageMemoryRequirements: an
// info structure in, VkMemoryRequirements2 out.
typedef void (*PFN_vkGetMemoryRequirements2)(VkDevice, const void*, VkMemoryRequirements2*);
typedef VkResult (*PFN_vkGetMemoryMetalHandleProperties)(VkDevice, int32_t, const void*, VkMemoryMetalHandleProperties*);

// For the fragment output arrays and VK_EXT_provoking_vertex.
typedef struct VkShaderModule_T* VkShaderModule;

enum {
    VK_INCOMPLETE = 5,
    VK_ERROR_LAYER_NOT_PRESENT = -6,
    VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO = 16,
    VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT = 1000128000,
    VK_STRUCTURE_TYPE_PIPELINE_ROBUSTNESS_CREATE_INFO_EXT = 1000068000,
    VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_REQUIRED_SUBGROUP_SIZE_CREATE_INFO = 1000225001,
    VK_STRUCTURE_TYPE_SHADER_MODULE_VALIDATION_CACHE_CREATE_INFO_EXT = 1000160001,
    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT = 1000254000,
    VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT = 1000254001,
    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_PROPERTIES_EXT = 1000254002,
    VK_SHADER_STAGE_FRAGMENT_BIT = 0x10,
    VK_EXT_PROVOKING_VERTEX_SPEC_VERSION = 1,
};
#define VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME "VK_EXT_provoking_vertex"

typedef struct VkBaseOutStructure {
    VkStructureType sType;
    struct VkBaseOutStructure* pNext;
} VkBaseOutStructure;

typedef struct {
    char extensionName[256];
    uint32_t specVersion;
} VkExtensionProperties;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    size_t codeSize;
    const uint32_t* pCode;
} VkShaderModuleCreateInfo;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    VkFlags stage;
    VkShaderModule module;
    const char* pName;
    const void* pSpecializationInfo;
} VkPipelineShaderStageCreateInfo;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    uint32_t stageCount;
    const VkPipelineShaderStageCreateInfo* pStages;
    const void* pVertexInputState;
    const void* pInputAssemblyState;
    const void* pTessellationState;
    const void* pViewportState;
    const VkBaseStructure* pRasterizationState;
    const void* pMultisampleState;
    const void* pDepthStencilState;
    const void* pColorBlendState;
    const void* pDynamicState;
    VkPipelineLayout layout;
    void* renderPass;
    uint32_t subpass;
    VkPipeline basePipelineHandle;
    int32_t basePipelineIndex;
} VkGraphicsPipelineCreateInfo;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    VkFlags flags;
    uint32_t queueCreateInfoCount;
    const void* pQueueCreateInfos;
    uint32_t enabledLayerCount;
    const char* const* ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char* const* ppEnabledExtensionNames;
    const void* pEnabledFeatures;
} VkDeviceCreateInfo;

// VkPhysicalDeviceProvokingVertexFeaturesEXT and ...PropertiesEXT: two
// VkBool32 after the header each.
typedef struct {
    VkStructureType sType;
    void* pNext;
    VkBool32 first;
    VkBool32 second;
} VkTwoBools;

typedef VkResult (*PFN_vkCreateShaderModule)(VkDevice, const VkShaderModuleCreateInfo*, const void*, VkShaderModule*);
typedef VkResult (*PFN_vkEnumerateDeviceExtensionProperties)(VkPhysicalDevice, const char*, uint32_t*, VkExtensionProperties*);
// vkGetPhysicalDeviceFeatures2 and vkGetPhysicalDeviceProperties2: a chain to fill.
typedef void (*PFN_vkGetPhysicalDeviceChain2)(VkPhysicalDevice, void*);

#define EXPORT __attribute__((visibility("default")))
#define LAYER_NAME "VK_LAYER_AVO_native_astc"

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
    PFN_vkGetPhysicalDeviceMemoryProperties memory_properties;
    PFN_vkGetPhysicalDeviceMemoryProperties2 memory_properties2;
    PFN_vkGetPhysicalDeviceMemoryProperties2 memory_properties2_khr;
    PFN_vkEnumerateDeviceExtensionProperties enumerate_extensions;
    PFN_vkGetPhysicalDeviceChain2 features2;
    PFN_vkGetPhysicalDeviceChain2 features2_khr;
    PFN_vkGetPhysicalDeviceChain2 properties2;
    PFN_vkGetPhysicalDeviceChain2 properties2_khr;
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
    PFN_vkAllocateMemory allocate_memory;
    PFN_vkBindImageMemory bind_image_memory;
    PFN_vkBindImageMemory2 bind_image_memory2;
    PFN_vkBindImageMemory2 bind_image_memory2_khr;
    // The memory types hidden from gfxstream, as memoryTypeBits, and the
    // driver's functions that name memory types.
    uint32_t hidden_types;
    PFN_vkGetImageMemoryRequirements image_requirements;
    PFN_vkGetMemoryRequirements2 image_requirements2;
    PFN_vkGetMemoryRequirements2 image_requirements2_khr;
    PFN_vkGetMemoryRequirements2 device_image_requirements;
    PFN_vkGetMemoryRequirements2 device_image_requirements_khr;
    PFN_vkGetMemoryMetalHandleProperties metal_handle_properties;
    // The driver's, for the fragment output arrays.
    PFN_vkCreateShaderModule create_shader_module;
    // The layer's VK_EXT_provoking_vertex is on: pipelines lose their
    // provoking-vertex state.
    int provoking_vertex;
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
static atomic_int astc_state; // 0 not decided, 1 off, 2 on

// AVO_NATIVE_ASTC=0 leaves gfxstream's ASTC emulation on.
static int native_astc(void) {
    int state = atomic_load(&astc_state);
    if (state == 0) {
        const char* value = getenv("AVO_NATIVE_ASTC");
        state = value && strcmp(value, "0") == 0 ? 1 : 2;
        atomic_store(&astc_state, state);
    }
    return state == 2;
}

static void add_linear(VkFormat format, VkFormatProperties* properties) {
    const VkFlags sampled = VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
    if (format < VK_FORMAT_ASTC_4x4_UNORM_BLOCK || format > VK_FORMAT_ASTC_12x12_SRGB_BLOCK || !native_astc()) return;
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

// MARK: Memory types

enum { VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT = 0x10 };

static uint32_t lazy_types(const VkPhysicalDeviceMemoryProperties* properties) {
    uint32_t bits = 0;
    for (uint32_t i = 0; i < properties->memoryTypeCount && i < 32; i++) {
        if (properties->memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT) bits |= 1u << i;
    }
    return bits;
}

// The lazily allocated types at the end go (MoltenVK's one is last). One
// before another type would keep its index, without the flag, and no
// resource names it (`hidden_types`).
static void hide_lazy_types(VkPhysicalDeviceMemoryProperties* properties) {
    if (properties->memoryTypeCount > 32) return;
    while (properties->memoryTypeCount > 0 &&
           (properties->memoryTypes[properties->memoryTypeCount - 1].propertyFlags & VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT)) {
        properties->memoryTypeCount--;
        memset(&properties->memoryTypes[properties->memoryTypeCount], 0, sizeof properties->memoryTypes[0]);
    }
    for (uint32_t i = 0; i < properties->memoryTypeCount; i++) {
        properties->memoryTypes[i].propertyFlags &= ~(VkFlags)VK_MEMORY_PROPERTY_LAZILY_ALLOCATED_BIT;
    }
}

static void GetPhysicalDeviceMemoryProperties(VkPhysicalDevice physical, VkPhysicalDeviceMemoryProperties* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->memory_properties) return;
    instance->memory_properties(physical, properties);
    hide_lazy_types(properties);
}

static void GetPhysicalDeviceMemoryProperties2(VkPhysicalDevice physical, VkPhysicalDeviceMemoryProperties2* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->memory_properties2) return;
    instance->memory_properties2(physical, properties);
    hide_lazy_types(&properties->memoryProperties);
}

static void GetPhysicalDeviceMemoryProperties2KHR(VkPhysicalDevice physical, VkPhysicalDeviceMemoryProperties2* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->memory_properties2_khr) return;
    instance->memory_properties2_khr(physical, properties);
    hide_lazy_types(&properties->memoryProperties);
}

static Device* device_of(VkDevice handle) { return find_device(key_of(handle)); }

static void GetImageMemoryRequirements(VkDevice handle, VkImage image, VkMemoryRequirements* requirements) {
    Device* device = device_of(handle);
    device->image_requirements(handle, image, requirements);
    requirements->memoryTypeBits &= ~device->hidden_types;
}

static void requirements2(VkDevice handle, PFN_vkGetMemoryRequirements2 next, const void* info, VkMemoryRequirements2* requirements) {
    next(handle, info, requirements);
    requirements->memoryRequirements.memoryTypeBits &= ~device_of(handle)->hidden_types;
}

static void GetImageMemoryRequirements2(VkDevice handle, const void* info, VkMemoryRequirements2* requirements) {
    requirements2(handle, device_of(handle)->image_requirements2, info, requirements);
}

static void GetImageMemoryRequirements2KHR(VkDevice handle, const void* info, VkMemoryRequirements2* requirements) {
    requirements2(handle, device_of(handle)->image_requirements2_khr, info, requirements);
}

static void GetDeviceImageMemoryRequirements(VkDevice handle, const void* info, VkMemoryRequirements2* requirements) {
    requirements2(handle, device_of(handle)->device_image_requirements, info, requirements);
}

static void GetDeviceImageMemoryRequirementsKHR(VkDevice handle, const void* info, VkMemoryRequirements2* requirements) {
    requirements2(handle, device_of(handle)->device_image_requirements_khr, info, requirements);
}

// gfxstream imports a ColorBuffer's or Buffer's MTLHeap; a private one also
// names the memoryless type.
static VkResult GetMemoryMetalHandlePropertiesEXT(VkDevice handle, int32_t type, const void* metal,
                                                  VkMemoryMetalHandleProperties* properties) {
    Device* device = device_of(handle);
    VkResult result = device->metal_handle_properties(handle, type, metal, properties);
    if (result == VK_SUCCESS) properties->memoryTypeBits &= ~device->hidden_types;
    return result;
}

// The function for `name` that hides memory types when the device has some
// to hide and the driver has the function, or NULL.
static PFN_vkVoidFunction memory_device_function(const Device* device, const char* name) {
    if (!device || !device->hidden_types) return NULL;
    if (strcmp(name, "vkGetImageMemoryRequirements") == 0 && device->image_requirements) {
        return (PFN_vkVoidFunction)GetImageMemoryRequirements;
    }
    if (strcmp(name, "vkGetImageMemoryRequirements2") == 0 && device->image_requirements2) {
        return (PFN_vkVoidFunction)GetImageMemoryRequirements2;
    }
    if (strcmp(name, "vkGetImageMemoryRequirements2KHR") == 0 && device->image_requirements2_khr) {
        return (PFN_vkVoidFunction)GetImageMemoryRequirements2KHR;
    }
    if (strcmp(name, "vkGetDeviceImageMemoryRequirements") == 0 && device->device_image_requirements) {
        return (PFN_vkVoidFunction)GetDeviceImageMemoryRequirements;
    }
    if (strcmp(name, "vkGetDeviceImageMemoryRequirementsKHR") == 0 && device->device_image_requirements_khr) {
        return (PFN_vkVoidFunction)GetDeviceImageMemoryRequirementsKHR;
    }
    if (strcmp(name, "vkGetMemoryMetalHandlePropertiesEXT") == 0 && device->metal_handle_properties) {
        return (PFN_vkVoidFunction)GetMemoryMetalHandlePropertiesEXT;
    }
    return NULL;
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
        fprintf(stderr, "[vk-trace] on: images, views, samplers, layouts past 16 samplers a stage, memory, and failures, each kind once\n");
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

// Memory: each type and size class once (a dedicated allocation is one
// image's), and every allocation or image binding that fails, with its size.
static uint64_t mib_class(VkDeviceSize size) {
    uint64_t mib = (size + (1u << 20) - 1) >> 20, class = 1;
    while (class < mib) class <<= 1;
    return class;
}

// VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO in `next`'s chain.
static int dedicated(const void* next) {
    for (const VkBaseStructure* s = next; s; s = s->pNext) {
        if (s->sType == 1000127001) return 1;
    }
    return 0;
}

static VkResult AllocateMemory(VkDevice handle, const VkMemoryAllocateInfo* info, const void* allocator, VkDeviceMemory* out) {
    Device* device = device_of(handle);
    VkResult result = device->allocate_memory(handle, info, allocator, out);
    if (result != VK_SUCCESS) {
        trace("memory type %u, %llu bytes%s FAILED with %d", info->memoryTypeIndex, (unsigned long long)info->allocationSize,
              dedicated(info->pNext) ? " dedicated" : "", result);
    } else {
        trace("memory type %u, %llu MiB class%s", info->memoryTypeIndex, (unsigned long long)mib_class(info->allocationSize),
              dedicated(info->pNext) ? " dedicated" : "");
    }
    return result;
}

static VkResult BindImageMemory(VkDevice handle, VkImage image, VkDeviceMemory memory, VkDeviceSize offset) {
    VkResult result = device_of(handle)->bind_image_memory(handle, image, memory, offset);
    if (result != VK_SUCCESS) trace("binding a format %d image FAILED with %d", format_of(image), result);
    return result;
}

static VkResult bind_image_memory2(PFN_vkBindImageMemory2 next, VkDevice handle, uint32_t count, const VkBindImageMemoryInfo* infos) {
    VkResult result = next(handle, count, infos);
    if (result != VK_SUCCESS) {
        for (uint32_t i = 0; i < count; i++) trace("binding a format %d image (of %u) FAILED with %d", format_of(infos[i].image), count, result);
    }
    return result;
}

static VkResult BindImageMemory2(VkDevice handle, uint32_t count, const VkBindImageMemoryInfo* infos) {
    return bind_image_memory2(device_of(handle)->bind_image_memory2, handle, count, infos);
}

static VkResult BindImageMemory2KHR(VkDevice handle, uint32_t count, const VkBindImageMemoryInfo* infos) {
    return bind_image_memory2(device_of(handle)->bind_image_memory2_khr, handle, count, infos);
}

// The trace's function for `name` when tracing and the driver has it, or NULL.
static PFN_vkVoidFunction traced_device_function(const Device* device, const char* name) {
    if (!device || !tracing()) return NULL;
    if (strcmp(name, "vkCreateImage") == 0 && device->create_image) return (PFN_vkVoidFunction)CreateImage;
    if (strcmp(name, "vkCreateImageView") == 0 && device->create_image_view) return (PFN_vkVoidFunction)CreateImageView;
    if (strcmp(name, "vkCreateSampler") == 0 && device->create_sampler) return (PFN_vkVoidFunction)CreateSampler;
    if (strcmp(name, "vkCreateDescriptorSetLayout") == 0 && device->create_set_layout) return (PFN_vkVoidFunction)CreateDescriptorSetLayout;
    if (strcmp(name, "vkCreatePipelineLayout") == 0 && device->create_pipeline_layout) return (PFN_vkVoidFunction)CreatePipelineLayout;
    if (strcmp(name, "vkCreateComputePipelines") == 0 && device->create_compute_pipelines) return (PFN_vkVoidFunction)CreateComputePipelines;
    if (strcmp(name, "vkAllocateMemory") == 0 && device->allocate_memory) return (PFN_vkVoidFunction)AllocateMemory;
    if (strcmp(name, "vkBindImageMemory") == 0 && device->bind_image_memory) return (PFN_vkVoidFunction)BindImageMemory;
    if (strcmp(name, "vkBindImageMemory2") == 0 && device->bind_image_memory2) return (PFN_vkVoidFunction)BindImageMemory2;
    if (strcmp(name, "vkBindImageMemory2KHR") == 0 && device->bind_image_memory2_khr) return (PFN_vkVoidFunction)BindImageMemory2KHR;
    return NULL;
}

// MARK: Fragment output arrays

static atomic_flag split_logged = ATOMIC_FLAG_INIT;

static VkResult CreateShaderModule(VkDevice handle, const VkShaderModuleCreateInfo* info, const void* allocator, VkShaderModule* out) {
    Device* device = device_of(handle);
    size_t words = 0;
    uint32_t* split = avo_split_output_arrays(info->pCode, info->codeSize / 4, &words);
    if (!split) return device->create_shader_module(handle, info, allocator, out);
    VkShaderModuleCreateInfo copy = *info;
    copy.codeSize = words * sizeof *split;
    copy.pCode = split;
    VkResult result = device->create_shader_module(handle, &copy, allocator, out);
    free(split);
    if (!atomic_flag_test_and_set(&split_logged)) {
        fprintf(stderr, "[gpu] split a fragment output array into separate outputs for MoltenVK (first: %zu words, %d)\n", words, result);
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
// chain, by size (vulkan_core.h), so that those ahead of it can be copied; 0
// for any other.
static size_t stage_struct_size(VkStructureType type) {
    switch (type) {
    case VK_STRUCTURE_TYPE_DEBUG_UTILS_OBJECT_NAME_INFO_EXT:
        return 40;
    case VK_STRUCTURE_TYPE_PIPELINE_ROBUSTNESS_CREATE_INFO_EXT:
        return 32;
    case VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_REQUIRED_SUBGROUP_SIZE_CREATE_INFO:
        return 24;
    case VK_STRUCTURE_TYPE_SHADER_MODULE_VALIDATION_CACHE_CREATE_INFO_EXT:
        return 24;
    default:
        return 0;
    }
}

// A fragment stage that brings its SPIR-V inline (a VkShaderModuleCreateInfo
// in its chain, no module) with an output array to split: `*out` becomes a
// copy of the stage whose chain runs through copies of the structures ahead
// of that info to a copy of it with the split code, then on into the
// caller's chain. False leaves the stage as it is.
static int split_inline_stage(const VkPipelineShaderStageCreateInfo* stage, VkPipelineShaderStageCreateInfo* out, Kept** kept) {
    if (stage->stage != VK_SHADER_STAGE_FRAGMENT_BIT || stage->module != NULL) return 0;
    size_t ahead = 0;
    const VkBaseStructure* at = stage->pNext;
    for (; at && at->sType != VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO; at = at->pNext) {
        size_t size = stage_struct_size(at->sType);
        if (!size) return 0;
        ahead += size;
    }
    if (!at) return 0;
    const VkShaderModuleCreateInfo* info = (const VkShaderModuleCreateInfo*)at;
    size_t words = 0;
    uint32_t* split = avo_split_output_arrays(info->pCode, info->codeSize / 4, &words);
    if (!split) return 0;
    // The structures, the info, then the code: every structure holds
    // pointers, so its size keeps the next one aligned.
    unsigned char* place = keep(kept, ahead + sizeof *info + words * sizeof *split);
    if (!place) {
        free(split);
        return 0;
    }
    *out = *stage;
    VkBaseOutStructure* last = (VkBaseOutStructure*)out;
    for (const VkBaseStructure* s = stage->pNext; s != at; s = s->pNext) {
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
    return 1;
}

// The pipelines as the driver gets them: copies where a fragment stage's
// inline SPIR-V was split, `infos` itself where none was. Short of memory a
// pipeline keeps its shaders as they are, as vkCreateShaderModule does.
static const VkGraphicsPipelineCreateInfo* split_inline_shaders(const VkGraphicsPipelineCreateInfo* infos, uint32_t count, Kept** kept) {
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

// MARK: Provoking vertex

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

// The driver's own device extensions, with room for one more; NULL on failure.
static VkExtensionProperties* driver_extensions(const Instance* instance, VkPhysicalDevice physical, uint32_t* count, VkResult* result) {
    *count = 0;
    *result = instance->enumerate_extensions(physical, NULL, count, NULL);
    if (*result != VK_SUCCESS) return NULL;
    VkExtensionProperties* all = calloc(*count + 1, sizeof *all);
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

static int has_extension(const VkExtensionProperties* all, uint32_t count, const char* name) {
    for (uint32_t i = 0; i < count; i++) {
        if (strcmp(all[i].extensionName, name) == 0) return 1;
    }
    return 0;
}

// Whether the layer stands in for VK_EXT_provoking_vertex on this physical
// device: the driver lacks it. (Unknown means no.)
static int stands_in_for_provoking_vertex(const Instance* instance, VkPhysicalDevice physical) {
    if (!instance || !instance->enumerate_extensions) return 0;
    uint32_t count;
    VkResult result;
    VkExtensionProperties* all = driver_extensions(instance, physical, &count, &result);
    if (!all) return 0;
    int native = has_extension(all, count, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME);
    free(all);
    return !native;
}

// The layer's own device extensions, which its manifest names too.
static VkResult own_extensions(uint32_t* count, VkExtensionProperties* properties) {
    if (!properties) {
        *count = 1;
        return VK_SUCCESS;
    }
    if (*count < 1) return VK_INCOMPLETE;
    memset(&properties[0], 0, sizeof properties[0]);
    snprintf(properties[0].extensionName, sizeof properties[0].extensionName, "%s", VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME);
    properties[0].specVersion = VK_EXT_PROVOKING_VERTEX_SPEC_VERSION;
    *count = 1;
    return VK_SUCCESS;
}

static VkResult EnumerateDeviceExtensionProperties(VkPhysicalDevice physical, const char* layer, uint32_t* count,
                                                   VkExtensionProperties* properties) {
    if (layer && strcmp(layer, LAYER_NAME) == 0) return own_extensions(count, properties);
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->enumerate_extensions) return VK_ERROR_LAYER_NOT_PRESENT;
    if (layer) return instance->enumerate_extensions(physical, layer, count, properties);
    uint32_t have;
    VkResult result;
    VkExtensionProperties* all = driver_extensions(instance, physical, &have, &result);
    if (!all) return result;
    if (!has_extension(all, have, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME)) {
        snprintf(all[have].extensionName, sizeof all[have].extensionName, "%s", VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME);
        all[have++].specVersion = VK_EXT_PROVOKING_VERTEX_SPEC_VERSION;
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

// vkGetPhysicalDeviceFeatures2 and vkGetPhysicalDeviceProperties2: the
// driver fills the chain without the provoking-vertex structure, the layer
// fills that (features: provokingVertexLast only; properties: neither).
static void physical_chain2(const Instance* instance, PFN_vkGetPhysicalDeviceChain2 next, VkPhysicalDevice physical, void* chain,
                            VkStructureType type, VkBool32 first) {
    Unlinked unlinked = unlink_struct(chain, type);
    if (unlinked.taken && !stands_in_for_provoking_vertex(instance, physical)) {
        relink(unlinked);
        unlinked.taken = NULL;
    }
    next(physical, chain);
    if (!unlinked.taken) return;
    relink(unlinked);
    VkTwoBools* values = (VkTwoBools*)unlinked.taken;
    values->first = first;
    values->second = 0;
}

static void GetPhysicalDeviceFeatures2(VkPhysicalDevice physical, void* features) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->features2) return;
    physical_chain2(instance, instance->features2, physical, features, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT, 1);
}

static void GetPhysicalDeviceFeatures2KHR(VkPhysicalDevice physical, void* features) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->features2_khr) return;
    physical_chain2(instance, instance->features2_khr, physical, features, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT,
                    1);
}

static void GetPhysicalDeviceProperties2(VkPhysicalDevice physical, void* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->properties2) return;
    physical_chain2(instance, instance->properties2, physical, properties,
                    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_PROPERTIES_EXT, 0);
}

static void GetPhysicalDeviceProperties2KHR(VkPhysicalDevice physical, void* properties) {
    Instance* instance = find_instance(key_of(physical));
    if (!instance || !instance->properties2_khr) return;
    physical_chain2(instance, instance->properties2_khr, physical, properties,
                    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_PROPERTIES_EXT, 0);
}

static atomic_flag inline_split_logged = ATOMIC_FLAG_INIT;
static atomic_flag provoking_logged = ATOMIC_FLAG_INIT;
static atomic_flag provoking_device_logged = ATOMIC_FLAG_INIT;

// Fragment stages with inline SPIR-V get their output arrays split, and with
// the layer's VK_EXT_provoking_vertex on, pipelines lose their
// provoking-vertex state.
static VkResult CreateGraphicsPipelines(VkDevice handle, VkPipelineCache cache, uint32_t count, const VkGraphicsPipelineCreateInfo* infos,
                                        const void* allocator, VkPipeline* out) {
    Device* device = device_of(handle);
    Kept* kept = NULL;
    const VkGraphicsPipelineCreateInfo* made = split_inline_shaders(infos, count, &kept);
    Unlinked on_stack[8];
    Unlinked* unlinked = on_stack;
    int any = 0;
    if (device->provoking_vertex) {
        if (count > 8 && !(unlinked = malloc(count * sizeof *unlinked))) {
            release(kept);
            return VK_ERROR_OUT_OF_HOST_MEMORY;
        }
        for (uint32_t i = 0; i < count; i++) {
            unlinked[i] = made[i].pRasterizationState
                ? unlink_struct(made[i].pRasterizationState, VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT)
                : (Unlinked){NULL, NULL};
            any = any || unlinked[i].taken;
        }
    }
    VkResult result = device->create_graphics_pipelines(handle, cache, count, made, allocator, out);
    if (device->provoking_vertex) {
        // Backwards, in case two pipelines share a rasterization state.
        for (uint32_t i = count; i-- > 0;) relink(unlinked[i]);
        if (unlinked != on_stack) free(unlinked);
    }
    if (any && !atomic_flag_test_and_set(&provoking_logged)) {
        fprintf(stderr, "[gpu] pipelines draw flat varyings from the first vertex (VK_EXT_provoking_vertex is Avo's layer's)\n");
    }
    if (kept && !atomic_flag_test_and_set(&inline_split_logged)) {
        fprintf(stderr, "[gpu] split a fragment output array in a pipeline's inline SPIR-V for MoltenVK (first: %d)\n", result);
    }
    release(kept);
    if (result != VK_SUCCESS && tracing()) trace("graphics pipelines FAILED with %d", result);
    return result;
}

// The function for `name` that rewrites shaders and pipelines, when the
// driver has it, or NULL.
static PFN_vkVoidFunction shader_device_function(const Device* device, const char* name) {
    if (!device) return NULL;
    if (strcmp(name, "vkCreateShaderModule") == 0 && device->create_shader_module) return (PFN_vkVoidFunction)CreateShaderModule;
    if (strcmp(name, "vkCreateGraphicsPipelines") == 0 && device->create_graphics_pipelines) {
        return (PFN_vkVoidFunction)CreateGraphicsPipelines;
    }
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
    instance->memory_properties = (PFN_vkGetPhysicalDeviceMemoryProperties)gipa(*out, "vkGetPhysicalDeviceMemoryProperties");
    instance->memory_properties2 = (PFN_vkGetPhysicalDeviceMemoryProperties2)gipa(*out, "vkGetPhysicalDeviceMemoryProperties2");
    instance->memory_properties2_khr = (PFN_vkGetPhysicalDeviceMemoryProperties2)gipa(*out, "vkGetPhysicalDeviceMemoryProperties2KHR");
    instance->enumerate_extensions = (PFN_vkEnumerateDeviceExtensionProperties)gipa(*out, "vkEnumerateDeviceExtensionProperties");
    instance->features2 = (PFN_vkGetPhysicalDeviceChain2)gipa(*out, "vkGetPhysicalDeviceFeatures2");
    instance->features2_khr = (PFN_vkGetPhysicalDeviceChain2)gipa(*out, "vkGetPhysicalDeviceFeatures2KHR");
    instance->properties2 = (PFN_vkGetPhysicalDeviceChain2)gipa(*out, "vkGetPhysicalDeviceProperties2");
    instance->properties2_khr = (PFN_vkGetPhysicalDeviceChain2)gipa(*out, "vkGetPhysicalDeviceProperties2KHR");
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

    // The layer's VK_EXT_provoking_vertex goes no further: not the extension,
    // nor its feature structure.
    const VkDeviceCreateInfo* asked = (const VkDeviceCreateInfo*)info;
    VkDeviceCreateInfo copy = *asked;
    const char** names = NULL;
    Unlinked feature = {NULL, NULL};
    int provoking_vertex = 0;
    for (uint32_t i = 0; i < asked->enabledExtensionCount; i++) {
        if (strcmp(asked->ppEnabledExtensionNames[i], VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME) == 0) provoking_vertex = 1;
    }
    provoking_vertex = provoking_vertex && stands_in_for_provoking_vertex(instance, physical);
    if (provoking_vertex) {
        if (!(names = malloc(asked->enabledExtensionCount * sizeof *names))) return VK_ERROR_OUT_OF_HOST_MEMORY;
        copy.enabledExtensionCount = 0;
        for (uint32_t i = 0; i < asked->enabledExtensionCount; i++) {
            if (strcmp(asked->ppEnabledExtensionNames[i], VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME) != 0) {
                names[copy.enabledExtensionCount++] = asked->ppEnabledExtensionNames[i];
            }
        }
        copy.ppEnabledExtensionNames = names;
        feature = unlink_struct(&copy, VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT);
    }
    VkResult result = create(physical, &copy, allocator, out);
    relink(feature);
    free(names);
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
    device->allocate_memory = (PFN_vkAllocateMemory)gdpa(*out, "vkAllocateMemory");
    device->bind_image_memory = (PFN_vkBindImageMemory)gdpa(*out, "vkBindImageMemory");
    device->bind_image_memory2 = (PFN_vkBindImageMemory2)gdpa(*out, "vkBindImageMemory2");
    device->bind_image_memory2_khr = (PFN_vkBindImageMemory2)gdpa(*out, "vkBindImageMemory2KHR");
    device->image_requirements = (PFN_vkGetImageMemoryRequirements)gdpa(*out, "vkGetImageMemoryRequirements");
    device->image_requirements2 = (PFN_vkGetMemoryRequirements2)gdpa(*out, "vkGetImageMemoryRequirements2");
    device->image_requirements2_khr = (PFN_vkGetMemoryRequirements2)gdpa(*out, "vkGetImageMemoryRequirements2KHR");
    device->device_image_requirements = (PFN_vkGetMemoryRequirements2)gdpa(*out, "vkGetDeviceImageMemoryRequirements");
    device->device_image_requirements_khr = (PFN_vkGetMemoryRequirements2)gdpa(*out, "vkGetDeviceImageMemoryRequirementsKHR");
    device->metal_handle_properties = (PFN_vkGetMemoryMetalHandleProperties)gdpa(*out, "vkGetMemoryMetalHandlePropertiesEXT");
    device->create_shader_module = (PFN_vkCreateShaderModule)gdpa(*out, "vkCreateShaderModule");
    device->provoking_vertex = provoking_vertex;
    if (provoking_vertex && !atomic_flag_test_and_set(&provoking_device_logged)) {
        fprintf(stderr, "[gpu] a device took Avo's VK_EXT_provoking_vertex (first in this engine; flat varyings come from the first vertex)\n");
    }
    // The driver's memory types (0x10 lazily allocated, Metal's memoryless):
    // which to hide, and for the trace, each one's property flags and heap.
    if (instance && instance->memory_properties) {
        VkPhysicalDeviceMemoryProperties properties;
        memset(&properties, 0, sizeof properties);
        instance->memory_properties(physical, &properties);
        device->hidden_types = lazy_types(&properties);
        if (tracing()) {
            char line[400] = "memory types:";
            for (uint32_t i = 0; i < properties.memoryTypeCount && i < 32; i++) {
                size_t used = strlen(line);
                snprintf(line + used, sizeof line - used, " %u=0x%x/heap %u%s", i, properties.memoryTypes[i].propertyFlags,
                         properties.memoryTypes[i].heapIndex, device->hidden_types & (1u << i) ? " (hidden)" : "");
            }
            trace("%s", line);
        }
    }
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
    PFN_vkVoidFunction ours = memory_device_function(device, name);
    if (!ours) ours = shader_device_function(device, name);
    if (!ours) ours = traced_device_function(device, name);
    if (ours) return ours;
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
    if (strcmp(name, "vkGetPhysicalDeviceMemoryProperties") == 0) {
        return instance->memory_properties ? (PFN_vkVoidFunction)GetPhysicalDeviceMemoryProperties : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceMemoryProperties2") == 0) {
        return instance->memory_properties2 ? (PFN_vkVoidFunction)GetPhysicalDeviceMemoryProperties2 : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceMemoryProperties2KHR") == 0) {
        return instance->memory_properties2_khr ? (PFN_vkVoidFunction)GetPhysicalDeviceMemoryProperties2KHR : NULL;
    }
    if (strcmp(name, "vkEnumerateDeviceExtensionProperties") == 0) {
        return instance->enumerate_extensions ? (PFN_vkVoidFunction)EnumerateDeviceExtensionProperties : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceFeatures2") == 0) {
        return instance->features2 ? (PFN_vkVoidFunction)GetPhysicalDeviceFeatures2 : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceFeatures2KHR") == 0) {
        return instance->features2_khr ? (PFN_vkVoidFunction)GetPhysicalDeviceFeatures2KHR : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceProperties2") == 0) {
        return instance->properties2 ? (PFN_vkVoidFunction)GetPhysicalDeviceProperties2 : NULL;
    }
    if (strcmp(name, "vkGetPhysicalDeviceProperties2KHR") == 0) {
        return instance->properties2_khr ? (PFN_vkVoidFunction)GetPhysicalDeviceProperties2KHR : NULL;
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

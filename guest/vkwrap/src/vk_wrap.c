// vulkan.ranchu.so (a wrapper): in GPU mode, does the gfxstream sync layer's
// work (guest/gfxsync) from inside the Vulkan HAL driver, so nothing has to go
// in /data/local/debug. Android's libvulkan loads the HAL driver named by
// ro.hardware.vulkan (ranchu) from /apex/com.google.cf.vulkan/lib64/hw; Avo
// bind-mounts a directory over that one holding this wrapper as
// vulkan.ranchu.so, the real driver beside it as REAL_NAME, and the
// unchanged software driver (GuestVulkanWrapper in AvoDaemonCore). An app
// whose packer kills it over a library in /data/local (FLUJO's ijiami) never
// sees one, because the layer's code now lives on the driver's own path.
//
// A HAL driver exposes a hwvulkan module (HAL_MODULE_INFO_SYM, "HMI") whose
// open() hands back a hwvulkan_device_t with the three entry points libvulkan
// starts from: EnumerateInstanceExtensionProperties, CreateInstance and
// GetInstanceProcAddr. This wrapper opens the real driver the same way and
// returns those three pointing at the sync layer instead.
//
// The layer (guest/gfxsync/src/vk_layer.c, linked in) is written for the
// Vulkan loader, which chains layers by a VK_*_LOADER_*_CREATE_INFO in the
// create info's pNext whose next_get_*_proc_addr is the next layer's. A HAL
// driver gets no such chain: libvulkan calls the driver's vkCreateInstance
// and vkCreateDevice straight. So the wrapper puts that link back — pointing
// at the real driver — ahead of the layer's own vkCreateInstance and
// vkCreateDevice, and hands everything else to the layer's
// vkGetInstanceProcAddr / vkGetDeviceProcAddr unchanged, except the global
// functions asked for with no instance (vkEnumerateInstanceVersion, from
// which libvulkan takes the driver's Vulkan version), which the real driver
// answers. The layer then runs over the real driver's functions, with two
// differences it handles itself: a new handle still holds the driver's
// loader magic (HWVULKAN_DISPATCH_MAGIC) until libvulkan replaces it after
// the create call, and presents come as QueueSignalReleaseImageANDROID.
#include <android/log.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/system_properties.h>
#include <vulkan/vulkan.h>

#define EXPORT __attribute__((visibility("default")))
#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "AvoVkWrap", __VA_ARGS__)

// The real driver, beside this wrapper in the bind-mounted hw directory. Its
// own dependencies stay in the parent lib directory, which the bind mount
// leaves in place, so it still links (GuestVulkanWrapper).
#define REAL_PATH "/apex/com.google.cf.vulkan/lib64/hw/vulkan.ranchu.avoreal.so"

// MARK: The loader's layer-link structures (Android's vulkan/vk_layer.h)

// The layer reads these out of the create info's pNext to find the next
// get-proc-addr. VK_STRUCTURE_TYPE_LOADER_{INSTANCE,DEVICE}_CREATE_INFO and
// the link-info function id are the loader's ABI, the same the layer expects.
enum { AVO_LAYER_LINK_INFO = 0 };

typedef struct AvoInstanceLink {
    struct AvoInstanceLink* next;
    PFN_vkGetInstanceProcAddr next_get_instance_proc_addr;
} AvoInstanceLink;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    int function;
    union {
        AvoInstanceLink* layer_info;
        void* set_loader_data;
    } u;
} AvoInstanceCreateInfo;

typedef struct AvoDeviceLink {
    struct AvoDeviceLink* next;
    PFN_vkGetInstanceProcAddr next_get_instance_proc_addr;
    PFN_vkGetDeviceProcAddr next_get_device_proc_addr;
} AvoDeviceLink;

typedef struct {
    VkStructureType sType;
    const void* pNext;
    int function;
    union {
        AvoDeviceLink* layer_info;
        void* set_loader_data;
    } u;
} AvoDeviceCreateInfo;

// MARK: Android's hwvulkan HAL interface (hardware/hwvulkan.h, not in the NDK)

#define HWVULKAN_HARDWARE_MODULE_ID "vulkan"
#define HWVULKAN_DEVICE_0 "vk0"
#define HWVULKAN_DISPATCH_MAGIC 0x01CDC0DE

struct hw_module_t;
struct hw_device_t;

typedef struct hw_module_methods_t {
    int (*open)(const struct hw_module_t* module, const char* id, struct hw_device_t** device);
} hw_module_methods_t;

// hardware/hardware.h as built for 64 bits (__LP64__): the reserved words
// are 64-bit there, which puts hwvulkan_device_t's entry points after 120
// bytes (checked below).
typedef struct hw_module_t {
    uint32_t tag;
    uint16_t module_api_version;
    uint16_t hal_api_version;
    const char* id;
    const char* name;
    const char* author;
    struct hw_module_methods_t* methods;
    void* dso;
    uint64_t reserved[32 - 7];
} hw_module_t;

typedef struct hw_device_t {
    uint32_t tag;
    uint32_t version;
    struct hw_module_t* module;
    uint64_t reserved[12];
    int (*close)(struct hw_device_t* device);
} hw_device_t;

#define HARDWARE_MODULE_TAG 0x48574D54  // 'HWMT'
#define HARDWARE_DEVICE_TAG 0x48574454  // 'HWDT'
#define HARDWARE_HAL_API_VERSION 0x0100
#define HWVULKAN_MODULE_API_VERSION_0_1 0x0001
#define HWVULKAN_DEVICE_API_VERSION_0_1 0x00010000

typedef struct hwvulkan_module_t {
    struct hw_module_t common;
} hwvulkan_module_t;

typedef struct hwvulkan_device_t {
    struct hw_device_t common;
    PFN_vkEnumerateInstanceExtensionProperties EnumerateInstanceExtensionProperties;
    PFN_vkCreateInstance CreateInstance;
    PFN_vkGetInstanceProcAddr GetInstanceProcAddr;
} hwvulkan_device_t;

_Static_assert(offsetof(hw_module_t, dso) == 40, "hw_module_t as libhardware lays it out");
_Static_assert(offsetof(hwvulkan_device_t, EnumerateInstanceExtensionProperties) == 120,
               "hwvulkan_device_t as libvulkan reads it");

// MARK: The sync layer, linked in (guest/gfxsync/src/vk_layer.c)

// Its loader entry points: a HAL GetInstanceProcAddr is exactly what
// vkGetInstanceProcAddr already is, and the create functions reach it through
// the link this wrapper puts back. vkCreateInstance and vkCreateDevice are
// static in the layer, so they are fetched through its get-proc-addrs.
extern PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance, const char*);
extern PFN_vkVoidFunction vkGetDeviceProcAddr(VkDevice, const char*);

// MARK: The real driver

static pthread_once_t real_once = PTHREAD_ONCE_INIT;
static hwvulkan_device_t* real_device;
static PFN_vkGetInstanceProcAddr real_gipa;
// The real driver's vkGetDeviceProcAddr, which it hands out only for an
// instance: taken from the first one made.
static _Atomic(PFN_vkGetDeviceProcAddr) real_gdpa;

static void open_real(void) {
    void* dso = dlopen(REAL_PATH, RTLD_NOW | RTLD_LOCAL);
    if (!dso) {
        LOG("the real driver did not open (%s): %s", REAL_PATH, dlerror());
        return;
    }
    hwvulkan_module_t* module = dlsym(dso, "HMI");
    if (!module || !module->common.methods || !module->common.methods->open) {
        LOG("the real driver has no hwvulkan module");
        return;
    }
    hw_device_t* device = NULL;
    if (module->common.methods->open(&module->common, HWVULKAN_DEVICE_0, &device) != 0 || !device) {
        LOG("the real driver's open() failed");
        return;
    }
    real_device = (hwvulkan_device_t*)device;
    real_gipa = real_device->GetInstanceProcAddr;
}

static hwvulkan_device_t* real(void) {
    pthread_once(&real_once, open_real);
    return real_device;
}

// MARK: The three entry points, pointing at the layer

// libvulkan asks only for the instance-less extensions here (layer_name NULL);
// the layer does not change them, so the real driver answers.
static VKAPI_ATTR VkResult VKAPI_CALL EnumerateInstanceExtensionProperties(const char* layer_name, uint32_t* count,
                                                                           VkExtensionProperties* properties) {
    hwvulkan_device_t* r = real();
    if (!r) return VK_ERROR_INITIALIZATION_FAILED;
    return r->EnumerateInstanceExtensionProperties(layer_name, count, properties);
}

static VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo* info,
                                                     const VkAllocationCallbacks* allocator, VkInstance* out) {
    hwvulkan_device_t* r = real();
    if (!r) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkCreateInstance layer_create =
        (PFN_vkCreateInstance)vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");
    if (!layer_create) return VK_ERROR_INITIALIZATION_FAILED;
    // The link the loader would add, pointing the layer at the real driver.
    AvoInstanceLink link = {.next = NULL, .next_get_instance_proc_addr = r->GetInstanceProcAddr};
    AvoInstanceCreateInfo chain = {
        .sType = VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO,
        .pNext = info->pNext,
        .function = AVO_LAYER_LINK_INFO,
        .u = {.layer_info = &link},
    };
    VkInstanceCreateInfo with_link = *info;
    with_link.pNext = &chain;
    VkResult result = layer_create(&with_link, allocator, out);
    if (result == VK_SUCCESS && !atomic_load(&real_gdpa)) {
        atomic_store(&real_gdpa, (PFN_vkGetDeviceProcAddr)r->GetInstanceProcAddr(*out, "vkGetDeviceProcAddr"));
    }
    return result;
}

// The loader-device link the HAL path lacks: libvulkan calls the driver's
// vkCreateDevice straight, so the wrapper puts it back before the layer's.
static VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
                                                   const VkAllocationCallbacks* allocator, VkDevice* out) {
    hwvulkan_device_t* r = real();
    if (!r) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkCreateDevice layer_create =
        (PFN_vkCreateDevice)vkGetInstanceProcAddr(VK_NULL_HANDLE, "vkCreateDevice");
    PFN_vkGetInstanceProcAddr gipa = r->GetInstanceProcAddr;
    // A device belongs to an instance made through CreateInstance above.
    PFN_vkGetDeviceProcAddr gdpa = atomic_load(&real_gdpa);
    if (!layer_create || !gipa || !gdpa) return VK_ERROR_INITIALIZATION_FAILED;
    AvoDeviceLink link = {
        .next = NULL,
        .next_get_instance_proc_addr = gipa,
        .next_get_device_proc_addr = gdpa,
    };
    AvoDeviceCreateInfo chain = {
        .sType = VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO,
        .pNext = info->pNext,
        .function = AVO_LAYER_LINK_INFO,
        .u = {.layer_info = &link},
    };
    VkDeviceCreateInfo with_link = *info;
    with_link.pNext = &chain;
    return layer_create(physical, &with_link, allocator, out);
}

// libvulkan builds its instance dispatch from this. The layer answers for the
// functions it wraps and for vkCreateDevice/vkGetDeviceProcAddr; the wrapper
// stands in only for the two create functions that need the loader link.
// With no instance, the real driver answers (global functions).
static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL GetInstanceProcAddr(VkInstance instance, const char* name) {
    if (!name) return NULL;
    if (strcmp(name, "vkGetInstanceProcAddr") == 0) return (PFN_vkVoidFunction)GetInstanceProcAddr;
    if (strcmp(name, "vkCreateInstance") == 0) return (PFN_vkVoidFunction)CreateInstance;
    if (strcmp(name, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)CreateDevice;
    if (instance == VK_NULL_HANDLE) {
        hwvulkan_device_t* r = real();
        return r ? r->GetInstanceProcAddr(VK_NULL_HANDLE, name) : NULL;
    }
    return vkGetInstanceProcAddr(instance, name);
}

// MARK: The HAL module

static int close_device(struct hw_device_t* device) {
    (void)device;
    return 0;
}

static hwvulkan_device_t wrapper_device = {
    .common = {.tag = HARDWARE_DEVICE_TAG, .version = HWVULKAN_DEVICE_API_VERSION_0_1, .module = NULL, .reserved = {0},
               .close = close_device},
    .EnumerateInstanceExtensionProperties = EnumerateInstanceExtensionProperties,
    .CreateInstance = CreateInstance,
    .GetInstanceProcAddr = GetInstanceProcAddr,
};

static int open_wrapper(const struct hw_module_t* module, const char* id, struct hw_device_t** device) {
    if (!id || strcmp(id, HWVULKAN_DEVICE_0) != 0 || !real()) return -1;  // -EINVAL / -ENODEV
    wrapper_device.common.module = (struct hw_module_t*)module;
    *device = &wrapper_device.common;
    LOG("Avo wraps the gfxstream Vulkan driver; the sync layer runs with no file in /data/local/debug");
    return 0;
}

static struct hw_module_methods_t wrapper_methods = {.open = open_wrapper};

EXPORT hwvulkan_module_t HMI = {
    .common = {
        .tag = HARDWARE_MODULE_TAG,
        .module_api_version = HWVULKAN_MODULE_API_VERSION_0_1,
        .hal_api_version = HARDWARE_HAL_API_VERSION,
        .id = HWVULKAN_HARDWARE_MODULE_ID,
        .name = "Avo gfxstream Vulkan wrapper",
        .author = "Avo",
        .methods = &wrapper_methods,
        .dso = NULL,
        .reserved = {0},
    },
};

// libVkLayer_avo_profile.so (VK_LAYER_AVO_profile): a Vulkan layer that
// reports the device profile's GPU in vkGetPhysicalDeviceProperties(2), so
// an app's own renderer reads "Adreno (TM) 750", vendor 0x5143 and the
// Qualcomm driver where the profile says so. Limits, features, formats and
// extensions stay the real GPU's: only names and IDs change, in the
// properties and in the header of the app's pipeline cache data.
//
// Android loads it into every app on Avo (debug.vulkan.layers, from
// /data/local/debug/vulkan; HostAgent installs it). Instances that ANGLE
// (GLES) or HWUI create keep the real GPU: they choose workarounds from the
// vendor ID, and the phone's are wrong for what really draws.
//
//   debug.avo.vk.name         deviceName (else debug.avo.gl.renderer)
//   debug.avo.vk.vendor       vendorID, e.g. 0x5143
//   debug.avo.vk.device       deviceID
//   debug.avo.vk.driver       driverVersion
//   debug.avo.vk.driver_id    VkDriverId, e.g. 8 (Qualcomm proprietary)
//   debug.avo.vk.driver_name  VkPhysicalDeviceDriverProperties::driverName
//   debug.avo.vk.driver_info  VkPhysicalDeviceDriverProperties::driverInfo
//
// The Vulkan HAL wrapper links this file in beside the gfxstream sync layer
// (guest/vkwrap): in that one library the loader's entry point names would
// collide with the sync layer's, so AVO_VK_WRAP renames them (avo_profile_*)
// and exposes the create functions the wrapper enters; the standalone layer
// (build.sh) keeps the loader's names.
#ifdef AVO_VK_WRAP
#define vkGetInstanceProcAddr avo_profile_vkGetInstanceProcAddr
#define vkGetDeviceProcAddr avo_profile_vkGetDeviceProcAddr
#define vkEnumerateInstanceLayerProperties avo_profile_vkEnumerateInstanceLayerProperties
#define vkEnumerateDeviceLayerProperties avo_profile_vkEnumerateDeviceLayerProperties
#define vkEnumerateInstanceExtensionProperties avo_profile_vkEnumerateInstanceExtensionProperties
#define vkEnumerateDeviceExtensionProperties avo_profile_vkEnumerateDeviceExtensionProperties
#endif

#include <pthread.h>
#include <stdio.h>
#include <vulkan/vulkan.h>

#ifdef AVO_VK_LOG
#include <android/log.h>
#define AVO_LOG(...) __android_log_print(ANDROID_LOG_INFO, "AvoVkLayer", __VA_ARGS__)
#else
#define AVO_LOG(...) ((void)0)
#endif

#include "avo_profile.h"

#define LAYER_NAME "VK_LAYER_AVO_profile"

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

static struct {
    char name[VK_MAX_PHYSICAL_DEVICE_NAME_SIZE];
    char driver_name[PROP_VALUE_MAX];
    char driver_info[PROP_VALUE_MAX];
    uint32_t vendor, device, driver, driver_id;
    bool has_vendor, has_device, has_driver, has_driver_id, any;
} profile;
static pthread_once_t profile_once = PTHREAD_ONCE_INIT;

static void read_profile(void) {
    char name[PROP_VALUE_MAX];
    avo_prop("debug.avo.vk.name", name);
    if (!name[0]) avo_prop("debug.avo.gl.renderer", name);
    snprintf(profile.name, sizeof profile.name, "%s", name);
    avo_prop("debug.avo.vk.driver_name", profile.driver_name);
    avo_prop("debug.avo.vk.driver_info", profile.driver_info);
    profile.has_vendor = avo_prop_u32("debug.avo.vk.vendor", &profile.vendor);
    profile.has_device = avo_prop_u32("debug.avo.vk.device", &profile.device);
    profile.has_driver = avo_prop_u32("debug.avo.vk.driver", &profile.driver);
    profile.has_driver_id = avo_prop_u32("debug.avo.vk.driver_id", &profile.driver_id);
    profile.any = profile.name[0] || profile.driver_name[0] || profile.driver_info[0] || profile.has_vendor
        || profile.has_device || profile.has_driver || profile.has_driver_id;
}

// What the layer knows about each instance, physical device and device.
typedef struct Instance {
    struct Instance* next;
    VkInstance handle;
    bool spoof;
    PFN_vkGetInstanceProcAddr gipa;
    PFN_vkDestroyInstance destroy;
    PFN_vkEnumeratePhysicalDevices enumerate;
    PFN_vkEnumeratePhysicalDeviceGroups enumerate_groups;
    PFN_vkEnumeratePhysicalDeviceGroupsKHR enumerate_groups_khr;
    PFN_vkGetPhysicalDeviceProperties properties;
    PFN_vkGetPhysicalDeviceProperties2 properties2;
    PFN_vkGetPhysicalDeviceProperties2KHR properties2_khr;
} Instance;
typedef struct Physical {
    struct Physical* next;
    VkPhysicalDevice handle;
    Instance* instance;
} Physical;
typedef struct Device {
    struct Device* next;
    VkDevice handle;
    PFN_vkGetDeviceProcAddr gdpa;
    PFN_vkDestroyDevice destroy;
    // A spoofed GPU with other IDs than the real one: pipeline cache headers
    // carry the IDs the app reads to the app, and the real ones to the driver.
    bool cache_ids;
    uint32_t vendor_id, device_id, real_vendor_id, real_device_id;
    PFN_vkGetPipelineCacheData get_cache_data;
    PFN_vkCreatePipelineCache create_cache;
} Device;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static Instance* instances;
static Physical* physicals;
static Device* devices;

static Instance* find_instance(VkInstance handle) {
    pthread_mutex_lock(&lock);
    Instance* found = instances;
    while (found && found->handle != handle) found = found->next;
    pthread_mutex_unlock(&lock);
    return found;
}

static Instance* instance_of(VkPhysicalDevice handle) {
    pthread_mutex_lock(&lock);
    Physical* found = physicals;
    while (found && found->handle != handle) found = found->next;
    pthread_mutex_unlock(&lock);
    return found ? found->instance : NULL;
}

static void remember(VkPhysicalDevice handle, Instance* instance) {
    pthread_mutex_lock(&lock);
    Physical* known = physicals;
    while (known && known->handle != handle) known = known->next;
    if (!known && (known = calloc(1, sizeof *known))) {
        known->handle = handle;
        known->next = physicals;
        physicals = known;
    }
    if (known) known->instance = instance;
    pthread_mutex_unlock(&lock);
}

static Device* find_device(VkDevice handle) {
    pthread_mutex_lock(&lock);
    Device* found = devices;
    while (found && found->handle != handle) found = found->next;
    pthread_mutex_unlock(&lock);
    return found;
}

// Only an app's own Vulkan instance reports the profile's GPU. ANGLE (which
// draws every app's GLES through one process-wide instance it shares with
// HWUI and the compositor) and the "android framework" instance (HWUI's) are
// left exactly as the real GPU, whichever thread creates them: changing the
// shared ANGLE instance risks its config choices and the on-screen picture,
// and it is not worth it, since Avo's GLES layer answers a GLES app's
// glGetString (gles_layer.c). So is an instance that HWUI or WebView code
// creates (avo_profile.h); an app's, even on a thread named "RenderThread"
// like Unreal Engine's, reports the profile.
static bool spoofs(const VkApplicationInfo* app) {
    pthread_once(&profile_once, read_profile);
    if (!profile.any || !avo_app_process()) return false;
    const char* engine = app && app->pEngineName ? app->pEngineName : "";
    if (strcmp(engine, "ANGLE") == 0 || strcmp(engine, "android framework") == 0) return false;
    return !avo_framework_call();
}

static void spoof_properties(VkPhysicalDeviceProperties* p) {
    if (profile.name[0]) snprintf(p->deviceName, sizeof p->deviceName, "%s", profile.name);
    if (profile.has_vendor) p->vendorID = profile.vendor;
    if (profile.has_device) p->deviceID = profile.device;
    if (profile.has_driver) p->driverVersion = profile.driver;
}

static void spoof_driver(VkDriverId* id, char* name, char* info) {
    if (profile.has_driver_id) *id = (VkDriverId)profile.driver_id;
    if (profile.driver_name[0]) snprintf(name, VK_MAX_DRIVER_NAME_SIZE, "%s", profile.driver_name);
    if (profile.driver_info[0]) snprintf(info, VK_MAX_DRIVER_INFO_SIZE, "%s", profile.driver_info);
}

static void spoof_properties2(VkPhysicalDeviceProperties2* p) {
    spoof_properties(&p->properties);
    for (VkBaseOutStructure* s = p->pNext; s; s = s->pNext) {
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES) {
            VkPhysicalDeviceDriverProperties* d = (VkPhysicalDeviceDriverProperties*)s;
            spoof_driver(&d->driverID, d->driverName, d->driverInfo);
        } else if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_PROPERTIES) {
            VkPhysicalDeviceVulkan12Properties* v = (VkPhysicalDeviceVulkan12Properties*)s;
            spoof_driver(&v->driverID, v->driverName, v->driverInfo);
        }
    }
}

// MARK: Instance

static VKAPI_ATTR VkResult VKAPI_CALL CreateInstance(const VkInstanceCreateInfo* info,
                                                     const VkAllocationCallbacks* allocator, VkInstance* out) {
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
        // The layer would hand out no functions for it: no instance.
        PFN_vkDestroyInstance destroy = (PFN_vkDestroyInstance)gipa(*out, "vkDestroyInstance");
        if (destroy) destroy(*out, allocator);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    VkInstance handle = *out;
    instance->handle = handle;
    instance->spoof = spoofs(info->pApplicationInfo);
    AVO_LOG("CreateInstance app='%s' engine='%s' spoof=%d",
            info->pApplicationInfo && info->pApplicationInfo->pApplicationName ? info->pApplicationInfo->pApplicationName : "(null)",
            info->pApplicationInfo && info->pApplicationInfo->pEngineName ? info->pApplicationInfo->pEngineName : "(null)",
            instance->spoof);
    instance->gipa = gipa;
    instance->destroy = (PFN_vkDestroyInstance)gipa(handle, "vkDestroyInstance");
    instance->enumerate = (PFN_vkEnumeratePhysicalDevices)gipa(handle, "vkEnumeratePhysicalDevices");
    instance->enumerate_groups = (PFN_vkEnumeratePhysicalDeviceGroups)gipa(handle, "vkEnumeratePhysicalDeviceGroups");
    instance->enumerate_groups_khr = (PFN_vkEnumeratePhysicalDeviceGroupsKHR)gipa(handle, "vkEnumeratePhysicalDeviceGroupsKHR");
    instance->properties = (PFN_vkGetPhysicalDeviceProperties)gipa(handle, "vkGetPhysicalDeviceProperties");
    instance->properties2 = (PFN_vkGetPhysicalDeviceProperties2)gipa(handle, "vkGetPhysicalDeviceProperties2");
    instance->properties2_khr = (PFN_vkGetPhysicalDeviceProperties2KHR)gipa(handle, "vkGetPhysicalDeviceProperties2KHR");
    pthread_mutex_lock(&lock);
    instance->next = instances;
    instances = instance;
    pthread_mutex_unlock(&lock);
    return result;
}

static VKAPI_ATTR void VKAPI_CALL DestroyInstance(VkInstance handle, const VkAllocationCallbacks* allocator) {
    pthread_mutex_lock(&lock);
    Instance* instance = NULL;
    for (Instance** at = &instances; *at; at = &(*at)->next) {
        if ((*at)->handle == handle) {
            instance = *at;
            *at = instance->next;
            break;
        }
    }
    for (Physical** at = &physicals; *at;) {
        Physical* physical = *at;
        if (instance && physical->instance == instance) {
            *at = physical->next;
            free(physical);
        } else {
            at = &physical->next;
        }
    }
    pthread_mutex_unlock(&lock);
    if (!instance) return;
    if (instance->destroy) instance->destroy(handle, allocator);
    free(instance);
}

static VKAPI_ATTR VkResult VKAPI_CALL EnumeratePhysicalDevices(VkInstance handle, uint32_t* count,
                                                               VkPhysicalDevice* physicals_out) {
    Instance* instance = find_instance(handle);
    if (!instance || !instance->enumerate) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = instance->enumerate(handle, count, physicals_out);
    if (physicals_out && (result == VK_SUCCESS || result == VK_INCOMPLETE)) {
        for (uint32_t i = 0; i < *count; i++) remember(physicals_out[i], instance);
    }
    return result;
}

static void remember_groups(Instance* instance, VkResult result, uint32_t* count, VkPhysicalDeviceGroupProperties* groups) {
    if (!groups || (result != VK_SUCCESS && result != VK_INCOMPLETE)) return;
    for (uint32_t i = 0; i < *count; i++) {
        for (uint32_t j = 0; j < groups[i].physicalDeviceCount; j++) remember(groups[i].physicalDevices[j], instance);
    }
}

static VKAPI_ATTR VkResult VKAPI_CALL EnumeratePhysicalDeviceGroups(VkInstance handle, uint32_t* count,
                                                                    VkPhysicalDeviceGroupProperties* groups) {
    Instance* instance = find_instance(handle);
    if (!instance || !instance->enumerate_groups) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = instance->enumerate_groups(handle, count, groups);
    remember_groups(instance, result, count, groups);
    return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL EnumeratePhysicalDeviceGroupsKHR(VkInstance handle, uint32_t* count,
                                                                       VkPhysicalDeviceGroupProperties* groups) {
    Instance* instance = find_instance(handle);
    if (!instance || !instance->enumerate_groups_khr) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = instance->enumerate_groups_khr(handle, count, groups);
    remember_groups(instance, result, count, groups);
    return result;
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties(VkPhysicalDevice physical, VkPhysicalDeviceProperties* p) {
    Instance* instance = instance_of(physical);
    if (!instance || !instance->properties) return;
    instance->properties(physical, p);
    if (instance->spoof) spoof_properties(p);
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties2(VkPhysicalDevice physical, VkPhysicalDeviceProperties2* p) {
    Instance* instance = instance_of(physical);
    if (!instance || !instance->properties2) return;
    instance->properties2(physical, p);
    if (instance->spoof) spoof_properties2(p);
}

static VKAPI_ATTR void VKAPI_CALL GetPhysicalDeviceProperties2KHR(VkPhysicalDevice physical, VkPhysicalDeviceProperties2* p) {
    Instance* instance = instance_of(physical);
    if (!instance || !instance->properties2_khr) return;
    instance->properties2_khr(physical, p);
    if (instance->spoof) spoof_properties2(p);
}

// MARK: Device

static VKAPI_ATTR VkResult VKAPI_CALL CreateDevice(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
                                                   const VkAllocationCallbacks* allocator, VkDevice* out) {
    DeviceCreateInfo* link = (DeviceCreateInfo*)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && link->function == LAYER_LINK_INFO)) {
        link = (DeviceCreateInfo*)link->pNext;
    }
    Instance* instance = instance_of(physical);
    if (!link || !link->u.layer_info || !instance) return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.layer_info->next_get_instance_proc_addr;
    PFN_vkGetDeviceProcAddr gdpa = link->u.layer_info->next_get_device_proc_addr;
    link->u.layer_info = link->u.layer_info->next;
    PFN_vkCreateDevice create = (PFN_vkCreateDevice)gipa(instance->handle, "vkCreateDevice");
    if (!create) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = create(physical, info, allocator, out);
    if (result != VK_SUCCESS) return result;
    Device* device = calloc(1, sizeof *device);
    if (!device) {
        PFN_vkDestroyDevice destroy = (PFN_vkDestroyDevice)gdpa(*out, "vkDestroyDevice");
        if (destroy) destroy(*out, allocator);
        return VK_ERROR_OUT_OF_HOST_MEMORY;
    }
    device->handle = *out;
    device->gdpa = gdpa;
    device->destroy = (PFN_vkDestroyDevice)gdpa(*out, "vkDestroyDevice");
    if (instance->spoof && instance->properties && (profile.has_vendor || profile.has_device)) {
        VkPhysicalDeviceProperties real;
        instance->properties(physical, &real);
        device->real_vendor_id = real.vendorID;
        device->real_device_id = real.deviceID;
        device->vendor_id = profile.has_vendor ? profile.vendor : real.vendorID;
        device->device_id = profile.has_device ? profile.device : real.deviceID;
        device->cache_ids = device->vendor_id != real.vendorID || device->device_id != real.deviceID;
        device->get_cache_data = (PFN_vkGetPipelineCacheData)gdpa(*out, "vkGetPipelineCacheData");
        device->create_cache = (PFN_vkCreatePipelineCache)gdpa(*out, "vkCreatePipelineCache");
    }
    pthread_mutex_lock(&lock);
    device->next = devices;
    devices = device;
    pthread_mutex_unlock(&lock);
    return result;
}

static VKAPI_ATTR void VKAPI_CALL DestroyDevice(VkDevice handle, const VkAllocationCallbacks* allocator) {
    pthread_mutex_lock(&lock);
    Device* device = NULL;
    for (Device** at = &devices; *at; at = &(*at)->next) {
        if ((*at)->handle == handle) {
            device = *at;
            *at = device->next;
            break;
        }
    }
    pthread_mutex_unlock(&lock);
    if (!device) return;
    if (device->destroy) device->destroy(handle, allocator);
    free(device);
}

// MARK: Pipeline caches

// A pipeline cache's data begins with VkPipelineCacheHeaderVersionOne, least
// significant byte first: the GPU's vendorID at byte 8, its deviceID at 12.
// Engines check those against vkGetPhysicalDeviceProperties and throw away a
// saved cache that does not match, so the app sees the profile's IDs there
// too, and the driver gets its own back.
static uint32_t le32(const unsigned char* p) {
    return p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static void put_le32(unsigned char* p, uint32_t value) {
    for (int i = 0; i < 4; i++) p[i] = (unsigned char)(value >> (8 * i));
}

static bool has_cache_header(const void* data, size_t size) {
    const unsigned char* p = data;
    return p && size >= sizeof(VkPipelineCacheHeaderVersionOne) && le32(p) >= sizeof(VkPipelineCacheHeaderVersionOne)
        && le32(p + 4) == VK_PIPELINE_CACHE_HEADER_VERSION_ONE;
}

// The header's IDs that are `from_*` become `to_*`; whether one did.
static bool replace_cache_ids(unsigned char* header, uint32_t from_vendor, uint32_t to_vendor, uint32_t from_device,
                              uint32_t to_device) {
    bool replaced = false;
    if (from_vendor != to_vendor && le32(header + 8) == from_vendor) {
        put_le32(header + 8, to_vendor);
        replaced = true;
    }
    if (from_device != to_device && le32(header + 12) == from_device) {
        put_le32(header + 12, to_device);
        replaced = true;
    }
    return replaced;
}

static VKAPI_ATTR VkResult VKAPI_CALL GetPipelineCacheData(VkDevice handle, VkPipelineCache cache, size_t* size,
                                                           void* data) {
    Device* device = find_device(handle);
    if (!device || !device->get_cache_data) return VK_ERROR_INITIALIZATION_FAILED;
    VkResult result = device->get_cache_data(handle, cache, size, data);
    // A short buffer holds as much as fits, header first, or nothing.
    if ((result == VK_SUCCESS || result == VK_INCOMPLETE) && has_cache_header(data, *size)) {
        replace_cache_ids(data, device->real_vendor_id, device->vendor_id, device->real_device_id, device->device_id);
    }
    return result;
}

static VKAPI_ATTR VkResult VKAPI_CALL CreatePipelineCache(VkDevice handle, const VkPipelineCacheCreateInfo* info,
                                                          const VkAllocationCallbacks* allocator, VkPipelineCache* cache) {
    Device* device = find_device(handle);
    if (!device || !device->create_cache) return VK_ERROR_INITIALIZATION_FAILED;
    unsigned char header[sizeof(VkPipelineCacheHeaderVersionOne)];
    unsigned char* restored = NULL;
    if (has_cache_header(info->pInitialData, info->initialDataSize)) {
        memcpy(header, info->pInitialData, sizeof header);
        // The app's data stays as it is: the driver reads a copy.
        if (replace_cache_ids(header, device->vendor_id, device->real_vendor_id, device->device_id, device->real_device_id)
            && (restored = malloc(info->initialDataSize))) {
            memcpy(restored, info->pInitialData, info->initialDataSize);
            memcpy(restored, header, sizeof header);
        }
    }
    if (!restored) return device->create_cache(handle, info, allocator, cache);
    VkPipelineCacheCreateInfo copy = *info;
    copy.pInitialData = restored;
    VkResult result = device->create_cache(handle, &copy, allocator, cache);
    free(restored);
    return result;
}

// MARK: Entry points

AVO_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice handle, const char* name) {
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (strcmp(name, "vkDestroyDevice") == 0) return (PFN_vkVoidFunction)DestroyDevice;
    Device* device = find_device(handle);
    if (!device) return NULL;
    if (device->cache_ids) {
        if (strcmp(name, "vkGetPipelineCacheData") == 0 && device->get_cache_data) {
            return (PFN_vkVoidFunction)GetPipelineCacheData;
        }
        if (strcmp(name, "vkCreatePipelineCache") == 0 && device->create_cache) {
            return (PFN_vkVoidFunction)CreatePipelineCache;
        }
    }
    return device->gdpa(handle, name);
}

AVO_EXPORT VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance handle, const char* name) {
    if (strcmp(name, "vkGetInstanceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
    if (strcmp(name, "vkCreateInstance") == 0) return (PFN_vkVoidFunction)CreateInstance;
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    Instance* instance = handle ? find_instance(handle) : NULL;
    if (!instance) return NULL;
    // Ours only where the next layer or driver has the function.
    if (strcmp(name, "vkDestroyInstance") == 0) return (PFN_vkVoidFunction)DestroyInstance;
    if (strcmp(name, "vkCreateDevice") == 0) return (PFN_vkVoidFunction)CreateDevice;
    if (strcmp(name, "vkEnumeratePhysicalDevices") == 0 && instance->enumerate) {
        return (PFN_vkVoidFunction)EnumeratePhysicalDevices;
    }
    if (strcmp(name, "vkEnumeratePhysicalDeviceGroups") == 0 && instance->enumerate_groups) {
        return (PFN_vkVoidFunction)EnumeratePhysicalDeviceGroups;
    }
    if (strcmp(name, "vkEnumeratePhysicalDeviceGroupsKHR") == 0 && instance->enumerate_groups_khr) {
        return (PFN_vkVoidFunction)EnumeratePhysicalDeviceGroupsKHR;
    }
    if (strcmp(name, "vkGetPhysicalDeviceProperties") == 0 && instance->properties) {
        return (PFN_vkVoidFunction)GetPhysicalDeviceProperties;
    }
    if (strcmp(name, "vkGetPhysicalDeviceProperties2") == 0 && instance->properties2) {
        return (PFN_vkVoidFunction)GetPhysicalDeviceProperties2;
    }
    if (strcmp(name, "vkGetPhysicalDeviceProperties2KHR") == 0 && instance->properties2_khr) {
        return (PFN_vkVoidFunction)GetPhysicalDeviceProperties2KHR;
    }
    return instance->gipa(handle, name);
}

static const VkLayerProperties layer = {
    .layerName = LAYER_NAME,
    .specVersion = VK_API_VERSION_1_3,
    .implementationVersion = 1,
    .description = "Avo: the device profile's GPU name and IDs",
};

static VkResult layer_properties(uint32_t* count, VkLayerProperties* properties) {
    if (!properties) {
        *count = 1;
        return VK_SUCCESS;
    }
    if (*count < 1) return VK_INCOMPLETE;
    properties[0] = layer;
    *count = 1;
    return VK_SUCCESS;
}

AVO_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceLayerProperties(uint32_t* count, VkLayerProperties* properties) {
    return layer_properties(count, properties);
}

AVO_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceLayerProperties(VkPhysicalDevice physical, uint32_t* count,
                                                                           VkLayerProperties* properties) {
    (void)physical;
    return layer_properties(count, properties);
}

// The layer adds no extensions.
AVO_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(const char* layer_name, uint32_t* count,
                                                                                 VkExtensionProperties* properties) {
    (void)properties;
    if (!layer_name || strcmp(layer_name, LAYER_NAME) != 0) return VK_ERROR_LAYER_NOT_PRESENT;
    *count = 0;
    return VK_SUCCESS;
}

AVO_EXPORT VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateDeviceExtensionProperties(VkPhysicalDevice physical, const char* layer_name,
                                                                               uint32_t* count, VkExtensionProperties* properties) {
    (void)properties;
    if (!layer_name || strcmp(layer_name, LAYER_NAME) != 0) {
        Instance* instance = physical ? instance_of(physical) : NULL;
        PFN_vkEnumerateDeviceExtensionProperties next = instance
            ? (PFN_vkEnumerateDeviceExtensionProperties)instance->gipa(instance->handle, "vkEnumerateDeviceExtensionProperties")
            : NULL;
        return next ? next(physical, layer_name, count, properties) : VK_ERROR_LAYER_NOT_PRESENT;
    }
    *count = 0;
    return VK_SUCCESS;
}

#ifdef AVO_VK_WRAP
// The wrapper's way in: it enters the layer at the top of its chain, its HAL
// path having no loader link of its own to fetch these by name with.
AVO_EXPORT VKAPI_ATTR VkResult VKAPI_CALL avo_profile_create_instance(const VkInstanceCreateInfo* info,
                                                                      const VkAllocationCallbacks* allocator, VkInstance* out) {
    return CreateInstance(info, allocator, out);
}

AVO_EXPORT VKAPI_ATTR VkResult VKAPI_CALL avo_profile_create_device(VkPhysicalDevice physical, const VkDeviceCreateInfo* info,
                                                                    const VkAllocationCallbacks* allocator, VkDevice* out) {
    return CreateDevice(physical, info, allocator, out);
}
#endif

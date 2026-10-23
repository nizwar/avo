// Drives Avo's Mac-side Vulkan layer (../native_astc.c) through a Vulkan
// loader and MoltenVK the way gfxstream does; run.sh says what to expect.
//
//   layer_test <libvulkan.dylib> provoking <vert.spv> <frag.spv>
//     what ANGLE does with VK_EXT_provoking_vertex: looks for the extension
//     and provokingVertexLast, makes a device with both and a pipeline that
//     asks for the last vertex; prints one line per step.
//   layer_test <libvulkan.dylib> extension <engine>
//     whether an instance whose engine is named <engine> is offered
//     VK_EXT_provoking_vertex: "extension listed" or "extension missing".
//   layer_test <libvulkan.dylib> draw <vert.spv> <frag.spv> <attachments> [--inline]
//     moltenvk_test's draw (guest/gfxsync/test): a 2x1 image into
//     `attachments` colour attachments, each attachment's two pixels printed
//     as RRGGBBAA; --inline brings the fragment SPIR-V inline in the pipeline
//     (VK_KHR_maintenance5) instead of in a module. Exit status 2: the
//     pipeline failed; 3: --inline without VK_KHR_maintenance5.
//
// run.sh points VK_DRIVER_FILES at the renderer's MoltenVK and, with the
// layer, VK_ADD_LAYER_PATH and VK_INSTANCE_LAYERS at it.
#include <dlfcn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CHECK(call)                                                                  \
    do {                                                                             \
        VkResult result_ = (call);                                                   \
        if (result_ != VK_SUCCESS) {                                                 \
            fprintf(stderr, "%s:%d: %s: %d\n", __FILE__, __LINE__, #call, result_); \
            exit(1);                                                                 \
        }                                                                            \
    } while (0)

enum { MAX_ATTACHMENTS = 8, WIDTH = 2 };

static PFN_vkGetInstanceProcAddr gipa;
static VkInstance instance;
#define FN(name) PFN_vk##name name = (PFN_vk##name)gipa(instance, "vk" #name)

static uint32_t* read_file(const char* path, size_t* words) {
    FILE* file = fopen(path, "rb");
    if (!file) {
        perror(path);
        exit(1);
    }
    fseek(file, 0, SEEK_END);
    long size = ftell(file);
    fseek(file, 0, SEEK_SET);
    uint32_t* code = malloc((size_t)size);
    if (!code || fread(code, 1, (size_t)size, file) != (size_t)size) exit(1);
    fclose(file);
    *words = (size_t)size / 4;
    return code;
}

static uint32_t memory_type(VkPhysicalDevice physical, uint32_t bits, VkMemoryPropertyFlags flags) {
    FN(GetPhysicalDeviceMemoryProperties);
    VkPhysicalDeviceMemoryProperties properties;
    GetPhysicalDeviceMemoryProperties(physical, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
        if ((bits & 1u << i) && (properties.memoryTypes[i].propertyFlags & flags) == flags) return i;
    }
    fprintf(stderr, "no memory type\n");
    exit(1);
}

static bool has_extension(VkPhysicalDevice physical, const char* name) {
    FN(EnumerateDeviceExtensionProperties);
    uint32_t count = 0;
    CHECK(EnumerateDeviceExtensionProperties(physical, NULL, &count, NULL));
    VkExtensionProperties* all = calloc(count, sizeof *all);
    CHECK(EnumerateDeviceExtensionProperties(physical, NULL, &count, all));
    bool found = false;
    for (uint32_t i = 0; i < count; i++) found = found || strcmp(all[i].extensionName, name) == 0;
    free(all);
    return found;
}

static VkShaderModule module_of(VkDevice device, const uint32_t* code, size_t words) {
    FN(CreateShaderModule);
    VkShaderModule module;
    CHECK(CreateShaderModule(device,
                             &(VkShaderModuleCreateInfo){
                                 .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                 .codeSize = words * 4,
                                 .pCode = code,
                             },
                             NULL, &module));
    return module;
}

static VkRenderPass render_pass_of(VkDevice device, uint32_t attachments) {
    VkAttachmentDescription descriptions[MAX_ATTACHMENTS];
    VkAttachmentReference references[MAX_ATTACHMENTS];
    for (uint32_t i = 0; i < attachments; i++) {
        descriptions[i] = (VkAttachmentDescription){
            .format = VK_FORMAT_R8G8B8A8_UNORM,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        };
        references[i] = (VkAttachmentReference){i, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    }
    FN(CreateRenderPass);
    VkRenderPass render_pass;
    CHECK(CreateRenderPass(device,
                           &(VkRenderPassCreateInfo){
                               .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
                               .attachmentCount = attachments,
                               .pAttachments = descriptions,
                               .subpassCount = 1,
                               .pSubpasses =
                                   &(VkSubpassDescription){
                                       .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
                                       .colorAttachmentCount = attachments,
                                       .pColorAttachments = references,
                                   },
                               .dependencyCount = 1,
                               .pDependencies =
                                   &(VkSubpassDependency){
                                       .srcSubpass = 0,
                                       .dstSubpass = VK_SUBPASS_EXTERNAL,
                                       .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                       .dstStageMask = VK_PIPELINE_STAGE_TRANSFER_BIT,
                                       .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                                       .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
                                   },
                           },
                           NULL, &render_pass));
    return render_pass;
}

// A pipeline drawing a full-screen triangle into `attachments` attachments:
// `stages` as given, `rasterization_next` chained to its rasterization state.
static VkResult pipeline_of(VkDevice device, VkRenderPass render_pass, uint32_t attachments,
                            const VkPipelineShaderStageCreateInfo stages[2], const void* rasterization_next,
                            VkPipeline* pipeline) {
    VkPipelineColorBlendAttachmentState blends[MAX_ATTACHMENTS];
    for (uint32_t i = 0; i < attachments; i++) blends[i] = (VkPipelineColorBlendAttachmentState){.colorWriteMask = 0xf};
    FN(CreatePipelineLayout);
    VkPipelineLayout layout;
    CHECK(CreatePipelineLayout(device, &(VkPipelineLayoutCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO},
                               NULL, &layout));
    FN(CreateGraphicsPipelines);
    return CreateGraphicsPipelines(
        device, VK_NULL_HANDLE, 1,
        &(VkGraphicsPipelineCreateInfo){
            .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = 2,
            .pStages = stages,
            .pVertexInputState = &(VkPipelineVertexInputStateCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO},
            .pInputAssemblyState =
                &(VkPipelineInputAssemblyStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
                    .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
                },
            .pViewportState =
                &(VkPipelineViewportStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
                    .viewportCount = 1,
                    .pViewports = &(VkViewport){0, 0, WIDTH, 1, 0, 1},
                    .scissorCount = 1,
                    .pScissors = &(VkRect2D){{0, 0}, {WIDTH, 1}},
                },
            .pRasterizationState =
                &(VkPipelineRasterizationStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
                    .pNext = rasterization_next,
                    .polygonMode = VK_POLYGON_MODE_FILL,
                    .cullMode = VK_CULL_MODE_NONE,
                    .lineWidth = 1,
                },
            .pMultisampleState =
                &(VkPipelineMultisampleStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
                    .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
                },
            .pColorBlendState =
                &(VkPipelineColorBlendStateCreateInfo){
                    .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
                    .attachmentCount = attachments,
                    .pAttachments = blends,
                },
            .layout = layout,
            .renderPass = render_pass,
        },
        NULL, pipeline);
}

// ANGLE's way to VK_EXT_provoking_vertex. 0 when every step worked.
static int provoking(VkPhysicalDevice physical, uint32_t family, const char* portability, const uint32_t* vert,
                     size_t vert_words, const uint32_t* frag, size_t frag_words) {
    int failures = 0;
    bool listed = has_extension(physical, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME);
    printf("extension %s\n", listed ? "listed" : "missing");
    if (!listed) failures++;

    FN(GetPhysicalDeviceFeatures2);
    VkPhysicalDeviceProvokingVertexFeaturesEXT features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT,
        .provokingVertexLast = 7,
        .transformFeedbackPreservesProvokingVertex = 7,
    };
    GetPhysicalDeviceFeatures2(physical, &(VkPhysicalDeviceFeatures2){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &features});
    printf("features last=%u transformFeedback=%u\n", features.provokingVertexLast, features.transformFeedbackPreservesProvokingVertex);
    if (features.provokingVertexLast != VK_TRUE || features.transformFeedbackPreservesProvokingVertex != VK_FALSE) failures++;

    FN(GetPhysicalDeviceProperties2);
    VkPhysicalDeviceProvokingVertexPropertiesEXT properties = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_PROPERTIES_EXT,
        .provokingVertexModePerPipeline = 7,
        .transformFeedbackPreservesTriangleFanProvokingVertex = 7,
    };
    GetPhysicalDeviceProperties2(physical,
                                 &(VkPhysicalDeviceProperties2){.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &properties});
    printf("properties perPipeline=%u triangleFan=%u\n", properties.provokingVertexModePerPipeline,
           properties.transformFeedbackPreservesTriangleFanProvokingVertex);
    if (properties.provokingVertexModePerPipeline != VK_FALSE || properties.transformFeedbackPreservesTriangleFanProvokingVertex != VK_FALSE) {
        failures++;
    }

    const char* extensions[2] = {VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME, portability};
    VkPhysicalDeviceProvokingVertexFeaturesEXT enable = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROVOKING_VERTEX_FEATURES_EXT,
        .provokingVertexLast = VK_TRUE,
    };
    FN(CreateDevice);
    VkDevice device;
    VkResult made = CreateDevice(physical,
                                 &(VkDeviceCreateInfo){
                                     .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                                     .pNext = &enable,
                                     .queueCreateInfoCount = 1,
                                     .pQueueCreateInfos =
                                         &(VkDeviceQueueCreateInfo){
                                             .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                             .queueFamilyIndex = family,
                                             .queueCount = 1,
                                             .pQueuePriorities = (float[]){1.0f},
                                         },
                                     .enabledExtensionCount = portability ? 2 : 1,
                                     .ppEnabledExtensionNames = extensions,
                                 },
                                 NULL, &device);
    printf("device %d\n", made);
    if (made != VK_SUCCESS) return failures + 1;
    // The caller's chain is whole again.
    if (enable.pNext != NULL || enable.provokingVertexLast != VK_TRUE) {
        printf("device: the feature structure changed\n");
        failures++;
    }

    const VkPipelineShaderStageCreateInfo stages[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, module_of(device, vert, vert_words), "main", NULL},
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_FRAGMENT_BIT, module_of(device, frag, frag_words), "main", NULL},
    };
    VkPipelineRasterizationProvokingVertexStateCreateInfoEXT last = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_PROVOKING_VERTEX_STATE_CREATE_INFO_EXT,
        .provokingVertexMode = VK_PROVOKING_VERTEX_MODE_LAST_VERTEX_EXT,
    };
    VkPipeline pipeline;
    VkResult pipelined = pipeline_of(device, render_pass_of(device, 1), 1, stages, &last, &pipeline);
    printf("pipeline %d\n", pipelined);
    if (pipelined != VK_SUCCESS) failures++;
    return failures;
}

// moltenvk_test's draw. 0, or the exit status.
static int draw(VkPhysicalDevice physical, uint32_t family, const char* portability, const uint32_t* vert, size_t vert_words,
                const uint32_t* frag, size_t frag_words, uint32_t attachments, bool inline_fragment) {
    const char* extensions[2];
    uint32_t extension_count = 0;
    if (portability) extensions[extension_count++] = portability;
    VkPhysicalDeviceMaintenance5FeaturesKHR maintenance5 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR,
        .maintenance5 = VK_TRUE,
    };
    if (inline_fragment) {
        if (!has_extension(physical, VK_KHR_MAINTENANCE_5_EXTENSION_NAME)) {
            fprintf(stderr, "no VK_KHR_maintenance5\n");
            return 3;
        }
        extensions[extension_count++] = VK_KHR_MAINTENANCE_5_EXTENSION_NAME;
    }
    FN(CreateDevice);
    VkDevice device;
    CHECK(CreateDevice(physical,
                       &(VkDeviceCreateInfo){
                           .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                           .pNext = inline_fragment ? &maintenance5 : NULL,
                           .queueCreateInfoCount = 1,
                           .pQueueCreateInfos =
                               &(VkDeviceQueueCreateInfo){
                                   .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                   .queueFamilyIndex = family,
                                   .queueCount = 1,
                                   .pQueuePriorities = (float[]){1.0f},
                               },
                           .enabledExtensionCount = extension_count,
                           .ppEnabledExtensionNames = extensions,
                       },
                       NULL, &device));

    FN(CreateImage);
    FN(GetImageMemoryRequirements);
    FN(AllocateMemory);
    FN(BindImageMemory);
    FN(CreateImageView);
    VkImage images[MAX_ATTACHMENTS];
    VkImageView views[MAX_ATTACHMENTS];
    for (uint32_t i = 0; i < attachments; i++) {
        CHECK(CreateImage(device,
                          &(VkImageCreateInfo){
                              .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
                              .imageType = VK_IMAGE_TYPE_2D,
                              .format = VK_FORMAT_R8G8B8A8_UNORM,
                              .extent = {WIDTH, 1, 1},
                              .mipLevels = 1,
                              .arrayLayers = 1,
                              .samples = VK_SAMPLE_COUNT_1_BIT,
                              .tiling = VK_IMAGE_TILING_OPTIMAL,
                              .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
                          },
                          NULL, &images[i]));
        VkMemoryRequirements needs;
        GetImageMemoryRequirements(device, images[i], &needs);
        VkDeviceMemory memory;
        CHECK(AllocateMemory(device,
                             &(VkMemoryAllocateInfo){
                                 .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                                 .allocationSize = needs.size,
                                 .memoryTypeIndex = memory_type(physical, needs.memoryTypeBits, 0),
                             },
                             NULL, &memory));
        CHECK(BindImageMemory(device, images[i], memory, 0));
        CHECK(CreateImageView(device,
                              &(VkImageViewCreateInfo){
                                  .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                                  .image = images[i],
                                  .viewType = VK_IMAGE_VIEW_TYPE_2D,
                                  .format = VK_FORMAT_R8G8B8A8_UNORM,
                                  .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
                              },
                              NULL, &views[i]));
    }

    FN(CreateBuffer);
    FN(GetBufferMemoryRequirements);
    FN(BindBufferMemory);
    FN(MapMemory);
    VkBuffer buffer;
    CHECK(CreateBuffer(device,
                       &(VkBufferCreateInfo){
                           .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                           .size = attachments * WIDTH * 4,
                           .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                       },
                       NULL, &buffer));
    VkMemoryRequirements needs;
    GetBufferMemoryRequirements(device, buffer, &needs);
    VkDeviceMemory buffer_memory;
    CHECK(AllocateMemory(device,
                         &(VkMemoryAllocateInfo){
                             .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
                             .allocationSize = needs.size,
                             .memoryTypeIndex = memory_type(physical, needs.memoryTypeBits,
                                                            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT
                                                                | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
                         },
                         NULL, &buffer_memory));
    CHECK(BindBufferMemory(device, buffer, buffer_memory, 0));

    VkRenderPass render_pass = render_pass_of(device, attachments);
    FN(CreateFramebuffer);
    VkFramebuffer framebuffer;
    CHECK(CreateFramebuffer(device,
                            &(VkFramebufferCreateInfo){
                                .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                                .renderPass = render_pass,
                                .attachmentCount = attachments,
                                .pAttachments = views,
                                .width = WIDTH,
                                .height = 1,
                                .layers = 1,
                            },
                            NULL, &framebuffer));

    const VkShaderModuleCreateInfo inline_code = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = frag_words * 4,
        .pCode = frag,
    };
    const VkPipelineShaderStageCreateInfo stages[2] = {
        {VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0, VK_SHADER_STAGE_VERTEX_BIT, module_of(device, vert, vert_words), "main", NULL},
        inline_fragment
            ? (VkPipelineShaderStageCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, &inline_code, 0,
                                                VK_SHADER_STAGE_FRAGMENT_BIT, VK_NULL_HANDLE, "main", NULL}
            : (VkPipelineShaderStageCreateInfo){VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, NULL, 0,
                                                VK_SHADER_STAGE_FRAGMENT_BIT, module_of(device, frag, frag_words), "main", NULL},
    };
    VkPipeline pipeline;
    VkResult made = pipeline_of(device, render_pass, attachments, stages, NULL, &pipeline);
    if (made != VK_SUCCESS) {
        fprintf(stderr, "vkCreateGraphicsPipelines: %d\n", made);
        return 2;
    }
    // The caller's stage is as it was.
    if (inline_fragment && (stages[1].pNext != &inline_code || inline_code.pCode != frag || inline_code.codeSize != frag_words * 4)) {
        fprintf(stderr, "the inline stage changed\n");
        return 1;
    }

    FN(CreateCommandPool);
    FN(AllocateCommandBuffers);
    FN(BeginCommandBuffer);
    FN(CmdBeginRenderPass);
    FN(CmdBindPipeline);
    FN(CmdDraw);
    FN(CmdEndRenderPass);
    FN(CmdCopyImageToBuffer);
    FN(EndCommandBuffer);
    FN(GetDeviceQueue);
    FN(QueueSubmit);
    FN(QueueWaitIdle);
    VkCommandPool pool;
    CHECK(CreateCommandPool(device,
                            &(VkCommandPoolCreateInfo){.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family},
                            NULL, &pool));
    VkCommandBuffer commands;
    CHECK(AllocateCommandBuffers(device,
                                 &(VkCommandBufferAllocateInfo){
                                     .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                                     .commandPool = pool,
                                     .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                                     .commandBufferCount = 1,
                                 },
                                 &commands));
    CHECK(BeginCommandBuffer(commands, &(VkCommandBufferBeginInfo){.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}));
    VkClearValue clears[MAX_ATTACHMENTS];
    memset(clears, 0, sizeof clears);
    CmdBeginRenderPass(commands,
                       &(VkRenderPassBeginInfo){
                           .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                           .renderPass = render_pass,
                           .framebuffer = framebuffer,
                           .renderArea = {{0, 0}, {WIDTH, 1}},
                           .clearValueCount = attachments,
                           .pClearValues = clears,
                       },
                       VK_SUBPASS_CONTENTS_INLINE);
    CmdBindPipeline(commands, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    CmdDraw(commands, 3, 1, 0, 0);
    CmdEndRenderPass(commands);
    for (uint32_t i = 0; i < attachments; i++) {
        CmdCopyImageToBuffer(commands, images[i], VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer, 1,
                             &(VkBufferImageCopy){
                                 .bufferOffset = i * WIDTH * 4,
                                 .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
                                 .imageExtent = {WIDTH, 1, 1},
                             });
    }
    CHECK(EndCommandBuffer(commands));
    VkQueue queue;
    GetDeviceQueue(device, family, 0, &queue);
    CHECK(QueueSubmit(queue, 1,
                      &(VkSubmitInfo){.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &commands},
                      VK_NULL_HANDLE));
    CHECK(QueueWaitIdle(queue));

    const uint8_t* pixels;
    CHECK(MapMemory(device, buffer_memory, 0, VK_WHOLE_SIZE, 0, (void**)&pixels));
    for (uint32_t i = 0; i < attachments * WIDTH; i++) {
        printf("%s%02x%02x%02x%02x", i ? " " : "", pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2], pixels[i * 4 + 3]);
    }
    printf("\n");
    return 0;
}

int main(int argc, char** argv) {
    bool provoking_mode = argc == 5 && strcmp(argv[2], "provoking") == 0;
    bool extension_mode = argc == 4 && strcmp(argv[2], "extension") == 0;
    bool draw_mode = argc >= 6 && strcmp(argv[2], "draw") == 0;
    if (!provoking_mode && !extension_mode && !draw_mode) {
        fprintf(stderr,
                "usage: %s <libvulkan.dylib> provoking <vert.spv> <frag.spv>\n"
                "       %s <libvulkan.dylib> extension <engine>\n"
                "       %s <libvulkan.dylib> draw <vert.spv> <frag.spv> <attachments> [--inline]\n",
                argv[0], argv[0], argv[0]);
        return 1;
    }
    size_t vert_words = 0, frag_words = 0;
    uint32_t* vert = extension_mode ? NULL : read_file(argv[3], &vert_words);
    uint32_t* frag = extension_mode ? NULL : read_file(argv[4], &frag_words);

    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library || !(gipa = (PFN_vkGetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr"))) {
        fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    // MoltenVK is a portability driver: the loader lists it only when asked to.
    FN(CreateInstance);
    const char* instance_extensions[] = {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    // ANGLE's instances are the ones offered VK_EXT_provoking_vertex.
    const VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pEngineName = extension_mode ? argv[3] : "ANGLE",
        .apiVersion = VK_API_VERSION_1_3,
    };
    CHECK(CreateInstance(&(VkInstanceCreateInfo){
                             .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
                             .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
                             .pApplicationInfo = &app,
                             .enabledExtensionCount = 1,
                             .ppEnabledExtensionNames = instance_extensions,
                         },
                         NULL, &instance));

    FN(EnumeratePhysicalDevices);
    uint32_t count = 1;
    VkPhysicalDevice physical;
    VkResult enumerated = EnumeratePhysicalDevices(instance, &count, &physical);
    if ((enumerated != VK_SUCCESS && enumerated != VK_INCOMPLETE) || count < 1) return 1;

    FN(GetPhysicalDeviceQueueFamilyProperties);
    VkQueueFamilyProperties families[16];
    count = 16;
    GetPhysicalDeviceQueueFamilyProperties(physical, &count, families);
    uint32_t family = 0;
    while (family < count && !(families[family].queueFlags & VK_QUEUE_GRAPHICS_BIT)) family++;
    if (family == count) return 1;
    if (extension_mode) {
        printf("extension %s\n", has_extension(physical, VK_EXT_PROVOKING_VERTEX_EXTENSION_NAME) ? "listed" : "missing");
        return 0;
    }
    const char* portability = has_extension(physical, "VK_KHR_portability_subset") ? "VK_KHR_portability_subset" : NULL;

    if (provoking_mode) return provoking(physical, family, portability, vert, vert_words, frag, frag_words) ? 1 : 0;
    uint32_t attachments = (uint32_t)atoi(argv[5]);
    if (attachments < 1 || attachments > MAX_ATTACHMENTS) return 1;
    bool inline_fragment = argc >= 7 && strcmp(argv[6], "--inline") == 0;
    return draw(physical, family, portability, vert, vert_words, frag, frag_words, attachments, inline_fragment);
}

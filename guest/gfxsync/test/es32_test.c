// Tests the gfxstream sync layer's ES 3.2 pieces on the Mac, under the
// sanitizers: the GLES version selector (debug.avo.gl.max), the ANGLE
// feature-override merge the constructor performs, the custom border
// colour the layer takes to Metal's six, and the read that settles
// whether the image's ANGLE knows exposeES32ForTesting. The blocks are
// extracted verbatim from src/vk_layer.c by run.sh, so what is tested is
// what ships.
//
// Properties and the environment arrive through stubs: the two the layer
// reads (HARNESS_GL_MAX, HARNESS_OVERRIDES) map to debug.avo.gl.max and
// debug.angle.feature_overrides_enabled.
#include <assert.h>
#include <pthread.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define PROP_VALUE_MAX 92
#define LOG(...) ((void)0)

// Two properties, each answered from an environment variable: the
// constructor runs before main, but the environment is there before any of
// it (that is exactly the layer's own situation: init put the property
// there long before the library loads).
int __system_property_get(const char* name, char* value) {
    const char* source = strcmp(name, "debug.avo.gl.max") == 0 ? "HARNESS_GL_MAX" : "HARNESS_OVERRIDES";
    const char* read = getenv(source);
    if (!read) read = "";
    snprintf(value, PROP_VALUE_MAX, "%s", read);
    return (int)strlen(read);
}

#include "es32_blocks.inc"

static int checks = 0;
#define CHECK(what, condition)                                                        \
    do {                                                                              \
        checks++;                                                                     \
        if (!(condition)) {                                                           \
            fprintf(stderr, "FAIL %s (%s:%d)\n", what, __FILE__, __LINE__);           \
            return 1;                                                                 \
        }                                                                             \
    } while (0)

int main(void) {
    // The constructor has run by now, before main, with whatever the
    // environment said — that is what the layer would do.
    const char* merged = getenv(AVO_FEATURES_ENV);
    printf("overrides -> %s\n", merged ? merged : "(env unset)");
    if (getenv("HARNESS_EXPECT")) CHECK("the constructor's merge", merged && strcmp(merged, getenv("HARNESS_EXPECT")) == 0);

    // read_gles_max: every value it understands, and the default.
    const struct { const char* value; int parsed; } versions[] = {
        {"", 32}, {"2.0", 20}, {"3.0", 30}, {"3.1", 31}, {"3.2", 32}, {"4.0", 32}, {"junk", 32},
    };
    for (size_t i = 0; i < sizeof versions / sizeof *versions; i++) {
        char* saved = strdup(getenv("HARNESS_GL_MAX") ? getenv("HARNESS_GL_MAX") : "");
        setenv("HARNESS_GL_MAX", versions[i].value, 1);
        read_gles_max();
        CHECK(versions[i].value, the_gles_max == versions[i].parsed);
        setenv("HARNESS_GL_MAX", saved, 1);
        free(saved);
    }

    // The border-colour corners stay exact; anything else is rounded.
    bool rounded = true;
    VkClearColorValue color = {.float32 = {0, 0, 0, 0}};
    CHECK("float transparent black", nearest_border_color(true, &color, &rounded) == VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK && !rounded);
    color.float32[3] = 1.0f;
    CHECK("float opaque black", nearest_border_color(true, &color, &rounded) == VK_BORDER_COLOR_FLOAT_OPAQUE_BLACK && !rounded);
    for (int i = 0; i < 4; i++) color.float32[i] = 1.0f;
    CHECK("float opaque white", nearest_border_color(true, &color, &rounded) == VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE && !rounded);
    color.float32[0] = 0.25f;
    CHECK("float rounded to white", nearest_border_color(true, &color, &rounded) == VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE && rounded);
    VkClearColorValue ints = {.int32 = {0, 0, 0, 0}};
    CHECK("int transparent black", nearest_border_color(false, &ints, &rounded) == VK_BORDER_COLOR_INT_TRANSPARENT_BLACK && !rounded);
    ints.int32[3] = 1;
    CHECK("int opaque black", nearest_border_color(false, &ints, &rounded) == VK_BORDER_COLOR_INT_OPAQUE_BLACK && !rounded);
    ints.int32[0] = ints.int32[1] = ints.int32[2] = 1;
    CHECK("int opaque white", nearest_border_color(false, &ints, &rounded) == VK_BORDER_COLOR_INT_OPAQUE_WHITE && !rounded);
    ints.int32[0] = 7;
    CHECK("int rounded to white", nearest_border_color(false, &ints, &rounded) == VK_BORDER_COLOR_INT_OPAQUE_WHITE && rounded);

    // The library scan: a name across the 64 KiB read boundary is found,
    // a near miss is not, and a library that will not open — or will not
    // read (a directory) — says nothing either way.
    const char* scratch = getenv("HARNESS_SCRATCH");
    char path[256];
    snprintf(path, sizeof path, "%s/hit", scratch);
    FILE* file = fopen(path, "wb");
    assert(file);
    char filler[70000];
    memset(filler, 'x', sizeof filler);
    fwrite(filler, 1, 65530, file);  // the name starts 6 bytes before the boundary
    fwrite("exposeES32ForTesting", 1, 20, file);
    fwrite(filler, 1, 4000, file);
    fclose(file);
    CHECK("a name across the boundary", angle_knows_the_feature(path));
    snprintf(path, sizeof path, "%s/miss", scratch);
    file = fopen(path, "wb");
    fwrite(filler, 1, 70000, file);
    fwrite("exposeES32ForTestin", 1, 19, file);  // one byte short
    fwrite(filler, 1, 4000, file);
    fclose(file);
    CHECK("a near miss", !angle_knows_the_feature(path));
    CHECK("a library that will not open", angle_knows_the_feature("/no/such/library"));
    CHECK("a library that will not read", angle_knows_the_feature(scratch));

    printf("es32: %d checks passed\n", checks);
    return 0;
}

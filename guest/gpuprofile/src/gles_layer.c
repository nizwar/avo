// libGLES_avo_profile.so: an Android GLES layer that reports the device
// profile's GPU in glGetString, so an app's own GLES renderer reads
// "Qualcomm" / "Adreno (TM) 750" / "OpenGL ES 3.1 V@0762.11 ..." where the
// profile says so instead of ANGLE's "Google Inc. (Apple)" / "ANGLE (...)".
// Extensions, limits and the ES version number stay the real ones: only the
// names change.
//
// Android loads it into every process (debug.gles.layers, from
// /data/local/debug/gles; HostAgent installs it). It does nothing outside
// app processes, and inside one only the app's own code sees the profile, on
// any thread (Unreal Engine's is named "RenderThread", like HWUI's): HWUI and
// WebView keep the real strings, since Skia and Chromium choose driver
// workarounds from them. The layer finds them on the caller's stack
// (avo_profile.h).
//
//   debug.avo.gl.vendor    GL_VENDOR
//   debug.avo.gl.renderer  GL_RENDERER
//   debug.avo.gl.version   GL_VERSION after "OpenGL ES <major>.<minor> "
//
// With any of them set, GL_VERSION (without a profile version) and
// GL_SHADING_LANGUAGE_VERSION also lose ANGLE's "(ANGLE ...)" suffix, the way
// a phone's driver reports them.
//
// Why it patches libEGL's tables: Android hands a GLES layer only libEGL's
// own entries (eglMakeCurrent, the glGetString that libGLESv2 forwards to
// libEGL), not the driver's GL functions. libGLESv1_CM's glGetString, which
// Java's GLES20/GLES30 classes bind to, reads the driver's function from the
// context's dispatch table (egl_connection_t::hooks) and never reaches a
// layer. So on the app's first eglMakeCurrent the layer swaps the driver's
// glGetString in both of those tables (ES 1 and ES 2+) for its own, which
// every path (libGLESv1_CM, libGLESv2/v3, eglGetProcAddress) ends at.
#include <EGL/egl.h>
#include <dlfcn.h>
#include <pthread.h>

#ifdef AVO_GL_LOG
#include <android/log.h>
#define AVO_LOG(...) __android_log_print(ANDROID_LOG_INFO, "AvoGlLayer", __VA_ARGS__)
#else
#define AVO_LOG(...) ((void)0)
#endif

#include "gles_profile.h"

// The loader's GLES layer interface (frameworks/native/opengl/libs/EGL/egl_layers.cpp).
typedef __eglMustCastToProperFunctionPointerType EGLFuncPointer;
typedef void* (*PFNEGLGETNEXTLAYERPROCADDRESSPROC)(void*, const char*);
typedef const GLubyte*(GL_APIENTRYP GetStringProc)(GLenum name);
typedef EGLBoolean(EGLAPIENTRYP MakeCurrentProc)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);

// The driver's glGetString from each dispatch table: ES 1, ES 2 and later.
static GetStringProc driver_get_string[2];

static const GLubyte* GL_APIENTRY GetStringES1(GLenum name) {
    return profile_string(name, driver_get_string[0](name));
}

static const GLubyte* GL_APIENTRY GetStringES2(GLenum name) {
    return profile_string(name, driver_get_string[1](name));
}

static bool is_get_string(void* function) {
    Dl_info info;
    return function && dladdr(function, &info) && info.dli_saddr == function && info.dli_sname
        && strcmp(info.dli_sname, "glGetString") == 0;
}

// egl_connection_t starts with the driver handle and the two dispatch tables
// (gl_hooks_t gHooks[2], one right after the other); find the driver's
// glGetString in the ES 2 table by its symbol name, then swap that slot in
// both. Anything unexpected leaves the tables, and the real strings, alone.
static void patch_dispatch(void) {
    if (!active()) return;
    void* egl = dlopen("libEGL.so", RTLD_NOW | RTLD_NOLOAD);
    void** (*connection)(void) = egl ? (void** (*)(void))dlsym(egl, "_ZN7android18egl_get_connectionEv") : NULL;
    void** cnx = connection ? connection() : NULL;
    if (egl) dlclose(egl);
    if (!cnx) return;
    uintptr_t es1 = (uintptr_t)cnx[1], es2 = (uintptr_t)cnx[2];
    if (!es1 || es2 <= es1 || es2 - es1 > 64 * 1024 || (es2 - es1) % sizeof(void*) != 0) {
        AVO_LOG("unexpected dispatch tables %p %p", (void*)es1, (void*)es2);
        return;
    }
    void** tables[2] = {(void**)es1, (void**)es2};
    size_t count = (es2 - es1) / sizeof(void*);
    size_t slot = 0;
    while (slot < count && !is_get_string(tables[1][slot])) slot++;
    if (slot == count) {
        AVO_LOG("no glGetString in the dispatch table");
        return;
    }
    GetStringProc wrappers[2] = {GetStringES1, GetStringES2};
    for (int i = 0; i < 2; i++) {
        void* function = __atomic_load_n(&tables[i][slot], __ATOMIC_RELAXED);
        if (!is_get_string(function)) continue;
        driver_get_string[i] = (GetStringProc)function;
        __atomic_store_n(&tables[i][slot], (void*)wrappers[i], __ATOMIC_RELEASE);
    }
    AVO_LOG("glGetString at slot %zu of %zu: ES1 %d, ES2 %d", slot, count, driver_get_string[0] != NULL,
            driver_get_string[1] != NULL);
}

static MakeCurrentProc next_make_current;
static pthread_once_t patch_once = PTHREAD_ONCE_INIT;

// Every GL call follows an eglMakeCurrent, and by the first one the driver's
// tables are filled in.
static EGLBoolean EGLAPIENTRY MakeCurrent(EGLDisplay display, EGLSurface draw, EGLSurface read, EGLContext context) {
    EGLBoolean result = next_make_current(display, draw, read, context);
    pthread_once(&patch_once, patch_dispatch);
    return result;
}

AVO_EXPORT void AndroidGLESLayer_Initialize(void* layer_id, PFNEGLGETNEXTLAYERPROCADDRESSPROC get_next_layer_proc_address) {
    (void)layer_id;
    (void)get_next_layer_proc_address;
}

// Everything else goes straight to the next layer or libEGL.
AVO_EXPORT void* AndroidGLESLayer_GetProcAddress(const char* name, EGLFuncPointer next) {
    if (next && strcmp(name, "eglMakeCurrent") == 0 && active()) {
        next_make_current = (MakeCurrentProc)next;
        return (void*)MakeCurrent;
    }
    return (void*)next;
}

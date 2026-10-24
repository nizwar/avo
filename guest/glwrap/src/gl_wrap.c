// libGLESv2_angle.so (a wrapper): reports the device profile's GPU in an
// app's own glGetString without a GLES layer, so nothing has to go in
// /data/local/debug, the path Android reads GLES layers from only on a
// debuggable build (ro.debuggable=1), and where a packer such as FLUJO's
// ijiami kills apps over a library. The strings, and who sees them, are the
// GLES layer's (guest/gpuprofile/src/gles_profile.h).
//
// ANGLE draws GLES on Avo: libEGL loads it as the system driver named by
// ro.hardware.egl (angle), libEGL_angle.so, libGLESv1_CM_angle.so and
// libGLESv2_angle.so from /system/lib64, and fills each context's dispatch
// table with dlsym(driver, "gl…"). Avo bind-mounts this wrapper over
// /system/lib64/libGLESv2_angle.so (GuestGLESWrapper in AvoDaemonCore) and
// puts the real library beside it as REAL_NAME, which the wrapper needs
// (DT_NEEDED). It defines only the glGetString family: a dlsym on the
// driver searches the wrapper, then what it needs, so every other function,
// and every EGL_* one libEGL_angle.so takes from it, is the real library's.
//
// What it exports:
// - glGetString: what the ES 2+ dispatch table holds, so libGLESv2/v3,
//   Java's GLES20/GLES30 (through libGLESv1_CM's table lookup) and
//   eglGetProcAddress all end here.
// - GL_GetString: ANGLE's own entry point, which libGLESv1_CM_angle.so's
//   glGetString (ES 1 contexts) calls into this library for. The real
//   glGetString may call it as well; the second look is skipped (`inside`).
#include <dlfcn.h>

#ifdef AVO_GL_LOG
#include <android/log.h>
#define AVO_LOG(...) __android_log_print(ANDROID_LOG_INFO, "AvoGlWrap", __VA_ARGS__)
#else
#define AVO_LOG(...) ((void)0)
#endif

#include "gles_profile.h"

// The real library, beside the wrapper in /system/lib64 (GuestGLESWrapper's
// realPath). The linker loaded it before this library's code runs.
#define REAL_NAME "libGLESv2_angle.avoreal.so"

typedef const GLubyte*(GL_APIENTRYP GetStringProc)(GLenum name);

static struct {
    GetStringProc gl_get_string;
    GetStringProc angle_get_string;
} real;
static pthread_once_t real_once = PTHREAD_ONCE_INIT;

static void find_real(void) {
    void* library = dlopen(REAL_NAME, RTLD_NOW | RTLD_NOLOAD);
    if (!library) {
        AVO_LOG("no %s", REAL_NAME);
        return;
    }
    // dlsym on its handle looks in it first: its own functions, never these.
    real.gl_get_string = (GetStringProc)dlsym(library, "glGetString");
    real.angle_get_string = (GetStringProc)dlsym(library, "GL_GetString");
    AVO_LOG("glGetString %p, GL_GetString %p", (void*)real.gl_get_string, (void*)real.angle_get_string);
}

// Set while the real glGetString runs: its own call into GL_GetString, if it
// makes one, already gets the profile's strings on the way out.
static _Thread_local bool inside;

static const GLubyte* answer(GetStringProc function, GLenum name) {
    if (!function) return NULL;
    if (inside) return function(name);
    inside = true;
    const GLubyte* text = function(name);
    inside = false;
    return active() ? profile_string(name, text) : text;
}

AVO_EXPORT const GLubyte* GL_APIENTRY glGetString(GLenum name) {
    pthread_once(&real_once, find_real);
    return answer(real.gl_get_string, name);
}

AVO_EXPORT const GLubyte* GL_APIENTRY GL_GetString(GLenum name) {
    pthread_once(&real_once, find_real);
    return answer(real.angle_get_string, name);
}

// Shared by Avo's GLES layer (gles_layer.c) and its ANGLE wrapper
// (guest/glwrap): the strings an app's own glGetString reads instead of
// ANGLE's, from the device profile.
//
//   debug.avo.gl.vendor    GL_VENDOR
//   debug.avo.gl.renderer  GL_RENDERER
//   debug.avo.gl.version   GL_VERSION after "OpenGL ES <major>.<minor> "
//
// With any of them set, GL_VERSION (without a profile version) and
// GL_SHADING_LANGUAGE_VERSION also lose ANGLE's "(ANGLE ...)" suffix, the way
// a phone's driver reports them. Extensions, limits and the ES version
// number stay the real ones: only the names change. Only an app process sees
// them, and in it only the app's own code: HWUI and WebView keep the real
// strings (avo_profile.h).
#pragma once

#include <GLES2/gl2.h>
#include <pthread.h>
#include <stdio.h>

#include "avo_profile.h"

static struct {
    char vendor[PROP_VALUE_MAX];
    char renderer[PROP_VALUE_MAX];
    char version[PROP_VALUE_MAX];
    bool any;
} profile;
static pthread_once_t profile_once = PTHREAD_ONCE_INIT;

static void read_profile(void) {
    avo_prop("debug.avo.gl.vendor", profile.vendor);
    avo_prop("debug.avo.gl.renderer", profile.renderer);
    avo_prop("debug.avo.gl.version", profile.version);
    profile.any = profile.vendor[0] || profile.renderer[0] || profile.version[0];
}

// An app process with GL strings to report: the layer does anything at all.
static bool active(void) {
    pthread_once(&profile_once, read_profile);
    return profile.any && avo_app_process();
}

// glGetString's strings live as long as the context; these live as long as
// the process. Each distinct one is kept once (a few per process).
typedef struct Kept {
    struct Kept* next;
    char text[];
} Kept;
static pthread_mutex_t kept_lock = PTHREAD_MUTEX_INITIALIZER;
static Kept* kept;

static const GLubyte* keep(const char* text) {
    pthread_mutex_lock(&kept_lock);
    Kept* found = kept;
    while (found && strcmp(found->text, text) != 0) found = found->next;
    if (!found && (found = malloc(sizeof *found + strlen(text) + 1))) {
        strcpy(found->text, text);
        found->next = kept;
        kept = found;
    }
    pthread_mutex_unlock(&kept_lock);
    return found ? (const GLubyte*)found->text : NULL;
}

// "OpenGL ES GLSL ES 3.10 (ANGLE 2.1 ...)" -> "OpenGL ES GLSL ES 3.10".
static const GLubyte* without_angle(const GLubyte* real) {
    const char* suffix = real ? strstr((const char*)real, " (ANGLE") : NULL;
    if (!suffix) return real;
    char text[128];
    size_t length = (size_t)(suffix - (const char*)real);
    if (length >= sizeof text) return real;
    memcpy(text, real, length);
    text[length] = '\0';
    const GLubyte* out = keep(text);
    return out ? out : real;
}

// "OpenGL ES 3.1.0 (ANGLE 2.1 ...)" -> "OpenGL ES 3.1 V@0762.11 (...)":
// the context's real version number, the profile's driver (or no driver,
// when the profile names none).
static const GLubyte* version_string(const GLubyte* real) {
    static const char prefix[] = "OpenGL ES ";
    int major, minor;
    if (!profile.version[0] || !real || strncmp((const char*)real, prefix, sizeof prefix - 1) != 0
        || sscanf((const char*)real + sizeof prefix - 1, "%d.%d", &major, &minor) != 2) {
        return without_angle(real);
    }
    char text[sizeof prefix + 24 + PROP_VALUE_MAX];
    snprintf(text, sizeof text, "%s%d.%d %s", prefix, major, minor, profile.version);
    const GLubyte* out = keep(text);
    return out ? out : real;
}

static const GLubyte* profile_string(GLenum name, const GLubyte* real) {
    // Other names (GL_EXTENSIONS and the like) stay as they are, without a
    // look at the caller.
    if (name != GL_VENDOR && name != GL_RENDERER && name != GL_VERSION && name != GL_SHADING_LANGUAGE_VERSION) {
        return real;
    }
    if (avo_framework_call()) return real;
    switch (name) {
        case GL_VENDOR: return profile.vendor[0] ? (const GLubyte*)profile.vendor : real;
        case GL_RENDERER: return profile.renderer[0] ? (const GLubyte*)profile.renderer : real;
        case GL_VERSION: return version_string(real);
        case GL_SHADING_LANGUAGE_VERSION: return without_angle(real);
        default: return real;
    }
}

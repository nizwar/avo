// Native half of the Avo Bridge Agent.
//
//  * vsock server sockets (Java has no AF_VSOCK support);
//  * posting VirtualDisplay frames to host displays through gfxstream. The
//    gralloc buffers are already host color buffers, so a frame is "posted"
//    by handing its host handle to the display with the same id
//    (rcCreateDisplayById / rcSetDisplayColorBuffer). This part needs the
//    gfxstream guest libraries and is only compiled in the AOSP build
//    (AVO_GFXSTREAM); SDK builds report it as unavailable.

#include <jni.h>

#include <errno.h>
#include <sys/socket.h>
#include <unistd.h>

#include <linux/vm_sockets.h>

#if defined(AVO_GFXSTREAM)
#include <android/hardware_buffer.h>
#include <android/hardware_buffer_jni.h>
#include <log/log.h>

#include "HostConnection.h"  // hardware/google/gfxstream/guest/OpenglSystemCommon
#endif

namespace {

jint nativeListen(JNIEnv*, jclass, jint port) {
    int fd = socket(AF_VSOCK, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return -errno;
    sockaddr_vm address{};
    address.svm_family = AF_VSOCK;
    address.svm_cid = VMADDR_CID_ANY;
    address.svm_port = static_cast<unsigned int>(port);
    if (bind(fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 || listen(fd, 4) != 0) {
        int error = errno;
        close(fd);
        return -error;
    }
    return fd;
}

jint nativeAccept(JNIEnv*, jclass, jint listener) {
    while (true) {
        int fd = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
        if (fd >= 0) return fd;
        if (errno != EINTR) return -errno;
    }
}

void nativeSetLowLatency(JNIEnv*, jclass, jint fd) {
    // vsock has no Nagle; keep the send buffer small so input never queues behind bulk data.
    int bytes = 16 * 1024;
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bytes, sizeof(bytes));
}

#if defined(AVO_GFXSTREAM)

ExtendedRCEncoderContext* renderControl(HostConnection** connection) {
    HostConnection* host = HostConnection::get();
    if (host == nullptr) return nullptr;
    if (connection != nullptr) *connection = host;
    return host->rcEncoder();
}

jboolean nativeAvailable(JNIEnv*, jclass) {
    ExtendedRCEncoderContext* rc = renderControl(nullptr);
    return rc != nullptr && rc->hasMultiDisplay() ? JNI_TRUE : JNI_FALSE;
}

void nativeCreateDisplay(JNIEnv*, jclass, jint id, jint width, jint height) {
    if (auto* rc = renderControl(nullptr)) {
        rc->rcCreateDisplayById(rc, static_cast<uint32_t>(id));
        rc->rcSetDisplayPose(rc, static_cast<uint32_t>(id), 0, 0, width, height);
    }
}

void nativeResizeDisplay(JNIEnv*, jclass, jint id, jint width, jint height) {
    if (auto* rc = renderControl(nullptr)) rc->rcSetDisplayPose(rc, static_cast<uint32_t>(id), 0, 0, width, height);
}

void nativeDestroyDisplay(JNIEnv*, jclass, jint id) {
    if (auto* rc = renderControl(nullptr)) rc->rcDestroyDisplay(rc, static_cast<uint32_t>(id));
}

jboolean nativePostFrame(JNIEnv* env, jclass, jint id, jobject hardwareBuffer) {
    HostConnection* host = nullptr;
    ExtendedRCEncoderContext* rc = renderControl(&host);
    AHardwareBuffer* buffer = AHardwareBuffer_fromHardwareBuffer(env, hardwareBuffer);
    if (rc == nullptr || buffer == nullptr) return JNI_FALSE;
    const native_handle_t* handle = AHardwareBuffer_getNativeHandle(buffer);
    uint32_t colorBuffer = host->grallocHelper()->getHostHandle(handle);
    if (colorBuffer == 0) return JNI_FALSE;
    // Commands are ordered on the host render thread, so the frame is complete
    // by the time the host displays it, and later rendering into this buffer
    // happens after the host has taken its copy.
    rc->rcSetDisplayColorBuffer(rc, static_cast<uint32_t>(id), colorBuffer);
    return JNI_TRUE;
}

#else

jboolean nativeAvailable(JNIEnv*, jclass) { return JNI_FALSE; }
void nativeCreateDisplay(JNIEnv*, jclass, jint, jint, jint) {}
void nativeResizeDisplay(JNIEnv*, jclass, jint, jint, jint) {}
void nativeDestroyDisplay(JNIEnv*, jclass, jint) {}
jboolean nativePostFrame(JNIEnv*, jclass, jint, jobject) { return JNI_FALSE; }

#endif

const JNINativeMethod kVsockMethods[] = {
    {"nativeListen", "(I)I", reinterpret_cast<void*>(nativeListen)},
    {"nativeAccept", "(I)I", reinterpret_cast<void*>(nativeAccept)},
    {"nativeSetLowLatency", "(I)V", reinterpret_cast<void*>(nativeSetLowLatency)},
};

const JNINativeMethod kFrameMethods[] = {
    {"nativeAvailable", "()Z", reinterpret_cast<void*>(nativeAvailable)},
    {"nativeCreateDisplay", "(III)V", reinterpret_cast<void*>(nativeCreateDisplay)},
    {"nativeResizeDisplay", "(III)V", reinterpret_cast<void*>(nativeResizeDisplay)},
    {"nativeDestroyDisplay", "(I)V", reinterpret_cast<void*>(nativeDestroyDisplay)},
    {"nativePostFrame", "(ILandroid/hardware/HardwareBuffer;)Z", reinterpret_cast<void*>(nativePostFrame)},
};

bool registerMethods(JNIEnv* env, const char* className, const JNINativeMethod* methods, int count) {
    jclass type = env->FindClass(className);
    return type != nullptr && env->RegisterNatives(type, methods, count) == JNI_OK;
}

}  // namespace

extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
    JNIEnv* env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    if (!registerMethods(env, "com/avodroid/bridge/io/Vsock", kVsockMethods, 3)) return JNI_ERR;
    if (!registerMethods(env, "com/avodroid/bridge/display/GfxstreamFrameSink", kFrameMethods, 5)) return JNI_ERR;
    return JNI_VERSION_1_6;
}

package com.avodroid.bridge.io;

import android.os.ParcelFileDescriptor;

import java.io.IOException;

/**
 * AF_VSOCK server sockets (Java has no vsock support). The host connects to
 * the guest's ports through the engine; only the daemon on the Mac can reach
 * them (spec: "Kanal vsock hanya bisa diakses oleh proses daemon").
 */
public final class Vsock {
    private Vsock() {}

    /** Binds VMADDR_CID_ANY:port and listens. Returns the listening descriptor. */
    public static ParcelFileDescriptor listen(int port) throws IOException {
        int fd = nativeListen(port);
        if (fd < 0) throw new IOException("vsock listen on port " + port + " failed: errno " + -fd);
        return ParcelFileDescriptor.adoptFd(fd);
    }

    /** Blocks until the host connects. */
    public static ParcelFileDescriptor accept(ParcelFileDescriptor listener) throws IOException {
        int fd = nativeAccept(listener.getFd());
        if (fd < 0) throw new IOException("vsock accept failed: errno " + -fd);
        return ParcelFileDescriptor.adoptFd(fd);
    }

    /** Disables Nagle-like batching for low-latency input (no-op if unsupported). */
    public static void setLowLatency(ParcelFileDescriptor socket) {
        nativeSetLowLatency(socket.getFd());
    }

    private static native int nativeListen(int port);
    private static native int nativeAccept(int fd);
    private static native void nativeSetLowLatency(int fd);
}

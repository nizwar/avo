package com.avodroid.bridge.io;

/** Loads libavobridge_jni once, before any class with native methods is used. */
public final class Natives {
    private static boolean loaded;

    private Natives() {}

    public static synchronized void load() {
        if (loaded) return;
        // JNI_OnLoad registers the natives of Vsock and GfxstreamFrameSink.
        System.loadLibrary("avobridge_jni");
        loaded = true;
    }
}

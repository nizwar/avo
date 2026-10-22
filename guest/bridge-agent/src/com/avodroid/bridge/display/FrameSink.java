package com.avodroid.bridge.display;

import android.view.Surface;

/**
 * Where a VirtualDisplay renders. The production sink hands every frame's
 * gralloc buffer to the host through gfxstream, so frames are shown on the
 * Mac without video encoding (spec: "frame tidak perlu di-encode").
 */
public interface FrameSink {
    interface Listener {
        /** The first frame of `hostDisplayId` reached the host. */
        void onFirstFrame(int hostDisplayId);
    }

    /** Creates the surface the display renders into. */
    Surface open(int hostDisplayId, int width, int height, int maxFps, Listener listener);

    /** Returns a new surface for a resized display. */
    Surface resize(int hostDisplayId, int width, int height);

    void setMaxFps(int hostDisplayId, int maxFps);

    void close(int hostDisplayId);

    /** False when frames do not reach the host (no gfxstream in this image). */
    boolean postsFrames();
}

package com.avodroid.bridge.display;

import android.graphics.PixelFormat;
import android.hardware.HardwareBuffer;
import android.hardware.SyncFence;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import android.util.SparseArray;
import android.view.Surface;

import com.avodroid.bridge.Bridge;

import java.io.IOException;

/**
 * Consumes each VirtualDisplay through an ImageReader and posts the buffers
 * to the host display with the same id via gfxstream (libavobridge_jni). The
 * buffers are host-side color buffers already, so posting only passes a handle.
 */
public final class GfxstreamFrameSink implements FrameSink {
    private static final long USAGE = HardwareBuffer.USAGE_GPU_SAMPLED_IMAGE | HardwareBuffer.USAGE_GPU_COLOR_OUTPUT;
    private final Handler handler;
    private final SparseArray<Target> targets = new SparseArray<>();
    private final boolean available;

    private static final class Target {
        ImageReader reader;
        Listener listener;
        boolean announced;
        long minIntervalNs;
        long lastPostNs;
    }

    public GfxstreamFrameSink() {
        HandlerThread thread = new HandlerThread("avo-frames", Process.THREAD_PRIORITY_DISPLAY);
        thread.start();
        handler = new Handler(thread.getLooper());
        available = nativeAvailable();
        if (!available) Log.w(Bridge.TAG, "gfxstream display posting unavailable in this build");
    }

    @Override
    public boolean postsFrames() {
        return available;
    }

    @Override
    public synchronized Surface open(int hostDisplayId, int width, int height, int maxFps, Listener listener) {
        Target target = new Target();
        target.listener = listener;
        target.minIntervalNs = intervalFor(maxFps);
        targets.put(hostDisplayId, target);
        if (available) nativeCreateDisplay(hostDisplayId, width, height);
        return attach(hostDisplayId, target, width, height);
    }

    @Override
    public synchronized Surface resize(int hostDisplayId, int width, int height) {
        Target target = targets.get(hostDisplayId);
        if (target == null) return null;
        if (target.reader != null) target.reader.close();
        if (available) nativeResizeDisplay(hostDisplayId, width, height);
        return attach(hostDisplayId, target, width, height);
    }

    @Override
    public synchronized void setMaxFps(int hostDisplayId, int maxFps) {
        Target target = targets.get(hostDisplayId);
        if (target != null) target.minIntervalNs = intervalFor(maxFps);
    }

    @Override
    public synchronized void close(int hostDisplayId) {
        Target target = targets.get(hostDisplayId);
        if (target == null) return;
        targets.remove(hostDisplayId);
        if (target.reader != null) target.reader.close();
        if (available) nativeDestroyDisplay(hostDisplayId);
    }

    private Surface attach(int hostDisplayId, Target target, int width, int height) {
        // Three buffers: one on screen on the Mac, one being composed, one spare.
        ImageReader reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 3, USAGE);
        reader.setOnImageAvailableListener(r -> onImage(hostDisplayId, r), handler);
        target.reader = reader;
        return reader.getSurface();
    }

    private void onImage(int hostDisplayId, ImageReader reader) {
        Image image;
        try {
            image = reader.acquireLatestImage();
        } catch (IllegalStateException e) {
            return;
        }
        if (image == null) return;
        try (Image frame = image) {
            Target target;
            synchronized (this) {
                target = targets.get(hostDisplayId);
            }
            if (target == null || !available) return;
            long now = SystemClock.elapsedRealtimeNanos();
            if (now - target.lastPostNs < target.minIntervalNs) return; // frame cap
            target.lastPostNs = now;
            // The producer's GPU work must be done before the host shows the buffer.
            try (SyncFence fence = frame.getFence()) {
                if (fence.isValid()) fence.awaitForever();
            } catch (IOException ignored) {
            }
            try (HardwareBuffer buffer = frame.getHardwareBuffer()) {
                if (buffer != null && nativePostFrame(hostDisplayId, buffer) && !target.announced) {
                    target.announced = true;
                    target.listener.onFirstFrame(hostDisplayId);
                }
            }
        }
    }

    private static long intervalFor(int fps) {
        // Allow a little jitter so a 60 FPS cap does not drop every other frame.
        return fps <= 0 ? 0 : (long) (1_000_000_000L / fps * 0.9);
    }

    private static native boolean nativeAvailable();
    private static native void nativeCreateDisplay(int hostDisplayId, int width, int height);
    private static native void nativeResizeDisplay(int hostDisplayId, int width, int height);
    private static native void nativeDestroyDisplay(int hostDisplayId);
    private static native boolean nativePostFrame(int hostDisplayId, HardwareBuffer buffer);
}

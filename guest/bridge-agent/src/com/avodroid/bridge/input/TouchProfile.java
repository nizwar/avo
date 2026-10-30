package com.avodroid.bridge.input;

import java.util.Random;

/**
 * One finger's digitizer numbers while it touches the screen, and the small
 * ways they move from event to event. A touch panel reports pressure, size
 * and the touch ellipse for every event — never constants — and stamps its
 * events at nanosecond resolution; MotionEvent.obtain leaves all of that
 * flat (pressure and size 1, no ellipse, whole milliseconds), so the
 * injector gives each finger a character of its own here. The ranges sit
 * inside what phone panels report for a finger at rest.
 *
 * Pure Java, so they can be checked without Android (test/TouchProfileTest.java).
 */
public final class TouchProfile {
    /** A finger's contact, from touch-down to lift-off. */
    public static final class Finger {
        private final Random random;
        private final float basePressure;
        private final float baseSize;
        /** A fingertip's ellipse across, in pixels (of a 420 dpi panel). */
        private final float baseMajor;
        private final float minorRatio;
        private float pressureWalk, sizeWalk;

        public Finger(Random random, float densityScale) {
            this.random = random;
            basePressure = 0.35f + random.nextFloat() * 0.4f;
            baseSize = 0.08f + random.nextFloat() * 0.14f;
            baseMajor = (35f + random.nextFloat() * 35f) * densityScale;
            minorRatio = 0.78f + random.nextFloat() * 0.14f;
        }

        /** The finger's numbers for one event; {@code lifting} when it leaves the screen. */
        public Numbers next(boolean lifting) {
            pressureWalk = clamp(pressureWalk + drift(0.03f), -0.08f, 0.08f);
            sizeWalk = clamp(sizeWalk + drift(0.004f), -0.02f, 0.02f);
            float pressure = clamp(basePressure + pressureWalk, 0.2f, 1f);
            float size = clamp(baseSize + sizeWalk, 0.02f, 0.35f);
            float major = clamp(baseMajor * (size / baseSize), 12f, 220f);
            return new Numbers(lifting ? pressure * 0.8f : pressure, size, major, major * minorRatio);
        }

        private float drift(float range) {
            return (random.nextFloat() - 0.5f) * 2 * range;
        }
    }

    /** What one event reports for one finger. */
    public static final class Numbers {
        public final float pressure, size, touchMajor, touchMinor;

        Numbers(float pressure, float size, float touchMajor, float touchMinor) {
            this.pressure = pressure;
            this.size = size;
            this.touchMajor = touchMajor;
            this.touchMinor = touchMinor;
        }
    }

    /**
     * An event time for {@code nowMs} at a digitizer's nanosecond resolution:
     * never a whole millisecond, never going back.
     */
    public static long nanos(long nowMs, long lastNanos, Random random) {
        long nanos = nowMs * 1_000_000L + 1 + (long) (random.nextDouble() * 999_997.0);
        if (nanos <= lastNanos) nanos = lastNanos + 1 + (long) (random.nextDouble() * 60_000.0);
        return nanos;
    }

    private static float clamp(float value, float low, float high) {
        return Math.max(low, Math.min(high, value));
    }

    private TouchProfile() {}
}

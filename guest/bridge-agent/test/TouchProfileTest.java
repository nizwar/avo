import com.avodroid.bridge.input.TouchProfile;

import java.util.HashSet;
import java.util.Random;
import java.util.Set;

/**
 * TouchProfile's ranges: a finger's numbers stay inside what touch panels
 * report, and move; event times are nanoseconds, never whole milliseconds.
 * Plain JVM, no Android: run by build.sh.
 */
public final class TouchProfileTest {
    private static int failures;

    private static void check(boolean ok, String what) {
        if (!ok) {
            failures++;
            System.err.println("FAIL " + what);
        }
    }

    public static void main(String[] args) {
        Random random = new Random(7);

        // One finger through a long drag: within a panel's ranges, and moving.
        TouchProfile.Finger finger = new TouchProfile.Finger(random, 1f);
        float minPressure = 1f, maxPressure = 0f, minSize = 1f, maxSize = 0f;
        for (int i = 0; i < 10_000; i++) {
            TouchProfile.Numbers numbers = finger.next(false);
            check(numbers.pressure >= 0.2f && numbers.pressure <= 1f, "pressure " + numbers.pressure);
            check(numbers.size >= 0.02f && numbers.size <= 0.35f, "size " + numbers.size);
            check(numbers.touchMajor >= numbers.touchMinor, "ellipse " + numbers.touchMajor + "x" + numbers.touchMinor);
            check(numbers.touchMajor >= 12f && numbers.touchMajor <= 220f, "touchMajor " + numbers.touchMajor);
            minPressure = Math.min(minPressure, numbers.pressure);
            maxPressure = Math.max(maxPressure, numbers.pressure);
            minSize = Math.min(minSize, numbers.size);
            maxSize = Math.max(maxSize, numbers.size);
        }
        check(maxPressure - minPressure > 0.01f, "pressure never moved");
        check(maxSize - minSize > 0.005f, "size never moved");
        check(finger.next(true).pressure < 1f, "lifting pressure");

        // New fingers differ: no two touches report the same character.
        Set<Integer> openings = new HashSet<>();
        for (int i = 0; i < 200; i++) {
            TouchProfile.Numbers numbers = new TouchProfile.Finger(random, 1f).next(false);
            openings.add(Float.floatToIntBits(numbers.pressure));
        }
        check(openings.size() >= 150, "every finger felt the same: " + openings.size());

        // Density moves the ellipse with it: a 560 dpi panel reports a wider one.
        float phone = new TouchProfile.Finger(random, 1f).next(false).touchMajor;
        float denser = new TouchProfile.Finger(random, 560f / 420f).next(false).touchMajor;
        check(denser > phone, "density did not widen the ellipse");

        // Event times: nanosecond precision, never going back.
        long last = 0;
        for (int ms = 0; ms < 1000; ms++) {
            long nanos = TouchProfile.nanos(ms, last, random);
            check(nanos > last, "time went back at " + ms);
            check(nanos % 1_000_000L != 0, "whole millisecond at " + ms);
            last = nanos;
        }
        // Two events in one millisecond stay ordered.
        long first = TouchProfile.nanos(5, 0, random);
        long second = TouchProfile.nanos(5, first, random);
        check(second > first, "same-millisecond events out of order");

        if (failures == 0) {
            System.out.println("TouchProfileTest ok");
        } else {
            System.exit(1);
        }
    }
}

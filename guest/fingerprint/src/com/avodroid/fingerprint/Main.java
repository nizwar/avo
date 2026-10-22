package com.avodroid.fingerprint;

import android.os.Binder;
import android.os.IBinder;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;

/**
 * Android's enrolled fingerprints for images without the Bridge Agent, so the
 * Runtime Daemon can give the fingers registered in Avo their names (HostAgent's
 * "Fingerprints"). Android has no shell command to list, rename or remove
 * them (`cmd fingerprint` only syncs a virtual sensor's enrollments, with
 * empty names, and touches it), so this calls Android's fingerprint service
 * the way Settings › Fingerprint does. Run over ADB as root: renaming and
 * removing need MANAGE_FINGERPRINT, which the shell user does not hold.
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-fingerprint.jar app_process / com.avodroid.fingerprint.Main status [USER]
 *   ... rename ID BASE64 [USER]   give fingerprint ID the name BASE64 (UTF-8), then status
 *   ... remove ID [USER]          remove fingerprint ID (Android also removes it from the sensor), then status
 * </pre>
 *
 * Status is one line each: "sensor ID" (the first fingerprint sensor),
 * "active 0|1" (an app or the lock screen waits for a finger), "lockout
 * 0|1|2" (none, timed, permanent), "lock TYPE" (USER's screen lock as
 * LockPatternUtils numbers it: -1 none, 1 pattern, 2 password or PIN, 3 PIN,
 * 4 password), "strongauth FLAGS" (why Android wants that credential before
 * a fingerprint, 0 for nothing), then "finger ID BASE64" per fingerprint of
 * USER (default 0), then "end COUNT". Names travel as Base64 so any text fits
 * on one line.
 */
public final class Main {
    private static final String SHELL = "com.android.shell";

    private final Object service;
    private final Object lockSettings;

    private Main() throws Exception {
        service = service("fingerprint", "android.hardware.fingerprint.IFingerprintService$Stub");
        if (service == null) throw new IllegalStateException("no fingerprint service");
        lockSettings = service("lock_settings", "com.android.internal.widget.ILockSettings$Stub");
    }

    private static Object service(String name, String stub) throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, name);
        if (binder == null) return null;
        return Class.forName(stub).getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    public static void main(String[] args) {
        try {
            int code = new Main().run(args);
            System.out.flush();
            System.exit(code);
        } catch (Throwable error) {
            Throwable cause = error.getCause() != null ? error.getCause() : error;
            System.out.println("error " + cause);
            System.exit(1);
        }
    }

    private int run(String[] args) throws Exception {
        if (args.length >= 1 && args[0].equals("status") && args.length <= 2) {
            printStatus(user(args, 1));
            return 0;
        }
        if (args.length >= 3 && args[0].equals("rename") && args.length <= 4) {
            int id = Integer.parseInt(args[1]);
            String name = new String(Base64.getDecoder().decode(args[2]), StandardCharsets.UTF_8);
            int user = user(args, 3);
            if (!enrolled(user, id)) return missing(id, user);
            invoke("rename", id, user, name);
            printStatus(user);
            return 0;
        }
        if (args.length >= 2 && args[0].equals("remove") && args.length <= 3) {
            int id = Integer.parseInt(args[1]);
            int user = user(args, 2);
            if (!enrolled(user, id)) return missing(id, user);
            // Without a receiver Android reports nothing back: wait until the
            // fingerprint is gone from its list (the sensor goes first).
            invoke("remove", new Binder(), id, user, null, SHELL);
            for (int i = 0; i < 50 && enrolled(user, id); i++) Thread.sleep(100);
            printStatus(user);
            return enrolled(user, id) ? 1 : 0;
        }
        System.err.println("usage: status [USER] | rename ID BASE64 [USER] | remove ID [USER]");
        return 2;
    }

    private static int user(String[] args, int index) {
        return args.length > index ? Integer.parseInt(args[index]) : 0;
    }

    private int missing(int id, int user) throws Exception {
        printStatus(user);
        System.out.println("error no fingerprint " + id);
        return 1;
    }

    private void printStatus(int user) throws Exception {
        int sensor = sensorId();
        System.out.println("sensor " + sensor);
        if (sensor >= 0) {
            System.out.println("active " + (truthy(invoke("isClientActive")) ? 1 : 0));
            System.out.println("lockout " + invoke("getLockoutModeForUser", sensor, user));
        }
        if (lockSettings != null) {
            System.out.println("lock " + call(lockSettings, "getCredentialType", user));
            System.out.println("strongauth " + call(lockSettings, "getStrongAuthForUser", user));
        }
        List<?> prints = fingerprints(user);
        for (Object print : prints) {
            int id = (Integer) print.getClass().getMethod("getBiometricId").invoke(print);
            Object name = print.getClass().getMethod("getName").invoke(print);
            String text = name == null ? "" : name.toString();
            System.out.println("finger " + id + " " + Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.UTF_8)));
        }
        System.out.println("end " + prints.size());
    }

    private boolean enrolled(int user, int id) throws Exception {
        for (Object print : fingerprints(user)) {
            if ((Integer) print.getClass().getMethod("getBiometricId").invoke(print) == id) return true;
        }
        return false;
    }

    private List<?> fingerprints(int user) throws Exception {
        Method method = method("getEnrolledFingerprints");
        // (userId, opPackageName, attributionTag) since Android 12; (userId, opPackageName) before.
        Object list = method.getParameterTypes().length == 3
                ? method.invoke(service, user, SHELL, null)
                : method.invoke(service, user, SHELL);
        return list == null ? List.of() : (List<?>) list;
    }

    /** The first fingerprint sensor's id, -1 when Android lists none. */
    private int sensorId() throws Exception {
        List<?> sensors = (List<?>) invoke("getSensorPropertiesInternal", SHELL);
        if (sensors == null || sensors.isEmpty()) return -1;
        Object first = sensors.get(0);
        Field field = first.getClass().getField("sensorId");
        return field.getInt(first);
    }

    private static boolean truthy(Object value) {
        return value instanceof Boolean && (Boolean) value;
    }

    private Method method(String name) {
        for (Method method : service.getClass().getMethods()) {
            if (method.getName().equals(name)) return method;
        }
        throw new IllegalStateException("IFingerprintService has no " + name);
    }

    private Object invoke(String name, Object... args) throws Exception {
        return call(service, name, args);
    }

    private static Object call(Object target, String name, Object... args) throws Exception {
        for (Method method : target.getClass().getMethods()) {
            if (method.getName().equals(name) && method.getParameterTypes().length == args.length) {
                return method.invoke(target, args);
            }
        }
        throw new IllegalStateException(target.getClass().getName() + " has no " + name + " taking " + args.length + " arguments");
    }
}

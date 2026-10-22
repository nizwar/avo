package com.avodroid.bridge;

import android.util.Log;

import java.lang.reflect.Method;

/**
 * Access to @hide / @SystemApi members of public framework classes. The agent
 * is a platform-signed privileged app, so hidden API checks do not apply; the
 * reflection only keeps the source buildable against the public SDK.
 */
public final class Hidden {
    private static final String TAG = "AvoBridge";

    private Hidden() {}

    public static Object call(Object target, String name, Class<?>[] types, Object... args) {
        try {
            Method method = (target instanceof Class<?> type ? type : target.getClass()).getMethod(name, types);
            return method.invoke(target instanceof Class<?> ? null : target, args);
        } catch (ReflectiveOperationException e) {
            Log.w(TAG, "hidden call " + name + " failed", e);
            return null;
        }
    }

    public static String property(String key, String fallback) {
        try {
            Class<?> properties = Class.forName("android.os.SystemProperties");
            return (String) properties.getMethod("get", String.class, String.class).invoke(null, key, fallback);
        } catch (ReflectiveOperationException e) {
            return fallback;
        }
    }

    public static int intField(Object target, String name, int fallback) {
        try {
            Class<?> type = target.getClass();
            while (type != null) {
                try {
                    return type.getDeclaredField(name).getInt(target);
                } catch (NoSuchFieldException e) {
                    type = type.getSuperclass();
                }
            }
        } catch (IllegalAccessException ignored) {
        }
        return fallback;
    }

    public static Class<?> type(String name) {
        try {
            return Class.forName(name);
        } catch (ClassNotFoundException e) {
            return null;
        }
    }
}

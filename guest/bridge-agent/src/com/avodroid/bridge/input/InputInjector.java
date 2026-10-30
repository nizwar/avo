package com.avodroid.bridge.input;

import android.content.res.Resources;
import android.hardware.input.InputManagerGlobal;
import android.os.SystemClock;
import android.util.Log;
import android.util.SparseLongArray;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import com.avodroid.bridge.Bridge;
import com.avodroid.bridge.display.DisplayController;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Random;

/**
 * Turns Input channel records into injected events on the right display.
 * Touches carry the character of the display's own digitizer: each finger
 * reports its own pressure, size and touch ellipse, on the touchscreen's
 * device, at nanosecond times (TouchProfile) — what a panel reports, not
 * MotionEvent.obtain's flat placeholders.
 */
final class InputInjector {
    static final int TYPE_TOUCH = 0x01;
    static final int TYPE_KEY = 0x02;
    static final int TYPE_SCROLL = 0x03;
    static final int TYPE_TEXT = 0x04;
    static final int TYPE_MOUSE = 0x05;
    static final int TYPE_GAMEPAD = 0x06;
    static final int TYPE_PING = 0x7F;

    private static final int INJECT_ASYNC = 0; // InputManager.INJECT_INPUT_EVENT_MODE_ASYNC
    private static final int MAX_POINTERS = 16;

    private final DisplayController displays;
    private final MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[MAX_POINTERS];
    private final MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[MAX_POINTERS];
    /** Gesture start time per Android display (MotionEvent downTime), in nanoseconds. */
    private final SparseLongArray downTimes = new SparseLongArray();
    /** Each finger's numbers, per display and pointer id. */
    private final HashMap<Long, TouchProfile.Finger> fingers = new HashMap<>();
    private final Random random = new Random();
    /** The last injected event time: event times never go back. */
    private long lastNanos;
    /** The touch panel the touches speak for; MIN_VALUE until the first look. */
    private int touchDeviceId = Integer.MIN_VALUE;
    private long touchDeviceScanMs;
    private final float densityScale = densityScale();
    /** MotionEvent's constructor that takes its times in nanoseconds, when the runtime allows reaching it. */
    private final Constructor<MotionEvent> nanosMotionEvent = nanosMotionEvent();
    private boolean warnedNanosMotionEvent;
    private final KeyCharacterMap keyMap = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);
    private final Method setDisplayId;
    private boolean warnedGamepad;

    InputInjector(DisplayController displays) {
        this.displays = displays;
        for (int i = 0; i < MAX_POINTERS; i++) {
            properties[i] = new MotionEvent.PointerProperties();
            coords[i] = new MotionEvent.PointerCoords();
        }
        Method method = null;
        try {
            method = InputEvent.class.getMethod("setDisplayId", int.class); // @hide
        } catch (NoSuchMethodException e) {
            Log.e(Bridge.TAG, "InputEvent.setDisplayId missing; input goes to the default display", e);
        }
        setDisplayId = method;
    }

    synchronized void inject(int type, ByteBuffer record, int length) {
        int hostDisplay = InputRecords.displayId(record);
        int display = hostDisplay == 0 ? 0 : displays.androidDisplayFor(hostDisplay);
        if (display < 0) return; // window already closed
        switch (type) {
            case TYPE_TOUCH -> touch(record, display);
            case TYPE_KEY -> key(record, display);
            case TYPE_SCROLL -> scroll(record, display);
            case TYPE_TEXT -> text(record, display);
            case TYPE_MOUSE -> mouse(record, display);
            case TYPE_GAMEPAD -> {
                if (!warnedGamepad) Log.w(Bridge.TAG, "native gamepad passthrough is not available yet; use keymap profiles");
                warnedGamepad = true;
            }
            default -> { }
        }
    }

    private void touch(ByteBuffer r, int display) {
        int action = InputRecords.touchAction(r);
        int actionIndex = InputRecords.touchActionIndex(r);
        int count = Math.min(InputRecords.touchPointerCount(r), MAX_POINTERS);
        long nowNanos = TouchProfile.nanos(SystemClock.uptimeMillis(), lastNanos, random);
        lastNanos = nowNanos;
        if (action == MotionEvent.ACTION_DOWN) downTimes.put(display, nowNanos);
        long downNanos = downTimes.get(display, nowNanos);
        boolean ending = action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL;
        for (int i = 0; i < count; i++) {
            int pointerId = InputRecords.pointerId(r, i);
            properties[i].clear();
            properties[i].id = pointerId;
            properties[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coords[i].clear();
            coords[i].x = InputRecords.pointerX(r, i);
            coords[i].y = InputRecords.pointerY(r, i);
            long key = fingerKey(display, pointerId);
            boolean begins = action == MotionEvent.ACTION_DOWN
                    || (action == MotionEvent.ACTION_POINTER_DOWN && actionIndex == i);
            boolean lifts = ending || (action == MotionEvent.ACTION_POINTER_UP && actionIndex == i);
            if (begins) fingers.put(key, new TouchProfile.Finger(random, densityScale));
            TouchProfile.Finger finger = lifts ? fingers.remove(key) : fingers.get(key);
            if (finger == null) {
                // A finger we never saw go down: what the host said of it.
                coords[i].pressure = InputRecords.pointerPressure(r, i);
                coords[i].size = 1;
            } else {
                TouchProfile.Numbers numbers = finger.next(lifts);
                coords[i].pressure = numbers.pressure;
                coords[i].size = numbers.size;
                coords[i].touchMajor = numbers.touchMajor;
                coords[i].touchMinor = numbers.touchMinor;
            }
        }
        int fullAction = action;
        if (action == MotionEvent.ACTION_POINTER_DOWN || action == MotionEvent.ACTION_POINTER_UP) {
            fullAction |= actionIndex << MotionEvent.ACTION_POINTER_INDEX_SHIFT;
        }
        MotionEvent event = obtainTouch(downNanos, nowNanos, fullAction, count);
        send(event, display);
        event.recycle();
    }

    private void key(ByteBuffer r, int display) {
        int action = InputRecords.keyDown(r) ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP;
        long now = SystemClock.uptimeMillis();
        KeyEvent event = new KeyEvent(now, now, action, InputRecords.keyCode(r), InputRecords.keyRepeat(r),
                InputRecords.keyMetaState(r), KeyCharacterMap.VIRTUAL_KEYBOARD, InputRecords.keyScanCode(r), 0,
                InputDevice.SOURCE_KEYBOARD);
        send(event, display);
    }

    private void scroll(ByteBuffer r, int display) {
        long now = SystemClock.uptimeMillis();
        properties[0].clear();
        properties[0].id = 0;
        properties[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
        coords[0].clear();
        coords[0].x = InputRecords.scrollX(r);
        coords[0].y = InputRecords.scrollY(r);
        coords[0].setAxisValue(MotionEvent.AXIS_HSCROLL, InputRecords.scrollHorizontal(r));
        coords[0].setAxisValue(MotionEvent.AXIS_VSCROLL, InputRecords.scrollVertical(r));
        MotionEvent event = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1, properties, coords, 0,
                InputRecords.scrollButtons(r), 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
        send(event, display);
        event.recycle();
    }

    private void mouse(ByteBuffer r, int display) {
        int action = InputRecords.mouseAction(r);
        long nowNanos = TouchProfile.nanos(SystemClock.uptimeMillis(), lastNanos, random);
        lastNanos = nowNanos;
        if (action == MotionEvent.ACTION_DOWN) downTimes.put(display, nowNanos);
        properties[0].clear();
        properties[0].id = 0;
        properties[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
        coords[0].clear();
        coords[0].x = InputRecords.mouseX(r);
        coords[0].y = InputRecords.mouseY(r);
        MotionEvent event = MotionEvent.obtain(downTimes.get(display, nowNanos) / 1_000_000L, nowNanos / 1_000_000L,
                action, 1, properties, coords, 0, InputRecords.mouseButtons(r), 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
        if (action == MotionEvent.ACTION_BUTTON_PRESS || action == MotionEvent.ACTION_BUTTON_RELEASE) {
            setActionButton(event, InputRecords.mouseActionButton(r));
        }
        send(event, display);
        event.recycle();
    }

    private void text(ByteBuffer r, int display) {
        String text = InputRecords.text(r);
        KeyEvent[] events = keyMap.getEvents(text.toCharArray());
        if (events != null) {
            for (KeyEvent event : events) send(event, display);
            return;
        }
        // Characters the virtual keyboard map cannot type (emoji, CJK) go as one
        // ACTION_MULTIPLE event, which text fields commit directly.
        long now = SystemClock.uptimeMillis();
        send(new KeyEvent(now, text, KeyCharacterMap.VIRTUAL_KEYBOARD, 0), display);
    }

    /** Lifts every pointer after the host disconnects (no stuck touches). */
    synchronized void cancelAll() {
        downTimes.clear();
        fingers.clear();
    }

    private void send(InputEvent event, int display) {
        try {
            if (setDisplayId != null && display > 0) setDisplayId.invoke(event, display);
            InputManagerGlobal.getInstance().injectInputEvent(event, INJECT_ASYNC);
        } catch (ReflectiveOperationException | RuntimeException e) {
            Log.w(Bridge.TAG, "inject failed", e);
        }
    }

    /**
     * A touch on the touchscreen's own device, with times at a digitizer's
     * nanosecond resolution. Without that constructor (hidden, and not every
     * runtime lets it be reached), MotionEvent.obtain keeps whole
     * milliseconds.
     */
    private MotionEvent obtainTouch(long downNanos, long eventNanos, int action, int count) {
        int deviceId = touchDeviceId();
        if (nanosMotionEvent != null) {
            try {
                // displayId 0: the display goes the way it always has, by
                // setDisplayId in send() — the constructor's order of its
                // five int parameters is nothing the types can say, so only
                // zeros go where a wrong slot would matter, and the fields
                // below check it understood the rest.
                MotionEvent event = (MotionEvent) nanosMotionEvent.newInstance(downNanos, eventNanos, action, count,
                        properties, coords, 0, 1f, 1f, deviceId, 0, InputDevice.SOURCE_TOUCHSCREEN, 0, 0);
                if (event.getDeviceId() == deviceId && event.getSource() == InputDevice.SOURCE_TOUCHSCREEN
                        && event.getEventTimeNanos() == eventNanos) {
                    return event;
                }
                event.recycle();
                warnNanosMotionEvent("constructor disagrees");
            } catch (ReflectiveOperationException | RuntimeException e) {
                warnNanosMotionEvent(String.valueOf(e));
            }
        }
        return MotionEvent.obtain(downNanos / 1_000_000L, eventNanos / 1_000_000L, action, count, properties, coords,
                0, 0, 1f, 1f, deviceId, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
    }

    private void warnNanosMotionEvent(String why) {
        if (warnedNanosMotionEvent) return;
        warnedNanosMotionEvent = true;
        Log.w(Bridge.TAG, "nanosecond MotionEvent unavailable (" + why + "); times stay milliseconds");
    }

    /**
     * The touch panel the touches belong to: the display's own touchscreen,
     * so an app asking the event's device finds a touch panel (a name like
     * fts_ts or goodix_ts) rather than the keyboard device id 0 stands for.
     * Looked for again from time to time until there is one (in the VM, the
     * panel may register late, or not at all: then id 0, as before).
     */
    private int touchDeviceId() {
        long now = SystemClock.uptimeMillis();
        if (touchDeviceId != Integer.MIN_VALUE && now - touchDeviceScanMs < 2000) return touchDeviceId;
        touchDeviceScanMs = now;
        touchDeviceId = 0;
        try {
            int[] ids = InputDevice.getDeviceIds();
            if (ids != null) {
                for (int id : ids) {
                    InputDevice device = InputDevice.getDevice(id);
                    if (device != null && !device.isVirtual()
                            && device.supportsSource(InputDevice.SOURCE_TOUCHSCREEN)) {
                        touchDeviceId = id;
                        break;
                    }
                }
            }
        } catch (RuntimeException e) {
            Log.w(Bridge.TAG, "cannot look for the touchscreen", e);
        }
        return touchDeviceId;
    }

    private static long fingerKey(int display, int pointerId) {
        return ((long) display << 8) | (pointerId & 0xFF);
    }

    private static float densityScale() {
        try {
            return Resources.getSystem().getDisplayMetrics().densityDpi / 420f;
        } catch (RuntimeException e) {
            return 1f;
        }
    }

    private static Constructor<MotionEvent> nanosMotionEvent() {
        try {
            Constructor<MotionEvent> constructor = MotionEvent.class.getDeclaredConstructor(long.class, long.class,
                    int.class, int.class, MotionEvent.PointerProperties[].class, MotionEvent.PointerCoords[].class,
                    int.class, float.class, float.class, int.class, int.class, int.class, int.class, int.class);
            constructor.setAccessible(true);
            return constructor;
        } catch (ReflectiveOperationException | RuntimeException e) {
            return null;
        }
    }

    private static void setActionButton(MotionEvent event, int button) {
        try {
            MotionEvent.class.getMethod("setActionButton", int.class).invoke(event, button); // @hide
        } catch (ReflectiveOperationException ignored) {
        }
    }
}

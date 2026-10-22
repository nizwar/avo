package com.avodroid.bridge.input;

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

import java.lang.reflect.Method;
import java.nio.ByteBuffer;

/** Turns Input channel records into injected events on the right display. */
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
    /** Gesture start time per Android display (MotionEvent downTime). */
    private final SparseLongArray downTimes = new SparseLongArray();
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

    void inject(int type, ByteBuffer record, int length) {
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
        long now = SystemClock.uptimeMillis();
        if (action == MotionEvent.ACTION_DOWN) downTimes.put(display, now);
        long downTime = downTimes.get(display, now);
        for (int i = 0; i < count; i++) {
            properties[i].clear();
            properties[i].id = InputRecords.pointerId(r, i);
            properties[i].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coords[i].clear();
            coords[i].x = InputRecords.pointerX(r, i);
            coords[i].y = InputRecords.pointerY(r, i);
            coords[i].pressure = InputRecords.pointerPressure(r, i);
            coords[i].size = 1;
        }
        int fullAction = action;
        if (action == MotionEvent.ACTION_POINTER_DOWN || action == MotionEvent.ACTION_POINTER_UP) {
            fullAction |= actionIndex << MotionEvent.ACTION_POINTER_INDEX_SHIFT;
        }
        MotionEvent event = MotionEvent.obtain(downTime, now, fullAction, count, properties, coords, 0, 0, 1f, 1f,
                0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
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
        long now = SystemClock.uptimeMillis();
        if (action == MotionEvent.ACTION_DOWN) downTimes.put(display, now);
        properties[0].clear();
        properties[0].id = 0;
        properties[0].toolType = MotionEvent.TOOL_TYPE_MOUSE;
        coords[0].clear();
        coords[0].x = InputRecords.mouseX(r);
        coords[0].y = InputRecords.mouseY(r);
        MotionEvent event = MotionEvent.obtain(downTimes.get(display, now), now, action, 1, properties, coords, 0,
                InputRecords.mouseButtons(r), 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
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
    void cancelAll() {
        downTimes.clear();
    }

    private void send(InputEvent event, int display) {
        try {
            if (setDisplayId != null && display > 0) setDisplayId.invoke(event, display);
            InputManagerGlobal.getInstance().injectInputEvent(event, INJECT_ASYNC);
        } catch (ReflectiveOperationException | RuntimeException e) {
            Log.w(Bridge.TAG, "inject failed", e);
        }
    }

    private static void setActionButton(MotionEvent event, int button) {
        try {
            MotionEvent.class.getMethod("setActionButton", int.class).invoke(event, button); // @hide
        } catch (ReflectiveOperationException ignored) {
        }
    }
}

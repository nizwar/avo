package com.avodroid.bridge.input;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/**
 * Field offsets of Input channel records (docs/protocol.md). Pure Java so the
 * layout can be checked against the host's encoder without Android
 * (test/InputRecordsTest.java reads proto/testdata/input-v1.bin, written by
 * the Swift tests). Buffers must be little-endian.
 */
public final class InputRecords {
    public static final int TOUCH = 0x01, KEY = 0x02, SCROLL = 0x03, TEXT = 0x04, MOUSE = 0x05, GAMEPAD = 0x06, PING = 0x7F;

    private InputRecords() {}

    public static int type(ByteBuffer r) { return r.get(0) & 0xFF; }
    public static int length(ByteBuffer r) { return r.getShort(2) & 0xFFFF; }
    public static int displayId(ByteBuffer r) { return r.getInt(4); }

    // TOUCH
    public static int touchAction(ByteBuffer r) { return r.get(8) & 0xFF; }
    public static int touchActionIndex(ByteBuffer r) { return r.get(9) & 0xFF; }
    public static int touchPointerCount(ByteBuffer r) { return r.get(10) & 0xFF; }
    public static int pointerId(ByteBuffer r, int i) { return r.getInt(16 + i * 16); }
    public static float pointerX(ByteBuffer r, int i) { return r.getFloat(20 + i * 16); }
    public static float pointerY(ByteBuffer r, int i) { return r.getFloat(24 + i * 16); }
    public static float pointerPressure(ByteBuffer r, int i) { return r.getFloat(28 + i * 16); }

    // KEY
    public static boolean keyDown(ByteBuffer r) { return (r.get(8) & 0xFF) == 0; }
    public static int keyCode(ByteBuffer r) { return r.getInt(12); }
    public static int keyMetaState(ByteBuffer r) { return r.getInt(16); }
    public static int keyRepeat(ByteBuffer r) { return r.getInt(20); }
    public static int keyScanCode(ByteBuffer r) { return r.getInt(24); }

    // SCROLL
    public static float scrollX(ByteBuffer r) { return r.getFloat(8); }
    public static float scrollY(ByteBuffer r) { return r.getFloat(12); }
    public static float scrollHorizontal(ByteBuffer r) { return r.getFloat(16); }
    public static float scrollVertical(ByteBuffer r) { return r.getFloat(20); }
    public static int scrollButtons(ByteBuffer r) { return r.getInt(24); }

    // TEXT
    public static String text(ByteBuffer r) {
        int count = r.getShort(8) & 0xFFFF;
        return new String(r.array(), r.arrayOffset() + 10, count, StandardCharsets.UTF_8);
    }

    // MOUSE
    public static int mouseAction(ByteBuffer r) { return r.get(8) & 0xFF; }
    public static float mouseX(ByteBuffer r) { return r.getFloat(12); }
    public static float mouseY(ByteBuffer r) { return r.getFloat(16); }
    public static int mouseButtons(ByteBuffer r) { return r.getInt(20); }
    public static int mouseActionButton(ByteBuffer r) { return r.getInt(24); }

    // GAMEPAD
    public static int gamepadIndex(ByteBuffer r) { return r.get(8) & 0xFF; }
    public static boolean gamepadConnected(ByteBuffer r) { return r.get(9) != 0; }
    public static int gamepadButtons(ByteBuffer r) { return r.getInt(12); }
    public static float gamepadAxis(ByteBuffer r, int axis) { return r.getFloat(16 + axis * 4); }

    // PING
    public static long pingToken(ByteBuffer r) { return r.getLong(8); }
}

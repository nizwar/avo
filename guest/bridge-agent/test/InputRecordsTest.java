import com.avodroid.bridge.input.InputRecords;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Decodes proto/testdata/input-v1.bin, written by the host's Swift encoder
 * (InputWireTests.goldenFileMatchesEncoding), with the accessors the injector
 * uses. Plain JVM, no Android: run by build.sh.
 */
public final class InputRecordsTest {
    private static int failures;

    private static void check(String what, Object actual, Object expected) {
        if (!actual.equals(expected)) {
            failures++;
            System.err.println("FAIL " + what + ": expected " + expected + ", got " + actual);
        }
    }

    public static void main(String[] args) throws Exception {
        byte[] bytes = Files.readAllBytes(Path.of(args[0]));
        ByteBuffer all = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        int offset = 0;
        int index = 0;
        while (offset < bytes.length) {
            ByteBuffer r = ByteBuffer.wrap(bytes, offset, bytes.length - offset).slice().order(ByteOrder.LITTLE_ENDIAN);
            int length = InputRecords.length(r);
            switch (index) {
                case 0 -> {
                    check("0 type", InputRecords.type(r), InputRecords.TOUCH);
                    check("0 display", InputRecords.displayId(r), 2);
                    check("0 action", InputRecords.touchAction(r), 0);
                    check("0 count", InputRecords.touchPointerCount(r), 1);
                    check("0 x", InputRecords.pointerX(r, 0), 10.5f);
                    check("0 y", InputRecords.pointerY(r, 0), 20.25f);
                    check("0 pressure", InputRecords.pointerPressure(r, 0), 1f);
                }
                case 1 -> {
                    check("1 action", InputRecords.touchAction(r), 5);
                    check("1 index", InputRecords.touchActionIndex(r), 1);
                    check("1 count", InputRecords.touchPointerCount(r), 2);
                    check("1 id", InputRecords.pointerId(r, 1), 4);
                    check("1 x", InputRecords.pointerX(r, 1), 300f);
                    check("1 pressure", InputRecords.pointerPressure(r, 1), 0.5f);
                }
                case 2 -> {
                    check("2 type", InputRecords.type(r), InputRecords.KEY);
                    check("2 display", InputRecords.displayId(r), 5);
                    check("2 down", InputRecords.keyDown(r), true);
                    check("2 code", InputRecords.keyCode(r), 111);
                    check("2 meta", InputRecords.keyMetaState(r), 0x1000);
                    check("2 repeat", InputRecords.keyRepeat(r), 2);
                    check("2 scan", InputRecords.keyScanCode(r), 1);
                }
                case 3 -> {
                    check("3 type", InputRecords.type(r), InputRecords.SCROLL);
                    check("3 x", InputRecords.scrollX(r), 100f);
                    check("3 y", InputRecords.scrollY(r), 200f);
                    check("3 h", InputRecords.scrollHorizontal(r), -0.5f);
                    check("3 v", InputRecords.scrollVertical(r), 2f);
                }
                case 4 -> {
                    check("4 type", InputRecords.type(r), InputRecords.TEXT);
                    check("4 text", InputRecords.text(r), "Halo, dunia! 🥑");
                }
                case 5 -> {
                    check("5 type", InputRecords.type(r), InputRecords.MOUSE);
                    check("5 action", InputRecords.mouseAction(r), 11);
                    check("5 x", InputRecords.mouseX(r), 1f);
                    check("5 y", InputRecords.mouseY(r), 2f);
                    check("5 buttons", InputRecords.mouseButtons(r), 2);
                    check("5 actionButton", InputRecords.mouseActionButton(r), 2);
                }
                case 6 -> {
                    check("6 type", InputRecords.type(r), InputRecords.GAMEPAD);
                    check("6 pad", InputRecords.gamepadIndex(r), 1);
                    check("6 connected", InputRecords.gamepadConnected(r), true);
                    check("6 buttons", InputRecords.gamepadButtons(r), 0b1011);
                    check("6 axis1", InputRecords.gamepadAxis(r, 1), -0.2f);
                    check("6 axis6", InputRecords.gamepadAxis(r, 6), -1f);
                }
                case 7 -> {
                    check("7 type", InputRecords.type(r), InputRecords.PING);
                    check("7 token", InputRecords.pingToken(r), 0xDEADBEEFCAFEL);
                }
                default -> check("record count", index, 7);
            }
            offset += length;
            index++;
        }
        check("records", index, 8);
        check("consumed", offset, all.capacity());
        if (failures > 0) {
            System.err.println(failures + " input layout check(s) failed");
            System.exit(1);
        }
        System.out.println("input layout matches the host encoder (" + index + " records)");
    }
}

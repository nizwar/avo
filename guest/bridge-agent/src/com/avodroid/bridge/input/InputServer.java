package com.avodroid.bridge.input;

import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.util.Log;

import com.avodroid.bridge.Bridge;
import com.avodroid.bridge.Protocol;
import com.avodroid.bridge.display.DisplayController;
import com.avodroid.bridge.io.ListenBackoff;
import com.avodroid.bridge.io.Vsock;

import java.io.DataInputStream;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Input channel (vsock 6001): fixed-layout records decoded into a reused
 * buffer, so a 1000 Hz mouse never allocates on this thread.
 */
public final class InputServer {
    private static final byte[] MAGIC = {'A', 'V', 'O', 'I'};
    private final InputInjector injector;

    public InputServer(DisplayController displays) {
        injector = new InputInjector(displays);
    }

    public void start() {
        Thread thread = new Thread(this::acceptLoop, "avo-input");
        thread.setDaemon(true);
        thread.start();
    }

    private void acceptLoop() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY);
        ListenBackoff backoff = new ListenBackoff(Bridge.TAG, "input server");
        while (true) {
            try (ParcelFileDescriptor listener = Vsock.listen(Protocol.PORT_INPUT)) {
                while (true) {
                    try (ParcelFileDescriptor socket = Vsock.accept(listener)) {
                        backoff.accepted();
                        Vsock.setLowLatency(socket);
                        serve(socket);
                    } catch (IOException e) {
                        Log.i(Bridge.TAG, "input session ended: " + e.getMessage());
                    }
                    injector.cancelAll();
                }
            } catch (IOException e) {
                if (!backoff.failed(e)) return;
            }
        }
    }

    private void serve(ParcelFileDescriptor socket) throws IOException {
        // The streams borrow the descriptor; the caller's try-with-resources closes the socket.
        DataInputStream in = new DataInputStream(new FileInputStream(socket.getFileDescriptor()));
        OutputStream out = new FileOutputStream(socket.getFileDescriptor());
        byte[] preamble = new byte[8];
        in.readFully(preamble);
        for (int i = 0; i < 4; i++) if (preamble[i] != MAGIC[i]) throw new IOException("bad input preamble");
        ByteBuffer reply = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN);
        reply.put(MAGIC).putShort((short) Protocol.INPUT_VERSION).putShort((short) 0);
        out.write(reply.array());
        out.flush();

        byte[] bytes = new byte[Protocol.INPUT_MAX_RECORD];
        ByteBuffer record = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        boolean warned = false;
        while (true) {
            in.readFully(bytes, 0, 8);
            int length = InputRecords.length(record);
            if (length < 8 || length > bytes.length) throw new IOException("bad input record length " + length);
            in.readFully(bytes, 8, length - 8);
            int type = InputRecords.type(record);
            if (type == InputRecords.PING) {
                out.write(bytes, 0, length); // echo for latency measurement
                out.flush();
                continue;
            }
            try {
                injector.inject(type, record, length);
            } catch (RuntimeException e) {
                // A record the framework refuses (no pointers, a text count past the
                // record) is skipped: uncaught on this thread, it would kill the agent.
                if (!warned) Log.w(Bridge.TAG, "input record skipped", e);
                warned = true;
            }
        }
    }
}

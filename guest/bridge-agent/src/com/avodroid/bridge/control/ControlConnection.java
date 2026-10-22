package com.avodroid.bridge.control;

import android.os.ParcelFileDescriptor;
import android.util.Log;

import com.google.protobuf.CodedInputStream;

import com.avodroid.bridge.Bridge;
import com.avodroid.bridge.Protocol;
import com.avodroid.bridge.proto.Envelope;
import com.avodroid.bridge.proto.Goodbye;
import com.avodroid.bridge.proto.Hello;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;

/**
 * One Control session: length-delimited Envelopes in both directions.
 * The first message each way is Hello; the agreed version is the lower of the
 * two as long as both sides still accept it.
 */
public final class ControlConnection {
    private final Bridge bridge;
    private final ParcelFileDescriptor socket;
    private final InputStream in;
    private final OutputStream out;
    private final RequestHandler handler;
    private volatile boolean helloDone;
    private volatile boolean closed;
    private int version;

    ControlConnection(Bridge bridge, ParcelFileDescriptor socket) {
        this.bridge = bridge;
        this.socket = socket;
        this.in = new BufferedInputStream(new ParcelFileDescriptor.AutoCloseInputStream(socket), 64 * 1024);
        this.out = new BufferedOutputStream(new ParcelFileDescriptor.AutoCloseOutputStream(socket), 64 * 1024);
        this.handler = new RequestHandler(bridge, this);
    }

    void start() {
        Thread thread = new Thread(this::readLoop, "avo-control");
        thread.setDaemon(true);
        thread.start();
    }

    private void readLoop() {
        try {
            while (!closed) {
                int first = in.read();
                if (first < 0) break;
                int length = CodedInputStream.readRawVarint32(first, in);
                if (length < 0 || length > Protocol.MAX_FRAME) throw new IOException("bad frame length " + length);
                byte[] body = in.readNBytes(length);
                if (body.length != length) break;
                Envelope envelope = Envelope.parseFrom(body);
                if (!helloDone) {
                    handshake(envelope);
                } else {
                    handler.handle(envelope);
                }
            }
        } catch (Exception e) {
            if (!closed) Log.w(Bridge.TAG, "control session ended", e);
        } finally {
            close();
        }
    }

    private void handshake(Envelope envelope) throws IOException {
        if (envelope.getPayloadCase() != Envelope.PayloadCase.HELLO) {
            throw new IOException("expected Hello, got " + envelope.getPayloadCase());
        }
        Hello host = envelope.getHello();
        Hello mine = bridge.hello();
        int agreed = Math.min(host.getProtocolVersion(), mine.getProtocolVersion());
        if (agreed < host.getMinProtocolVersion() || agreed < mine.getMinProtocolVersion()) {
            String message = agreed < mine.getMinProtocolVersion()
                    ? "This Android image needs Avo protocol " + mine.getMinProtocolVersion() + "; update Avo."
                    : "Avo needs a newer Android image (protocol " + host.getMinProtocolVersion() + ").";
            write(Envelope.newBuilder().setGoodbye(Goodbye.newBuilder()
                    .setReason(Goodbye.Reason.REASON_INCOMPATIBLE_VERSION).setMessage(message)));
            throw new IOException(message);
        }
        version = agreed;
        helloDone = true;
        write(Envelope.newBuilder().setHello(mine));
        Log.i(Bridge.TAG, "control session up: " + host.getSoftwareVersion() + ", protocol " + version);
    }

    /** Replies to a request (same request id). */
    void reply(Envelope request, Envelope.Builder response) {
        write(response.setRequestId(request.getRequestId()));
    }

    void sendEvent(Envelope.Builder event) {
        if (helloDone) write(event.setRequestId(0));
    }

    private synchronized void write(Envelope.Builder envelope) {
        if (closed) return;
        try {
            envelope.setProtocolVersion(version == 0 ? Protocol.VERSION : version).build().writeDelimitedTo(out);
            out.flush();
        } catch (IOException e) {
            Log.w(Bridge.TAG, "control write failed", e);
            close();
        }
    }

    void close() {
        if (closed) return;
        closed = true;
        // Each connection has its own pool, whose idle threads would otherwise outlive it.
        handler.shutdown();
        try {
            socket.close();
        } catch (IOException ignored) {
        }
    }
}

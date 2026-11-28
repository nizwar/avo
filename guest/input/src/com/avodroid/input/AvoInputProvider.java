package com.avodroid.input;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import org.json.JSONObject;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.ArrayBlockingQueue;

/** The authenticated ADB connection opens one bidirectional socket for the lifetime of the keyboard bridge. */
public final class AvoInputProvider extends ContentProvider {
    static final Handler main = new Handler(Looper.getMainLooper());
    // Only the main thread installs a peer or publishes a snapshot.
    private static Peer peer;
    private LocalServerSocket listener;
    private final String address = "avo-input-" + UUID.randomUUID();

    @Override public boolean onCreate() { return true; }

    @Override public synchronized Bundle call(String method, String arg, Bundle extras) {
        int uid = Binder.getCallingUid();
        if (uid != Process.SHELL_UID && uid != Process.ROOT_UID) throw new SecurityException("shell only");
        if (!"connect".equals(method)) throw new IllegalArgumentException("unknown command");
        if (listener == null) {
            try {
                listener = new LocalServerSocket(address);
                new Thread(this::accept, "Avo Input connections").start();
            } catch (IOException e) { throw new IllegalStateException(e); }
        }
        Bundle reply = new Bundle();
        reply.putString("socket", address);
        return reply;
    }

    private void accept() {
        try {
            while (true) {
                LocalSocket socket = listener.accept();
                int uid = socket.getPeerCredentials().getUid();
                if (uid != Process.SHELL_UID && uid != Process.ROOT_UID) { socket.close(); continue; }
                Peer next = new Peer(socket);
                main.post(() -> {
                    if (peer != null) {
                        peer.close();
                        AvoInputService.disconnected();
                    }
                    peer = next;
                    next.start();
                    AvoInputService.connected();
                });
            }
        } catch (IOException ignored) {}
    }

    static void publish(JSONObject state) {
        if (peer != null) peer.publish(state.toString());
    }

    private static final class Peer {
        final LocalSocket socket;
        final ArrayBlockingQueue<String> outgoing = new ArrayBlockingQueue<>(8);
        final Thread writer;
        volatile boolean closed;

        Peer(LocalSocket socket) {
            this.socket = socket;
            writer = new Thread(this::write, "Avo Input state");
        }

        void start() {
            writer.start();
            new Thread(this::read, "Avo Input edits").start();
        }

        void publish(String state) {
            // A slow or disconnected host must never block Android's input-method thread.
            if (!outgoing.offer(state)) close();
        }

        void read() {
            try (DataInputStream in = new DataInputStream(socket.getInputStream())) {
                while (!closed) {
                    int length = in.readInt();
                    if (length <= 0 || length > 8 * 1024 * 1024) break;
                    byte[] bytes = new byte[length];
                    in.readFully(bytes);
                    JSONObject edit = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
                    main.post(() -> { if (peer == this && !closed) AvoInputService.receive(edit); });
                }
            } catch (Exception ignored) {
                // A new connection starts a new session. Never log typed text.
            } finally { close(); }
        }

        void write() {
            try (DataOutputStream out = new DataOutputStream(socket.getOutputStream())) {
                while (!closed) {
                    byte[] bytes = outgoing.take().getBytes(StandardCharsets.UTF_8);
                    out.writeInt(bytes.length);
                    out.write(bytes);
                    out.flush();
                }
            } catch (IOException | InterruptedException ignored) {
            } finally { close(); }
        }

        synchronized void close() {
            if (closed) return;
            closed = true;
            writer.interrupt();
            try { socket.close(); } catch (IOException ignored) {}
            main.post(() -> {
                if (peer == this) { peer = null; AvoInputService.disconnected(); }
            });
        }
    }

    @Override public String getType(Uri uri) { return null; }
    @Override public Cursor query(Uri uri, String[] fields, String filter, String[] args, String order) { throw new UnsupportedOperationException(); }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { throw new UnsupportedOperationException(); }
}

package com.avodroid.bridge.control;

import android.os.ParcelFileDescriptor;

import com.avodroid.bridge.Bridge;
import com.avodroid.bridge.Protocol;
import com.avodroid.bridge.io.ListenBackoff;
import com.avodroid.bridge.io.Vsock;
import com.avodroid.bridge.proto.Envelope;

/**
 * Accepts the daemon's Control connections on vsock 6000. A new connection
 * replaces the old one (the daemon reconnects after restarts and snapshot
 * restores).
 */
public final class ControlServer {
    private final Bridge bridge;
    private volatile ControlConnection current;

    public ControlServer(Bridge bridge) {
        this.bridge = bridge;
    }

    public void start() {
        Thread thread = new Thread(this::acceptLoop, "avo-control-accept");
        thread.setDaemon(true);
        thread.start();
    }

    private void acceptLoop() {
        ListenBackoff backoff = new ListenBackoff(Bridge.TAG, "control server");
        while (true) {
            try (ParcelFileDescriptor listener = Vsock.listen(Protocol.PORT_CONTROL)) {
                while (true) {
                    ParcelFileDescriptor socket = Vsock.accept(listener);
                    backoff.accepted();
                    ControlConnection connection = new ControlConnection(bridge, socket);
                    ControlConnection previous = current;
                    current = connection;
                    if (previous != null) previous.close();
                    connection.start();
                }
            } catch (Exception e) {
                if (!backoff.failed(e)) return;
            }
        }
    }

    /** Sends an event on the current session, if any. */
    public void send(Envelope.Builder event) {
        ControlConnection connection = current;
        if (connection != null) connection.sendEvent(event);
    }
}

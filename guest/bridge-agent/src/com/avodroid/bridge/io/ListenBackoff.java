package com.avodroid.bridge.io;

import android.util.Log;

/**
 * Retries for a vsock server whose listener fails (no vsock device, the port
 * taken): each new error is logged once, and the wait grows from one second
 * to four. A connection accepted again starts both over.
 */
public final class ListenBackoff {
    private static final long FIRST_MS = 1000;
    private static final long MAX_MS = 4000;
    private final String tag;
    private final String what;
    private long delayMs = FIRST_MS;
    private String lastError;

    public ListenBackoff(String tag, String what) {
        this.tag = tag;
        this.what = what;
    }

    /** The server works again: the next failure is logged and retried after a second. */
    public void accepted() {
        delayMs = FIRST_MS;
        lastError = null;
    }

    /** Logs `error` unless it repeats the last one, then waits. False when interrupted. */
    public boolean failed(Exception error) {
        String text = String.valueOf(error);
        if (!text.equals(lastError)) Log.e(tag, what + " error; retrying", error);
        lastError = text;
        try {
            Thread.sleep(delayMs);
        } catch (InterruptedException e) {
            return false;
        }
        delayMs = Math.min(delayMs * 2, MAX_MS);
        return true;
    }
}

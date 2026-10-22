package com.avodroid.bridge.clip;

import android.content.ClipData;
import android.content.ClipboardManager;

import com.avodroid.bridge.Bridge;
import com.avodroid.bridge.proto.ClipboardChanged;
import com.avodroid.bridge.proto.Envelope;

/** Two-way clipboard sync (spec: "Clipboard tersinkron dua arah"). */
public final class ClipboardBridge {
    private final Bridge bridge;
    private ClipboardManager clipboard;
    /** Text the Mac sent last, so it is not echoed back. */
    private String fromHost;

    public ClipboardBridge(Bridge bridge) {
        this.bridge = bridge;
    }

    public void start() {
        clipboard = bridge.context.getSystemService(ClipboardManager.class);
        clipboard.addPrimaryClipChangedListener(this::changed);
    }

    private void changed() {
        ClipData clip = clipboard.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) return;
        CharSequence text = clip.getItemAt(0).coerceToText(bridge.context);
        if (text == null || text.length() == 0) return;
        String value = text.toString();
        if (value.equals(fromHost)) return;
        bridge.send(Envelope.newBuilder().setClipboardChanged(ClipboardChanged.newBuilder().setText(value)));
    }

    public void set(String text) {
        fromHost = text;
        clipboard.setPrimaryClip(ClipData.newPlainText("Mac", text));
    }
}

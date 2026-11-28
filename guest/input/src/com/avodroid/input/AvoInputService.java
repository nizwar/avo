package com.avodroid.input;

import android.inputmethodservice.InputMethodService;
import android.os.Handler;
import android.os.HandlerThread;
import android.text.InputType;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputBinding;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.SurroundingText;
import org.json.JSONException;
import org.json.JSONObject;
import java.util.UUID;

/** Forwards host composition to the active Android editor through its InputConnection. */
public final class AvoInputService extends InputMethodService {
    private static AvoInputService active;
    private final HandlerThread contextThread = new HandlerThread("Avo Input editor context");
    private Handler contextReader;
    private String session;
    private boolean attached;
    private int start, end, markStart, markEnd;
    private long ack, revision;

    @Override public void onCreate() {
        super.onCreate();
        contextThread.start();
        contextReader = new Handler(contextThread.getLooper());
    }

    @Override public boolean onEvaluateInputViewShown() { return false; }
    @Override public boolean onEvaluateFullscreenMode() { return false; }

    @Override public void onStartInput(EditorInfo info, boolean restarting) {
        super.onStartInput(info, restarting);
        active = this;
        start = info.initialSelStart;
        end = info.initialSelEnd;
        markStart = markEnd = -1;
        newSession();
    }

    @Override public void onFinishInput() {
        if (active == this) { active = null; connected(); }
        attached = false;
        session = null;
        revision++;
        super.onFinishInput();
    }

    @Override public void onDestroy() {
        if (active == this) { active = null; connected(); }
        contextThread.quitSafely();
        super.onDestroy();
    }

    static void connected() {
        if (active == null) AvoInputProvider.publish(object("kind", "focus"));
        else active.newSession();
    }

    static void disconnected() {
        if (active != null) {
            active.attached = false;
            InputConnection connection = active.getCurrentInputConnection();
            if (connection != null) connection.finishComposingText();
            active.markStart = active.markEnd = -1;
        }
    }

    private void newSession() {
        attached = false;
        ack = 0;
        revision++;
        session = UUID.randomUUID().toString();
        EditorInfo info = getCurrentInputEditorInfo();
        InputBinding binding = getCurrentInputBinding();
        if (binding == null || info == null || info.inputType == InputType.TYPE_NULL) {
            AvoInputProvider.publish(object("kind", "focus"));
            return;
        }
        AvoInputProvider.publish(object("kind", "focus", "session", session, "pid", binding.getPid(), "package", info.packageName));
    }

    static void receive(JSONObject edit) {
        AvoInputService ime = active;
        if (ime == null || !edit.optString("session").equals(ime.session)) return;
        InputConnection connection = ime.getCurrentInputConnection();
        if (connection == null) return;
        if ("attach".equals(edit.optString("action"))) {
            ime.attached = true;
            ime.publish();
            return;
        }
        long sequence = edit.optLong("sequence", -1);
        if (!ime.attached || sequence != ime.ack + 1) return;
        ime.ack = sequence;
        connection.beginBatchEdit();
        try {
            ime.apply(connection, edit);
        } finally {
            connection.endBatchEdit();
        }
        ime.publish();
    }

    private void apply(InputConnection c, JSONObject edit) {
        String action = edit.optString("action");
        if ("finish".equals(action)) {
            c.finishComposingText();
            markStart = markEnd = -1;
            return;
        }
        if ("cancel".equals(action)) {
            if (markStart >= 0) { c.setComposingText("", 1); start = end = markStart; }
            c.finishComposingText();
            markStart = markEnd = -1;
            return;
        }
        if (!"commit".equals(action) && !"mark".equals(action)) return;
        String text = edit.optString("text");
        int from = edit.optInt("from", -1), to = edit.optInt("to", -1);
        int anchor = markStart >= 0 ? markStart : Math.min(start, end);
        if (from >= 0) {
            if (to < from || !c.finishComposingText() || !c.setSelection(from, to)) return;
            anchor = from;
        }
        if ("commit".equals(action)) {
            if (c.commitText(text, 1) && anchor >= 0) start = end = anchor + text.length();
            markStart = markEnd = -1;
        } else if (c.setComposingText(text, 1)) {
            if (text.isEmpty()) { c.finishComposingText(); markStart = markEnd = -1; }
            else if (anchor >= 0) { markStart = anchor; markEnd = anchor + text.length(); }
            if (anchor < 0) return;
            int a = edit.optInt("caretStart", text.length()), b = edit.optInt("caretEnd", a);
            start = anchor + Math.max(0, Math.min(text.length(), a));
            end = anchor + Math.max(0, Math.min(text.length(), b));
            if (start != anchor + text.length() || end != start) c.setSelection(start, end);
        }
    }

    @Override public void onUpdateSelection(int oldStart, int oldEnd, int newStart, int newEnd, int candidatesStart, int candidatesEnd) {
        super.onUpdateSelection(oldStart, oldEnd, newStart, newEnd, candidatesStart, candidatesEnd);
        if (start == newStart && end == newEnd && markStart == candidatesStart && markEnd == candidatesEnd) return;
        start = newStart; end = newEnd; markStart = candidatesStart; markEnd = candidatesEnd;
        if (attached) publish();
    }

    private JSONObject state() {
        return object("kind", "state", "session", session, "ack", ack, "start", start, "end", end,
                "markStart", markStart, "markEnd", markEnd, "privateEditor", privateEditor(getCurrentInputEditorInfo()));
    }

    private void publish() {
        long version = ++revision;
        AvoInputProvider.publish(state());
        EditorInfo info = getCurrentInputEditorInfo();
        InputConnection connection = getCurrentInputConnection();
        if (connection == null || info == null || privateEditor(info)) return;
        // An editor may be busy. Fetch reconversion context off the IME thread and discard late replies.
        contextReader.removeCallbacksAndMessages(null);
        contextReader.post(() -> {
            SurroundingText context = connection.getSurroundingText(512, 512, 0);
            if (context == null || context.getOffset() < 0 || context.getText().length() > 2048) return;
            AvoInputProvider.main.post(() -> {
                if (!attached || active != this || revision != version) return;
                JSONObject snapshot = state();
                try {
                    snapshot.put("text", context.getText().toString());
                    snapshot.put("offset", context.getOffset());
                    snapshot.put("start", context.getOffset() + context.getSelectionStart());
                    snapshot.put("end", context.getOffset() + context.getSelectionEnd());
                } catch (JSONException impossible) { throw new AssertionError(impossible); }
                AvoInputProvider.publish(snapshot);
            });
        });
    }

    private static boolean privateEditor(EditorInfo info) {
        if (info == null) return true;
        int type = info.inputType & (InputType.TYPE_MASK_CLASS | InputType.TYPE_MASK_VARIATION);
        return type == (InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD)
                || type == (InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD)
                || type == (InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)
                || type == (InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD)
                || (info.imeOptions & EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING) != 0;
    }

    private static JSONObject object(Object... pairs) {
        JSONObject value = new JSONObject();
        try {
            for (int i = 0; i < pairs.length; i += 2) value.put((String) pairs[i], pairs[i + 1]);
        } catch (JSONException impossible) { throw new AssertionError(impossible); }
        return value;
    }
}

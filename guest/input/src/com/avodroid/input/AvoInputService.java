package com.avodroid.input;

import android.inputmethodservice.InputMethodService;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;
import android.text.InputType;
import android.util.SparseLongArray;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputBinding;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.SurroundingText;
import org.json.JSONException;
import org.json.JSONObject;
import java.util.UUID;

/** Forwards host composition to the active Android editor through its InputConnection. */
public final class AvoInputService extends InputMethodService {
    private static final int MAX_CONTEXT_LENGTH = 2048;
    private static AvoInputService active;
    private final HandlerThread contextThread = new HandlerThread("Avo Input editor context");
    private Handler contextReader;
    private String session;
    private boolean attached;
    private boolean composing;
    private boolean keyPending;
    private final SparseLongArray keyDownTimes = new SparseLongArray();
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
        composing = false;
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
            active.composing = false;
            active.markStart = active.markEnd = -1;
        }
    }

    private void newSession() {
        attached = false;
        keyPending = false;
        keyDownTimes.clear();
        ack = 0;
        revision++;
        session = UUID.randomUUID().toString();
        EditorInfo info = getCurrentInputEditorInfo();
        InputBinding binding = getCurrentInputBinding();
        if (info == null || info.inputType == InputType.TYPE_NULL || getCurrentInputConnection() == null) {
            AvoInputProvider.publish(object("kind", "focus"));
            return;
        }
        // Android can start an editor with a live InputConnection and no InputBinding.
        AvoInputProvider.publish(binding != null
                ? object("kind", "focus", "session", session, "pid", binding.getPid())
                : object("kind", "focus", "session", session, "package", info.packageName));
    }

    static void receive(JSONObject edit) {
        AvoInputService ime = active;
        if (ime == null || !edit.optString("session").equals(ime.session)) return;
        InputConnection connection = ime.getCurrentInputConnection();
        if (connection == null) return;
        String action = edit.optString("action");
        if ("attach".equals(action)) {
            ime.attached = true;
            ime.publish();
            return;
        }
        long sequence = edit.optLong("sequence", -1);
        if (!ime.attached || ime.keyPending || sequence != ime.ack + 1) return;
        ime.ack = sequence;
        if ("keyDown".equals(action) || "keyUp".equals(action)) {
            ime.sendKey(connection, edit, "keyDown".equals(action));
            return;
        }
        connection.beginBatchEdit();
        try {
            ime.apply(connection, edit);
        } finally {
            connection.endBatchEdit();
        }
        ime.publish();
    }

    private void sendKey(InputConnection connection, JSONObject edit, boolean down) {
        int code = edit.optInt("keyCode", KeyEvent.KEYCODE_UNKNOWN);
        if (code <= KeyEvent.KEYCODE_UNKNOWN || code > KeyEvent.getMaxKeyCode()) {
            publish();
            return;
        }
        int repeat = edit.optInt("repeatCount", 0);
        long now = SystemClock.uptimeMillis();
        long pressed = down && repeat == 0 ? now : keyDownTimes.get(code, now);
        if (down) keyDownTimes.put(code, pressed); else keyDownTimes.delete(code);
        connection.sendKeyEvent(new KeyEvent(pressed, now, down ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP,
                code, repeat, edit.optInt("metaState"), KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_SOFT_KEYBOARD | KeyEvent.FLAG_KEEP_TOUCH_MODE));
        // sendKeyEvent only queues the key. Wait for the editor to handle a cursor request
        // on the same connection before acknowledging it, even when its UI thread is busy.
        String current = session;
        keyPending = true;
        revision++;
        contextReader.removeCallbacksAndMessages(null);
        contextReader.post(() -> {
            connection.requestCursorUpdates(InputConnection.CURSOR_UPDATE_IMMEDIATE,
                    InputConnection.CURSOR_UPDATE_FILTER_INSERTION_MARKER);
            AvoInputProvider.main.post(() -> {
                if (!attached || !current.equals(session)) return;
                keyPending = false;
                publish();
            });
        });
    }

    private void apply(InputConnection c, JSONObject edit) {
        String action = edit.optString("action");
        if ("finish".equals(action)) {
            c.finishComposingText();
            composing = false;
            markStart = markEnd = -1;
            return;
        }
        if ("cancel".equals(action)) {
            if (composing && c.setComposingText("", 1)) start = end = markStart;
            c.finishComposingText();
            composing = false;
            markStart = markEnd = -1;
            return;
        }
        if (!"commit".equals(action) && !"mark".equals(action)) return;
        String text = edit.optString("text");
        int from = edit.optInt("from", -1), to = edit.optInt("to", -1);
        int anchor = composing ? markStart : Math.min(start, end);
        if (from >= 0) {
            if (to < from || !c.finishComposingText()) return;
            composing = false;
            markStart = markEnd = -1;
            if (!c.setSelection(from, to)) return;
            anchor = from;
        }
        if ("commit".equals(action)) {
            if (!c.commitText(text, 1)) return;
            if (anchor >= 0) start = end = anchor + text.length();
            composing = false;
            markStart = markEnd = -1;
        } else if (c.setComposingText(text, 1)) {
            // A custom editor may accept composing text without reporting its selection.
            composing = !text.isEmpty();
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
        composing = candidatesStart >= 0;
        if (attached) publish();
    }

    private JSONObject state() {
        return object("kind", "state", "session", session, "ack", ack, "start", start, "end", end,
                "markStart", markStart, "markEnd", markEnd, "privateEditor", privateEditor(getCurrentInputEditorInfo()));
    }

    private void publish() {
        if (keyPending) return;
        long version = ++revision;
        AvoInputProvider.publish(state());
        EditorInfo info = getCurrentInputEditorInfo();
        InputConnection connection = getCurrentInputConnection();
        contextReader.removeCallbacksAndMessages(null);
        if (connection == null || info == null || privateEditor(info)) return;
        // Android includes the entire selection in addition to the text requested on each side.
        int selected = start >= 0 && end >= 0 ? Math.abs(end - start) : 0;
        if (selected > MAX_CONTEXT_LENGTH) return;
        int side = Math.min(512, (MAX_CONTEXT_LENGTH - selected) / 2);
        // An editor may be busy. Fetch reconversion context off the IME thread and discard late replies.
        contextReader.post(() -> {
            SurroundingText context = connection.getSurroundingText(side, side, 0);
            if (context == null || context.getOffset() < 0 || context.getText().length() > MAX_CONTEXT_LENGTH) return;
            AvoInputProvider.main.post(() -> {
                if (!attached || active != this || revision != version) return;
                // Some editors provide their first absolute selection with the surrounding text.
                start = context.getOffset() + context.getSelectionStart();
                end = context.getOffset() + context.getSelectionEnd();
                JSONObject snapshot = state();
                try {
                    snapshot.put("text", context.getText().toString());
                    snapshot.put("offset", context.getOffset());
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

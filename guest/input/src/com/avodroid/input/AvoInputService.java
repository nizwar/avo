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
import java.util.function.Consumer;
import java.util.function.Supplier;

/** Forwards host composition to the active Android editor through its InputConnection. */
public final class AvoInputService extends InputMethodService {
    private static final int MAX_CONTEXT_LENGTH = 2048;
    private static AvoInputService active;
    private final HandlerThread contextThread = new HandlerThread("Avo Input editor context");
    private Handler contextReader;
    private String session;
    private boolean attached;
    private boolean composing;
    private boolean selectionReported;
    private boolean editPending;
    private final SparseLongArray keyDownTimes = new SparseLongArray();
    private int start, end, markStart, markEnd;
    private long ack, revision, markSequence;
    private int generation;

    @Override public void onCreate() {
        super.onCreate();
        contextThread.start();
        contextReader = new Handler(contextThread.getLooper());
    }

    @Override public boolean onEvaluateInputViewShown() { return false; }
    @Override public boolean onEvaluateFullscreenMode() { return false; }

    @Override public void onStartInput(EditorInfo info, boolean restarting) {
        super.onStartInput(info, restarting);
        boolean sameEditor = restarting && active == this && session != null
                && info.inputType != InputType.TYPE_NULL && getCurrentInputConnection() != null;
        active = this;
        start = info.initialSelStart;
        end = info.initialSelEnd;
        composing = false;
        selectionReported = start >= 0 && end >= 0;
        markSequence = 0;
        markStart = markEnd = -1;
        if (sameEditor) {
            // Android restarted the connection to this field. Its contents may have changed;
            // the authenticated target and the order of incoming keystrokes have not.
            generation++;
            revision++;
            editPending = false;
            contextReader.removeCallbacksAndMessages(null);
            if (attached) publish();
        } else {
            newSession();
        }
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
        editPending = false;
        keyDownTimes.clear();
        ack = 0;
        markSequence = 0;
        generation = 0;
        revision++;
        EditorInfo info = getCurrentInputEditorInfo();
        InputBinding binding = getCurrentInputBinding();
        if (info == null || info.inputType == InputType.TYPE_NULL || getCurrentInputConnection() == null) {
            session = null;
            AvoInputProvider.publish(object("kind", "focus"));
            return;
        }
        session = UUID.randomUUID().toString();
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
        if (!ime.attached || ime.editPending || sequence != ime.ack + 1) return;
        ime.ack = sequence;
        // A queued candidate for a rejected or retired mark must not replace a different selection.
        if (edit.has("afterMark") && edit.optLong("afterMark") != ime.markSequence) {
            ime.publish();
            return;
        }
        if ("keyDown".equals(action) || "keyUp".equals(action)) {
            ime.sendKey(connection, edit, "keyDown".equals(action));
            return;
        }
        if (edit.has("from") || edit.has("to")) {
            ime.replace(connection, edit);
        } else {
            ime.applyBatch(connection, edit, -1, -1);
            ime.publish();
        }
    }

    /** AppKit coordinates describe the Mac's view, which can include unconfirmed edits. */
    private void replace(InputConnection connection, JSONObject edit) {
        JSONObject basis = edit.optJSONObject("basis");
        int from = edit.optInt("from", -1), to = edit.optInt("to", -1);
        if (basis == null || basis.optInt("generation", -1) != generation || from < 0 || to < from) {
            publish();
            return;
        }
        int a = basis.optInt("start", -1), b = basis.optInt("end", -1);
        if (from == to && from == a && a == b) {
            insertAtCaret(connection, edit);
            return;
        }
        String text = basis.optString("text", null);
        int offset = basis.optInt("offset", -1);
        int left = Math.min(a, b), right = Math.max(a, b);
        if (privateEditor(getCurrentInputEditorInfo()) || text == null || text.length() > MAX_CONTEXT_LENGTH
                || offset < 0 || from < offset || left < offset || Math.max(to, right) > (long) offset + text.length()) {
            publish();
            return;
        }
        readForEdit(() -> connection.getSurroundingText(left - offset, text.length() - (right - offset), 0), live -> {
            if (live == null || live.getOffset() < 0) return;
            if ((long) live.getOffset() + live.getSelectionStart() == a && (long) live.getOffset() + live.getSelectionEnd() == b
                    && live.getText().toString().regionMatches(offset - live.getOffset(), text, 0, text.length())) {
                applyBatch(connection, edit, from, to);
            }
        });
    }

    /** Follow the real insertion point after navigation, without overwriting a newly selected word. */
    private void insertAtCaret(InputConnection connection, JSONObject edit) {
        if (privateEditor(getCurrentInputEditorInfo())) {
            if (selectionReported && start >= 0 && start == end) applyBatch(connection, edit, -1, -1);
            publish();
            return;
        }
        readForEdit(() -> connection.getSurroundingText(0, 0, 0), live -> {
            if (live == null || live.getSelectionStart() != live.getSelectionEnd()) return;
            start = end = live.getOffset() < 0 ? -1 : live.getOffset() + live.getSelectionStart();
            applyBatch(connection, edit, -1, -1);
        });
    }

    private void applyBatch(InputConnection connection, JSONObject edit, int from, int to) {
        selectionReported = false;
        connection.beginBatchEdit();
        try {
            apply(connection, edit, from, to);
        } finally {
            connection.endBatchEdit();
        }
    }

    /** Keep subsequent edits behind an editor read without blocking the input-method thread. */
    private <T> void readForEdit(Supplier<T> read, Consumer<T> complete) {
        editPending = true;
        long version = ++revision;
        contextReader.removeCallbacksAndMessages(null);
        contextReader.post(() -> {
            T result = read.get();
            AvoInputProvider.main.post(() -> {
                if (!attached || revision != version) return;
                editPending = false;
                complete.accept(result);
                publish();
            });
        });
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
        selectionReported = false;
        connection.sendKeyEvent(new KeyEvent(pressed, now, down ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP,
                code, repeat, edit.optInt("metaState"), KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_SOFT_KEYBOARD | KeyEvent.FLAG_KEEP_TOUCH_MODE));
        // sendKeyEvent only queues the key. Wait for the editor to handle a cursor request
        // on the same connection before acknowledging it, even when its UI thread is busy.
        readForEdit(() -> connection.requestCursorUpdates(InputConnection.CURSOR_UPDATE_IMMEDIATE,
                InputConnection.CURSOR_UPDATE_FILTER_INSERTION_MARKER), ignored -> {});
    }

    private void apply(InputConnection c, JSONObject edit, int from, int to) {
        String action = edit.optString("action");
        if ("finish".equals(action)) {
            c.finishComposingText();
            composing = false;
            markSequence = 0;
            markStart = markEnd = -1;
            return;
        }
        if ("cancel".equals(action)) {
            if (composing && c.setComposingText("", 1)) start = end = markStart;
            c.finishComposingText();
            composing = false;
            markSequence = 0;
            markStart = markEnd = -1;
            return;
        }
        boolean commit = "commit".equals(action);
        if (!commit && !"mark".equals(action)) return;
        String text = edit.optString("text");
        int anchor = composing ? markStart : Math.min(start, end);
        if (edit.has("from")) {
            anchor = from >= 0 ? from : Math.min(start, end);
            if (from < 0 || !commit) {
                if (!c.finishComposingText()) return;
                composing = false;
                markSequence = 0;
                markStart = markEnd = -1;
                if (from >= 0 && !c.setSelection(from, to)) return;
            }
        }
        if (commit) {
            // Send a verified document replacement to the app in one editor command.
            boolean sent = from >= 0 ? c.replaceText(from, to, text, 1, null) : c.commitText(text, 1);
            if (!sent) return;
            if (anchor >= 0) start = end = anchor + text.length();
            composing = false;
            markSequence = 0;
            markStart = markEnd = -1;
        } else if (c.setComposingText(text, 1)) {
            // A custom editor may accept composing text without reporting its selection.
            composing = !text.isEmpty();
            markSequence = composing ? ack : 0;
            if (text.isEmpty()) { c.finishComposingText(); markStart = markEnd = -1; }
            else if (anchor >= 0) { markStart = anchor; markEnd = anchor + text.length(); }
            int a = edit.optInt("caretStart", text.length()), b = edit.optInt("caretEnd", a);
            start = end = anchor < 0 ? -1 : anchor + text.length();
            if (composing && a >= 0 && a <= b && b <= text.length() && (a != text.length() || b != a)) {
                selectInMark(c, text, anchor, a, b);
            }
        }
    }

    private void selectInMark(InputConnection connection, String text, int anchor, int a, int b) {
        // A filter can shorten or remove the composing text. Never extend its selection into
        // the neighbouring word just because the Mac supplied a longer string.
        boolean readText = anchor >= 0 && text.length() <= MAX_CONTEXT_LENGTH && !privateEditor(getCurrentInputEditorInfo());
        readForEdit(() -> {
            if (readText) return connection.getSurroundingText(text.length(), 0, 0);
            connection.requestCursorUpdates(InputConnection.CURSOR_UPDATE_IMMEDIATE,
                    InputConnection.CURSOR_UPDATE_FILTER_INSERTION_MARKER);
            return (SurroundingText) null;
        }, live -> {
            int from, length;
            if (selectionReported) {
                if (markStart < 0 || markEnd < markStart) return;
                from = markStart;
                length = markEnd - markStart;
            } else {
                if (live == null || live.getOffset() < 0 || live.getSelectionStart() != live.getSelectionEnd()
                        || (long) live.getOffset() + live.getSelectionEnd() != (long) anchor + text.length()
                        || !live.getText().toString().regionMatches(anchor - live.getOffset(), text, 0, text.length())) return;
                from = anchor;
                length = text.length();
            }
            int first = from + Math.min(a, length), last = from + Math.min(b, length);
            if (connection.setSelection(first, last)) { start = first; end = last; }
        });
    }

    @Override public void onUpdateSelection(int oldStart, int oldEnd, int newStart, int newEnd, int candidatesStart, int candidatesEnd) {
        super.onUpdateSelection(oldStart, oldEnd, newStart, newEnd, candidatesStart, candidatesEnd);
        if (selectionReported && markStart >= 0 && candidatesStart < 0) markSequence = 0;
        selectionReported = true;
        if (start == newStart && end == newEnd && markStart == candidatesStart && markEnd == candidatesEnd) return;
        start = newStart; end = newEnd; markStart = candidatesStart; markEnd = candidatesEnd;
        composing = candidatesStart >= 0;
        if (attached) publish();
    }

    private JSONObject state(boolean contextPending) {
        return object("kind", "state", "session", session, "generation", generation, "ack", ack, "start", start, "end", end,
                "markStart", markStart, "markEnd", markEnd, "markSequence", markSequence == 0 ? null : markSequence,
                "privateEditor", privateEditor(getCurrentInputEditorInfo()), "contextPending", contextPending);
    }

    private void publish() {
        if (editPending) return;
        long version = ++revision;
        EditorInfo info = getCurrentInputEditorInfo();
        InputConnection connection = getCurrentInputConnection();
        contextReader.removeCallbacksAndMessages(null);
        // Android includes the entire selection in addition to the text requested on each side.
        int selected = start >= 0 && end >= 0 ? Math.abs(end - start) : 0;
        boolean readContext = connection != null && !privateEditor(info) && selected <= MAX_CONTEXT_LENGTH;
        AvoInputProvider.publish(state(readContext));
        if (!readContext) return;
        int side = Math.min(512, (MAX_CONTEXT_LENGTH - selected) / 2);
        // An editor may be busy. Fetch reconversion context off the IME thread and discard late replies.
        contextReader.post(() -> {
            SurroundingText context = connection.getSurroundingText(side, side, 0);
            AvoInputProvider.main.post(() -> {
                if (!attached || active != this || revision != version) return;
                if (context == null || context.getOffset() < 0 || context.getText().length() > MAX_CONTEXT_LENGTH) {
                    AvoInputProvider.publish(state(false));
                    return;
                }
                // Some editors provide their first absolute selection with the surrounding text.
                start = context.getOffset() + context.getSelectionStart();
                end = context.getOffset() + context.getSelectionEnd();
                JSONObject snapshot = state(false);
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

package com.avodroid.tests.input;

import android.app.Activity;
import android.content.*;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.text.Editable;
import android.text.InputType;
import android.text.Selection;
import android.view.KeyEvent;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodInfo;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.InputMethodSubtype;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import org.json.JSONTokener;

/** A native or web editor that records paste keys and clipboard changes during input. */
public final class Editor extends Activity {
    private ClipboardManager clipboard;
    private EditText field;
    private Editable unreportedText;
    private WebView web;
    private boolean initialized;
    private int pasteKeys;
    private boolean clipboardChanged;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        checkKeyboardSubtype();
        try {
            getContentResolver().call(Uri.parse("content://com.avodroid.input.editor"), "connect", null, null);
            throw new AssertionError("an ordinary app could access the input endpoint");
        } catch (SecurityException expected) {}
        clipboard = getSystemService(ClipboardManager.class);
        if (getIntent().getBooleanExtra("web", false)) {
            web = new WebView(this);
            web.getSettings().setJavaScriptEnabled(true);
            web.setWebViewClient(new WebViewClient() {
                @Override public void onPageFinished(WebView view, String url) {
                    web.requestFocus();
                    web.evaluateJavascript("document.querySelector('input').focus()", ignored -> write("page", "ready"));
                }
            });
            setContentView(web);
            web.loadDataWithBaseURL(null, "<meta name='viewport' content='width=device-width'>"
                    + "<input autofocus style='position:fixed;inset:0;width:100%;height:100%'>", "text/html", "UTF-8", null);
        } else {
            if (getIntent().getBooleanExtra("unknownSelection", false)) {
                unreportedText = Editable.Factory.getInstance().newEditable("");
                Selection.setSelection(unreportedText, 0);
            }
            field = new EditText(this) {
                @Override public InputConnection onCreateInputConnection(EditorInfo info) {
                    if (unreportedText == null) return super.onCreateInputConnection(info);
                    info.inputType = InputType.TYPE_CLASS_TEXT;
                    info.imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING;
                    return new BaseInputConnection(this, true) {
                        @Override public Editable getEditable() { return unreportedText; }
                    };
                }
            };
            field.setSingleLine(true);
            if (getIntent().getBooleanExtra("password", false)) {
                field.setInputType(android.text.InputType.TYPE_CLASS_TEXT | android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD);
            }
            field.setShowSoftInputOnFocus(false);
            setContentView(field);
            field.requestFocus();
        }
        registerReceiver(receiver, new IntentFilter(getPackageName() + ".READ"), Context.RECEIVER_EXPORTED);
    }

    private void checkKeyboardSubtype() {
        for (InputMethodInfo ime : getSystemService(InputMethodManager.class).getInputMethodList()) {
            if (!"com.avodroid.input/.AvoInputService".equals(ime.getId())) continue;
            for (int i = 0; i < ime.getSubtypeCount(); i++) {
                InputMethodSubtype subtype = ime.getSubtypeAt(i);
                if ("keyboard".equals(subtype.getMode()) && subtype.isAsciiCapable()) return;
            }
        }
        throw new AssertionError("Android Settings needs an ASCII-capable Avo Input keyboard subtype");
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused || initialized) return;
        initialized = true;
        String kind = getIntent().getStringExtra("clip");
        if ("uri".equals(kind)) {
            clipboard.setPrimaryClip(ClipData.newRawUri("file", Uri.parse("content://" + getPackageName() + ".files/item")));
        } else if ("empty".equals(kind)) {
            clipboard.clearPrimaryClip();
        } else {
            clipboard.setPrimaryClip(ClipData.newPlainText("seed", "SEED"));
        }
        long before = clipTimestamp();
        clipboard.addPrimaryClipChangedListener(() -> {
            if (clipTimestamp() != before) clipboardChanged = true;
        });
        write("ready", "ready");
    }

    private long clipTimestamp() {
        ClipDescription description = clipboard.getPrimaryClipDescription();
        return description == null ? -1 : description.getTimestamp();
    }

    @Override public boolean dispatchKeyEvent(KeyEvent key) {
        if (key.getAction() == KeyEvent.ACTION_DOWN && key.getKeyCode() == KeyEvent.KEYCODE_V
                && key.isCtrlPressed()) pasteKeys++;
        return super.dispatchKeyEvent(key);
    }

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            ClipData clip = clipboard.getPrimaryClip();
            String before = "empty";
            if (clip != null) {
                ClipData.Item item = clip.getItemAt(0);
                before = item.getUri() != null ? item.getUri().toString() : item.getText().toString();
            }
            final String suffix = "|" + before + "|" + pasteKeys + "|" + clipboardChanged;
            if (unreportedText != null) write("result", unreportedText + suffix);
            else if (web == null) write("result", field.getText() + suffix);
            else web.evaluateJavascript("document.querySelector('input').value", value -> {
                try { write("result", new JSONTokener(value).nextValue() + suffix); }
                catch (org.json.JSONException error) { throw new IllegalStateException(error); }
            });
        }
    };

    private void write(String name, String text) {
        try (FileOutputStream out = openFileOutput(name, MODE_PRIVATE)) {
            out.write(text.getBytes(StandardCharsets.UTF_8));
        } catch (IOException error) { throw new IllegalStateException(error); }
    }

    @Override public void onDestroy() {
        unregisterReceiver(receiver);
        super.onDestroy();
    }

    /** A private, grantable URI like the file or image another app copied. */
    public static final class Files extends ContentProvider {
        @Override public boolean onCreate() { return true; }
        @Override public String getType(Uri uri) { return "application/octet-stream"; }
        @Override public Cursor query(Uri uri, String[] p, String s, String[] a, String o) { return null; }
        @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
        @Override public int delete(Uri uri, String s, String[] a) { throw new UnsupportedOperationException(); }
        @Override public int update(Uri uri, ContentValues v, String s, String[] a) { throw new UnsupportedOperationException(); }
    }
}

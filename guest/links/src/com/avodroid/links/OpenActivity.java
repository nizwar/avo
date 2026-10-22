package com.avodroid.links;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import java.net.IDN;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.concurrent.ThreadLocalRandom;

/**
 * Hands a link an app opens (a web page, an e-mail address, a place) to the
 * Mac and finishes; Avo makes this app Android's default browser. The link
 * travels in Android's log, which the Runtime Daemon follows over ADB
 * (HostAgent's "Links", reading this app's log lines only):
 *
 * <pre>
 *   I AvoLinks: open MILLIS ID PART/COUNT TEXT
 * </pre>
 *
 * TEXT is the link as printable ASCII (an international domain name as
 * punycode, any other character percent-encoded), cut into parts that each
 * fit one log entry. MILLIS is when it was logged (the daemon follows the log
 * on from there after a reconnect) and ID tells one link's parts from
 * another's. Which links the Mac opens is the daemon's decision.
 */
public final class OpenActivity extends Activity {
    static final String TAG = "AvoLinks";
    /** Characters per part: a log entry holds a little over 4,000 bytes. */
    static final int PART = 3000;
    /** Longer links are not passed on (the daemon would refuse them too). */
    static final int MAX_PARTS = 16;
    private static final char[] HEX = "0123456789ABCDEF".toCharArray();

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        try {
            String link = link(getIntent());
            if (link != null) send(link);
        } catch (RuntimeException e) {
            Log.w(TAG, "not passed on: " + e);
        }
        // Theme.NoDisplay: an activity of it must finish before onResume.
        finish();
    }

    /** The link to pass on, or null for an intent this app does not handle. */
    static String link(Intent intent) {
        if (intent == null) return null;
        String action = intent.getAction();
        Uri uri = intent.getData();
        if (uri == null || !(Intent.ACTION_VIEW.equals(action) || Intent.ACTION_SENDTO.equals(action))) return null;
        uri = uri.normalizeScheme();
        String scheme = uri.getScheme();
        if (scheme == null) return null;
        switch (scheme) {
            case "http":
            case "https":
                return ascii(withAsciiHost(uri));
            case "mailto":
                return ascii(withMailExtras(uri.toString(), intent));
            case "geo":
                return ascii(uri.toString());
            default:
                return null;
        }
    }

    /** An international domain name as punycode, which the Mac's URL parsers take. */
    static String withAsciiHost(Uri uri) {
        String text = uri.toString();
        String host = uri.getHost();
        int start = text.indexOf("://");
        if (host == null || start < 0 || isAscii(host)) return text;
        int at = text.indexOf(host, start + 3);
        if (at < 0) return text;
        try {
            return text.substring(0, at) + IDN.toASCII(host, IDN.ALLOW_UNASSIGNED) + text.substring(at + host.length());
        } catch (IllegalArgumentException e) {
            return text;
        }
    }

    /**
     * Apps that ask for an e-mail often leave the URI bare ({@code mailto:})
     * and put the recipients, subject and text in extras: those go into the
     * URI (RFC 6068), unless it has them already.
     */
    static String withMailExtras(String text, Intent intent) {
        int question = text.indexOf('?');
        StringBuilder address = new StringBuilder(question < 0 ? text : text.substring(0, question));
        StringBuilder query = new StringBuilder(question < 0 ? "" : text.substring(question + 1));
        String present = "&" + query.toString().toLowerCase(Locale.ROOT);
        String[] to = intent.getStringArrayExtra(Intent.EXTRA_EMAIL);
        if (to == null && intent.getStringExtra(Intent.EXTRA_EMAIL) != null) {
            to = new String[] {intent.getStringExtra(Intent.EXTRA_EMAIL)};
        }
        if (to != null) {
            for (String recipient : to) {
                if (recipient == null || recipient.trim().isEmpty()) continue;
                if (address.length() > "mailto:".length()) address.append(',');
                address.append(Uri.encode(recipient.trim(), "@+"));
            }
        }
        add(query, present, "cc", recipients(intent.getStringArrayExtra(Intent.EXTRA_CC)));
        add(query, present, "bcc", recipients(intent.getStringArrayExtra(Intent.EXTRA_BCC)));
        add(query, present, "subject", intent.getCharSequenceExtra(Intent.EXTRA_SUBJECT));
        add(query, present, "body", intent.getCharSequenceExtra(Intent.EXTRA_TEXT));
        return query.length() == 0 ? address.toString() : address + "?" + query;
    }

    private static void add(StringBuilder query, String present, String name, CharSequence value) {
        if (value == null || value.length() == 0 || present.contains("&" + name + "=")) return;
        if (query.length() > 0) query.append('&');
        query.append(name).append('=').append(Uri.encode(value.toString()));
    }

    private static String recipients(String[] list) {
        if (list == null) return null;
        StringBuilder out = new StringBuilder();
        for (String recipient : list) {
            if (recipient == null || recipient.trim().isEmpty()) continue;
            if (out.length() > 0) out.append(',');
            out.append(recipient.trim());
        }
        return out.toString();
    }

    private static boolean isAscii(String text) {
        for (int i = 0; i < text.length(); i++) {
            if (text.charAt(i) > 0x7e) return false;
        }
        return true;
    }

    /** Printable ASCII stays; every other byte of the UTF-8 text is percent-encoded. */
    static String ascii(String text) {
        StringBuilder out = new StringBuilder(text.length());
        for (byte b : text.getBytes(StandardCharsets.UTF_8)) {
            int c = b & 0xff;
            if (c > 0x20 && c < 0x7f) {
                out.append((char) c);
            } else {
                out.append('%').append(HEX[c >> 4]).append(HEX[c & 15]);
            }
        }
        return out.toString();
    }

    static void send(String link) {
        int count = (link.length() + PART - 1) / PART;
        if (count > MAX_PARTS) {
            Log.w(TAG, "not passed on: " + link.length() + " characters is too long");
            return;
        }
        String head = "open " + System.currentTimeMillis() + " "
                + Long.toHexString(ThreadLocalRandom.current().nextLong()) + " ";
        for (int i = 0; i < count; i++) {
            String part = link.substring(i * PART, Math.min(link.length(), (i + 1) * PART));
            Log.i(TAG, head + (i + 1) + "/" + count + " " + part);
        }
    }
}

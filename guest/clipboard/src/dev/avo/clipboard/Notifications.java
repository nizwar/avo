package dev.avo.clipboard;

import android.app.ActivityOptions;
import android.app.Notification;
import android.app.RemoteInput;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Apps' notifications as a notification listener sees them:
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-clipboard.jar app_process / dev.avo.clipboard.Main dismiss KEY...
 *   ... actions KEY...            one JSON object per notification still there and line:
 *                                 {"key", "actions": [{"title", "reply", "hint"?}]}
 *   ... act KEY INDEX [BASE64]    presses the notification's button INDEX, with this text (UTF-8)
 *                                 as the answer when the button takes one (an inline reply)
 * </pre>
 *
 * {@code dismiss} does what swiping them away in Android's shade does (a
 * listener's cancel: ongoing and no-clear ones stay, the app hears of it as a
 * dismissal) and prints {@code dismissed N}; {@code act} does what tapping a
 * button does (Reply sends the text the way the shade's reply field does) and
 * prints {@code acted}.
 *
 * It registers a listener the way {@code cmd notification snooze} does inside
 * the system server, without the user granting notification access: Android
 * allows that to the system and to holders of STATUS_BAR_SERVICE, which the
 * shell user (and root) are.
 */
final class Notifications {
    /** A listener that only reads and cancels; what Android tells it is ignored. */
    public static final class Listener extends NotificationListenerService {}

    private interface Body {
        void run(Context context, Listener listener) throws Exception;
    }

    private Notifications() {}

    private static void listening(Body body) throws Exception {
        Context context = AppInfo.systemContext();
        Listener listener = new Listener();
        Method register = NotificationListenerService.class.getMethod(
                "registerAsSystemService", Context.class, ComponentName.class, int.class);
        Method unregister = NotificationListenerService.class.getMethod("unregisterAsSystemService");
        register.invoke(listener, context, new ComponentName(context.getPackageName(), Listener.class.getName()), 0);
        try {
            body.run(context, listener);
        } finally {
            unregister.invoke(listener);
        }
    }

    static void dismiss(String[] keys) throws Exception {
        listening((context, listener) -> listener.cancelNotifications(keys));
        System.out.println("dismissed " + keys.length);
    }

    static void actions(String[] keys) throws Exception {
        listening((context, listener) -> {
            StatusBarNotification[] found = listener.getActiveNotifications(keys);
            if (found == null) return;
            for (StatusBarNotification sbn : found) {
                JSONArray actions = new JSONArray();
                Notification.Action[] all = sbn.getNotification().actions;
                for (int index = 0; all != null && index < all.length; index++) {
                    Notification.Action action = all[index];
                    if (action == null || action.title == null || action.actionIntent == null) continue;
                    JSONObject json = new JSONObject();
                    json.put("index", index);
                    json.put("title", action.title.toString());
                    RemoteInput input = freeForm(action);
                    json.put("reply", input != null);
                    if (input != null && input.getLabel() != null) json.put("hint", input.getLabel().toString());
                    actions.put(json);
                }
                JSONObject json = new JSONObject();
                json.put("key", sbn.getKey());
                json.put("actions", actions);
                System.out.println(json.toString());
            }
        });
        System.out.flush();
    }

    static void act(String key, int index, String encodedText) throws Exception {
        String text = encodedText == null ? null
                : new String(Base64.getDecoder().decode(encodedText), StandardCharsets.UTF_8);
        listening((context, listener) -> {
            StatusBarNotification[] found = listener.getActiveNotifications(new String[]{key});
            if (found == null || found.length == 0) throw new IllegalStateException("notification is gone");
            Notification.Action[] all = found[0].getNotification().actions;
            if (all == null || index < 0 || index >= all.length || all[index] == null || all[index].actionIntent == null) {
                throw new IllegalArgumentException("no button " + index);
            }
            Notification.Action action = all[index];
            Intent fillIn = new Intent();
            RemoteInput[] inputs = action.getRemoteInputs();
            if (text != null && inputs != null) {
                // Every free-form input gets the text, as the shade's reply field gives it.
                Bundle results = new Bundle();
                for (RemoteInput input : inputs) {
                    if (input.getAllowFreeFormInput()) results.putCharSequence(input.getResultKey(), text);
                }
                RemoteInput.addResultsToIntent(inputs, fillIn, results);
                RemoteInput.setResultsSource(fillIn, RemoteInput.SOURCE_FREE_FORM_INPUT);
            }
            Bundle options = null;
            if (Build.VERSION.SDK_INT >= 34) {
                // A button that opens an activity may, as one tapped in the shade may.
                options = ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED).toBundle();
            }
            action.actionIntent.send(context, 0, fillIn, null, null, null, options);
        });
        System.out.println("acted");
    }

    /** The button's input that takes typed text, if any (a Reply button's). */
    private static RemoteInput freeForm(Notification.Action action) {
        RemoteInput[] inputs = action.getRemoteInputs();
        if (inputs == null) return null;
        for (RemoteInput input : inputs) {
            if (input.getAllowFreeFormInput()) return input;
        }
        return null;
    }
}

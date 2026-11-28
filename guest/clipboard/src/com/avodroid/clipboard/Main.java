package com.avodroid.clipboard;

import android.content.ClipData;
import android.os.IBinder;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Base64;

/**
 * Avo's clipboard bridge for Android images without the Bridge Agent. The
 * Runtime Daemon runs it over ADB as the shell user, which may use the
 * clipboard from the background:
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-clipboard.jar app_process / com.avodroid.clipboard.Main get
 *   ... set BASE64        replace the clipboard with this text
 *   ... watch             print "clip BASE64" whenever the clipboard text changes
 *   ... appinfo PACKAGE...  label, version, size and launcher icon per app (see AppInfo)
 *   ... dismiss KEY...      dismisses these notifications, as a swipe in the shade (see Notifications)
 *   ... actions KEY...      these notifications' buttons (see Notifications)
 *   ... act KEY INDEX [BASE64]  presses one, with the text of a reply (see Notifications)
 *   ... media watch     what Android plays, for the Mac's Now Playing; takes play, pause... on stdin (see Media)
 * </pre>
 *
 * Text travels as Base64 (UTF-8) so it fits on one line.
 */
public final class Main {
    private static final String SHELL = "com.android.shell";

    private final Object service;
    private final Method get;
    private final Method set;

    private Main() throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "clipboard");
        service = Class.forName("android.content.IClipboard$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
        Method getter = null, setter = null;
        for (Method method : service.getClass().getMethods()) {
            if (method.getName().equals("getPrimaryClip")) getter = method;
            if (method.getName().equals("setPrimaryClip")) setter = method;
        }
        if (getter == null || setter == null) throw new IllegalStateException("no IClipboard");
        get = getter;
        set = setter;
    }

    /**
     * Arguments for the Android version's signature: (clip?), calling
     * package, attribution tag (newer), user id, device id (newer).
     */
    private static Object[] arguments(Method method, ClipData clip) {
        Class<?>[] types = method.getParameterTypes();
        Object[] values = new Object[types.length];
        int index = 0;
        if (clip != null) values[index++] = clip;
        boolean packageGiven = false;
        for (; index < types.length; index++) {
            if (types[index] == String.class) {
                values[index] = packageGiven ? null : SHELL;
                packageGiven = true;
            } else if (types[index] == int.class) {
                values[index] = 0; // user 0, default device
            }
        }
        return values;
    }

    private String text() throws Exception {
        ClipData clip = (ClipData) get.invoke(service, arguments(get, null));
        if (clip == null || clip.getItemCount() == 0) return null;
        CharSequence text = clip.getItemAt(0).getText();
        return text == null ? null : text.toString();
    }

    private void setText(String text) throws Exception {
        set.invoke(service, arguments(set, ClipData.newPlainText("Avo", text)));
    }

    private static String encode(String text) {
        return Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.UTF_8));
    }

    private interface Command {
        void run() throws Exception;
    }

    /**
     * Runs a command and exits, with 1 and {@code error ...} on stderr when
     * it fails: an uncaught exception would hang app_process, which tries
     * to report the crash to a system that does not know it.
     */
    private static void exitAfter(Command command) {
        try {
            command.run();
        } catch (Throwable error) {
            System.err.println("error " + error);
            System.exit(1);
        }
        System.exit(0);
    }

    public static void main(String[] args) throws Exception {
        String command = args.length > 0 ? args[0] : "";
        if (command.equals("appinfo")) {
            AppInfo.run(Arrays.copyOfRange(args, 1, args.length));
            System.exit(0); // the system context's threads would keep it running
        }
        if (command.equals("dismiss")) {
            Notifications.dismiss(Arrays.copyOfRange(args, 1, args.length));
            System.exit(0);
        }
        if (command.equals("actions")) {
            Notifications.actions(Arrays.copyOfRange(args, 1, args.length));
            System.exit(0);
        }
        if (command.equals("act")) {
            exitAfter(() -> Notifications.act(args[1], Integer.parseInt(args[2]), args.length > 3 ? args[3] : null));
        }
        if (command.equals("media")) {
            exitAfter(() -> Media.run(Arrays.copyOfRange(args, 1, args.length)));
        }
        Main clipboard = new Main();
        switch (command) {
            case "get": {
                String text = clipboard.text();
                System.out.println(text == null ? "" : encode(text));
                break;
            }
            case "set":
                clipboard.setText(new String(Base64.getDecoder().decode(args[1]), StandardCharsets.UTF_8));
                break;
            case "watch": {
                String last = clipboard.text();
                System.out.println("ready");
                System.out.flush();
                while (true) {
                    Thread.sleep(300);
                    String now = clipboard.text();
                    if (now != null && !now.equals(last)) {
                        System.out.println("clip " + encode(now));
                        System.out.flush();
                    }
                    last = now;
                }
            }
            default:
                System.err.println("usage: get | set BASE64 | watch | appinfo PACKAGE... | dismiss KEY... | actions KEY... | act KEY INDEX [BASE64] | media watch");
                System.exit(2);
        }
    }
}

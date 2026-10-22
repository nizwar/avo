package com.avodroid.macstate;

import android.content.res.Configuration;
import android.os.IBinder;
import android.os.LocaleList;
import java.lang.reflect.Method;
import java.util.List;

/**
 * Android's system languages for images without the Bridge Agent, so the
 * Runtime Daemon can keep them in step with the Mac's (HostAgent's Mac state).
 * Android has no shell command for them (`cmd locale` only sets per-app
 * languages), so this makes the change Settings › Languages makes
 * (LocalePicker.updateLocales): a persistent configuration whose locales the
 * user set, which Android keeps across boots and hands to every app. Run over
 * ADB as the shell user, which may change the configuration and settings:
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-macstate.jar app_process / com.avodroid.macstate.Main locales
 *   ... locales TAGS      make TAGS (comma-separated BCP 47, first preferred) Android's languages
 * </pre>
 *
 * Either way it prints "locales TAGS" with Android's languages afterwards.
 *
 * <p>Audio focus as on a Mac, where every app's window plays at once: on a
 * phone only one app holds audio focus, so an app another one takes it from
 * pauses or mutes itself (two games side by side silence each other). With
 * multi audio focus (Android's desktop mode, AudioService
 * setMultiAudioFocusEnabled) every app asking for focus keeps it; calls and
 * short sounds (notifications, ducking) still work as before. Android keeps
 * it across boots (Settings.System multi_audio_focus_enabled, which
 * AudioService reads only when it starts):
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-macstate.jar app_process / com.avodroid.macstate.Main audiofocus
 * </pre>
 *
 * It prints "audiofocus shared".
 *
 * <p>Input focus for the Mac's key window: Android focuses one display at a
 * time (the GPU engine's displays share it), and moves it only on a touch.
 * Games pause their sound while their window is unfocused, and keys and
 * gamepads go to the focused display, so the window the Mac user works in
 * takes it (IActivityTaskManager.setFocusedRootTask on the display's top
 * visible task):
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-macstate.jar app_process / com.avodroid.macstate.Main focus-display ID
 * </pre>
 *
 * It prints "focused task TASK on display ID", or "no task on display ID".
 */
public final class Main {
    private static final String SHELL = "com.android.shell";

    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("audiofocus")) {
            shareAudioFocus();
            System.out.println("audiofocus shared");
            System.exit(0);
        }
        if (args.length == 2 && args[0].equals("focus-display")) {
            int display = Integer.parseInt(args[1]);
            int task = focusDisplay(display);
            System.out.println(task < 0 ? "no task on display " + display : "focused task " + task + " on display " + display);
            System.exit(task < 0 ? 1 : 0);
        }
        if (args.length < 1 || args.length > 2 || !args[0].equals("locales")) {
            System.err.println("usage: locales [TAGS] | audiofocus | focus-display ID");
            System.exit(2);
        }
        Object activity = activityManager();
        if (args.length == 2) {
            Configuration config = new Configuration();
            config.setLocales(LocaleList.forLanguageTags(args[1]));
            // As chosen in Settings: Android persists it (persist.sys.locale,
            // system_locales) and tells apps (ACTION_LOCALE_CHANGED).
            Configuration.class.getField("userSetLocale").setBoolean(config, true);
            updatePersistentConfiguration(activity, config);
        }
        Configuration now = (Configuration) activity.getClass().getMethod("getConfiguration").invoke(activity);
        System.out.println("locales " + now.getLocales().toLanguageTags());
        System.exit(0);
    }

    /** IAudioService.setMultiAudioFocusEnabled(true): a no-op when it is on already. */
    private static void shareAudioFocus() throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "audio");
        Object audio = Class.forName("android.media.IAudioService$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
        audio.getClass().getMethod("setMultiAudioFocusEnabled", boolean.class).invoke(audio, true);
    }

    /**
     * Focuses the top visible root task on `display`, as a touch there would;
     * its task id, or -1 when the display shows none.
     */
    private static int focusDisplay(int display) throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "activity_task");
        Object tasks = Class.forName("android.app.IActivityTaskManager$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
        List<?> roots = (List<?>) tasks.getClass().getMethod("getAllRootTaskInfosOnDisplay", int.class)
                .invoke(tasks, display);
        // Top first.
        for (Object root : roots) {
            if (!root.getClass().getField("visible").getBoolean(root)) continue;
            int task = root.getClass().getField("taskId").getInt(root);
            tasks.getClass().getMethod("setFocusedRootTask", int.class).invoke(tasks, task);
            return task;
        }
        return -1;
    }

    private static Object activityManager() throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, "activity");
        return Class.forName("android.app.IActivityManager$Stub")
                .getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    /**
     * updatePersistentConfigurationWithAttribution(config, package, tag)
     * where Android has it (11 and later, which checks WRITE_SETTINGS for
     * the calling package), else updatePersistentConfiguration(config).
     */
    private static void updatePersistentConfiguration(Object activity, Configuration config) throws Exception {
        for (Method method : activity.getClass().getMethods()) {
            if (method.getName().equals("updatePersistentConfigurationWithAttribution")
                    && method.getParameterTypes().length == 3) {
                method.invoke(activity, config, SHELL, null);
                return;
            }
        }
        activity.getClass().getMethod("updatePersistentConfiguration", Configuration.class).invoke(activity, config);
    }
}

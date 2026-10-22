package com.avodroid.clipboard;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.AdaptiveIconDrawable;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.Drawable;
import android.os.Looper;
import android.util.DisplayMetrics;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.util.Base64;
import java.util.Iterator;
import java.util.List;
import org.json.JSONObject;

/**
 * What the launcher shows for installed apps, asked of Android itself:
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-clipboard.jar app_process / com.avodroid.clipboard.Main appinfo PACKAGE...
 * </pre>
 *
 * prints one JSON object per package and line:
 *
 * <pre>
 *   {"package", "label", "versionName", "versionCode", "sizeBytes", "firstInstallTime", "lastUpdateTime", "system", "game",
 *    "orientation"                                            ("portrait" | "landscape", when its activities ask for one)
 *    "backgroundPng" | "backgroundColor", "foregroundPng"     (an AdaptiveIconDrawable's full-bleed 108 dp layers)
 *    "iconPng"                                                (any other launcher icon)}
 *   {"package", "error"}                                      (not installed, not readable)
 * </pre>
 *
 * Resources come from the installed APKs through PackageManager (base and
 * split APKs, system and updated system apps alike); nothing is read whole
 * into memory. PNGs travel as Base64, colours as unsigned ARGB.
 */
final class AppInfo {
    /** A 108 dp adaptive icon layer at 4 px per dp (xxxhdpi). */
    private static final int LAYER_PIXELS = 432;
    /** Any other launcher icon. */
    private static final int ICON_PIXELS = 256;

    private AppInfo() {}

    static void run(String[] packages) throws Exception {
        PackageManager pm = systemContext().getPackageManager();
        for (String name : packages) {
            JSONObject json;
            try {
                json = describe(pm, name);
            } catch (Throwable error) {
                json = new JSONObject();
                json.put("package", name);
                json.put("error", String.valueOf(error));
            }
            System.out.println(json.toString());
            System.out.flush();
        }
    }

    /**
     * Android's own system context, built the way the system server does
     * (an ActivityThread marked as the system's), without becoming an app.
     */
    static Context systemContext() throws Exception {
        if (Looper.getMainLooper() == null) Looper.prepareMainLooper();
        Class<?> threadClass = Class.forName("android.app.ActivityThread");
        Object thread;
        try {
            Constructor<?> constructor = threadClass.getDeclaredConstructor();
            constructor.setAccessible(true);
            thread = constructor.newInstance();
            Field current = threadClass.getDeclaredField("sCurrentActivityThread");
            current.setAccessible(true);
            current.set(null, thread);
            Field system = threadClass.getDeclaredField("mSystemThread");
            system.setAccessible(true);
            system.setBoolean(thread, true);
        } catch (ReflectiveOperationException error) {
            thread = threadClass.getMethod("systemMain").invoke(null);
        }
        return (Context) threadClass.getMethod("getSystemContext").invoke(thread);
    }

    private static JSONObject describe(PackageManager pm, String name) throws Exception {
        PackageInfo info = pm.getPackageInfo(name, 0);
        ApplicationInfo app = info.applicationInfo;
        Intent main = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(name);
        List<ResolveInfo> launchers = pm.queryIntentActivities(main, 0);
        ActivityInfo activity = launchers.isEmpty() ? null : launchers.get(0).activityInfo;

        JSONObject json = new JSONObject();
        json.put("package", name);
        String label = label(pm, name, activity, app);
        if (label != null) json.put("label", label);
        if (info.versionName != null) json.put("versionName", info.versionName);
        json.put("versionCode", info.getLongVersionCode());
        json.put("sizeBytes", apkBytes(app));
        json.put("firstInstallTime", info.firstInstallTime);
        json.put("lastUpdateTime", info.lastUpdateTime);
        json.put("system", (app.flags & ApplicationInfo.FLAG_SYSTEM) != 0);
        // A game by its own account: its manifest's appCategory, or the older isGame.
        @SuppressWarnings("deprecation") boolean flaggedGame = (app.flags & ApplicationInfo.FLAG_IS_GAME) != 0;
        json.put("game", app.category == ApplicationInfo.CATEGORY_GAME || flaggedGame);
        String orientation = orientation(pm, name, activity);
        if (orientation != null) json.put("orientation", orientation);
        JSONObject icon;
        try {
            icon = iconKeys(icon(pm, activity, app));
        } catch (Throwable error) {
            // Drawn as PackageManager loads it instead (default density); else
            // none, and HostAgent reads the base APK's.
            try {
                icon = iconKeys(activity != null ? activity.loadIcon(pm) : app.loadIcon(pm));
            } catch (Throwable again) {
                icon = new JSONObject().put("iconError", String.valueOf(error));
            }
        }
        for (Iterator<String> keys = icon.keys(); keys.hasNext(); ) {
            String key = keys.next();
            json.put(key, icon.get(key));
        }
        return json;
    }

    /**
     * The app's label, as the Bridge Agent and the Mac's APK reader give it;
     * the launcher activity's when the app has none of its own.
     */
    private static String label(PackageManager pm, String name, ActivityInfo activity, ApplicationInfo app) {
        CharSequence label = app.loadLabel(pm);
        String text = label != null ? label.toString().trim() : "";
        if ((text.isEmpty() || text.equals(name)) && activity != null) {
            CharSequence own = activity.loadLabel(pm);
            if (own != null && !own.toString().trim().isEmpty()) text = own.toString().trim();
        }
        return text.isEmpty() ? null : text;
    }

    /**
     * The orientation the app asks for: its launcher activity's
     * screenOrientation, else the one its other activities agree on; null
     * when they let the screen turn (or disagree).
     */
    private static String orientation(PackageManager pm, String name, ActivityInfo launcher) {
        String own = launcher != null ? orientation(launcher.screenOrientation) : null;
        if (own != null || launcher == null) return own;
        ActivityInfo[] activities;
        try {
            activities = pm.getPackageInfo(name, PackageManager.GET_ACTIVITIES).activities;
        } catch (Throwable error) {
            return null;
        }
        String agreed = null;
        for (ActivityInfo activity : activities != null ? activities : new ActivityInfo[0]) {
            String asked = orientation(activity.screenOrientation);
            if (asked == null) continue;
            if (agreed != null && !agreed.equals(asked)) return null;
            agreed = asked;
        }
        return agreed;
    }

    /** "portrait" or "landscape" for a screenOrientation that keeps to one; null for any other. */
    private static String orientation(int screenOrientation) {
        switch (screenOrientation) {
            case ActivityInfo.SCREEN_ORIENTATION_PORTRAIT:
            case ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT:
            case ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT:
            case ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT:
                return "portrait";
            case ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE:
            case ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE:
            case ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE:
            case ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE:
                return "landscape";
            default:
                return null;
        }
    }

    /** The base APK and every split (density, ABI and language configs, feature splits). */
    private static long apkBytes(ApplicationInfo app) {
        long total = app.sourceDir != null ? new File(app.sourceDir).length() : 0;
        if (app.splitSourceDirs != null) {
            for (String split : app.splitSourceDirs) total += new File(split).length();
        }
        return total;
    }

    /**
     * The launcher icon as Launcher3 loads it: the activity's icon (else the
     * app's) at the highest density the APKs have, else PackageManager's.
     */
    private static Drawable icon(PackageManager pm, ActivityInfo activity, ApplicationInfo app) {
        int resource = activity != null ? activity.getIconResource() : app.icon;
        if (resource != 0) {
            try {
                Resources resources = pm.getResourcesForApplication(app);
                Drawable drawable = resources.getDrawableForDensity(resource, DisplayMetrics.DENSITY_XXXHIGH, null);
                if (drawable != null) return drawable;
            } catch (Throwable ignored) {
                // Falls back to the default density below.
            }
        }
        try {
            Drawable drawable = activity != null ? activity.loadIcon(pm) : app.loadIcon(pm);
            if (drawable != null) return drawable;
        } catch (Throwable ignored) {
            // The default icon below.
        }
        return pm.getDefaultActivityIcon();
    }

    /** The icon's keys, all drawn or none (a failure throws). */
    private static JSONObject iconKeys(Drawable icon) throws Exception {
        JSONObject json = new JSONObject();
        if (icon instanceof AdaptiveIconDrawable) {
            AdaptiveIconDrawable adaptive = (AdaptiveIconDrawable) icon;
            Drawable background = adaptive.getBackground();
            Drawable foreground = adaptive.getForeground();
            if (background instanceof ColorDrawable) {
                json.put("backgroundColor", ((ColorDrawable) background).getColor() & 0xFFFFFFFFL);
            } else if (background != null) {
                json.put("backgroundPng", png(background, LAYER_PIXELS, false));
            }
            if (foreground != null) json.put("foregroundPng", png(foreground, LAYER_PIXELS, false));
            if (background == null && foreground == null) json.put("iconPng", png(icon, ICON_PIXELS, true));
        } else {
            json.put("iconPng", png(icon, ICON_PIXELS, true));
        }
        return json;
    }

    /**
     * Draws `drawable` on a `pixels`-square bitmap: filling it (an adaptive
     * layer is full bleed), or keeping its aspect ratio, centred.
     */
    private static String png(Drawable drawable, int pixels, boolean keepAspect) {
        Bitmap bitmap = Bitmap.createBitmap(pixels, pixels, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        int width = pixels, height = pixels;
        int intrinsicWidth = drawable.getIntrinsicWidth(), intrinsicHeight = drawable.getIntrinsicHeight();
        if (keepAspect && intrinsicWidth > 0 && intrinsicHeight > 0 && intrinsicWidth != intrinsicHeight) {
            if (intrinsicWidth > intrinsicHeight) {
                height = Math.max(1, Math.round(pixels * (float) intrinsicHeight / intrinsicWidth));
            } else {
                width = Math.max(1, Math.round(pixels * (float) intrinsicWidth / intrinsicHeight));
            }
        }
        int left = (pixels - width) / 2, top = (pixels - height) / 2;
        drawable.setBounds(left, top, left + width, top + height);
        drawable.draw(canvas);
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        bitmap.recycle();
        return Base64.getEncoder().encodeToString(out.toByteArray());
    }
}

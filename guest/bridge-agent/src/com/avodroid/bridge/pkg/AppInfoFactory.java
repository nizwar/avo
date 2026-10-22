package com.avodroid.bridge.pkg;

import android.app.usage.StorageStats;
import android.app.usage.StorageStatsManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.AdaptiveIconDrawable;
import android.graphics.drawable.Drawable;
import android.os.Process;
import android.os.storage.StorageManager;

import com.google.protobuf.ByteString;

import com.avodroid.bridge.proto.AdaptiveIcon;
import com.avodroid.bridge.proto.AppInfo;

import java.io.ByteArrayOutputStream;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/** Builds AppInfo messages: label, version, size and launcher icon layers. */
public final class AppInfoFactory {
    /** 108 dp at xxxhdpi; the Mac renders the 72 dp safe zone onto its squircle. */
    private static final int LAYER_SIZE = 432;
    private static final int LEGACY_SIZE = 192;
    private final Context context;
    private final PackageManager pm;

    public AppInfoFactory(Context context) {
        this.context = context;
        this.pm = context.getPackageManager();
    }

    /** Apps with a launcher activity: the ones that get a Mac shortcut. */
    public List<AppInfo> listLaunchable(boolean includeIcons, boolean includeSystem) {
        Intent main = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER);
        Set<String> packages = new HashSet<>();
        for (ResolveInfo info : pm.queryIntentActivities(main, PackageManager.MATCH_ALL)) {
            packages.add(info.activityInfo.packageName);
        }
        List<AppInfo> result = new ArrayList<>();
        for (String name : packages) {
            if (name.equals(context.getPackageName())) continue;
            AppInfo info = describe(name, includeIcons);
            if (info != null && (includeSystem || !info.getSystemApp() || isUserFacingSystemApp(name))) result.add(info);
        }
        return result;
    }

    /** System apps worth a shortcut on the Mac (settings, files, browser). */
    private static boolean isUserFacingSystemApp(String name) {
        return name.equals("com.android.settings") || name.equals("com.android.documentsui")
                || name.equals("com.google.android.documentsui") || name.equals("org.fdroid.fdroid")
                || name.equals("com.aurora.store");
    }

    public AppInfo describe(String packageName, boolean includeIcon) {
        PackageInfo info;
        try {
            info = pm.getPackageInfo(packageName, 0);
        } catch (PackageManager.NameNotFoundException e) {
            return null;
        }
        ApplicationInfo app = info.applicationInfo;
        if (app == null) return null;
        AppInfo.Builder builder = AppInfo.newBuilder()
                .setPackage(packageName)
                .setLabel(String.valueOf(app.loadLabel(pm)))
                .setVersionName(info.versionName == null ? "" : info.versionName)
                .setVersionCode(info.getLongVersionCode())
                .setFirstInstallTimeMs(info.firstInstallTime)
                .setLastUpdateTimeMs(info.lastUpdateTime)
                .setSystemApp((app.flags & ApplicationInfo.FLAG_SYSTEM) != 0)
                .setLaunchable(pm.getLaunchIntentForPackage(packageName) != null);
        String installer = installer(packageName);
        if (installer != null) builder.setInstallerPackage(installer);
        long size = size(app);
        if (size > 0) builder.setSizeBytes(size);
        if (includeIcon) addIcon(builder, app);
        return builder.build();
    }

    private String installer(String packageName) {
        try {
            String name = pm.getInstallSourceInfo(packageName).getInstallingPackageName();
            return name;
        } catch (PackageManager.NameNotFoundException e) {
            return null;
        }
    }

    private long size(ApplicationInfo app) {
        try {
            StorageStatsManager stats = context.getSystemService(StorageStatsManager.class);
            StorageStats s = stats.queryStatsForPackage(StorageManager.UUID_DEFAULT, app.packageName, Process.myUserHandle());
            return s.getAppBytes() + s.getDataBytes() + s.getCacheBytes();
        } catch (Exception e) {
            return 0;
        }
    }

    private void addIcon(AppInfo.Builder builder, ApplicationInfo app) {
        Drawable icon = app.loadUnbadgedIcon(pm);
        if (icon instanceof AdaptiveIconDrawable adaptive) {
            AdaptiveIcon.Builder layers = AdaptiveIcon.newBuilder();
            if (adaptive.getBackground() != null) layers.setBackgroundPng(png(adaptive.getBackground(), LAYER_SIZE));
            if (adaptive.getForeground() != null) layers.setForegroundPng(png(adaptive.getForeground(), LAYER_SIZE));
            if (adaptive.getMonochrome() != null) layers.setMonochromePng(png(adaptive.getMonochrome(), LAYER_SIZE));
            builder.setAdaptiveIcon(layers);
        }
        builder.setIconPng(png(icon, LEGACY_SIZE));
    }

    /** `drawable` on a `size`-square bitmap, which the caller recycles. */
    public static Bitmap render(Drawable drawable, int size) {
        Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, size, size);
        drawable.draw(canvas);
        return bitmap;
    }

    public static ByteString pngOf(Bitmap bitmap) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out);
        return ByteString.copyFrom(out.toByteArray());
    }

    static ByteString png(Drawable drawable, int size) {
        Bitmap bitmap = render(drawable, size);
        ByteString png = pngOf(bitmap);
        bitmap.recycle();
        return png;
    }
}

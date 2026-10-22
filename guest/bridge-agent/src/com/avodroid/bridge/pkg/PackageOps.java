package com.avodroid.bridge.pkg;

import android.app.ActivityManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.IntentSender;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.content.pm.PackageManager;
import android.content.pm.PermissionInfo;
import android.os.Handler;
import android.os.Process;
import android.os.UserHandle;

import com.avodroid.bridge.Hidden;
import com.avodroid.bridge.proto.Permission;

import java.io.File;
import java.io.FileInputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

/** Control Panel › Aplikasi actions, done with PackageManager directly. */
public final class PackageOps {
    private static final String ACTION_RESULT = "com.avodroid.bridge.PACKAGE_RESULT";
    private final Context context;
    private final PackageManager pm;
    private final Handler handler;

    public PackageOps(Context context, Handler handler) {
        this.context = context;
        this.pm = context.getPackageManager();
        this.handler = handler;
    }

    public void forceStop(String packageName) {
        Hidden.call(context.getSystemService(ActivityManager.class), "forceStopPackage", new Class<?>[]{String.class}, packageName);
    }

    /** "Clear data": removes the app's data and cache. */
    public void deleteData(String packageName) {
        Class<?> observer = Hidden.type("android.content.pm.IPackageDataObserver");
        Object ok = Hidden.call(context.getSystemService(ActivityManager.class), "clearApplicationUserData",
                new Class<?>[]{String.class, observer}, packageName, null);
        if (!Boolean.TRUE.equals(ok)) throw new IllegalStateException("could not clear data of " + packageName);
    }

    public List<Permission> permissions(String packageName) throws PackageManager.NameNotFoundException {
        PackageInfo info = pm.getPackageInfo(packageName, PackageManager.GET_PERMISSIONS);
        List<Permission> result = new ArrayList<>();
        if (info.requestedPermissions == null) return result;
        for (int i = 0; i < info.requestedPermissions.length; i++) {
            String name = info.requestedPermissions[i];
            boolean granted = (info.requestedPermissionsFlags[i] & PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0;
            Permission.Builder permission = Permission.newBuilder().setName(name).setGranted(granted);
            try {
                PermissionInfo details = pm.getPermissionInfo(name, 0);
                permission.setLabel(String.valueOf(details.loadLabel(pm)));
                permission.setRuntime(details.getProtection() == PermissionInfo.PROTECTION_DANGEROUS);
            } catch (PackageManager.NameNotFoundException ignored) {
                permission.setLabel(name);
            }
            result.add(permission.build());
        }
        return result;
    }

    public void setPermission(String packageName, String permission, boolean granted) {
        Hidden.call(pm, granted ? "grantRuntimePermission" : "revokeRuntimePermission",
                new Class<?>[]{String.class, String.class, UserHandle.class}, packageName, permission, Process.myUserHandle());
    }

    public void uninstall(String packageName) throws Exception {
        try (Result result = new Result()) {
            context.getPackageManager().getPackageInstaller().uninstall(packageName, result.sender);
            check(result.get(2));
        }
    }

    /** Installs APKs already on the guest (split sets in one session). */
    public void install(String path, List<String> splits) throws Exception {
        PackageInstaller installer = pm.getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        int id = installer.createSession(params);
        boolean committed = false;
        try (PackageInstaller.Session session = installer.openSession(id)) {
            List<String> files = new ArrayList<>();
            files.add(path);
            files.addAll(splits);
            for (int i = 0; i < files.size(); i++) {
                File file = new File(files.get(i));
                try (InputStream in = new FileInputStream(file);
                     OutputStream out = session.openWrite(i == 0 ? "base.apk" : "split_" + i + ".apk", 0, file.length())) {
                    in.transferTo(out);
                    session.fsync(out);
                }
            }
            try (Result result = new Result()) {
                session.commit(result.sender);
                committed = true;
                check(result.get(5));
            }
        } finally {
            // Closing a session keeps it, and the APKs copied into it so far stay
            // on /data until Android expires it days later.
            if (!committed) {
                try {
                    installer.abandonSession(id);
                } catch (RuntimeException ignored) {
                }
            }
        }
    }

    /**
     * One operation's result. Its own action makes its own PendingIntent, so two
     * operations at once (the workers are two) cannot take each other's result;
     * closing it drops the receiver, also when the result never came.
     */
    private final class Result implements AutoCloseable {
        private final CompletableFuture<Intent> future = new CompletableFuture<>();
        private final BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context c, Intent intent) {
                future.complete(intent);
            }
        };
        private final PendingIntent pending;
        final IntentSender sender;

        Result() {
            String action = ACTION_RESULT + "." + UUID.randomUUID();
            pending = PendingIntent.getBroadcast(context, 0, new Intent(action).setPackage(context.getPackageName()),
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
            sender = pending.getIntentSender();
            context.registerReceiver(receiver, new IntentFilter(action), null, handler, Context.RECEIVER_NOT_EXPORTED);
        }

        Intent get(long minutes) throws Exception {
            return future.get(minutes, TimeUnit.MINUTES);
        }

        @Override
        public void close() {
            context.unregisterReceiver(receiver);
            pending.cancel();
        }
    }

    private static void check(Intent result) {
        int status = result.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        if (status != PackageInstaller.STATUS_SUCCESS) {
            String message = result.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
            throw new IllegalStateException(message == null ? "PackageInstaller status " + status : message);
        }
    }
}

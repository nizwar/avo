package com.avodroid.bridge.pkg;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.Uri;

import com.avodroid.bridge.Bridge;
import com.avodroid.bridge.proto.AppInfo;
import com.avodroid.bridge.proto.AppInstalled;
import com.avodroid.bridge.proto.AppRemoved;
import com.avodroid.bridge.proto.Envelope;

/**
 * PACKAGE_ADDED / PACKAGE_REMOVED → AppInstalled / AppRemoved, including apps
 * installed from inside Android (F-Droid, Aurora Store), spec §2.
 */
public final class PackageEvents extends BroadcastReceiver {
    private final Bridge bridge;

    public PackageEvents(Bridge bridge) {
        this.bridge = bridge;
    }

    public void register() {
        IntentFilter filter = new IntentFilter();
        filter.addAction(Intent.ACTION_PACKAGE_ADDED);
        filter.addAction(Intent.ACTION_PACKAGE_REMOVED);
        filter.addAction(Intent.ACTION_PACKAGE_CHANGED);
        filter.addDataScheme("package");
        bridge.context.registerReceiver(this, filter, null, bridge.handler, Context.RECEIVER_NOT_EXPORTED);
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        Uri data = intent.getData();
        if (data == null) return;
        String packageName = data.getSchemeSpecificPart();
        boolean replacing = intent.getBooleanExtra(Intent.EXTRA_REPLACING, false);
        switch (String.valueOf(intent.getAction())) {
            case Intent.ACTION_PACKAGE_ADDED, Intent.ACTION_PACKAGE_CHANGED -> {
                AppInfo info = bridge.apps.describe(packageName, true);
                if (info == null || !info.getLaunchable()) return;
                bridge.send(Envelope.newBuilder().setAppInstalled(
                        AppInstalled.newBuilder().setApp(info).setReplacing(replacing)));
            }
            case Intent.ACTION_PACKAGE_REMOVED -> bridge.send(Envelope.newBuilder().setAppRemoved(
                    AppRemoved.newBuilder().setPackage(packageName).setReplacing(replacing)));
            default -> { }
        }
    }
}

package com.avodroid.bridge;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Belt and braces next to android:persistent: make sure the bridge runs after boot. */
public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        Bridge.start(context);
    }
}

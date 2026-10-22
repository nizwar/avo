package com.avodroid.bridge;

import android.app.Service;
import android.content.Intent;
import android.os.IBinder;

/** Keeps a started component around the bridge; the work lives in Bridge. */
public final class BridgeService extends Service {
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Bridge.start(this);
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}

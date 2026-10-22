package com.avodroid.bridge;

import android.app.Application;

/** Persistent system app: the system starts this process at boot and keeps it alive. */
public final class BridgeApplication extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        Bridge.start(this);
    }
}

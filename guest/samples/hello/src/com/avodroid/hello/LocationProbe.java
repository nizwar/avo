package com.avodroid.hello;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.location.LocationManager;

/**
 * Asks Android's GPS for one fix and posts it as a notification (real or
 * mock), to check Avo's location and notification paths from adb:
 * {@code adb shell am broadcast -n com.avodroid.hello/.LocationProbe}.
 */
public final class LocationProbe extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        PendingResult result = goAsync();
        LocationManager manager = context.getSystemService(LocationManager.class);
        try {
            manager.getCurrentLocation(LocationManager.GPS_PROVIDER, null, context.getMainExecutor(), location -> {
                Notifier.post(context, "GPS", location == null ? "Tidak ada fix GPS"
                        : String.format("%.5f, %.5f ±%.0f m (%s)", location.getLatitude(), location.getLongitude(),
                                        location.getAccuracy(), location.isMock() ? "mock" : "asli"));
                result.finish();
            });
        } catch (SecurityException e) {
            Notifier.post(context, "GPS", "Izin lokasi belum diberikan");
            result.finish();
        }
    }
}

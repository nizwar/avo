package com.avodroid.hello;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Posts a notification, to see Avo pass it on to macOS. The "Kirim
 * notifikasi" button uses it, and so can adb:
 * {@code adb shell am broadcast -n com.avodroid.hello/.Notifier --es text "Halo"}.
 */
public final class Notifier extends BroadcastReceiver {
    private static final String CHANNEL = "hello";

    @Override
    public void onReceive(Context context, Intent intent) {
        String text = intent.getStringExtra("text");
        post(context, "Avo Hello", text != null ? text : "Halo dari Android!");
    }

    static void post(Context context, String title, String text) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL, "Pesan", NotificationManager.IMPORTANCE_DEFAULT));
        Intent open = new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        Notification notification = new Notification.Builder(context, CHANNEL)
                .setSmallIcon(android.R.drawable.ic_dialog_info)
                .setContentTitle(title)
                .setContentText(text)
                .setAutoCancel(true)
                .setContentIntent(PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_IMMUTABLE))
                .build();
        manager.notify((int) (System.currentTimeMillis() % 100000), notification);
    }
}

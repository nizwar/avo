package com.avodroid.widgets;

import android.appwidget.AppWidgetHost;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.ComponentName;
import android.content.Context;
import android.content.SharedPreferences;

/**
 * The one widget host of the app. Android keeps one listener per host id,
 * so every WidgetActivity shares this host (and its updates) instead of
 * starting its own. A slot is the Mac's name for one widget panel; it keeps
 * its Android widget id here, so the panel shows the same widget after
 * Android or the Mac restarts.
 */
final class Widgets {
    /** "Avo" in ASCII: any number does, as long as it stays the same. */
    static final int HOST_ID = 0x41766f;

    private static AppWidgetHost host;
    private static int listeners;

    private Widgets() {}

    static synchronized AppWidgetHost host(Context context) {
        if (host == null) host = new AppWidgetHost(context.getApplicationContext(), HOST_ID);
        return host;
    }

    /** An activity shows a widget: the host listens while any does. */
    static synchronized void startListening(Context context) {
        if (listeners++ == 0) host(context).startListening();
    }

    static synchronized void stopListening(Context context) {
        if (listeners > 0 && --listeners == 0) host(context).stopListening();
    }

    private static SharedPreferences slots(Context context) {
        return context.getSharedPreferences("slots", Context.MODE_PRIVATE);
    }

    /** The widget id `slot` has, if Android still has that widget of `provider`. */
    static int widget(Context context, String slot, ComponentName provider) {
        int id = slots(context).getInt(slot, -1);
        if (id < 0) return -1;
        AppWidgetProviderInfo info = AppWidgetManager.getInstance(context).getAppWidgetInfo(id);
        if (info == null || !info.provider.equals(provider)) {
            forget(context, slot, false);
            return -1;
        }
        return id;
    }

    static void remember(Context context, String slot, int id) {
        slots(context).edit().putInt(slot, id).apply();
    }

    /** The panel was removed on the Mac (or its widget is gone): Android lets go of the widget. */
    static boolean forget(Context context, String slot, boolean delete) {
        int id = slots(context).getInt(slot, -1);
        slots(context).edit().remove(slot).apply();
        if (id < 0) return false;
        if (delete) host(context).deleteAppWidgetId(id);
        return true;
    }
}

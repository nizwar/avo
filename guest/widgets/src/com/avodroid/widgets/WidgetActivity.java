package com.avodroid.widgets;

import android.app.Activity;
import android.appwidget.AppWidgetHostView;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.ComponentName;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.Color;
import android.hardware.display.DisplayManager;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.util.SizeF;
import android.view.Display;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.widget.FrameLayout;
import java.util.Collections;

/**
 * One widget, filling a display of its own that a panel on the Mac shows.
 * Started by the daemon with `avo-widget://SLOT?provider=PACKAGE/CLASS` as
 * its data: the slot's widget is shown again, or a new one of that provider
 * is bound (Avo granted the app that, `appwidget grantbind`) and, when the
 * widget wants it, set up by its configuration activity first.
 *
 * The activity ends with its display: a panel closed on the Mac unplugs the
 * display, and Android would otherwise move it to its own screen.
 */
public final class WidgetActivity extends Activity implements DisplayManager.DisplayListener {
    private static final String TAG = "AvoWidgets";
    private static final int REQUEST_BIND = 1;
    private static final int REQUEST_CONFIGURE = 2;

    private String slot;
    private ComponentName provider;
    private int pendingId = -1;
    private AppWidgetHostView view;
    private boolean listening;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().getDecorView().setBackgroundColor(Color.TRANSPARENT);
        WindowInsetsController insets = getWindow().getInsetsController();
        if (insets != null) insets.hide(WindowInsets.Type.systemBars());
        getSystemService(DisplayManager.class).registerDisplayListener(this, null);

        Uri data = getIntent().getData();
        slot = data == null ? null : data.getHost();
        String flat = data == null ? null : data.getQueryParameter("provider");
        provider = flat == null ? null : ComponentName.unflattenFromString(flat);
        if (slot == null || provider == null || getDisplay().getDisplayId() == Display.DEFAULT_DISPLAY) {
            Log.w(TAG, "nothing to show: " + data);
            finish();
            return;
        }
        int id = Widgets.widget(this, slot, provider);
        if (id >= 0) {
            show(id);
            return;
        }
        pendingId = Widgets.host(this).allocateAppWidgetId();
        if (AppWidgetManager.getInstance(this).bindAppWidgetIdIfAllowed(pendingId, provider)) {
            configureOrShow(pendingId);
        } else {
            // Not granted (yet): Android asks the user, once per app if they say so.
            Intent bind = new Intent(AppWidgetManager.ACTION_APPWIDGET_BIND)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, pendingId)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_PROVIDER, provider);
            startActivityForResult(bind, REQUEST_BIND);
        }
    }

    private void configureOrShow(int id) {
        AppWidgetProviderInfo info = AppWidgetManager.getInstance(this).getAppWidgetInfo(id);
        if (info == null) {
            failed(id, "no provider info");
            return;
        }
        if (info.configure != null && (info.widgetFeatures & AppWidgetProviderInfo.WIDGET_FEATURE_CONFIGURATION_OPTIONAL) == 0) {
            try {
                Widgets.host(this).startAppWidgetConfigureActivityForResult(this, id, 0, REQUEST_CONFIGURE, null);
                return;
            } catch (RuntimeException error) {
                // A configuration activity that cannot start: the widget as it comes.
                Log.w(TAG, "cannot configure " + provider.flattenToShortString(), error);
            }
        }
        show(id);
    }

    @Override
    protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (pendingId < 0) return;
        if (result != RESULT_OK && request == REQUEST_BIND) {
            failed(pendingId, "not allowed to bind");
            return;
        }
        // Settings closed without Done: the widget as it comes (the Mac's
        // panel removes it), never an empty panel that keeps asking.
        if (request == REQUEST_BIND) configureOrShow(pendingId);
        else show(pendingId);
    }

    private void failed(int id, String why) {
        Log.w(TAG, provider.flattenToShortString() + ": " + why);
        Widgets.host(this).deleteAppWidgetId(id);
        pendingId = -1;
        finish();
    }

    private void show(int id) {
        pendingId = -1;
        Widgets.remember(this, slot, id);
        AppWidgetProviderInfo info = AppWidgetManager.getInstance(this).getAppWidgetInfo(id);
        // Taps open their app on Android's own screen, not in this display (MainDisplayContext).
        view = Widgets.host(this).createView(new MainDisplayContext(getApplicationContext()), id, info);
        FrameLayout root = new FrameLayout(this);
        root.addView(view, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setContentView(root);
        // The widget lays out for the panel's size, as a launcher tells it its cell size.
        view.addOnLayoutChangeListener(this::laidOut);
        startListening();
    }

    private void laidOut(View v, int left, int top, int right, int bottom, int oldLeft, int oldTop, int oldRight, int oldBottom) {
        if (right - left == oldRight - oldLeft && bottom - top == oldBottom - oldTop) return;
        float density = getResources().getDisplayMetrics().density;
        SizeF size = new SizeF((right - left) / density, (bottom - top) / density);
        view.updateAppWidgetSize(new Bundle(), Collections.singletonList(size));
    }

    private void startListening() {
        if (listening || view == null) return;
        listening = true;
        Widgets.startListening(this);
    }

    private void stopListening() {
        if (!listening) return;
        listening = false;
        Widgets.stopListening(this);
    }

    @Override
    protected void onStart() {
        super.onStart();
        startListening();
    }

    @Override
    protected void onStop() {
        stopListening();
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        stopListening();
        getSystemService(DisplayManager.class).unregisterDisplayListener(this);
        super.onDestroy();
    }

    /** Moved to Android's own screen (its display went first): nothing shows it there. */
    @Override
    public void onConfigurationChanged(Configuration config) {
        super.onConfigurationChanged(config);
        Display display = getDisplay();
        if (display != null && display.getDisplayId() == Display.DEFAULT_DISPLAY) finish();
    }

    @Override
    public void onDisplayRemoved(int displayId) {
        Display display = getDisplay();
        if (display == null || display.getDisplayId() == displayId) finish();
    }

    @Override
    public void onDisplayAdded(int displayId) {}

    @Override
    public void onDisplayChanged(int displayId) {}
}

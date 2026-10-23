package com.avodroid.widgets;

import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProviderInfo;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.Process;
import android.util.Base64;
import android.util.JsonWriter;
import java.io.ByteArrayOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;

/**
 * What the daemon asks of Avo Widgets through Android's shell:
 *
 * <pre>
 *   content read --uri content://com.avodroid.widgets/providers
 *   content call --uri content://com.avodroid.widgets --method delete --arg SLOT
 * </pre>
 *
 * "providers" is the widgets Android has, as one JSON array: per widget its
 * provider ("package/class"), app package and label, its own label, the size
 * it asks for in dp (min, and the launcher cells it targets), whether and how
 * it resizes (which ways, and its resize limits in dp; a max of 0 sets none),
 * whether it has a configuration step, and a preview (a PNG of at most
 * {@link #PREVIEW} pixels a side, Base64; the app's icon when the widget has
 * none). "delete" lets go of a removed panel's widget.
 *
 * Only Android's shell (and root) may ask: the list says which apps are installed.
 */
public final class WidgetsProvider extends ContentProvider {
    private static final int PREVIEW = 256;

    @Override
    public boolean onCreate() {
        return true;
    }

    private static void checkCaller() {
        int uid = Binder.getCallingUid();
        if (uid != Process.SHELL_UID && uid != Process.ROOT_UID && uid != Process.SYSTEM_UID) {
            throw new SecurityException("Avo Widgets answers Android's shell only");
        }
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        checkCaller();
        if (!"providers".equals(uri.getLastPathSegment())) throw new FileNotFoundException(uri.toString());
        try {
            ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
            byte[] json = providers();
            new Thread(() -> {
                try (ParcelFileDescriptor.AutoCloseOutputStream out = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                    out.write(json);
                } catch (IOException ignored) {
                    // The reader went away.
                }
            }).start();
            return pipe[0];
        } catch (IOException error) {
            throw new FileNotFoundException(error.toString());
        }
    }

    private byte[] providers() throws IOException {
        PackageManager pm = getContext().getPackageManager();
        float density = getContext().getResources().getDisplayMetrics().density;
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (JsonWriter json = new JsonWriter(new OutputStreamWriter(bytes, StandardCharsets.UTF_8))) {
            json.beginArray();
            for (AppWidgetProviderInfo info : AppWidgetManager.getInstance(getContext()).getInstalledProviders()) {
                // Lock screen and search box only widgets are a launcher's own.
                if ((info.widgetCategory & AppWidgetProviderInfo.WIDGET_CATEGORY_HOME_SCREEN) == 0) continue;
                String pkg = info.provider.getPackageName();
                json.beginObject();
                json.name("provider").value(info.provider.flattenToString());
                json.name("package").value(pkg);
                json.name("label").value(info.loadLabel(pm));
                CharSequence app;
                try {
                    app = pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0));
                } catch (PackageManager.NameNotFoundException e) {
                    app = pkg;
                }
                json.name("appLabel").value(app.toString());
                json.name("minWidth").value(Math.round(info.minWidth / density));
                json.name("minHeight").value(Math.round(info.minHeight / density));
                json.name("cellWidth").value(info.targetCellWidth);
                json.name("cellHeight").value(info.targetCellHeight);
                json.name("resizable").value(info.resizeMode != AppWidgetProviderInfo.RESIZE_NONE);
                json.name("resizing").beginObject();
                json.name("horizontal").value((info.resizeMode & AppWidgetProviderInfo.RESIZE_HORIZONTAL) != 0);
                json.name("vertical").value((info.resizeMode & AppWidgetProviderInfo.RESIZE_VERTICAL) != 0);
                json.name("minWidth").value(Math.round(info.minResizeWidth / density));
                json.name("minHeight").value(Math.round(info.minResizeHeight / density));
                json.name("maxWidth").value(Math.round(info.maxResizeWidth / density));
                json.name("maxHeight").value(Math.round(info.maxResizeHeight / density));
                json.endObject();
                json.name("configurable").value(info.configure != null
                        && (info.widgetFeatures & AppWidgetProviderInfo.WIDGET_FEATURE_CONFIGURATION_OPTIONAL) == 0);
                String preview = preview(info, pm);
                if (preview != null) json.name("preview").value(preview);
                json.endObject();
            }
            json.endArray();
        }
        return bytes.toByteArray();
    }

    private String preview(AppWidgetProviderInfo info, PackageManager pm) {
        try {
            Drawable drawable = info.loadPreviewImage(getContext(), 0);
            if (drawable == null) drawable = pm.getApplicationIcon(info.provider.getPackageName());
            int width = Math.max(1, drawable.getIntrinsicWidth()), height = Math.max(1, drawable.getIntrinsicHeight());
            float scale = Math.min(1f, (float) PREVIEW / Math.max(width, height));
            Bitmap bitmap = Bitmap.createBitmap(Math.max(1, Math.round(width * scale)), Math.max(1, Math.round(height * scale)),
                    Bitmap.Config.ARGB_8888);
            drawable.setBounds(0, 0, bitmap.getWidth(), bitmap.getHeight());
            drawable.draw(new Canvas(bitmap));
            ByteArrayOutputStream png = new ByteArrayOutputStream();
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, png);
            return Base64.encodeToString(png.toByteArray(), Base64.NO_WRAP);
        } catch (RuntimeException | PackageManager.NameNotFoundException e) {
            return null;
        }
    }

    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        checkCaller();
        Bundle result = new Bundle();
        if ("delete".equals(method) && arg != null) {
            long token = Binder.clearCallingIdentity();
            try {
                result.putBoolean("deleted", Widgets.forget(getContext(), arg, true));
            } finally {
                Binder.restoreCallingIdentity(token);
            }
        }
        return result;
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] args, String sort) {
        return null;
    }

    @Override
    public String getType(Uri uri) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] args) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] args) {
        return 0;
    }
}

package com.avodroid.bridge.display;

import android.app.ActivityManager;
import android.app.ActivityOptions;
import android.app.ActivityTaskManager;
import android.app.PendingIntent;
import android.app.TaskStackListener;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.display.VirtualDisplayConfig;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.RemoteException;
import android.text.TextUtils;
import android.util.Log;
import android.util.SparseArray;
import android.util.SparseIntArray;
import android.view.Surface;

import com.avodroid.bridge.Bridge;
import com.avodroid.bridge.Hidden;
import com.avodroid.bridge.notify.NotificationBridge;
import com.avodroid.bridge.proto.DisplayContentChanged;
import com.avodroid.bridge.proto.DisplayReady;
import com.avodroid.bridge.proto.Envelope;
import com.avodroid.bridge.proto.Launch;
import com.avodroid.bridge.proto.Orientation;
import com.avodroid.bridge.proto.OrientationRequest;
import com.avodroid.bridge.proto.Resize;
import com.avodroid.bridge.proto.ShareFiles;
import com.avodroid.bridge.proto.TaskClosed;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * One VirtualDisplay per task (spec: "Membuat satu VirtualDisplay per task").
 * Host display ids come from the daemon; each app launched on its display
 * with ActivityOptions.setLaunchDisplayId shows up as its own Mac window.
 *
 * All methods except the task listener callbacks run on the bridge handler.
 */
public final class DisplayController {
    // DisplayManager.VIRTUAL_DISPLAY_FLAG_* (several are @hide).
    private static final int FLAG_PUBLIC = 1;
    private static final int FLAG_OWN_CONTENT_ONLY = 1 << 3;
    private static final int FLAG_SUPPORTS_TOUCH = 1 << 6;
    private static final int FLAG_ROTATES_WITH_CONTENT = 1 << 7;
    private static final int FLAG_DESTROY_CONTENT_ON_REMOVAL = 1 << 8;
    private static final int FLAG_TRUSTED = 1 << 10;
    private static final int FLAG_OWN_DISPLAY_GROUP = 1 << 11;
    private static final int FLAG_ALWAYS_UNLOCKED = 1 << 12;
    private static final int FLAG_OWN_FOCUS = 1 << 14;
    private static final int FLAGS = FLAG_PUBLIC | FLAG_OWN_CONTENT_ONLY | FLAG_SUPPORTS_TOUCH | FLAG_ROTATES_WITH_CONTENT
            | FLAG_DESTROY_CONTENT_ON_REMOVAL | FLAG_TRUSTED | FLAG_OWN_DISPLAY_GROUP | FLAG_ALWAYS_UNLOCKED | FLAG_OWN_FOCUS;

    private final Bridge bridge;
    private final Context context;
    private final DisplayManager displayManager;
    private final FrameSink frames = new GfxstreamFrameSink();
    private final SparseArray<Entry> byHost = new SparseArray<>();
    /** Android display id -> host display id (read from the input thread too). */
    private final SparseIntArray hostByAndroid = new SparseIntArray();
    /** Task id -> Android display id. */
    private final SparseIntArray taskDisplays = new SparseIntArray();
    private int defaultFps = 60;

    private static final class Entry {
        int hostId;
        String packageName;
        VirtualDisplay display;
        int androidId;
        int width;
        int height;
        int dpi;
        Surface surface;
        final Set<Integer> tasks = new HashSet<>();
    }

    public DisplayController(Bridge bridge) {
        this.bridge = bridge;
        this.context = bridge.context;
        this.displayManager = context.getSystemService(DisplayManager.class);
    }

    /** Android display id for a host display, or -1 (Input channel lookup). */
    public synchronized int androidDisplayFor(int hostId) {
        Entry entry = byHost.get(hostId);
        return entry == null ? -1 : entry.androidId;
    }

    public void launch(Launch request) throws Exception {
        if (byHost.get(request.getDisplayId()) != null) throw new IllegalArgumentException("display exists");
        Intent intent = launchIntent(request);
        if (intent == null) throw new IllegalArgumentException(request.getPackage() + " has no launcher activity");

        Entry entry = new Entry();
        entry.hostId = request.getDisplayId();
        entry.packageName = request.getPackage();
        entry.width = request.getWidth();
        entry.height = request.getHeight();
        entry.dpi = request.getDpi();
        int fps = request.getRefreshRate() > 0 ? request.getRefreshRate() : defaultFps;
        try {
            entry.surface = frames.open(entry.hostId, entry.width, entry.height, fps, this::firstFrame);

            VirtualDisplayConfig config = new VirtualDisplayConfig.Builder("avo-" + entry.hostId, entry.width, entry.height, entry.dpi)
                    .setFlags(FLAGS)
                    .setSurface(entry.surface)
                    .setRequestedRefreshRate(fps)
                    .build();
            entry.display = displayManager.createVirtualDisplay(config, bridge.handler, null);
            if (entry.display == null) throw new IllegalStateException("could not create a display");
            entry.androidId = entry.display.getDisplay().getDisplayId();
            synchronized (this) {
                byHost.put(entry.hostId, entry);
                hostByAndroid.put(entry.androidId, entry.hostId);
            }

            ActivityOptions options = ActivityOptions.makeBasic().setLaunchDisplayId(entry.androidId);
            if (!request.getNotificationKey().isEmpty()) {
                PendingIntent content = NotificationBridge.contentIntent(request.getNotificationKey());
                if (content != null) {
                    content.send(context, 0, null, null, null, null, options.toBundle());
                    afterLaunch(entry);
                    return;
                }
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_MULTIPLE_TASK);
            context.startActivity(intent, options.toBundle());
            afterLaunch(entry);
        } catch (Exception e) {
            // The host forgets a display whose launch failed and never sends Close
            // for it: its VirtualDisplay, buffers and host display go now.
            synchronized (this) {
                byHost.remove(entry.hostId);
                if (entry.display != null) hostByAndroid.delete(entry.androidId);
            }
            if (entry.display != null) entry.display.release();
            frames.close(entry.hostId);
            throw e;
        }
    }

    private void afterLaunch(Entry entry) {
        // Without a frame transport (development images) there is no first
        // frame to wait for; announce the display right away.
        if (!frames.postsFrames()) firstFrame(entry.hostId);
    }

    private Intent launchIntent(Launch request) {
        if (!request.getDataUri().isEmpty()) {
            Intent view = new Intent(Intent.ACTION_VIEW);
            Uri uri = Uri.parse(request.getDataUri());
            if (request.getMimeType().isEmpty()) view.setData(uri); else view.setDataAndType(uri, request.getMimeType());
            view.setPackage(request.getPackage());
            view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            return view;
        }
        if (!request.getComponent().isEmpty()) {
            ComponentName component = ComponentName.unflattenFromString(request.getComponent());
            return component == null ? null : new Intent(Intent.ACTION_MAIN).setComponent(component);
        }
        return context.getPackageManager().getLaunchIntentForPackage(request.getPackage());
    }

    private void firstFrame(int hostId) {
        Entry entry;
        synchronized (this) {
            entry = byHost.get(hostId);
        }
        if (entry == null) return;
        bridge.send(Envelope.newBuilder().setDisplayReady(DisplayReady.newBuilder()
                .setDisplayId(hostId).setPackage(entry.packageName)));
    }

    public void resize(Resize request) {
        Entry entry = require(request.getDisplayId());
        entry.width = request.getWidth();
        entry.height = request.getHeight();
        if (request.getDpi() > 0) entry.dpi = request.getDpi();
        Surface surface = frames.resize(entry.hostId, entry.width, entry.height);
        entry.display.resize(entry.width, entry.height, entry.dpi);
        if (surface != null) {
            entry.surface = surface;
            entry.display.setSurface(surface);
        }
    }

    public void close(int hostId) {
        Entry entry;
        synchronized (this) {
            entry = byHost.get(hostId);
            if (entry == null) return;
            byHost.remove(hostId);
            hostByAndroid.delete(entry.androidId);
        }
        // DESTROY_CONTENT_ON_REMOVAL finishes the task instead of moving it to the default display.
        entry.display.release();
        frames.close(hostId);
    }

    /** Minimised windows stop rendering; the app keeps running. */
    public void setVisible(int hostId, boolean visible) {
        Entry entry = require(hostId);
        entry.display.setSurface(visible ? entry.surface : null);
    }

    public void setRefreshRate(int hostId, int fps) {
        if (hostId == 0) {
            defaultFps = fps;
            synchronized (this) {
                for (int i = 0; i < byHost.size(); i++) frames.setMaxFps(byHost.keyAt(i), fps);
            }
        } else {
            require(hostId);
            frames.setMaxFps(hostId, fps);
        }
    }

    /** Files copied to /sdcard/Download by the daemon, shared with the app on the display. */
    public void share(ShareFiles request) throws Exception {
        Entry entry = require(request.getDisplayId());
        String[] paths = request.getPathsList().toArray(new String[0]);
        String[] types = request.getMimeTypesList().toArray(new String[0]);
        ArrayList<Uri> uris = new ArrayList<>();
        CountDownLatch scanned = new CountDownLatch(paths.length);
        MediaScannerConnection.scanFile(context, paths, types, (path, uri) -> {
            if (uri != null) synchronized (uris) { uris.add(uri); }
            scanned.countDown();
        });
        scanned.await(10, TimeUnit.SECONDS);
        if (uris.isEmpty()) throw new IllegalStateException("files could not be indexed");

        Intent share = uris.size() == 1 ? new Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uris.get(0))
                : new Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris);
        share.setType(types.length == 1 ? types[0] : "*/*");
        share.setPackage(entry.packageName);
        share.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_GRANT_READ_URI_PERMISSION);
        ActivityOptions options = ActivityOptions.makeBasic().setLaunchDisplayId(entry.androidId);
        if (share.resolveActivity(context.getPackageManager()) == null) {
            // The app cannot receive shares; leave the files in Downloads.
            Log.i(Bridge.TAG, entry.packageName + " does not accept shared files");
            return;
        }
        context.startActivity(share, options.toBundle());
    }

    private Entry require(int hostId) {
        Entry entry;
        synchronized (this) {
            entry = byHost.get(hostId);
        }
        if (entry == null) throw new IllegalArgumentException("no display " + hostId);
        return entry;
    }

    // MARK: Task tracking

    public void watchTasks() {
        try {
            ActivityTaskManager.getService().registerTaskStackListener(new Listener());
        } catch (RemoteException | RuntimeException e) {
            Log.e(Bridge.TAG, "cannot watch tasks; windows will not close with their apps", e);
        }
    }

    private final class Listener extends TaskStackListener {
        @Override
        public void onTaskMovedToFront(ActivityManager.RunningTaskInfo info) {
            bridge.handler.post(() -> track(info.taskId, Hidden.intField(info, "displayId", -1)));
        }

        @Override
        public void onTaskDisplayChanged(int taskId, int newDisplayId) {
            bridge.handler.post(() -> track(taskId, newDisplayId));
        }

        @Override
        public void onTaskRemoved(int taskId) {
            bridge.handler.post(() -> taskRemoved(taskId));
        }

        @Override
        public void onTaskDescriptionChanged(ActivityManager.RunningTaskInfo info) {
            CharSequence label = info.taskDescription == null ? null : info.taskDescription.getLabel();
            int androidId = Hidden.intField(info, "displayId", -1);
            bridge.handler.post(() -> {
                int hostId = hostFor(androidId);
                if (hostId <= 0 || TextUtils.isEmpty(label)) return;
                Entry entry = byHost.get(hostId);
                bridge.send(Envelope.newBuilder().setDisplayContentChanged(DisplayContentChanged.newBuilder()
                        .setDisplayId(hostId).setPackage(entry == null ? "" : entry.packageName).setTitle(label.toString())));
            });
        }

        @Override
        public void onTaskRequestedOrientationChanged(int taskId, int requested) {
            bridge.handler.post(() -> {
                int hostId = hostFor(taskDisplays.get(taskId, -1));
                if (hostId <= 0) return;
                bridge.send(Envelope.newBuilder().setOrientationRequest(OrientationRequest.newBuilder()
                        .setDisplayId(hostId).setOrientation(orientation(requested))));
            });
        }
    }

    private synchronized int hostFor(int androidId) {
        return androidId < 0 ? -1 : hostByAndroid.get(androidId, -1);
    }

    private void track(int taskId, int androidId) {
        int previous = taskDisplays.get(taskId, -1);
        if (previous == androidId) return;
        Entry old = byHost.get(hostFor(previous));
        if (old != null) old.tasks.remove(taskId);
        taskDisplays.put(taskId, androidId);
        Entry entry = byHost.get(hostFor(androidId));
        if (entry != null) entry.tasks.add(taskId);
    }

    /** The app finished its last task on a display: close the Mac window too. */
    private void taskRemoved(int taskId) {
        int androidId = taskDisplays.get(taskId, -1);
        taskDisplays.delete(taskId);
        int hostId = hostFor(androidId);
        Entry entry = byHost.get(hostId);
        if (entry == null) return;
        entry.tasks.remove(taskId);
        if (!entry.tasks.isEmpty()) return;
        bridge.send(Envelope.newBuilder().setTaskClosed(TaskClosed.newBuilder()
                .setDisplayId(hostId).setPackage(entry.packageName)));
        close(hostId);
    }

    private static Orientation orientation(int requested) {
        return switch (requested) {
            case ActivityInfo.SCREEN_ORIENTATION_PORTRAIT, ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT,
                 ActivityInfo.SCREEN_ORIENTATION_USER_PORTRAIT -> Orientation.ORIENTATION_PORTRAIT;
            case ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE, ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE,
                 ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE -> Orientation.ORIENTATION_LANDSCAPE;
            case ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT -> Orientation.ORIENTATION_REVERSE_PORTRAIT;
            case ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE -> Orientation.ORIENTATION_REVERSE_LANDSCAPE;
            default -> Orientation.ORIENTATION_UNSPECIFIED;
        };
    }
}

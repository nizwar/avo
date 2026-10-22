package com.avodroid.bridge.control;

import android.util.Log;

import com.avodroid.bridge.Bridge;
import com.avodroid.bridge.notify.NotificationBridge;
import com.avodroid.bridge.proto.AppInfo;
import com.avodroid.bridge.proto.AppList;
import com.avodroid.bridge.proto.Envelope;
import com.avodroid.bridge.proto.PermissionList;
import com.avodroid.bridge.proto.Pong;
import com.avodroid.bridge.proto.Reply;

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/** Executes host requests and answers each with a Reply or typed response. */
final class RequestHandler {
    private final Bridge bridge;
    private final ControlConnection connection;
    /** Slow work (package manager, icons) runs off the read loop. */
    private final ExecutorService workers = Executors.newFixedThreadPool(2);

    RequestHandler(Bridge bridge, ControlConnection connection) {
        this.bridge = bridge;
        this.connection = connection;
    }

    /** The connection is gone: the workers end once the requests they have are done. */
    void shutdown() {
        workers.shutdown();
    }

    void handle(Envelope request) {
        switch (request.getPayloadCase()) {
            case PING -> connection.reply(request, Envelope.newBuilder()
                    .setPong(Pong.newBuilder().setNonce(request.getPing().getNonce())));
            case LAUNCH -> onFramework(request, () -> bridge.displays.launch(request.getLaunch()));
            case RESIZE -> onFramework(request, () -> bridge.displays.resize(request.getResize()));
            case CLOSE -> onFramework(request, () -> bridge.displays.close(request.getClose().getDisplayId()));
            case SET_DISPLAY_VISIBILITY -> onFramework(request, () -> bridge.displays.setVisible(
                    request.getSetDisplayVisibility().getDisplayId(), request.getSetDisplayVisibility().getVisible()));
            case SET_REFRESH_RATE -> onFramework(request, () -> bridge.displays.setRefreshRate(
                    request.getSetRefreshRate().getDisplayId(), request.getSetRefreshRate().getFps()));
            case SHARE_FILES -> onFramework(request, () -> bridge.displays.share(request.getShareFiles()));
            case LIST_APPS -> workers.execute(() -> {
                // Uncaught, an exception on a worker (one app's broken icon) kills the agent.
                try {
                    List<AppInfo> apps = bridge.apps.listLaunchable(request.getListApps().getIncludeIcons(),
                            request.getListApps().getIncludeSystem());
                    connection.reply(request, Envelope.newBuilder().setAppList(AppList.newBuilder().addAllApps(apps)));
                } catch (Exception e) {
                    fail(request, Reply.Status.STATUS_FAILED, e);
                }
            });
            case GET_PERMISSIONS -> workers.execute(() -> {
                String pkg = request.getGetPermissions().getPackage();
                try {
                    connection.reply(request, Envelope.newBuilder().setPermissionList(PermissionList.newBuilder()
                            .setPackage(pkg).addAllPermissions(bridge.packages.permissions(pkg))));
                } catch (Exception e) {
                    fail(request, Reply.Status.STATUS_NOT_FOUND, e);
                }
            });
            case SET_PERMISSION -> onWorker(request, () -> bridge.packages.setPermission(
                    request.getSetPermission().getPackage(), request.getSetPermission().getPermission(),
                    request.getSetPermission().getGranted()));
            case INSTALL -> onWorker(request, () -> bridge.packages.install(
                    request.getInstall().getPath(), request.getInstall().getSplitPathsList()));
            case UNINSTALL -> onWorker(request, () -> bridge.packages.uninstall(request.getUninstall().getPackage()));
            case FORCE_STOP -> onWorker(request, () -> bridge.packages.forceStop(request.getForceStop().getPackage()));
            case DELETE_APP_DATA -> onWorker(request, () -> bridge.packages.deleteData(request.getDeleteAppData().getPackage()));
            case SET_CLIPBOARD -> onFramework(request, () -> bridge.clipboard.set(request.getSetClipboard().getText()));
            case OPEN_NOTIFICATION -> onFramework(request, () -> NotificationBridge.open(
                    request.getOpenNotification().getKey(), request.getOpenNotification().getDisplayId()));
            case DISMISS_NOTIFICATION -> onFramework(request, () -> NotificationBridge.dismiss(
                    request.getDismissNotification().getKey()));
            case GOODBYE -> connection.close();
            default -> {
                if (request.getRequestId() != 0) {
                    connection.reply(request, Envelope.newBuilder().setReply(Reply.newBuilder()
                            .setStatus(Reply.Status.STATUS_UNSUPPORTED).setMessage(request.getPayloadCase().name())));
                }
            }
        }
    }

    interface Action {
        void run() throws Exception;
    }

    /** Runs on the bridge Looper thread (display and window APIs). */
    private void onFramework(Envelope request, Action action) {
        bridge.handler.post(() -> runAndReply(request, action));
    }

    private void onWorker(Envelope request, Action action) {
        workers.execute(() -> runAndReply(request, action));
    }

    private void runAndReply(Envelope request, Action action) {
        try {
            action.run();
            connection.reply(request, Envelope.newBuilder().setReply(Reply.newBuilder().setStatus(Reply.Status.STATUS_OK)));
        } catch (IllegalArgumentException e) {
            fail(request, Reply.Status.STATUS_INVALID_ARGUMENT, e);
        } catch (SecurityException e) {
            fail(request, Reply.Status.STATUS_PERMISSION_DENIED, e);
        } catch (Exception e) {
            fail(request, Reply.Status.STATUS_FAILED, e);
        }
    }

    private void fail(Envelope request, Reply.Status status, Exception e) {
        Log.w(Bridge.TAG, request.getPayloadCase() + " failed", e);
        String message = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
        connection.reply(request, Envelope.newBuilder().setReply(Reply.newBuilder().setStatus(status).setMessage(message)));
    }
}

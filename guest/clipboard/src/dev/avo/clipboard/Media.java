package dev.avo.clipboard;

import android.content.Context;
import android.graphics.Bitmap;
import android.media.MediaMetadata;
import android.media.session.MediaController;
import android.media.session.MediaSessionManager;
import android.media.session.PlaybackState;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.List;
import org.json.JSONObject;

/**
 * What Android plays, for the Mac's Now Playing and media keys:
 *
 * <pre>
 *   CLASSPATH=/data/local/tmp/avo-clipboard.jar app_process / dev.avo.clipboard.Main media watch
 * </pre>
 *
 * prints {@code ready}, then a line each time what plays changes:
 * {@code media JSON}, or {@code media none} when nothing does.
 *
 * <pre>
 *   {"package", "title", "artist", "album", "durationMs", "positionMs", "speed",
 *    "state": "playing" | "paused" | "buffering" | "stopped",
 *    "next", "previous", "seek",            (what the app lets the Mac do)
 *    "artworkJpeg"?}                        (Base64; only when it changed, "" when it went)
 * </pre>
 *
 * It reads commands for what it shows on stdin, one per line: {@code play},
 * {@code pause}, {@code toggle}, {@code next}, {@code previous}, {@code stop},
 * {@code seek MS}. Run it with the raw {@code exec:} service, which gives it
 * that stdin; it ends with it.
 *
 * The session shown is the first playing one in Android's order (the most
 * recently active first), or else the first with something to show; the
 * commands go to that one, not to whichever Android's own media keys would
 * pick. The shell user may see and control every app's sessions
 * (MEDIA_CONTENT_CONTROL).
 */
final class Media {
    /** The longest edge of the artwork sent. */
    private static final int ARTWORK_PIXELS = 512;

    private final MediaSessionManager manager;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final List<MediaController> controllers = new ArrayList<>();
    private final MediaController.Callback callback = new MediaController.Callback() {
        @Override
        public void onPlaybackStateChanged(PlaybackState state) {
            report();
        }

        @Override
        public void onMetadataChanged(MediaMetadata metadata) {
            report();
        }

        @Override
        public void onSessionDestroyed() {
            report();
        }
    };
    /** What the last line said but for the position, and where playing would have started from. */
    private String lastReport;
    private double lastOrigin;
    private byte[] lastArtwork = new byte[0];

    private Media(Context context) throws Exception {
        // An app's process gets this as it starts; app_process does not.
        // Android 17 reads the platform initializer's, older ones the other's.
        Class<?> services = Class.forName("android.media.MediaServiceManager");
        Object registry = services.getConstructor().newInstance();
        for (String name : new String[]{"android.media.MediaFrameworkPlatformInitializer",
                "android.media.MediaFrameworkInitializer"}) {
            try {
                Class.forName(name).getMethod("setMediaServiceManager", services).invoke(null, registry);
            } catch (ClassNotFoundException | NoSuchMethodException absent) {
                // Not in this release.
            }
        }
        manager = context.getSystemService(MediaSessionManager.class);
    }

    static void run(String[] args) throws Exception {
        if (args.length == 0 || !args[0].equals("watch")) {
            System.err.println("usage: media watch");
            System.exit(2);
        }
        new Media(AppInfo.systemContext()).watch();
    }

    private void watch() {
        manager.addOnActiveSessionsChangedListener(this::follow, null, handler);
        follow(manager.getActiveSessions(null));
        System.out.println("ready");
        System.out.flush();
        Thread commands = new Thread(this::readCommands, "commands");
        commands.setDaemon(true);
        commands.start();
        Looper.loop();
    }

    private void readCommands() {
        try (BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8))) {
            for (String line; (line = in.readLine()) != null; ) {
                String command = line.trim();
                if (!command.isEmpty()) handler.post(() -> perform(command));
            }
        } catch (Exception ignored) {
            // The Mac went away.
        }
        System.exit(0);
    }

    private void perform(String command) {
        MediaController shown = shown(controllers);
        if (shown == null) return;
        MediaController.TransportControls controls = shown.getTransportControls();
        String[] words = command.split(" ");
        switch (words[0]) {
            case "play" -> controls.play();
            case "pause" -> controls.pause();
            case "toggle" -> {
                if (playing(shown)) controls.pause(); else controls.play();
            }
            case "next" -> controls.skipToNext();
            case "previous" -> controls.skipToPrevious();
            case "stop" -> controls.stop();
            case "seek" -> {
                if (words.length > 1) controls.seekTo(Long.parseLong(words[1]));
            }
            default -> System.err.println("unknown command " + command);
        }
    }

    /** Listens to each active session's changes. */
    private void follow(List<MediaController> active) {
        for (MediaController controller : controllers) controller.unregisterCallback(callback);
        controllers.clear();
        if (active != null) {
            for (MediaController controller : active) {
                controller.registerCallback(callback, handler);
                controllers.add(controller);
            }
        }
        report();
    }

    private static boolean playing(MediaController controller) {
        PlaybackState state = controller.getPlaybackState();
        return state != null && state.getState() == PlaybackState.STATE_PLAYING;
    }

    private static MediaController shown(List<MediaController> active) {
        for (MediaController controller : active) {
            if (playing(controller)) return controller;
        }
        for (MediaController controller : active) {
            MediaMetadata metadata = controller.getMetadata();
            PlaybackState state = controller.getPlaybackState();
            if (metadata != null && metadata.getString(MediaMetadata.METADATA_KEY_TITLE) != null
                    && state != null && state.getState() != PlaybackState.STATE_NONE) {
                return controller;
            }
        }
        return null;
    }

    private void report() {
        MediaController shown = shown(controllers);
        String line;
        try {
            if (shown == null) {
                if ("none".equals(lastReport)) return;
                lastReport = "none";
                lastArtwork = new byte[0];
                line = "media none";
            } else {
                PlaybackState state = shown.getPlaybackState();
                JSONObject json = describe(shown);
                String report = json.toString();
                // Android moves the position on with the clock each time it
                // is read; a seek moves where it started from.
                double origin = state == null ? 0
                        : state.getPosition() - state.getLastPositionUpdateTime() * (double) state.getPlaybackSpeed();
                byte[] artwork = artwork(shown.getMetadata());
                boolean artworkChanged = !Arrays.equals(artwork, lastArtwork);
                if (report.equals(lastReport) && Math.abs(origin - lastOrigin) < 250 && !artworkChanged) return;
                lastReport = report;
                lastOrigin = origin;
                json.put("positionMs", position(state));
                if (artworkChanged) {
                    lastArtwork = artwork;
                    json.put("artworkJpeg", Base64.getEncoder().encodeToString(artwork));
                }
                line = "media " + json;
            }
        } catch (Exception error) {
            return;
        }
        System.out.println(line);
        System.out.flush();
    }

    /** All but the position and the artwork. */
    private static JSONObject describe(MediaController controller) throws Exception {
        MediaMetadata metadata = controller.getMetadata();
        PlaybackState state = controller.getPlaybackState();
        JSONObject json = new JSONObject();
        json.put("package", controller.getPackageName());
        json.put("title", text(metadata, MediaMetadata.METADATA_KEY_TITLE));
        String artist = text(metadata, MediaMetadata.METADATA_KEY_ARTIST);
        json.put("artist", artist.isEmpty() ? text(metadata, MediaMetadata.METADATA_KEY_ALBUM_ARTIST) : artist);
        json.put("album", text(metadata, MediaMetadata.METADATA_KEY_ALBUM));
        json.put("durationMs", metadata == null ? 0 : Math.max(metadata.getLong(MediaMetadata.METADATA_KEY_DURATION), 0));
        long actions = state == null ? 0 : state.getActions();
        json.put("next", (actions & PlaybackState.ACTION_SKIP_TO_NEXT) != 0);
        json.put("previous", (actions & PlaybackState.ACTION_SKIP_TO_PREVIOUS) != 0);
        json.put("seek", (actions & PlaybackState.ACTION_SEEK_TO) != 0);
        json.put("state", state == null ? "stopped" : name(state.getState()));
        json.put("speed", state == null ? 0.0 : (double) state.getPlaybackSpeed());
        return json;
    }

    /** Where it is now, not where it was when the app last said. */
    private static long position(PlaybackState state) {
        if (state == null) return 0;
        long position = state.getPosition();
        if (state.getState() == PlaybackState.STATE_PLAYING && state.getLastPositionUpdateTime() > 0) {
            position += (long) ((SystemClock.elapsedRealtime() - state.getLastPositionUpdateTime()) * state.getPlaybackSpeed());
        }
        return Math.max(position, 0);
    }

    private static String text(MediaMetadata metadata, String key) {
        if (metadata == null) return "";
        CharSequence text = metadata.getText(key);
        return text == null ? "" : text.toString();
    }

    private static String name(int state) {
        switch (state) {
            case PlaybackState.STATE_PLAYING:
            case PlaybackState.STATE_FAST_FORWARDING:
            case PlaybackState.STATE_REWINDING:
                return "playing";
            case PlaybackState.STATE_BUFFERING:
            case PlaybackState.STATE_CONNECTING:
            case PlaybackState.STATE_SKIPPING_TO_NEXT:
            case PlaybackState.STATE_SKIPPING_TO_PREVIOUS:
            case PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM:
                return "buffering";
            case PlaybackState.STATE_PAUSED:
                return "paused";
            default:
                return "stopped";
        }
    }

    private static byte[] artwork(MediaMetadata metadata) {
        if (metadata == null) return new byte[0];
        Bitmap bitmap = metadata.getBitmap(MediaMetadata.METADATA_KEY_ART);
        if (bitmap == null) bitmap = metadata.getBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART);
        if (bitmap == null) bitmap = metadata.getBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON);
        if (bitmap == null || bitmap.getWidth() <= 0 || bitmap.getHeight() <= 0) return new byte[0];
        float scale = Math.min(1f, (float) ARTWORK_PIXELS / Math.max(bitmap.getWidth(), bitmap.getHeight()));
        Bitmap scaled = scale < 1f ? Bitmap.createScaledBitmap(bitmap, Math.max(1, Math.round(bitmap.getWidth() * scale)),
                Math.max(1, Math.round(bitmap.getHeight() * scale)), true) : bitmap;
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        scaled.compress(Bitmap.CompressFormat.JPEG, 90, out);
        return out.toByteArray();
    }
}

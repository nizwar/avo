package com.avodroid.hello;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.DashPathEffect;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.SparseArray;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Random;

/**
 * Arena: a small game whose on-screen controls sit where the sample keymap
 * profile (keymap/com.avodroid.hello.json) puts its controls, so every kind of
 * Avo key mapping control can be checked by playing:
 *
 * <pre>
 *   joystick, bottom left    dpad  "move"   (W A S D)
 *   LOMPAT button            tap   "jump"   (Space)
 *   TEMBAK button            tap   "fire"   (J)
 *   PERISAI button           hold  "shield" (K, while held)
 *   aim area, top right      aim   "aim"    (the eye: F8 locks the mouse)
 *   swipe anywhere else      swipe "dash"   (E)
 *   EMOSI wheel              anchor "emote" (hold B, move the mouse, let go)
 * </pre>
 *
 * Positions are fractions of the view and radii fractions of its height,
 * the same normalization as Avo's profiles, so the layout follows any window
 * size. Every touch is drawn with its pointer id, and keys that arrive
 * unmapped are shown, which makes it easy to see what a mapping sends.
 */
final class GameView extends View {
    // Keep in sync with keymap/com.avodroid.hello.json.
    static final float STICK_X = 0.18f, STICK_Y = 0.78f, STICK_R = 0.11f;
    static final float JUMP_X = 0.88f, JUMP_Y = 0.80f;
    static final float FIRE_X = 0.74f, FIRE_Y = 0.88f;
    static final float SHIELD_X = 0.88f, SHIELD_Y = 0.62f;
    static final float EMOTE_X = 0.50f, EMOTE_Y = 0.90f, WHEEL_R = 0.13f;
    static final float BUTTON_R = 0.055f;
    private static final String[] EMOTES = {"😀", "👍", "😂", "😮", "😡", "❤️"};
    static final RectF AIM = new RectF(0.55f, 0.08f, 1.0f, 0.50f);

    private static final long JUMP_MS = 450, DASH_MS = 220, PRESS_FLASH_MS = 160;

    private enum Role { STICK, JUMP, FIRE, SHIELD, EMOTE, AIM, ARENA }

    private static final class Touch {
        final Role role;
        final float startX, startY;
        final long downAt;
        float x, y;

        Touch(Role role, float x, float y, long downAt) {
            this.role = role;
            this.startX = this.x = x;
            this.startY = this.y = y;
            this.downAt = downAt;
        }
    }

    /** Active touches by pointer id. */
    private final SparseArray<Touch> touches = new SparseArray<>();

    // The scene, in fractions of the view so a resize keeps it.
    private float playerX = 0.35f, playerY = 0.62f;
    private float crossX = 0.78f, crossY = 0.28f;
    private float stickX, stickY;
    private long jumpStart = -1, dashUntil, hitFlashUntil, jumpPressed, firePressed;
    private float dashX, dashY;
    private int score, shots, jumps, dashes, emotes;
    private String shownEmote;
    private long emoteUntil;
    private String status = "Sentuh kontrolnya, atau pasang key mapping lewat ikon keyboard di title bar.";
    /** Bullets: x, y, vx, vy (fractions, per second). Targets: x, y. */
    private final List<float[]> bullets = new ArrayList<>();
    private final List<float[]> targets = new ArrayList<>();
    private final Random random = new Random();
    private long lastFrame;

    private final float density;
    private final Paint fill = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint stroke = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint dashed = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint label = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Paint hud = new Paint(Paint.ANTI_ALIAS_FLAG);

    GameView(Context context) {
        super(context);
        density = getResources().getDisplayMetrics().density;
        setFocusable(true);
        setFocusableInTouchMode(true);
        stroke.setStyle(Paint.Style.STROKE);
        stroke.setStrokeWidth(2.5f * density);
        dashed.setStyle(Paint.Style.STROKE);
        dashed.setStrokeWidth(1.5f * density);
        dashed.setColor(Color.argb(150, 0xd8, 0xe8, 0xa7));
        dashed.setPathEffect(new DashPathEffect(new float[] {8 * density, 6 * density}, 0));
        label.setTextAlign(Paint.Align.CENTER);
        label.setFakeBoldText(true);
        hud.setColor(Color.rgb(0xfb, 0xf8, 0xf1));
        for (int i = 0; i < 3; i++) targets.add(newTarget());
    }

    // MARK: State

    void save(Bundle state) {
        state.putFloatArray("arena", new float[] {playerX, playerY, crossX, crossY});
        state.putIntArray("counts", new int[] {score, shots, jumps, dashes, emotes});
    }

    void restore(Bundle state) {
        float[] arena = state.getFloatArray("arena");
        int[] counts = state.getIntArray("counts");
        if (arena != null && arena.length == 4) {
            playerX = arena[0];
            playerY = arena[1];
            crossX = arena[2];
            crossY = arena[3];
        }
        if (counts != null && counts.length == 5) {
            score = counts[0];
            shots = counts[1];
            jumps = counts[2];
            dashes = counts[3];
            emotes = counts[4];
        }
    }

    void keyPressed(int keyCode) {
        String name = KeyEvent.keyCodeToString(keyCode).replace("KEYCODE_", "");
        status = "Tombol " + name + " tidak dipetakan: sampai ke game sebagai tombol, bukan sentuhan.";
        invalidate();
    }

    // MARK: Touch

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        long now = SystemClock.uptimeMillis();
        switch (event.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
            case MotionEvent.ACTION_POINTER_DOWN: {
                int index = event.getActionIndex();
                float x = event.getX(index), y = event.getY(index);
                Touch touch = new Touch(roleAt(x, y), x, y, now);
                touches.put(event.getPointerId(index), touch);
                pressed(touch, now);
                break;
            }
            case MotionEvent.ACTION_MOVE:
                for (int i = 0; i < event.getPointerCount(); i++) {
                    Touch touch = touches.get(event.getPointerId(i));
                    if (touch == null) continue;
                    float x = event.getX(i), y = event.getY(i);
                    if (touch.role == Role.AIM) aimBy(x - touch.x, y - touch.y);
                    touch.x = x;
                    touch.y = y;
                }
                break;
            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_POINTER_UP: {
                int id = event.getPointerId(event.getActionIndex());
                Touch touch = touches.get(id);
                touches.remove(id);
                if (touch != null) released(touch, event.getX(event.getActionIndex()), event.getY(event.getActionIndex()), now);
                break;
            }
            case MotionEvent.ACTION_CANCEL:
                touches.clear();
                break;
            default:
                break;
        }
        updateStick();
        invalidate();
        return true;
    }

    private Role roleAt(float x, float y) {
        float w = getWidth(), h = getHeight();
        if (near(x, y, JUMP_X * w, JUMP_Y * h, BUTTON_R * h * 1.25f)) return Role.JUMP;
        if (near(x, y, FIRE_X * w, FIRE_Y * h, BUTTON_R * h * 1.25f)) return Role.FIRE;
        if (near(x, y, SHIELD_X * w, SHIELD_Y * h, BUTTON_R * h * 1.25f)) return Role.SHIELD;
        if (near(x, y, EMOTE_X * w, EMOTE_Y * h, BUTTON_R * h * 1.25f)) return Role.EMOTE;
        if (near(x, y, STICK_X * w, STICK_Y * h, STICK_R * h * 1.6f)) return Role.STICK;
        if (AIM.contains(x / w, y / h)) return Role.AIM;
        return Role.ARENA;
    }

    private static boolean near(float x, float y, float cx, float cy, float r) {
        return Math.hypot(x - cx, y - cy) <= r;
    }

    private void pressed(Touch touch, long now) {
        switch (touch.role) {
            case JUMP:
                jumpPressed = now;
                if (jumpStart < 0 || now - jumpStart > JUMP_MS) {
                    jumpStart = now;
                    jumps++;
                    status = "Lompat!";
                }
                break;
            case FIRE:
                firePressed = now;
                fire();
                break;
            case SHIELD:
                status = "Perisai aktif selama tombol ditahan.";
                break;
            case EMOTE:
                status = "Roda emoji: geser ke arah emoji, lalu lepas.";
                break;
            default:
                break;
        }
    }

    private void released(Touch touch, float x, float y, long now) {
        if (touch.role == Role.SHIELD && !holding(Role.SHIELD)) status = "Perisai lepas.";
        if (touch.role == Role.EMOTE) {
            int chosen = emoteAt(x, y);
            if (chosen >= 0) {
                shownEmote = EMOTES[chosen];
                emoteUntil = now + 1800;
                emotes++;
                status = "Emoji " + shownEmote + " dipilih.";
            } else {
                status = "Roda emoji ditutup tanpa memilih.";
            }
            return;
        }
        if (touch.role != Role.ARENA) return;
        float h = getHeight();
        float dx = x - touch.startX, dy = y - touch.startY;
        double distance = Math.hypot(dx, dy);
        if (distance > 0.07f * h && now - touch.downAt < 900) {
            // A swipe: dash that way.
            dashX = (float) (dx / distance);
            dashY = (float) (dy / distance);
            dashUntil = now + DASH_MS;
            dashes++;
            status = "Swipe " + arrow(dx, dy) + ": dash!";
        } else if (distance < 0.02f * h) {
            // A tap in the arena moves the crosshair there.
            crossX = clamp(x / getWidth(), 0.03f, 0.97f);
            crossY = clamp(y / h, 0.1f, 0.97f);
            status = "Bidikan dipindah.";
        }
    }

    /** The emoji the finger points at on the wheel, or -1 near the centre. */
    private int emoteAt(float x, float y) {
        float h = getHeight(), cx = EMOTE_X * getWidth(), cy = EMOTE_Y * h;
        float dx = x - cx, dy = y - cy;
        if (Math.hypot(dx, dy) < WHEEL_R * h * 0.35f) return -1;
        // Items fan out above the button: from left (180°) to right (360°).
        double angle = Math.toDegrees(Math.atan2(dy, dx));
        if (angle > 0) angle = dx < 0 ? -180 : 0;
        int index = (int) Math.round((angle + 180) / 180 * (EMOTES.length - 1));
        return Math.max(0, Math.min(EMOTES.length - 1, index));
    }

    private static String arrow(float dx, float dy) {
        if (Math.abs(dx) > Math.abs(dy)) return dx > 0 ? "→" : "←";
        return dy > 0 ? "↓" : "↑";
    }

    private Touch touchWith(Role role) {
        for (int i = 0; i < touches.size(); i++) {
            if (touches.valueAt(i).role == role) return touches.valueAt(i);
        }
        return null;
    }

    private boolean holding(Role role) {
        for (int i = 0; i < touches.size(); i++) {
            if (touches.valueAt(i).role == role) return true;
        }
        return false;
    }

    private void updateStick() {
        stickX = 0;
        stickY = 0;
        float h = getHeight(), w = getWidth();
        for (int i = 0; i < touches.size(); i++) {
            Touch touch = touches.valueAt(i);
            if (touch.role != Role.STICK) continue;
            float vx = (touch.x - STICK_X * w) / (STICK_R * h), vy = (touch.y - STICK_Y * h) / (STICK_R * h);
            float length = (float) Math.hypot(vx, vy);
            if (length > 1) {
                vx /= length;
                vy /= length;
            }
            stickX = vx;
            stickY = vy;
        }
    }

    private void aimBy(float dx, float dy) {
        crossX = clamp(crossX + dx / getWidth() * 1.6f, 0.03f, 0.97f);
        crossY = clamp(crossY + dy / getHeight() * 1.6f, 0.1f, 0.97f);
    }

    private void fire() {
        float w = getWidth(), h = getHeight();
        float dx = (crossX - playerX) * w, dy = (crossY - playerY) * h;
        float length = (float) Math.hypot(dx, dy);
        if (length < 1) return;
        float speed = 1.2f * h;
        bullets.add(new float[] {playerX, playerY, dx / length * speed / w, dy / length * speed / h});
        shots++;
        status = "Tembak!";
    }

    private float[] newTarget() {
        return new float[] {0.08f + random.nextFloat() * 0.84f, 0.16f + random.nextFloat() * 0.38f};
    }

    private static float clamp(float value, float min, float max) {
        return Math.max(min, Math.min(max, value));
    }

    // MARK: Frame

    @Override
    protected void onDraw(Canvas canvas) {
        long now = SystemClock.uptimeMillis();
        float dt = lastFrame == 0 ? 0 : Math.min((now - lastFrame) / 1000f, 0.05f);
        lastFrame = now;
        step(now, dt);

        float w = getWidth(), h = getHeight();
        canvas.drawColor(Color.rgb(0x13, 0x2b, 0x1f));
        fill.setColor(Color.argb(28, 0xd8, 0xe8, 0xa7));
        for (float g = 0.1f; g < 1; g += 0.1f) {
            canvas.drawRect(0, g * h, w, g * h + density, fill);
            canvas.drawRect(g * w, 0, g * w + density, h, fill);
        }

        // Aim area.
        RectF area = new RectF(AIM.left * w + 4 * density, AIM.top * h, AIM.right * w - 4 * density, AIM.bottom * h);
        canvas.drawRoundRect(area, 14 * density, 14 * density, dashed);
        text(canvas, "AREA BIDIK · drag / mouse", area.centerX(), area.bottom - 10 * density, 11, Color.argb(170, 0xd8, 0xe8, 0xa7));

        // Targets.
        for (float[] target : targets) {
            float r = 0.035f * h;
            fill.setColor(Color.rgb(0xe8, 0x6a, 0x3a));
            canvas.drawCircle(target[0] * w, target[1] * h, r, fill);
            fill.setColor(Color.rgb(0xfb, 0xf8, 0xf1));
            canvas.drawCircle(target[0] * w, target[1] * h, r * 0.55f, fill);
            fill.setColor(Color.rgb(0xe8, 0x6a, 0x3a));
            canvas.drawCircle(target[0] * w, target[1] * h, r * 0.25f, fill);
        }

        // Aim line and crosshair.
        float px = playerX * w, py = playerY * h, cx = crossX * w, cy = crossY * h;
        stroke.setColor(Color.argb(90, 0xfb, 0xf8, 0xf1));
        stroke.setStrokeWidth(1.5f * density);
        canvas.drawLine(px, py, cx, cy, stroke);
        stroke.setColor(Color.rgb(0xfb, 0xf8, 0xf1));
        stroke.setStrokeWidth(2 * density);
        float c = 12 * density;
        canvas.drawCircle(cx, cy, c, stroke);
        canvas.drawLine(cx - c * 1.6f, cy, cx - c * 0.5f, cy, stroke);
        canvas.drawLine(cx + c * 0.5f, cy, cx + c * 1.6f, cy, stroke);
        canvas.drawLine(cx, cy - c * 1.6f, cx, cy - c * 0.5f, stroke);
        canvas.drawLine(cx, cy + c * 0.5f, cx, cy + c * 1.6f, stroke);

        // Bullets.
        fill.setColor(Color.rgb(0xf6, 0xd3, 0x4a));
        for (float[] bullet : bullets) canvas.drawCircle(bullet[0] * w, bullet[1] * h, 4.5f * density, fill);

        if (shownEmote != null && now < emoteUntil) {
            text(canvas, shownEmote, playerX * w, playerY * h - 0.09f * h, 30, Color.WHITE);
        }

        // Player: an avocado; jumping lifts it off its shadow.
        float r = 0.04f * h;
        float lift = 0;
        if (jumpStart >= 0 && now - jumpStart < JUMP_MS) {
            lift = (float) Math.sin(Math.PI * (now - jumpStart) / JUMP_MS) * 0.09f * h;
        }
        fill.setColor(Color.argb(90, 0, 0, 0));
        canvas.drawOval(px - r, py + r * 0.6f, px + r, py + r * 1.1f, fill);
        if (holding(Role.SHIELD)) {
            stroke.setColor(Color.rgb(0x6e, 0xd6, 0xf0));
            stroke.setStrokeWidth(4 * density);
            canvas.drawCircle(px, py - lift, r * 1.6f, stroke);
        }
        fill.setColor(Color.rgb(0x3d, 0x6b, 0x2a));
        canvas.drawCircle(px, py - lift, r, fill);
        fill.setColor(Color.rgb(0xd8, 0xe8, 0xa7));
        canvas.drawCircle(px, py - lift, r * 0.78f, fill);
        fill.setColor(Color.rgb(0x8a, 0x5a, 0x2b));
        canvas.drawCircle(px, py - lift + r * 0.12f, r * 0.36f, fill);

        // Controls.
        float sx = STICK_X * w, sy = STICK_Y * h, sr = STICK_R * h;
        stroke.setColor(Color.argb(170, 0xd8, 0xe8, 0xa7));
        stroke.setStrokeWidth(2.5f * density);
        canvas.drawCircle(sx, sy, sr, stroke);
        fill.setColor(stickX != 0 || stickY != 0 ? Color.rgb(0xd8, 0xe8, 0xa7) : Color.argb(140, 0xd8, 0xe8, 0xa7));
        canvas.drawCircle(sx + stickX * sr, sy + stickY * sr, sr * 0.38f, fill);
        text(canvas, "GERAK", sx, sy + sr + 16 * density, 11, Color.argb(200, 0xd8, 0xe8, 0xa7));
        button(canvas, "LOMPAT", JUMP_X * w, JUMP_Y * h, holding(Role.JUMP) || now - jumpPressed < PRESS_FLASH_MS);
        button(canvas, "TEMBAK", FIRE_X * w, FIRE_Y * h, holding(Role.FIRE) || now - firePressed < PRESS_FLASH_MS);
        button(canvas, "PERISAI", SHIELD_X * w, SHIELD_Y * h, holding(Role.SHIELD));
        button(canvas, "EMOSI", EMOTE_X * w, EMOTE_Y * h, holding(Role.EMOTE));
        Touch wheel = touchWith(Role.EMOTE);
        if (wheel != null) {
            float ex = EMOTE_X * w, ey = EMOTE_Y * h, wr = WHEEL_R * h;
            int pointed = emoteAt(wheel.x, wheel.y);
            for (int i = 0; i < EMOTES.length; i++) {
                double angle = Math.toRadians(-180 + 180.0 * i / (EMOTES.length - 1));
                float ix = ex + (float) Math.cos(angle) * wr, iy = ey + (float) Math.sin(angle) * wr;
                fill.setColor(i == pointed ? Color.rgb(0xf6, 0xd3, 0x4a) : Color.argb(200, 0x13, 0x2b, 0x1f));
                canvas.drawCircle(ix, iy, 0.045f * h, fill);
                text(canvas, EMOTES[i], ix, iy + 9 * density, 22, Color.WHITE);
            }
            stroke.setColor(Color.rgb(0xf6, 0xd3, 0x4a));
            stroke.setStrokeWidth(3 * density);
            canvas.drawLine(ex, ey, wheel.x, wheel.y, stroke);
        }

        // Every touch, with its pointer id.
        for (int i = 0; i < touches.size(); i++) {
            Touch touch = touches.valueAt(i);
            fill.setColor(Color.argb(110, 0xf6, 0xd3, 0x4a));
            canvas.drawCircle(touch.x, touch.y, 22 * density, fill);
            text(canvas, String.valueOf(touches.keyAt(i)), touch.x, touch.y + 5 * density, 13, Color.BLACK);
        }

        // HUD.
        fill.setColor(Color.argb(150, 0, 0, 0));
        canvas.drawRect(0, 0, w, 0.11f * h, fill);
        hud.setTextSize(15 * density);
        hud.setFakeBoldText(true);
        canvas.drawText(String.format(Locale.ROOT, "Skor %d   Tembak %d   Lompat %d   Dash %d   Emoji %d", score, shots, jumps, dashes, emotes),
                12 * density, 0.035f * h + 6 * density, hud);
        hud.setFakeBoldText(false);
        hud.setTextSize(12 * density);
        canvas.drawText(String.format(Locale.ROOT, "Sentuhan aktif: %d   Joystick: %.2f, %.2f", touches.size(), stickX, stickY),
                12 * density, 0.065f * h + 6 * density, hud);
        canvas.drawText(status, 12 * density, 0.095f * h + 6 * density, hud);

        if (now < hitFlashUntil) {
            fill.setColor(Color.argb(60, 0xf6, 0xd3, 0x4a));
            canvas.drawRect(0, 0, w, h, fill);
        }
        if (animating(now)) postInvalidateOnAnimation();
    }

    private void step(long now, float dt) {
        float w = getWidth(), h = getHeight();
        if (w == 0 || h == 0) return;
        float speed = 0.45f * h;
        float vx = stickX * speed, vy = stickY * speed;
        if (now < dashUntil) {
            vx += dashX * 1.6f * h;
            vy += dashY * 1.6f * h;
        }
        playerX = clamp(playerX + vx * dt / w, 0.04f, 0.96f);
        playerY = clamp(playerY + vy * dt / h, 0.16f, 0.96f);

        for (Iterator<float[]> it = bullets.iterator(); it.hasNext();) {
            float[] bullet = it.next();
            bullet[0] += bullet[2] * dt;
            bullet[1] += bullet[3] * dt;
            if (bullet[0] < 0 || bullet[0] > 1 || bullet[1] < 0.1f || bullet[1] > 1) {
                it.remove();
                continue;
            }
            for (int i = 0; i < targets.size(); i++) {
                float[] target = targets.get(i);
                if (Math.hypot((bullet[0] - target[0]) * w, (bullet[1] - target[1]) * h) < 0.04f * h) {
                    targets.set(i, newTarget());
                    score++;
                    hitFlashUntil = now + 120;
                    status = "Kena! Skor " + score + ".";
                    it.remove();
                    break;
                }
            }
        }
    }

    private boolean animating(long now) {
        return touches.size() > 0 || !bullets.isEmpty() || now < dashUntil || now < hitFlashUntil
                || (jumpStart >= 0 && now - jumpStart < JUMP_MS)
                || now - jumpPressed < PRESS_FLASH_MS || now - firePressed < PRESS_FLASH_MS || now < emoteUntil;
    }

    private void button(Canvas canvas, String name, float x, float y, boolean down) {
        float r = BUTTON_R * getHeight();
        fill.setColor(down ? Color.rgb(0xf6, 0xd3, 0x4a) : Color.argb(120, 0xd8, 0xe8, 0xa7));
        canvas.drawCircle(x, y, r, fill);
        stroke.setColor(Color.rgb(0xd8, 0xe8, 0xa7));
        stroke.setStrokeWidth(2 * density);
        canvas.drawCircle(x, y, r, stroke);
        text(canvas, name, x, y + 4 * density, 10, down ? Color.BLACK : Color.rgb(0x13, 0x2b, 0x1f));
    }

    private void text(Canvas canvas, String value, float x, float y, int sp, int color) {
        label.setTextSize(sp * density);
        label.setColor(color);
        canvas.drawText(value, x, y, label);
    }

    @Override
    protected void onSizeChanged(int w, int h, int oldw, int oldh) {
        super.onSizeChanged(w, h, oldw, oldh);
        // Fingers on the old layout no longer mean anything.
        touches.clear();
        updateStick();
    }
}

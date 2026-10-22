package com.avodroid.hello;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.graphics.Color;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** Counter, text field, display info, GPS, sound (touch, keys, sizes, location, speaker and microphone) and the way into the Arena game. */
public final class MainActivity extends Activity implements LocationListener {
    private int count;
    private TextView info;
    private Button counter;
    private TextView gps;
    private TextView microphone;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        if (state != null) count = state.getInt("count");
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        root.setBackgroundColor(Color.rgb(0x2f, 0x4a, 0x1f));
        int pad = dp(24);
        root.setPadding(pad, pad, pad, pad);

        TextView title = text("Halo dari Android", 28);
        info = text("", 14);
        showDisplayInfo();

        counter = new Button(this);
        counter.setOnClickListener(v -> {
            count++;
            showCount();
        });
        showCount();

        EditText field = new EditText(this);
        field.setHint("Ketik di sini");
        field.setTextColor(Color.WHITE);
        field.setHintTextColor(Color.rgb(0xd8, 0xe8, 0xa7));

        gps = text("GPS: ketuk “Tampilkan lokasi”", 14);
        Button location = new Button(this);
        location.setText("Tampilkan lokasi");
        location.setOnClickListener(v -> showLocation());

        Button notify = new Button(this);
        notify.setText("Kirim notifikasi (3 detik lagi)");
        notify.setOnClickListener(v -> {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[] {android.Manifest.permission.POST_NOTIFICATIONS}, 2);
                return;
            }
            // A moment to switch to another app and watch it arrive on the Mac.
            v.postDelayed(() -> Notifier.post(this, "Avo Hello", "Halo dari Android! Ketukan ke-" + count), 3000);
        });

        Button tone = new Button(this);
        tone.setText("Putar nada (tes speaker)");
        tone.setOnClickListener(v -> AudioCheck.playTone());
        microphone = text("Mikrofon: ketuk “Tes mikrofon”", 14);
        Button record = new Button(this);
        record.setText("Tes mikrofon (rekam 3 detik)");
        record.setOnClickListener(v -> testMicrophone());

        Button game = new Button(this);
        game.setText("Main game Arena (tes key mapping)");
        game.setOnClickListener(v -> startActivity(new Intent(this, GameActivity.class)));

        root.addView(title);
        root.addView(info);
        root.addView(counter, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        root.addView(field, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        LinearLayout.LayoutParams below = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        below.topMargin = dp(24);
        root.addView(game, below);
        root.addView(location);
        root.addView(gps);
        root.addView(notify);
        root.addView(tone);
        root.addView(record);
        root.addView(microphone);
        // Small windows scroll instead of cutting buttons off.
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(Color.rgb(0x2f, 0x4a, 0x1f));
        scroll.addView(root);
        setContentView(scroll);
        handle(getIntent());
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        handle(intent);
    }

    // adb shell am start -n com.avodroid.hello/.MainActivity --ez location true   (or tone, mic)
    private void handle(Intent intent) {
        if (intent.getBooleanExtra("location", false)) showLocation();
        if (intent.getBooleanExtra("tone", false)) AudioCheck.playTone();
        if (intent.getBooleanExtra("mic", false)) testMicrophone();
    }

    private void testMicrophone() {
        if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {android.Manifest.permission.RECORD_AUDIO}, 3);
            return;
        }
        AudioCheck.testMicrophone(microphone);
    }

    private void showLocation() {
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] {android.Manifest.permission.ACCESS_FINE_LOCATION}, 1);
            return;
        }
        gps.setText("GPS: mencari…");
        LocationManager manager = getSystemService(LocationManager.class);
        manager.requestLocationUpdates(LocationManager.GPS_PROVIDER, 1000, 0, this);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        boolean granted = results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED;
        if (requestCode == 1) {
            if (granted) showLocation(); else gps.setText("GPS: izin lokasi ditolak");
        } else if (requestCode == 3) {
            if (granted) AudioCheck.testMicrophone(microphone); else microphone.setText("Mikrofon: izin ditolak");
        }
    }

    @Override
    public void onLocationChanged(Location location) {
        // A fix from the GNSS HAL is real; one from a test provider is a mock.
        gps.setText(String.format("GPS: %.5f, %.5f ±%.0f m (%s)", location.getLatitude(), location.getLongitude(),
                location.getAccuracy(), location.isMock() ? "mock" : "asli"));
    }

    @Override
    protected void onDestroy() {
        getSystemService(LocationManager.class).removeUpdates(this);
        super.onDestroy();
    }

    @Override
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putInt("count", count);
    }

    // The window was resized or moved to another display: no restart, just new numbers.
    @Override
    public void onConfigurationChanged(Configuration configuration) {
        super.onConfigurationChanged(configuration);
        showDisplayInfo();
    }

    // Avo re-plugs a resized display: the task comes back on a new display id.
    @Override
    protected void onResume() {
        super.onResume();
        showDisplayInfo();
    }

    private void showDisplayInfo() {
        info.setText(String.format("Display %d · %d×%d px · %d dpi",
                getDisplay().getDisplayId(),
                getResources().getDisplayMetrics().widthPixels,
                getResources().getDisplayMetrics().heightPixels,
                getResources().getDisplayMetrics().densityDpi));
    }

    private void showCount() {
        counter.setText("Ketuk: " + count);
    }

    private TextView text(String value, int sp) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextColor(Color.rgb(0xfb, 0xf8, 0xf1));
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, sp);
        view.setGravity(Gravity.CENTER);
        view.setPadding(0, dp(8), 0, dp(8));
        return view;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}

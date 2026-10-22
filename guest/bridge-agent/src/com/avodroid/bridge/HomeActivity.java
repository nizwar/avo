package com.avodroid.bridge;

import android.app.Activity;
import android.os.Bundle;

/**
 * The default HOME activity. Avo has no launcher (spec §1): this activity
 * draws nothing and finishes, so "home" is never visible.
 */
public final class HomeActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Bridge.start(this);
        finish();
    }
}

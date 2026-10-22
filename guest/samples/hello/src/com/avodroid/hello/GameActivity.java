package com.avodroid.hello;

import android.app.Activity;
import android.os.Bundle;
import android.view.KeyEvent;

/** Hosts the Arena game. Back returns to the first screen. */
public final class GameActivity extends Activity {
    private GameView game;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        game = new GameView(this);
        if (state != null) game.restore(state);
        setContentView(game);
    }

    @Override
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        game.save(state);
    }

    // Keys Avo did not map arrive as key events: the game shows them so an
    // unmapped key is easy to spot, but only touches play.
    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        if (keyCode != KeyEvent.KEYCODE_BACK) game.keyPressed(keyCode);
        return super.onKeyDown(keyCode, event);
    }
}

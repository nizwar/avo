package dev.avo.widgets;

import android.app.ActivityOptions;
import android.content.Context;
import android.content.ContextWrapper;
import android.content.Intent;
import android.content.IntentSender;
import android.os.Bundle;
import android.view.Display;

/**
 * The context widget views are created with. A tap on a widget starts its
 * PendingIntent through the view's context; by default Android starts the
 * app on the display the tap came from, inside the widget's panel. Here it
 * starts on Android's own screen instead, where the Mac gives the app its
 * own window (HostAgent's look at that screen).
 */
final class MainDisplayContext extends ContextWrapper {
    MainDisplayContext(Context base) {
        super(base);
    }

    private static Bundle onMainDisplay(Bundle options) {
        Bundle merged = options == null ? new Bundle() : new Bundle(options);
        merged.putAll(ActivityOptions.makeBasic().setLaunchDisplayId(Display.DEFAULT_DISPLAY).toBundle());
        return merged;
    }

    @Override
    public void startIntentSender(IntentSender intent, Intent fillInIntent, int flagsMask, int flagsValues, int extraFlags,
                                  Bundle options) throws IntentSender.SendIntentException {
        super.startIntentSender(intent, fillInIntent, flagsMask, flagsValues, extraFlags, onMainDisplay(options));
    }

    @Override
    public void startActivity(Intent intent, Bundle options) {
        super.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), onMainDisplay(options));
    }

    @Override
    public void startActivity(Intent intent) {
        startActivity(intent, null);
    }
}

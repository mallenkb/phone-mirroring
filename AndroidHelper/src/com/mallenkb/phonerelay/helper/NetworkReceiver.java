package com.mallenkb.phonerelay.helper;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

/** Called by the system each time the phone joins a Wi-Fi network. */
public final class NetworkReceiver extends BroadcastReceiver {
    /**
     * Wireless debugging only starts on a connected Wi-Fi network, and right
     * after a join the network can still be settling, so the helper waits a
     * moment, then checks again once more in case the first try was too early.
     */
    private static final long[] DELAYS_MS = {2_000, 8_000};

    @Override
    public void onReceive(Context context, Intent intent) {
        enableSoon(this, context, "wifi connected");
    }

    static void enableSoon(BroadcastReceiver receiver, Context context, String reason) {
        final PendingResult pending = receiver.goAsync();
        final Context appContext = context.getApplicationContext();
        new Thread(() -> {
            try {
                for (long delay : DELAYS_MS) {
                    Thread.sleep(delay);
                    String result = WirelessDebugging.enable(appContext, reason);
                    Log.i(WirelessDebugging.TAG, reason + ": " + result);
                }
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            } finally {
                pending.finish();
            }
        }, "PhoneRelayHelper-enable").start();
    }
}

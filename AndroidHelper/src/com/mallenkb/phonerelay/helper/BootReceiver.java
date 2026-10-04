package com.mallenkb.phonerelay.helper;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Re-registers the Wi-Fi callback after a reboot or app update. */
public final class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        WirelessDebugging.registerWifiCallback(context);
        NetworkReceiver.enableSoon(this, context, "boot");
    }
}

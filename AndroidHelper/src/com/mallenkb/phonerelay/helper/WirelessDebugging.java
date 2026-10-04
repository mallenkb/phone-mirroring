package com.mallenkb.phonerelay.helper;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.provider.Settings;
import android.util.Log;

/**
 * Keeps Android's Wireless debugging switched on so Phone Relay on the Mac can
 * reconnect without a cable after a reboot or a Wi-Fi drop. Android turns the
 * switch off on both; Phone Relay then reconnects over it and, in legacy mode,
 * re-arms adb on port 5555.
 */
final class WirelessDebugging {
    static final String TAG = "PhoneRelayHelper";
    private static final String ADB_WIFI_ENABLED = "adb_wifi_enabled";
    private static final String WRITE_SECURE_SETTINGS = "android.permission.WRITE_SECURE_SETTINGS";

    private WirelessDebugging() {}

    static boolean hasPermission(Context context) {
        return context.checkSelfPermission(WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED;
    }

    static boolean isUsbDebuggingOn(Context context) {
        return Settings.Global.getInt(context.getContentResolver(), Settings.Global.ADB_ENABLED, 0) == 1;
    }

    static boolean isWirelessDebuggingOn(Context context) {
        return Settings.Global.getInt(context.getContentResolver(), ADB_WIFI_ENABLED, 0) == 1;
    }

    /**
     * Turns Wireless debugging on. Does nothing if the user switched USB
     * debugging off, so the helper never re-enables debugging they disabled.
     * Android itself asks once per Wi-Fi network ("Always allow on this
     * network") before Wireless debugging runs there.
     */
    static String enable(Context context, String reason) {
        if (!hasPermission(context)) {
            Log.w(TAG, "Not allowed to change Wireless debugging (" + reason + "); grant WRITE_SECURE_SETTINGS over adb");
            return "Permission missing";
        }
        if (!isUsbDebuggingOn(context)) {
            Log.i(TAG, "USB debugging is off; leaving Wireless debugging alone (" + reason + ")");
            return "USB debugging is off";
        }
        if (isWirelessDebuggingOn(context)) {
            return "Already on";
        }
        try {
            Settings.Global.putInt(context.getContentResolver(), ADB_WIFI_ENABLED, 1);
            Log.i(TAG, "Turned Wireless debugging on (" + reason + ")");
            return "Turned on";
        } catch (SecurityException error) {
            Log.w(TAG, "Android refused to change Wireless debugging (" + reason + ")", error);
            return "Refused by Android";
        }
    }

    /**
     * Registers a Wi-Fi network callback delivered as a broadcast, so the
     * helper reacts to every Wi-Fi connection without a running process.
     * The registration lasts until reboot or app update, which BootReceiver
     * covers.
     */
    static void registerWifiCallback(Context context) {
        ConnectivityManager connectivity = context.getSystemService(ConnectivityManager.class);
        if (connectivity == null) return;
        NetworkRequest request = new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .build();
        Intent intent = new Intent(context, NetworkReceiver.class);
        PendingIntent pending = PendingIntent.getBroadcast(
                context,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_MUTABLE);
        try {
            connectivity.registerNetworkCallback(request, pending);
            Log.i(TAG, "Wi-Fi callback registered");
        } catch (RuntimeException error) {
            Log.w(TAG, "Could not register the Wi-Fi callback", error);
        }
    }
}

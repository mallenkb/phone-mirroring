package com.mallenkb.phonerelay.helper;

import android.app.Activity;
import android.os.Bundle;
import android.util.TypedValue;
import android.view.Gravity;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/** Status screen. Opening it also registers the Wi-Fi callback. */
public final class MainActivity extends Activity {
    private TextView status;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        WirelessDebugging.registerWifiCallback(this);

        int padding = dp(24);
        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        column.setPadding(padding, padding, padding, padding);
        column.setGravity(Gravity.TOP);

        TextView title = new TextView(this);
        title.setText("Phone Relay Helper");
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 24);
        column.addView(title);

        TextView about = new TextView(this);
        about.setText("Turns Wireless debugging back on after a reboot or when the phone rejoins Wi-Fi, "
                + "so Phone Relay on your Mac reconnects without a cable. It does nothing while USB "
                + "debugging is off.");
        about.setPadding(0, dp(12), 0, dp(12));
        column.addView(about);

        status = new TextView(this);
        status.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        column.addView(status);

        Button enable = new Button(this);
        enable.setText("Turn on Wireless debugging now");
        enable.setOnClickListener(view -> {
            String result = WirelessDebugging.enable(this, "button");
            refresh(result);
        });
        column.addView(enable);

        TextView setup = new TextView(this);
        setup.setText("Setup: Phone Relay grants the one permission this needs the next time the phone is "
                + "connected by USB. To grant it by hand:\n\nadb shell pm grant "
                + getPackageName() + " android.permission.WRITE_SECURE_SETTINGS\n\n"
                + "The first time Wireless debugging starts on a Wi-Fi network, Android asks to allow it. "
                + "Tick \"Always allow on this network\".");
        setup.setPadding(0, dp(16), 0, 0);
        setup.setTextIsSelectable(true);
        column.addView(setup);

        ScrollView scroll = new ScrollView(this);
        scroll.addView(column);
        setContentView(scroll);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refresh(null);
    }

    private void refresh(String lastResult) {
        StringBuilder text = new StringBuilder();
        text.append("Permission: ").append(WirelessDebugging.hasPermission(this) ? "granted" : "not granted yet");
        text.append("\nUSB debugging: ").append(WirelessDebugging.isUsbDebuggingOn(this) ? "on" : "off");
        text.append("\nWireless debugging: ").append(WirelessDebugging.isWirelessDebuggingOn(this) ? "on" : "off");
        if (lastResult != null) {
            text.append("\n\nLast action: ").append(lastResult);
        }
        status.setText(text);
    }

    private int dp(int value) {
        return (int) TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics());
    }
}

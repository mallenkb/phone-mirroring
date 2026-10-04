# Phone Relay Helper (Android)

A small Android app that keeps Phone Relay reconnecting without a cable.

Android turns Wireless debugging off when the phone reboots or leaves Wi-Fi,
and legacy adb on port 5555 is lost on every reboot. The helper turns Wireless
debugging back on at boot and each time the phone joins a Wi-Fi network. Phone
Relay on the Mac finds the phone by its serial in the `adb-<serial>` mDNS name
and reconnects over it.

The helper never turns debugging on if the user switched USB debugging off.

## Build

```bash
AndroidHelper/build.sh
```

`AndroidHelper/build.sh --bundle` also copies the APK into the Mac app
(`Sources/PhoneRelay/Resources/PhoneRelayHelper.apk`) and updates its checksum in
`scripts/release-artifacts.sha256`. Phone Relay installs that bundled copy when
the user opts in during onboarding or in Settings.

This uses only the Android SDK command-line tools (javac from Android Studio's
JDK, d8, aapt2, zipalign, apksigner). The signing key is created on first build
at `~/.android/phone-relay-helper.keystore`; keep it, or Android will refuse to
install later builds over the installed app.

## Install and set up

1. In Phone Relay, choose "Install When Connected" in onboarding, or turn on
   Settings > Reconnect after restarts. The next time the phone connects, the app
   installs the helper and grants it `WRITE_SECURE_SETTINGS`
   (`AppModel+HelperApp.swift`). By hand:
   `adb -P 5038 -s <serial> install -r AndroidHelper/build/PhoneRelayHelper.apk`, then
   `adb shell pm grant com.mallenkb.phonerelay.helper android.permission.WRITE_SECURE_SETTINGS`
2. The first time Wireless debugging starts on a Wi-Fi network, Android asks to
   allow it. Tick "Always allow on this network".

Samsung phones may put rarely opened apps into "deep sleep", which can block the
helper's Wi-Fi callback. Exclude it under Settings > Battery > Background usage
limits if it stops working.

# Android Mirroring

Native SwiftUI macOS prototype for a local-first Android mirroring client.

## What is included

- Polished onboarding/dashboard shell
- Device readiness model for companion, notifications, trust, and mirroring
- Android 11+ Wireless debugging QR pairing with `adb pair` / `adb connect`
- USB-to-Wi-Fi handoff through legacy `adb tcpip 5555` when supported
- `adb devices -l` scan through a managed subprocess
- Native in-process mirroring backed by the bundled `scrcpy-server` artifact
- Adjustable mirroring quality (resolution / bitrate / frame-rate) in Settings
- Drag-and-drop onto the mirror to install `.apk`s or push files to the phone
- Screenshot, screen recording, and optional experimental Android notification forwarding
- Dismissible in-app error banner (with **Open Log**) so failures aren't silent
- Keyboard-shortcuts reference under **Help ▸ Keyboard Shortcuts**

## Third-party notices

This project includes and/or interoperates with `scrcpy` from Genymobile. Scrcpy is licensed under the Apache License 2.0. See `THIRD_PARTY_NOTICES.md` and `LICENSES/scrcpy-APACHE-2.0.txt`.

## Run

Prerequisites:

- macOS 13 or newer
- Xcode Command Line Tools with Swift 5.9 or newer
- Android platform tools (`adb`)
- A bundled or locally built `scrcpy-server` artifact

Common Homebrew setup:

```sh
brew install android-platform-tools
```

Run from SwiftPM:

```sh
swift run AndroidMirrorMac
```

For app-bundle testing, use:

```sh
script/build_and_run.sh
```

For release-style packaging without launching the app:

```sh
scripts/package_app.sh
```

The app does not require the standalone `scrcpy` CLI for live mirroring. It pushes `scrcpy-server` to the phone through `adb` and runs the device-side server with `app_process`.

## Sharing the app (signing & notarization)

`script/build_and_run.sh` ad-hoc signs the bundle, which only runs on the machine that built it. To distribute it to other Macs without Gatekeeper warnings, sign with a Developer ID and notarize:

```sh
DEVELOPER_ID="Developer ID Application: You (TEAMID)" \
APPLE_ID="you@example.com" TEAM_ID="TEAMID" APP_PASSWORD="app-specific-pw" \
  scripts/notarize.sh
```

Entitlements live in `scripts/AndroidMirrorMac.entitlements`. A paid Apple Developer account is required.

## Continuous integration

`.github/workflows/ci.yml` runs `swift build` and `swift test` on every push and pull request.

To pair, enable Wireless debugging on the Android phone and scan the QR code shown by the app. USB debugging is also supported: connect the phone, authorize the Mac, then use the USB flow. When possible the app promotes the connection to Wi-Fi ADB on port `5555`; `scripts/verify_usb_wifi_handoff.sh` can validate that handoff.

Troubleshooting:

- Logs are written to `~/Library/Logs/Android Mirroring.log`.
- Debug builds can override the adb path with `ANDROID_MIRROR_ADB_PATH=/path/to/adb`.
- Run `swift test` for the Swift parser/unit test suite. Hardware-dependent mirroring and USB/Wi-Fi handoff still need manual device validation.

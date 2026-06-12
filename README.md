# PhoneRelay

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
- Screenshot, screen recording, and Android notification forwarding (on by default, auto-disabled if macOS notification permission is denied; toggle in Settings)
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
swift run PhoneRelayBinary
```

For app-bundle testing, use:

```sh
scripts/build_and_run.sh
```

For release-style packaging without launching the app:

```sh
scripts/package_app.sh
```

The app does not require the standalone `scrcpy` CLI for live mirroring. It pushes `scrcpy-server` to the phone through `adb` and runs the device-side server with `app_process`.

## Sharing the app (signing & notarization)

`scripts/build_and_run.sh` ad-hoc signs the bundle, which only runs on the machine that built it. To distribute it to other Macs without Gatekeeper warnings, sign with a Developer ID and notarize:

```sh
DEVELOPER_ID="Developer ID Application: You (TEAMID)" \
APPLE_ID="you@example.com" TEAM_ID="TEAMID" APP_PASSWORD="app-specific-pw" \
  scripts/notarize.sh
```

Dev builds use `scripts/PhoneRelay.entitlements`; notarized release builds use `scripts/PhoneRelay.release.entitlements` (no hardened-runtime exceptions — `notarize.sh` fails if any leak in). A paid Apple Developer account is required. Keep the bundle identifier stable (`BUNDLE_ID=com.yourdomain.PhoneRelay scripts/build_and_run.sh` when rebranding), because changing it resets macOS privacy authorization for Notification Center and Local Network access.

## Continuous integration

`.github/workflows/ci.yml` runs `swift build` and `swift test` on every push and pull request.

`.github/workflows/auto-update-release.yml` builds the `PhoneRelay.dmg` asset used by Sparkle and publishes it to GitHub Releases with a signed `appcast.xml`. Run it manually as **Auto Update** with a version such as `0.1.2`, or push a tag such as `v0.1.2`. Public auto-update releases require repository secrets for `DEVELOPER_ID_CERTIFICATE_BASE64`, `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `DEVELOPER_ID`, `APPLE_ID`, `TEAM_ID`, `APP_PASSWORD`, `SPARKLE_PUBLIC_ED_KEY`, and `SPARKLE_PRIVATE_ED_KEY`; the workflow fails before publishing if signing, notarization, and Sparkle update signing are not configured. Generate the Sparkle keys with `.build/artifacts/sparkle/Sparkle/bin/generate_keys` after running `swift package resolve`.

## Download site

The static download page lives in `docs/` and is deployed by `.github/workflows/pages.yml` through GitHub Pages when Pages is enabled for the repository. During deploy, the workflow reads GitHub's latest release with `GITHUB_TOKEN`, writes `docs/release.json`, and publishes the site artifact. The page reads that metadata file and updates the visible version number, file size, published date, release link, and `.dmg` download link automatically. Publishing a new GitHub release with `PhoneRelay.dmg` and `appcast.xml` assets is enough to update the site link and Sparkle appcast. Private repositories require a GitHub plan that supports private Pages, or the repository must be made public.

To pair, enable Wireless debugging on the Android phone and scan the QR code shown by the app. USB debugging is also supported: connect the phone, authorize the Mac, then use the USB flow. When possible the app promotes the connection to Wi-Fi ADB on port `5555`; `scripts/verify_usb_wifi_handoff.sh` can validate that handoff.

Troubleshooting:

- Logs are written to `~/Library/Logs/PhoneRelay.log`.
- Debug builds can override the adb path with `ANDROID_MIRROR_ADB_PATH=/path/to/adb`.
- Run `swift test` for the Swift parser/unit test suite. Hardware-dependent mirroring and USB/Wi-Fi handoff still need manual device validation.

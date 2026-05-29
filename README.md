# Android Mirroring

Native SwiftUI macOS prototype for a local-first Android mirroring client.

## What is included

- Polished onboarding/dashboard shell
- Device readiness model for companion, notifications, trust, and mirroring
- Manual local pairing placeholder with verification code UX
- `adb devices -l` scan through a managed subprocess
- `scrcpy` launch/stop through a managed subprocess
- Privacy-mode test macOS notification
- Readable diagnostics panel

## Run

```sh
swift run AndroidMirrorMac
```

For live mirroring, install `adb` and `scrcpy` and ensure they are available on `PATH`.

Common Homebrew setup:

```sh
brew install android-platform-tools scrcpy
```

Then connect an Android phone with USB debugging, authorize the Mac on the phone, scan adb, and start mirroring.

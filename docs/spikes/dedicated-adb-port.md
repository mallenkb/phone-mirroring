# Spike: dedicated adb server port (NOT committed architecture)

**Status: open — design + validation checklist only. No product code changes
until every checklist item passes on real hardware.**

## Problem

The shared adb daemon on `tcp:5037` is owned by whoever spawned it first —
Terminal, Android Studio, an AI assistant's shell, or the app. Two failure
classes follow (INVARIANTS.md rules 8–9):

1. **TCC attribution freeze:** the daemon inherits the *spawner's* macOS
   Local Network identity at spawn time and keeps it for its lifetime. A
   daemon spawned under a denied identity silently fails every LAN
   `adb connect` for all clients — confirmed live 2026-07-03 (daemon
   attributed to a denied "claude" shell identity).
2. **Cross-tool interference:** any other adb client with a mismatched
   version kills and respawns the server; `kill-server` from anywhere drops
   the app's live mirror transports.

## Proposed mechanism

Run the app's entire adb stack against a private server socket:

- Set `ADB_SERVER_SOCKET=tcp:127.0.0.1:5038` (or `ANDROID_ADB_SERVER_PORT`)
  in the environment of **every** process the app spawns that talks to adb:
  all `Tooling.runResult("adb", …)` invocations *and* the scrcpy client
  (scrcpy shells out to adb itself — a missed env var splits the stack).
- The app's first adb call auto-spawns the private daemon → attribution is
  always the app's own; Terminal/Android Studio churn on 5037 can't touch it.

## Why it isn't committed yet

Two adb servers can contend for **exclusive USB device claims**. If the 5037
server (Android Studio, user shell) holds the USB device, the app's 5038
server may see nothing on USB — turning "fixes Wi-Fi attribution" into
"breaks USB mirroring". This is the question the spike must answer first.

## Validation checklist (all on real hardware, S906B reference device)

- [ ] USB mirror starts while a 5037 server (spawned by Terminal) is running.
- [ ] USB→Wi-Fi handoff completes end-to-end on the private port, including
      the `tcpip 5555` path and the TLS wireless-debugging fallback.
- [ ] Sticky manual Disconnect + cable-replug resume still behave per
      INVARIANTS.md rule 4.
- [ ] Android Studio open simultaneously: both see the device, neither
      steals it mid-mirror; logcat in Studio while the app mirrors.
- [ ] `adb devices` in a user Terminal (5037) during a live app mirror
      neither kills the app's daemon nor its transports.
- [ ] Phone reboot mid-session: recovery flows work on the private port.
- [ ] Wireless pairing (QR + code) works against the private server —
      `adb pair` honors `ADB_SERVER_SOCKET`.
- [ ] Kill the 5038 daemon manually: app's recovery respawns it with app
      attribution (log line + working Wi-Fi connects).

## Fallback if the spike fails

Keep the shared 5037 daemon and rely on the shipped mitigation (2026-07-04):
attribution-signature detection (`sawReachableNoRoute`: TCP probe reaches the
port while `adb connect` says "No route to host") → guarded in-app daemon
respawn (`recoverADBDaemonIfSafe`, never mid-mirror, cooldown-limited) + the
Fix Connection button.

# Behavioral Invariants

Rules that keep Phone Relay stable. Each one was paid for with a real
debugging session; none is obvious from the code alone. **Do not "clean up"
behavior described here without reading the why.** If a change violates one
of these on purpose, update this file in the same commit.

## Connection & transports

1. **Never run `adb kill-server` while a mirror session is live.**
   It drops every adb transport, killing the active mirror. The one-shot
   restart escalations in `AppModel` are gated (`allowADBServerRestart:
   false` wherever a session could be riding another transport). A
   configure-first handoff may opt in only while no mirror, mirror session, or
   mirror-launch task exists, and only after the app's TCP probe reached the
   listener while `adb connect` alone returned `No route to host` or a host
   protocol timeout/reset. This also applies to tests: a test that reaches a
   real `kill-server` will kill the user's live mirror (observed 2026-07-02).

2. **Authenticated Wireless debugging is the default Wi-Fi transport.** A
   fresh `_adb-tls-connect._tcp` endpoint wins over saved routes, and a verified
   TLS endpoint may replace an older stored `:5555` route. Port 5555 is neither
   synthesized, dialed, persisted, enabled, nor searched for while
   `Connection.allowLegacyADBWireless` is off. The setting defaults to on. Even then,
   an advertised TLS endpoint wins. A Wi-Fi IP observed over USB is identity
   metadata, not a dialable endpoint. After a network-path or stored-network
   fingerprint change, live TLS discovery goes first and a stale endpoint must
   not consume the first attempt.

   Legacy mode exists for Android 10 and vendor-limited devices. It is an
   explicit security tradeoff because ADB authentication does not encrypt the
   port-5555 session. Its listener does not survive a phone reboot, so cable
   arming and subnet recovery remain available only while compatibility is on.

3. **`adb tcpip` restarts the phone's adbd and drops the live USB mirror.**
   Automatic USB-to-Wi-Fi handoff is configure-first: prove the Mac has a route
   to the phone's current LAN, prepare and verify Wi-Fi while no mirror exists,
   then launch exactly one mirror on Wi-Fi. Only a closed port, same-LAN proof,
   an authorized owner, and a serial not inside its failure backoff may
   authorize `tcpip`. On failure, explicitly return adbd to the exact original
   USB serial before launching the USB fallback. An explicit USB choice may
   capture IP/MAC and verify an already-listening legacy/TLS/mDNS route, but
   background preparation must never restart adbd or promote away from its live
   USB mirror.

   When legacy compatibility is enabled, two authorized owners exist. The first is the configure-first handoff
   (`activatePreparedMirror`). The second is the cable-arrival arm
   (`armWirelessWithoutMirroring`, `armWirelessDebuggingForAttachedUSB`), which
   runs `tcpip` while deliberately starting *no* mirror: `tcpip` mode dies on
   every phone reboot and can only be restored over USB, so a cable that is
   merely plugged in — to charge, while manually disconnected, while USB
   mirroring is pinned — must still re-arm `:5555`. It fires on the plug-in edge
   only (`wirelessArmRetryInterval`, 60s, because `tcpip`'s own adbd restart
   creates a second edge), and yields to a live mirror and to every other
   connection workflow.

   The failure verdict is **time-boxed, not session-long**
   (`ConnectionCoordinator.legacyHandoffRetryDelay`: 60s → 5m → 30m). A
   session-long verdict was tried (8ae7a297) and does protect against the
   "USB mirror dies every few seconds" loop, but it also meant one transient
   failure — adbd mid-restart right after a reboot is the common one — disabled
   the app's only way to re-arm Wi-Fi until relaunch. The escalation keeps the
   number of destructive retries bounded while staying self-healing. A verified
   Wi-Fi route clears the verdict outright.

4. **Manual Disconnect is sticky.** It stops the mirror but keeps discovery
   running; auto-re-mirror stays paused until a transport *re-appears* (cable
   replugged, phone Wi-Fi toggled off/on). A disconnect must never fall over
   to a continuously-present transport; when both routes genuinely return
   together, the normal Wi-Fi-first policy applies. Per-transport suppression
   was tried and reverted (f8d3c86). The coordinator's
   `manuallyDisconnected` state is the hard gate: timer, discovery, wake, and
   network-path events cannot end it. Only an explicit user reconnect or a
   verified transport reappearance may resume.

5. **The USB→Wi-Fi handoff pipeline has a total time budget**
   (`wirelessHandoffMaxDuration`, 10s) sized to absorb slow route/MAC reads
   plus adbd's 1–4s restart. Shrinking it misfiles healthy phones as
   "blocks adb-over-Wi-Fi". A timeout is not permission to launch against a
   missing USB row: the fallback must first require the exact USB shell
   sentinel, or recover through the prepared Wi-Fi address with `adb usb` and
   wait for that same serial to return.

6. **Wireless pins prevent USB↔Wi-Fi ping-pong; user choices do not disable
   handoff.** A cable moved to Wi-Fi (`wirelessPinnedUSBSerials`) is ignored by
   the watcher while the Wi-Fi route is being pursued. A user's explicit USB
   or Wi-Fi choice is a connection-scoped `TransportIntent`: USB launches on
   the cable and permits only non-destructive Wi-Fi preparation, Wi-Fi refuses
   silent USB fallback for that attempt, and later automatic cable discovery
   returns to configure-first Wi-Fi handoff. Every handoff, discovered-Wi-Fi
   dial, and automatic reconnect task owns a coordinator generation; cancelled
   work checks ownership after suspension and before state changes so it cannot
   clear or promote a replacement task.

   Connection availability is phone-scoped once a selected/saved identity
   exists. A matching live route turns its chooser icon green before dialing;
   routes from another phone cannot produce `USB + Wi-Fi` or resume a manually
   disconnected phone. A lone mDNS candidate may stand in for a changed address
   only when exactly one wireless record is eligible; with multiple records,
   service ID or host identity must match. User-initiated dialing stays on the
   chooser as an inline row state until the ready mirror replaces it, with no
   intermediate loading screen or disappearing-window gap.

7. **Never poll faster — react to events.** Discovery latency work is done
   with kernel/system push (persistent `NWBrowser` Bonjour monitors, IOKit
   USB-attach wake, NWPathMonitor, wake notifications), never by tightening
   poll intervals. The polls that remain are safety nets. Candidate TCP probes
   may run concurrently because they do not mutate ADB transport state; all
   `adb connect` calls for a phone remain serial and coordinator-owned.

   Automatic reconnect uses one coordinator backoff clock with the intended
   5, 10, 20, 30-second cadence. Do not compose it with the legacy
   `failedAutoConnectTargets` cooldown. A task owner generation and a separate
   per-attempt generation are both required: only the current task may mutate
   route state or clear its handle, and verified transport evidence may wake the
   one clock early without bypassing mirror-crash protection.

## adb daemon & macOS identity (TCC)

8. **The adb daemon's Local Network attribution freezes at spawn and the
   daemon outlives app rebuilds.** A daemon spawned from a shell (including
   an AI assistant's shell — confirmed live 2026-07-03, attributed to a
   denied "claude" identity) silently breaks every Wi-Fi `adb connect` with
   instant "No route to host" *for the app too*. The configure-first handoff
   now recognizes the stronger signature (its own TCP probe reached the port,
   but ADB was denied, timed out, or reset its host protocol), restarts the
   daemon once from the signed app while quiescent, and retries inside the same
   budget. Every Phone Relay ADB process uses private server port 5038, so a
   shell or Android Studio daemon on the default port 5037 cannot take ownership
   of the app's transports or Local Network attribution. If manual recovery is
   ever required, stop the app-owned daemon through Phone Relay and let its
   poller respawn it. Never diagnose the app by starting another client against
   port 5038; use the log file.

9. **Instant "No route to host" on every connect while phone→Mac pings work
   is a permission/attribution problem, not a network problem.** Check the
   daemon's spawner and the Local Network TCC state before touching any
   handoff code. Stale TCC rows keyed to old signatures show toggled-ON
   while silently denying; flipping them does nothing. First allow the
   quiescent app-owned daemon restart above to run. Only if an app-owned
   daemon still shows the same reachable-port/ADB-denied signature should a
   developer reset `com.mallenkb.PhoneRelay`, relaunch the app, and approve a
   fresh Local Network prompt.

10. **The `defaults` CLI lies about this app.** A stale sandbox container at
    `~/Library/Containers/com.mallenkb.PhoneRelay` makes `defaults read`
    resolve into the (empty) container while the non-sandboxed app writes to
    `~/Library/Preferences/com.mallenkb.PhoneRelay.plist`. Inspect that
    plist with `plutil -p`.

11. **Only script-pipeline builds are daily-driver safe.** Sandboxed
    Xcode/TestFlight builds use container HOME → foreign adb keys and
    split-brain preferences; the adb stack breaks.

## Device store & setup

12. **`MirrorBehavior.explicitDeviceSetupRequired` wipes the paired-phone
    store at every launch until a persisting connect clears it.** It is read
    from the standard domain AND every compatibility suite, so a debug build
    pressing "Forget All Phones" poisons all builds. A live mirror with an
    empty Devices page means this flag (or a connect path that skipped
    `touchPairedPhone`).

13. **Every successful connect path should persist the device, but observation
    is not verification.** Paths that mirror without `touchPairedPhone` create
    "streaming but not remembered" states (observed 2026-07-02). Persist an
    observed USB-side Wi-Fi IP separately. Promote `wifiAddress`, its network
    fingerprint, and verification time only after TCP plus ADB shell readiness
    succeeds. When adding a connect path, persist the verified winning route on
    success. After an authenticated network connect, read `ro.serialno` and use
    that hardware identity instead of an address or mDNS instance name. Optional
    identities may match only when the incoming value is non-nil; `nil == nil`
    must never merge two phone records.

13a. **Phone Files never trusts a lexical shared-storage prefix by itself.**
    Reject dot traversal, quote every phone-side shell value, and resolve each
    existing path with `readlink -f` before an operation that can follow a
    symlink. Both the requested path and its resolved target must remain under
    `/sdcard` or `/storage`; resolution failure is a closed boundary.

## Notifications

14. **Notification click/reply/mark-read is Vision-OCR driving the phone's
    shade.** `uiautomator dump` never idles on the reference device;
    `dumpsys` intent reconstruction loses extras. The OCR path is inherently
    Samsung-layout-coupled; the fallback ladder (locate row → launch source
    app) must stay intact.

15. **Hide-previews means hidden on disk too.** When
    `notificationHideBodyEnabled` is on, message text is stripped from
    `userInfo` (macOS persists it) — click-to-open degrades to title-only /
    app-launch by design. OTP suppression defaults ON; missing 2FA banners
    are by design.

16. **Banner delivery breaks silently on identity churn** (bundle-id change,
    ad-hoc re-sign, stale /Applications copy). Check `authorizationStatus`
    and delivery-failed log lines before debugging forwarder code.

## UI & windows

17. **Nothing may surface over first-run onboarding**; after Get Started the
    connection screen holds 3s before auto-mirror. The connection window
    never steals focus on auto-reconnect (activate only when the app is
    already active). Newest duplicate app instance yields to the oldest.

18. **Screen-off on the S906B:** the client must not auto-send
    display-power-OFF at session start — it aborts the server on this
    device. The 30s screen-off setting uses the safe control-message path.

## Build, tests, releases

19. **Version/build numbers live in 4 places** (pbxproj ×2 configs, Sources
    Info.plist, both scripts); `ReleaseReadinessTests` enforces lockstep.

20. **Test-suite gotchas:** `swift test | tail` masks the exit code; some
    tests read `AppModel.swift` as *text* (moving code breaks them — update
    paths); suites that create UserDefaults domains must clean up
   (`TestDomainHygiene` sweeps crash leftovers); never run the suite while
   a live mirror matters (see rule 1). `testManualWirelessPairing` is
   environment-flaky at clean HEAD, and the full-suite `MirrorScrollSpeedTests`
   SIGSEGV is a parallel-run artifact; neither alone attributes a reconnect
   coordinator regression.

21. **`dist/`, `scrcpy-source/`, `PhoneRelay.app/` stay untracked.** The git
    pack already carries ~430 MB of historical binaries; don't add more.

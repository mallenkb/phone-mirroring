# Behavioral Invariants

Rules that keep Phone Relay stable. Each one was paid for with a real
debugging session; none is obvious from the code alone. **Do not "clean up"
behavior described here without reading the why.** If a change violates one
of these on purpose, update this file in the same commit.

## Connection & transports

1. **Never run `adb kill-server` while a mirror session is live.**
   It drops every adb transport, killing the active mirror. The one-shot
   restart escalations in `AppModel` are gated (`allowADBServerRestart:
   false` wherever a session could be riding another transport). This also
   applies to tests: a test that reaches a real `kill-server` will kill the
   user's live mirror (observed 2026-07-02).

2. **Reconnect prefers legacy `tcpip 5555` over Android-11 TLS wireless
   debugging.** The `:5555` listener survives without the phone's
   Wireless-debugging toggle; the TLS random port dies when the toggle goes
   off. Coordinator-owned reconnects build candidates canonically — stable
   `:5555` endpoints first, then other saved routes, then freshly advertised
   TLS — and gate dials on the TCP probe (dead TLS routes are skipped; the
   preferred stable endpoint always gets one real connect). Manual retry,
   handoff, and address-recovery paths still use the legacy saved-address-first
   resolver and dial every candidate; unifying them is Stage 2 work, so within
   Stage 1 the two resolvers coexist deliberately. In both, reachability may
   move live endpoints ahead of dead ones but never changes preference within
   the live group — do not reorder to TLS-first. `tcpip` mode does NOT survive
   a phone reboot; the TLS route is the fallback for exactly that case.

3. **`adb tcpip` restarts the phone's adbd and drops the live USB mirror.**
   Every handoff path probes port 5555 first and only runs `tcpip` when the
   port is closed AND the serial hasn't already failed a legacy handoff this
   session (`failedLegacyHandoffSerials`). Removing that memory reintroduces
   a doomed ~15s detour on every reconnect for phones that block
   adb-over-Wi-Fi.

4. **Manual Disconnect is sticky.** It stops the mirror but keeps discovery
   running; auto-re-mirror stays paused until a transport *re-appears* (cable
   replugged, phone Wi-Fi toggled off/on) — and reconnects on **that same
   channel**. A disconnect must never fall over to the other transport, and
   per-transport suppression was tried and reverted (f8d3c86). The coordinator's
   `manuallyDisconnected` state is the hard gate: timer, discovery, wake, and
   network-path events cannot end it. Only an explicit user reconnect or a
   verified reappearance on the same channel may resume.

5. **The USB→Wi-Fi handoff pipeline has a total time budget**
   (`wirelessHandoffMaxDuration`, 10s) sized to absorb slow route/MAC reads
   plus adbd's 1–4s restart. Shrinking it misfiles healthy phones as
   "blocks adb-over-Wi-Fi".

6. **Wireless pins prevent USB↔Wi-Fi ping-pong.** A cable moved to Wi-Fi
   (`wirelessPinnedUSBSerials`) is ignored by the watcher while the Wi-Fi
   route is being pursued; a user's explicit USB choice
   (`manualUSBPinnedSerials`) must never be overridden by in-flight handoff
   work.

7. **Never poll faster — react to events.** Discovery latency work is done
   with kernel/system push (persistent `NWBrowser` Bonjour monitors, IOKit
   USB-attach wake, NWPathMonitor, wake notifications), never by tightening
   poll intervals. The polls that remain are safety nets. Candidate TCP probes
   may run concurrently because they do not mutate ADB transport state; all
   `adb connect` calls for a phone remain serial and coordinator-owned.

   The single-flight reconnect rollout is intentionally two-stage. Stage 1
   routes every trigger through the coordinator while legacy cooldown clocks
   remain. Stage 2 removes those redundant clocks only after Stage 1 is verified,
   so live regressions remain bisectable.

## adb daemon & macOS identity (TCC)

8. **The adb daemon's Local Network attribution freezes at spawn and the
   daemon outlives app rebuilds.** A daemon spawned from a shell (including
   an AI assistant's shell — confirmed live 2026-07-03, attributed to a
   denied "claude" identity) silently breaks every Wi-Fi `adb connect` with
   instant "No route to host" *for the app too*. Remedy: `pkill -f "adb -L
   tcp:5037"` and let the **app's** poller respawn it. Never run bare `adb`
   commands from a shell while diagnosing the app; use the log file.

9. **Instant "No route to host" on every connect while phone→Mac pings work
   is a permission/attribution problem, not a network problem.** Check the
   daemon's spawner and the Local Network TCC state before touching any
   handoff code. Stale TCC rows keyed to old signatures show toggled-ON
   while silently denying; flipping them does nothing. The working remedy:
   `tccutil reset All com.mallenkb.PhoneRelay`, relaunch the app, approve
   the fresh prompt.

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

13. **Every successful connect path should persist the device.** Paths that
    mirror without `touchPairedPhone` create "streaming but not remembered"
    states (observed 2026-07-02). When adding a connect path, persist on
    success.

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

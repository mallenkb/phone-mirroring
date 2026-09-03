import AppKit
import Darwin
import Foundation
import Network

@MainActor
extension AppModel {
    func cancelWirelessReconnectWork() {
        connectionCoordinator.cancelWirelessReconnectWork()
        isManualADBTargetConnecting = false
        isRecoveringConnection = false
        isAwaitingReconnect = false
        isAutoConnecting = false
    }

    func startDiscovery() {
        guard backgroundServicesEnabled else { return }
        discovery.start { [weak self] phones in
            guard let self else { return }
            guard !(self.pairedPhones.isEmpty && self.explicitDeviceSetupRequired) else {
                self.discoveredPhones = []
                return
            }
            let previousAddresses = Set(
                self.discoveredPhones.filter { $0.kind.isConnectable }.map(\.address)
            )
            let currentAddresses = Set(
                phones.filter { $0.kind.isConnectable }.map(\.address)
            )
            self.discoveredPhones = phones
            // After a manual Disconnect the phone stays visible/online here, but
            // auto-re-mirror is held until the user reconnects (or replugs) — so
            // Disconnect means "stop mirroring", not "stop discovering".
            guard !self.isAutoReconnectSuppressedForManualDisconnect else { return }
            // Only a route *appearing* is evidence worth a backoff bypass; a
            // phone dropping off mDNS would just spend a doomed attempt and
            // inflate the failure count.
            let appearedAddresses = currentAddresses.subtracting(previousAddresses)
            guard let address = phones.first(where: {
                $0.kind.isConnectable && appearedAddresses.contains($0.address)
            })?.address else {
                return
            }
            let eventID = self.connectionCoordinator.nextAutomaticDiscoveryEventID()
            self.requestAutomaticReconnect(
                trigger: .discovery(address: address, eventID: eventID)
            )
        }
    }

    func resumeDiscoveryAfterManualConnect() {
        // An explicit user route choice owns the connection until it resolves;
        // automatic work must not race it or create a second transport.
        connectionCoordinator.cancelAutomaticReconnect(clearRetryState: false)
        manualDisconnectKnownSerials = nil
        manualDisconnectBaselineSerials = []
        manualDisconnectWiFiProbeInFlight = false
        guard isAutoReconnectSuppressedForManualDisconnect else {
            if backgroundServicesEnabled {
                startDiscovery()
                startDeviceWatcher()
            }
            return
        }
        connectionCoordinator.leaveManualDisconnect()
        if backgroundServicesEnabled {
            startDiscovery()
            startDeviceWatcher()
        }
    }

    /// A manual Disconnect just stops the mirror — it must not tear down
    /// discovery. The mDNS poller and device watcher keep running, so the phone
    /// stays visible/online and one click (or a replug) from reconnecting; only
    /// *auto-re-mirror* is held for the session (gated in the discovery callback
    /// and the device-watcher's suppressed branch), so the button isn't
    /// immediately undone by the watcher re-mirroring the still-online phone.
    func suppressAutoReconnectForManualDisconnect() {
        connectionCoordinator.enterManualDisconnect()
        // Disconnect stops mirroring, not presence. Clear stale connection
        // failures so live USB/Wi-Fi routes can immediately render as online.
        activeError = nil
        clearConnectionStall()
        manualDisconnectKnownSerials = nil
        manualDisconnectBaselineSerials = []
        manualDisconnectWiFiProbeInFlight = false
        isAutoConnecting = false
        isScanning = false
        lastPresenceAutoConnectAttemptAt = nil
        autoConnectTargetsInFlight.removeAll()
        failedAutoConnectTargets.removeAll()
        previousAuthorizedSerials.removeAll()
        lastUSBHandoffSerial = nil
        wirelessPinnedUSBSerials.removeAll()
        launchReconnectDeadline = nil
        if backgroundServicesEnabled {
            startDiscovery()
            startDeviceWatcher()
        }
    }

    /// Per-poll handling while a manual Disconnect keeps auto-connect paused.
    ///
    /// The first poll seeds the baseline of transports that were online at
    /// disconnect — those, and anything that stays continuously online, are
    /// ignored so Disconnect never falls over to the still-connected channel.
    /// When a transport *re-appears* (a cable replugged, or Wi-Fi toggled off
    /// then on) it's treated as an explicit request to reconnect on that very
    /// channel: the pause is lifted and a mirror is started over it. Otherwise we
    /// drop transports that have gone away (so their return counts as fresh) and
    /// keep a dropped saved Wi-Fi route warm.
    func handleManualDisconnectPause(authorized: [AuthorizedADBDevice]) async {
        let currentSerials = Set(authorized.map(\.serial))

        guard let known = manualDisconnectKnownSerials else {
            // First poll after Disconnect: whatever is online now is the baseline
            // the user chose to leave connected, so none of it should reconnect.
            manualDisconnectKnownSerials = currentSerials
            manualDisconnectBaselineSerials = currentSerials
            return
        }

        if let resumeDevice = Self.manualDisconnectResumeDevice(
            authorizedDevices: authorized,
            knownSerials: known,
            selectedDevice: selectedDevice,
            pairedPhones: pairedPhones
        ) {
            Logger.log("Transport re-discovered after manual disconnect; reconnecting on serial=\(resumeDevice.serial) usb=\(resumeDevice.isUSB)")
            resumeDiscoveryAfterManualConnect()
            previousAuthorizedSerials = currentSerials
            lastPresenceAutoConnectAttemptAt = Date()
            if resumeDevice.isUSB {
                lastUSBHandoffSerial = resumeDevice.serial
            }
            await mirrorAuthorizedDevicePreferringWireless(resumeDevice)
            refreshAutoConnectingState(authorized: authorized)
            return
        }

        // Nothing new yet. Forget transports that have dropped so their return
        // registers as a fresh re-discovery, then keep a dropped saved Wi-Fi
        // route warm (adb won't reconnect a wireless device on its own).
        manualDisconnectKnownSerials = known.intersection(currentSerials)
        probeSavedWirelessRouteWhilePausedIfNeeded(authorized: authorized)
    }

    /// While paused after a manual disconnect, gently re-probe the most recent
    /// saved Wi-Fi route when no wireless device is currently connected, so a
    /// phone whose Wi-Fi was switched off and back on re-appears in `adb devices`
    /// and trips the re-discovery reconnect above. Best-effort, fire-and-forget,
    /// and capped to one in-flight probe — it never starts a mirror itself; the
    /// watcher does that once the device shows up.
    func probeSavedWirelessRouteWhilePausedIfNeeded(authorized: [AuthorizedADBDevice]) {
        guard !manualDisconnectWiFiProbeInFlight else { return }
        guard !authorized.contains(where: { !$0.isUSB }) else { return }
        // Only chase a Wi-Fi route that was actually connected at disconnect and
        // has since dropped (the "toggled Wi-Fi off then on" case). Never dial a
        // route the user never had up, so a USB-only Disconnect can't silently
        // jump onto a stale saved Wi-Fi route.
        guard let address = Self.recordsByMostRecent(autoConnectEligiblePairedPhones)
            .compactMap(\.resolvedWiFiAddress)
            .first(where: {
                manualDisconnectBaselineSerials.contains($0)
                    && (legacyWirelessCompatibilityEnabled || !Self.isLegacyWirelessAddress($0))
            })
        else { return }

        manualDisconnectWiFiProbeInFlight = true
        let adb = self.adb
        Task { [weak self] in
            _ = await Task.detached {
                adb.run(["connect", address], timeout: Self.wirelessHandoffConnectTimeout)
            }.value
            guard let self else { return }
            self.manualDisconnectWiFiProbeInFlight = false
        }
    }

    /// ADB does not automatically re-add a wireless target after Wi-Fi drops; the
    /// saved route must be nudged with `adb connect`. This keeps the
    /// status UI fresh in the background without using the heavier mirror-start
    /// reconnect path or its longer failure cooldown.
    func probeSavedWiFiStatusIfNeeded(authorized: [AuthorizedADBDevice]) {
        guard !savedWiFiStatusProbeInFlight else { return }
        let records = Self.recordsByMostRecent(autoConnectEligiblePairedPhones)
        guard let record = records.first(where: { record in
            guard let address = record.resolvedWiFiAddress else { return false }
            return legacyWirelessCompatibilityEnabled || !Self.isLegacyWirelessAddress(address)
        }),
              let address = record.resolvedWiFiAddress else {
            return
        }
        // A merely-waiting automatic reconnect (parked in backoff) must not
        // block this probe: a plain :5555 phone advertises nothing over mDNS,
        // so this cheap dial is the only signal that turns the Wi-Fi status
        // green while the coordinator sleeps. Only an actively dialing flight
        // (or manual wireless work) owns the wire.
        guard Self.shouldProbeSavedWiFiStatus(
            hasSavedWiFiRoute: true,
            hasLiveWirelessDevice: authorized.contains { !$0.isUSB },
            isPairing: isPairing,
            isMirroring: isMirroring,
            hasWirelessWorkInFlight: connectionCoordinator.isPreparingWiFiHandoff
                || connectionCoordinator.isAutomaticReconnectDialing,
            isListenerMissing: connectionCoordinator.wirelessListenerMissingRecordIDs
                .contains(record.id),
            lastProbeAt: lastSavedWiFiStatusProbeAt
        ) else {
            return
        }

        lastSavedWiFiStatusProbeAt = Date()
        savedWiFiStatusProbeInFlight = true
        let adb = self.adb
        Task { [weak self] in
            let connectOutput = await Task.detached {
                adb.run(["connect", address], timeout: Self.wirelessHandoffConnectTimeout)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard Self.adbConnectSucceeded(connectOutput) else {
                self.savedWiFiStatusProbeInFlight = false
                return
            }

            let output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
            guard !Task.isCancelled else { return }
            self.savedWiFiStatusProbeInFlight = false
            let refreshed = Self.devicesAvailableForCurrentPath(
                Self.authorizedADBDevices(in: output),
                isPathLossConfirmed: self.isNetworkPathLossConfirmed
            )
            self.recordADBHealth(output, authorizedDevices: refreshed)
            self.applyDevicePresence(output)
            if refreshed.contains(where: { !$0.isUSB }) {
                self.failedAutoConnectTargets.removeValue(forKey: address)
                Logger.log("Saved Wi-Fi route reappeared during background status probe address=\(address)")
            }
        }
    }

    // MARK: - Window registration

    func registerConnectionWindow(_ window: NSWindow?) {
        guard let window else { return }
        connectionWindow = window
        if isFirstRunOnboardingActive {
            hideConnectionWindow()
        }
    }

    /// A launch presentation may defend the window for at most this long.
    /// Unbounded, it re-raised the window on every resign until the user
    /// clicked elsewhere — a visible focus tug-of-war ("flashing").
    nonisolated static let foregroundLaunchPresentationWindow: TimeInterval = 3

    func beginForegroundLaunchPresentation() {
        foregroundLaunchPresentationActive = true
        foregroundLaunchPresentationStartedAt = Date()
    }

    func endForegroundLaunchPresentation() {
        foregroundLaunchPresentationActive = false
        foregroundLaunchPresentationStartedAt = nil
    }

    var shouldPreserveForegroundLaunchPresentationAfterResign: Bool {
        guard foregroundLaunchPresentationActive,
              let startedAt = foregroundLaunchPresentationStartedAt else { return false }
        return Date().timeIntervalSince(startedAt) < Self.foregroundLaunchPresentationWindow
    }

    var shouldAssertForegroundPresentation: Bool {
        foregroundLaunchPresentationActive || NSApp?.isActive == true
    }

    func resetFirstTimeUserOnboardingState() {
        UserDefaults.standard.set(false, forKey: "hasSeenFirstTimeUserOnboarding")
        UserDefaults.standard.removeObject(forKey: PairedPhoneStore.defaultsKey)
        for suiteName in PairedPhoneStore.compatibilitySuites {
            UserDefaults(suiteName: suiteName)?.set(false, forKey: "hasSeenFirstTimeUserOnboarding")
            UserDefaults(suiteName: suiteName)?.removeObject(forKey: PairedPhoneStore.defaultsKey)
        }
        pairedPhones = []
        sessionAutoConnectSuspendedRecordIDs.removeAll()
        selectedDevice = .demo
        isSelectedDeviceOnline = false
        requireExplicitDeviceSetup()
        stopQRCodePairingSession()
    }

    // MARK: - First-run onboarding presentation gate

    /// After onboarding completes, auto-mirror stays paused until this instant
    /// so the freshly revealed connection screen is actually seen before a
    /// mirror session takes over.
    nonisolated static let postOnboardingMirrorHoldDuration: TimeInterval = 3

    func setFirstRunOnboardingActive(_ active: Bool) {
        guard isFirstRunOnboardingActive != active else { return }
        isFirstRunOnboardingActive = active
        guard active else { return }
        // Onboarding owns the screen: drop any pending post-onboarding hold
        // and take the connection window (and its chrome) off screen here, so
        // the invariant doesn't depend on every caller remembering to hide it.
        postOnboardingRevealTask?.cancel()
        postOnboardingRevealTask = nil
        postOnboardingMirrorHoldUntil = nil
        suspendQRCodePairingForOnboarding()
        hideConnectionWindow()
    }

    nonisolated static func shouldHoldAutoMirrorStart(
        onboardingActive: Bool,
        holdUntil: Date?,
        now: Date = Date()
    ) -> Bool {
        if onboardingActive {
            return true
        }
        if let holdUntil, now < holdUntil {
            return true
        }
        return false
    }

    var isAutoMirrorHeldForOnboarding: Bool {
        Self.shouldHoldAutoMirrorStart(
            onboardingActive: isFirstRunOnboardingActive,
            holdUntil: postOnboardingMirrorHoldUntil
        )
    }

    func completeFirstTimeUserOnboarding() {
        requireExplicitDeviceSetup()
        selectedDevice = .demo
        isSelectedDeviceOnline = false
        isFirstRunOnboardingActive = false
        // Let the connection screen breathe before any auto-mirror takeover,
        // then rescan so an already-plugged phone connects (and hands off to
        // Wi-Fi) right when the hold lifts instead of waiting for the next poll.
        postOnboardingMirrorHoldUntil = Date().addingTimeInterval(Self.postOnboardingMirrorHoldDuration)
        UserDefaults.standard.set(true, forKey: "hasSeenFirstTimeUserOnboarding")
        postOnboardingRevealTask?.cancel()
        postOnboardingRevealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.postOnboardingMirrorHoldDuration * 1_000_000_000)
            )
            guard let self, !Task.isCancelled else { return }
            self.postOnboardingMirrorHoldUntil = nil
            self.scanADBDevices()
        }
    }

    // MARK: - Discovery → auto-reconnect

    /// On launch, try saved adb routes immediately; if needed, give mDNS a few
    /// seconds for a previously-paired phone to advertise its connect service.
    /// Bluetooth-style auto-reconnect.
    func attemptAutoReconnect() {
        requestAutomaticReconnect(trigger: .launch)
    }

    enum AutomaticWirelessAttemptOutcome {
        case connected(sessionAddress: String)
        case failed(ConnectionCoordinator.AutomaticReconnectFailure)
    }

    /// Pure decision: does this reconnect failure warrant the "plug in once"
    /// prompt right now? Only the listener-missing verdict qualifies, and it
    /// qualifies on the first failure — the sweep already proved the listener
    /// gone, so a second dial adds information about nothing.
    nonisolated static func shouldSurfaceListenerMissingPrompt(
        failure: ConnectionCoordinator.AutomaticReconnectFailure,
        failureCount: Int
    ) -> Bool {
        failure == .wirelessListenerMissing && failureCount >= 1
    }

    func nextAutomaticReconnectRecord(now: Date = Date()) -> PairedPhoneRecord? {
        var records = Self.recordsByMostRecent(autoConnectEligiblePairedPhones)
            .filter(Self.isWirelessRecord)
        guard !records.isEmpty else { return nil }

        // A record whose LAN sweep proved the adb listener gone is parked: no
        // timer-driven redial can bring it back, so selecting it would only
        // burn another sweep + dial cycle every backoff window. Only a cable
        // (whose successful arm clears the verdict) or fresh evidence — a
        // discovery/network/wake bypass, which may mean the phone's state
        // actually changed — unparks it. With every record parked the loop
        // exits to idle instead of churning, and any later trigger restarts it.
        let hasFreshEvidence = connectionCoordinator.automaticReconnectBypassPending
            || connectionCoordinator.automaticReconnectPreferredRecordID != nil
        if !hasFreshEvidence {
            records = records.filter {
                !connectionCoordinator.wirelessListenerMissingRecordIDs.contains($0.id)
            }
            guard !records.isEmpty else { return nil }
        }
        let allowSingleCandidateFallback = records.count == 1

        if let preferredID = connectionCoordinator.automaticReconnectPreferredRecordID,
           let preferredIndex = records.firstIndex(where: { $0.id == preferredID }) {
            connectionCoordinator.automaticReconnectPreferredRecordID = nil
            connectionCoordinator.automaticReconnectRecordCursor = (preferredIndex + 1) % records.count
            return records[preferredIndex]
        }
        connectionCoordinator.automaticReconnectPreferredRecordID = nil

        // Fresh phone-matched evidence wins even if another remembered phone is
        // first by recency. This also makes a discovery wake target the device
        // that actually appeared instead of spending it on an offline favorite.
        let start = connectionCoordinator.automaticReconnectRecordCursor % records.count
        for offset in 0..<records.count {
            let index = (start + offset) % records.count
            let record = records[index]
            let retryAt = connectionCoordinator.automaticRetryStates[record.id]?.nextRetryAt
                ?? .distantPast
            let isLive = Self.rememberedConnectablePhone(
                for: record,
                in: discoveredPhones,
                allowSingleCandidateFallback: allowSingleCandidateFallback
            ) != nil || Self.liveWirelessAuthorizedDevice(
                for: record,
                in: latestAuthorizedADBDevices
            ) != nil
            if isLive, retryAt <= now {
                connectionCoordinator.automaticReconnectRecordCursor = (index + 1) % records.count
                return record
            }
        }

        for offset in 0..<records.count {
            let index = (start + offset) % records.count
            let retryAt = connectionCoordinator.automaticRetryStates[records[index].id]?.nextRetryAt
                ?? .distantPast
            if retryAt <= now {
                connectionCoordinator.automaticReconnectRecordCursor = (index + 1) % records.count
                return records[index]
            }
        }

        // Every phone is cooling down. Park on the earliest deadline, then the
        // cursor will continue after it, so one absent recent phone cannot starve
        // every other paired phone forever.
        let indexedRecords = Array(records.enumerated())
        guard let earliest = indexedRecords.min(by: { lhs, rhs in
            let left = connectionCoordinator.automaticRetryStates[lhs.element.id]?.nextRetryAt
                ?? .distantFuture
            let right = connectionCoordinator.automaticRetryStates[rhs.element.id]?.nextRetryAt
                ?? .distantFuture
            return left < right
        }) else { return nil }
        connectionCoordinator.automaticReconnectRecordCursor = (earliest.offset + 1) % records.count
        return earliest.element
    }

    /// Single entry point for every automatic wireless reconnect trigger.
    /// Explicit USB, QR pairing, and user-initiated Wi-Fi work remain separate
    /// workflows, but cancel this task before taking ownership of the route.
    func requestAutomaticReconnect(
        trigger: ConnectionCoordinator.AutomaticReconnectTrigger
    ) {
        guard Self.automaticReconnectTriggerAllowed(
                explicitDeviceSetupRequired: explicitDeviceSetupRequired,
                isFirstRunOnboardingActive: isFirstRunOnboardingActive,
                isAutoMirrorHeldForOnboarding: isAutoMirrorHeldForOnboarding
              ),
              backgroundServicesEnabled,
              !isMirroring,
              mirrorSession == nil,
              mirrorLaunchTask == nil,
              !isPairing,
              !isAutoReconnectSuppressedForManualDisconnect,
              !connectionCoordinator.hasManualConnectionWorkInFlight else { return }
        let records = Self.recordsByMostRecent(autoConnectEligiblePairedPhones)
            .filter(Self.isWirelessRecord)
        let allowSingleCandidateFallback = records.count == 1
        let discoveredAddress: String?
        if case .discovery(let address, _) = trigger {
            discoveredAddress = address
        } else {
            discoveredAddress = nil
        }
        let evidenceRecord = discoveredAddress.flatMap { address in
            records.first { candidate in
                Self.rememberedConnectablePhone(
                    for: candidate,
                    in: discoveredPhones,
                    allowSingleCandidateFallback: allowSingleCandidateFallback
                )?.address == address
            }
        }
        guard let record = evidenceRecord ?? records.first(where: { candidate in
            Self.rememberedConnectablePhone(
                for: candidate,
                in: discoveredPhones,
                allowSingleCandidateFallback: allowSingleCandidateFallback
            ) != nil
        }) ?? records.first else { return }
        if evidenceRecord != nil {
            connectionCoordinator.automaticReconnectPreferredRecordID = record.id
        }

        if connectionCoordinator.automaticReconnectTask != nil {
            connectionCoordinator.requestAutomaticReconnectWake(
                recordID: record.id,
                trigger: trigger
            )
            return
        }

        let taskGeneration = connectionCoordinator.beginAutomaticReconnectTask()
        connectionCoordinator.automaticReconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.runAutomaticReconnectLoop(
                initialTrigger: trigger,
                taskGeneration: taskGeneration
            )
        }
    }

    nonisolated static func automaticReconnectTriggerAllowed(
        explicitDeviceSetupRequired: Bool,
        isFirstRunOnboardingActive: Bool,
        isAutoMirrorHeldForOnboarding: Bool
    ) -> Bool {
        !explicitDeviceSetupRequired
            && !isFirstRunOnboardingActive
            && !isAutoMirrorHeldForOnboarding
    }

    func runAutomaticReconnectLoop(
        initialTrigger: ConnectionCoordinator.AutomaticReconnectTrigger,
        taskGeneration: Int
    ) async {
        defer {
            if connectionCoordinator.ownsAutomaticReconnectTask(
                taskGeneration: taskGeneration
            ) {
                connectionCoordinator.finishAutomaticReconnectTask(taskGeneration)
                isAutoConnecting = false
            }
        }
        var trigger = initialTrigger

        while !Task.isCancelled,
              connectionCoordinator.ownsAutomaticReconnectTask(
                taskGeneration: taskGeneration
              ) {
            guard !explicitDeviceSetupRequired,
                  !isFirstRunOnboardingActive,
                  !isAutoMirrorHeldForOnboarding,
                  !isMirroring,
                  mirrorSession == nil,
                  mirrorLaunchTask == nil,
                  !isPairing,
                  !isAutoReconnectSuppressedForManualDisconnect,
                  !connectionCoordinator.hasManualConnectionWorkInFlight,
                  let record = nextAutomaticReconnectRecord() else {
                if connectionCoordinator.ownsAutomaticReconnectTask(
                    taskGeneration: taskGeneration
                ), connectionCoordinator.automaticReconnectState != .manuallyDisconnected {
                    connectionCoordinator.automaticReconnectState = .idle
                }
                return
            }

            let now = Date()
            let mayAttempt = connectionCoordinator.consumeAutomaticReconnectBypass()
                || connectionCoordinator.mayAttemptAutomaticReconnect(
                    recordID: record.id,
                    trigger: trigger,
                    now: now
                )

            if !mayAttempt {
                let retryAt = connectionCoordinator
                    .automaticRetryStates[record.id]?.nextRetryAt ?? .distantPast
                if retryAt > now {
                    await connectionCoordinator.sleepUntilAutomaticReconnect(retryAt)
                    guard connectionCoordinator.ownsAutomaticReconnectTask(
                        taskGeneration: taskGeneration
                    ) else { return }
                    trigger = .watcher
                    continue
                }
            }

            guard let generation = connectionCoordinator.beginAutomaticReconnect(
                recordID: record.id
            ) else {
                return
            }
            Logger.log(
                "Automatic reconnect phase=attempt-start phone=\(record.displayName) task=\(taskGeneration) attempt=\(generation)"
            )

            isAutoConnecting = true
            if hasCompletedSuccessfulMirrorConnection {
                isRecoveringConnection = true
                isAwaitingReconnect = true
            }
            select(record: record)
            stopQRCodePairingSession()

            let outcome = await performAutomaticWirelessReconnect(
                record: record,
                taskGeneration: taskGeneration,
                attemptGeneration: generation
            )
            guard !Task.isCancelled,
                  connectionCoordinator.ownsAutomaticReconnectTask(
                    taskGeneration: taskGeneration,
                    attemptGeneration: generation
                  ) else { return }

            switch outcome {
            case .connected(let sessionAddress):
                let completed = await completeAutomaticWirelessReconnect(
                    record: record,
                    sessionAddress: sessionAddress,
                    taskGeneration: taskGeneration,
                    attemptGeneration: generation
                )
                guard completed,
                      !Task.isCancelled,
                      connectionCoordinator.ownsAutomaticReconnectTask(
                        taskGeneration: taskGeneration,
                        attemptGeneration: generation
                      ),
                      !isAutoReconnectSuppressedForManualDisconnect else { return }
                connectionCoordinator.recordAutomaticReconnectSuccess(recordID: record.id)
                // A route that connected proves the listener is alive; drop any
                // stale "plug in once" verdict so a later unrelated failure
                // can't inherit it.
                wirelessListenerMissingRecordIDs.remove(record.id)
                Logger.log(
                    "Automatic reconnect phase=connected phone=\(record.displayName) task=\(taskGeneration) attempt=\(generation)"
                )
                isRecoveringConnection = false
                isAwaitingReconnect = false
                return

            case .failed(let failure):
                let retryAt = connectionCoordinator.recordAutomaticReconnectFailure(
                    recordID: record.id,
                    failure: failure,
                    notBefore: autoMirrorBackoffUntil,
                    // The user is looking at the connect screen. Keep the
                    // saved endpoint hot instead of parking a known IP behind
                    // the background 10/20/30-second ladder. Whole-subnet
                    // recovery remains independently throttled below.
                    maximumDelay: isConnectionAttemptForegrounded ? 5 : nil
                )
                let failureCount = connectionCoordinator.automaticRetryStates[record.id]?.failureCount ?? 1
                Logger.log(
                    "Automatic reconnect phase=attempt-failed phone=\(record.displayName) task=\(taskGeneration) attempt=\(generation) failure=\(failure.rawValue) count=\(failureCount) retry_in=\(String(format: "%.1f", max(0, retryAt.timeIntervalSinceNow)))s"
                )
                // A swept-and-silent LAN is proof, not a guess: nothing here
                // speaks adb, so more waiting cannot help. Say so on the first
                // proof — not after repeat dials — because the fix is a
                // two-second cable and the alternative is watching a spinner
                // while the loop churns a dead port.
                if Self.shouldSurfaceListenerMissingPrompt(
                    failure: failure,
                    failureCount: failureCount
                ) {
                    if activeError?.title != Self.wifiListenerMissingErrorTitle {
                        reportError(
                            Self.wifiListenerMissingErrorTitle,
                            "\(record.displayName) isn't offering adb over Wi-Fi. Restarting the phone turns that off, and it can only be switched back on over USB. Plug the cable in for a moment — Phone Relay re-enables Wi-Fi and you can unplug again."
                        )
                    }
                } else if failureCount >= 4 {
                    // Pairing-required is the one plateau failure that is
                    // provably the user's to fix — the phone only advertises
                    // its pairing service — so say that instead of "waiting".
                    if failure == .pairingRequired {
                        if activeError?.title != Self.wifiPairingRequiredErrorTitle {
                            reportError(
                                Self.wifiPairingRequiredErrorTitle,
                                "\(record.displayName) is only advertising its pairing service. Open Wireless debugging on the phone and pair with QR again, or connect USB once."
                            )
                        }
                    } else if activeError?.title != Self.wifiConnectionNotReadyErrorTitle {
                        reportError(
                            Self.wifiConnectionNotReadyErrorTitle,
                            "Phone Relay is still checking for \(record.displayName). Keep the phone awake and on the same Wi-Fi. If it was restarted, plug the cable in for a moment to switch Wi-Fi back on."
                        )
                    }
                }
                isAutoConnecting = true
                // Re-enter selection immediately. Another paired phone may be
                // ready now; if every record is cooling down, the next loop
                // chooses the earliest coordinator deadline and sleeps once.
                trigger = .watcher
                continue
            }
        }
    }

    func performAutomaticWirelessReconnect(
        record: PairedPhoneRecord,
        taskGeneration: Int,
        attemptGeneration: Int
    ) async -> AutomaticWirelessAttemptOutcome {
        func ownsAttempt() -> Bool {
            !Task.isCancelled && connectionCoordinator.ownsAutomaticReconnectTask(
                taskGeneration: taskGeneration,
                attemptGeneration: attemptGeneration
            )
        }
        guard ownsAttempt() else { return .failed(.temporarilyUnavailable) }
        let adb = self.adb
        // The device watcher owns the protected adb warm-up. Start network
        // discovery/preflight now so it overlaps that cold start; any later
        // serialized `adb connect` naturally waits behind the shared warm-up.

        let allowsSingleLiveCandidate = autoConnectEligiblePairedPhones
            .filter(Self.isWirelessRecord)
            .count == 1
        let authorizedCandidate = Self.liveWirelessAuthorizedDevice(
            for: record,
            in: latestAuthorizedADBDevices
        )?.serial
        let authorizedAddress = authorizedCandidate.flatMap { address in
            legacyWirelessCompatibilityEnabled || !Self.isLegacyWirelessAddress(address)
                ? address
                : nil
        }
        let discoveredCandidate = Self.rememberedConnectablePhone(
            for: record,
            in: discoveredPhones,
            allowSingleCandidateFallback: allowsSingleLiveCandidate
        )?.address
        let discoveredAddress = discoveredCandidate.flatMap { address in
            legacyWirelessCompatibilityEnabled || !Self.isLegacyWirelessAddress(address)
                ? address
                : nil
        }
        // A resolved discovery endpoint is immediately dialable. An authorized
        // service-name row can still fail as an `adb connect` target, so use it
        // only for the direct shell-ready fast path above and prefer discovery
        // for any reconnect command that follows.
        let liveAddress = discoveredAddress ?? authorizedAddress
        let savedAddress = record.resolvedWiFiAddress ?? record.lastAddress
        let currentNetworkFingerprint = WiFiAddressRecovery.currentNetworkFingerprint()
        let networkChanged = connectionCoordinator.preferCurrentNetworkForNextReconnect
            || (record.wifiNetworkFingerprint.flatMap { previous in
                currentNetworkFingerprint.map { previous != $0 }
            } ?? false)
        var result: RememberedWirelessConnectResult
        if let authorizedAddress,
           await Self.isADBDeviceShellReady(
                adb: adb,
                serial: authorizedAddress,
                timeout: Self.automaticReconnectLiveShellTimeout
           ) {
            // The watcher already proved identity and adb now proved shell
            // readiness. Reconnecting and probing this same live transport
            // only delays first frame and can destabilize a healthy route.
            result = RememberedWirelessConnectResult(
                connectedAddress: authorizedAddress,
                connectAttempts: 0,
                noRouteToHostFailures: 0
            )
        } else if let liveAddress {
            // Discovery has already resolved the phone's current endpoint. Dial
            // that single route first instead of probing stale saved and :5555
            // candidates before it. Healthy discoveries now reach mirror launch
            // after one readiness round; saved routes remain the fallback.
            Logger.log("Automatic reconnect prioritizing fresh live endpoint for \(record.displayName)")
            result = await Self.connectToRememberedWirelessReadiness(
                adb: adb,
                savedAddress: liveAddress,
                candidateAddresses: [liveAddress],
                allowLegacyCompatibility: legacyWirelessCompatibilityEnabled,
                restrictDialsToReachableOrStable: true,
                readinessAttempts: 2,
                delayNanoseconds: Self.wirelessHandoffRetryDelayNanoseconds,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                },
                connectTimeout: Self.wirelessHandoffConnectTimeout,
                shellTimeout: Self.wirelessHandoffShellTimeout
            )

            if result.connectedAddress == nil, !networkChanged {
                let fallbackCandidates = Self.canonicalReconnectCandidateAddresses(
                    savedAddress: savedAddress,
                    liveAddress: nil,
                    allowLegacyCompatibility: legacyWirelessCompatibilityEnabled
                ).filter { $0 != liveAddress }
                if !fallbackCandidates.isEmpty {
                    let fallback = await Self.connectToRememberedWirelessReadiness(
                        adb: adb,
                        savedAddress: savedAddress,
                        candidateAddresses: fallbackCandidates,
                        allowLegacyCompatibility: legacyWirelessCompatibilityEnabled,
                        restrictDialsToReachableOrStable: true,
                        readinessAttempts: 2,
                        delayNanoseconds: Self.wirelessHandoffRetryDelayNanoseconds,
                        preflightLocalNetworkAccess: { address in
                            await Self.preflightLocalNetworkAccess(address: address)
                        },
                        connectTimeout: Self.wirelessHandoffConnectTimeout,
                        shellTimeout: Self.wirelessHandoffShellTimeout
                    )
                    result.connectAttempts += fallback.connectAttempts
                    result.noRouteToHostFailures += fallback.noRouteToHostFailures
                    result.sawReachableNoRoute = result.sawReachableNoRoute
                        || fallback.sawReachableNoRoute
                    result.connectedAddress = fallback.connectedAddress
                }
            }
        } else if networkChanged {
            Logger.log("Automatic reconnect detected a new network with no live endpoint for \(record.displayName)")
            result = RememberedWirelessConnectResult(
                connectedAddress: nil,
                connectAttempts: 0,
                noRouteToHostFailures: 0
            )
        } else {
            let candidates = Self.canonicalReconnectCandidateAddresses(
                savedAddress: savedAddress,
                liveAddress: liveAddress,
                allowLegacyCompatibility: legacyWirelessCompatibilityEnabled
            )
            result = await Self.connectToRememberedWirelessReadiness(
                adb: adb,
                savedAddress: savedAddress,
                candidateAddresses: candidates,
                allowLegacyCompatibility: legacyWirelessCompatibilityEnabled,
                restrictDialsToReachableOrStable: true,
                readinessAttempts: 2,
                delayNanoseconds: Self.wirelessHandoffRetryDelayNanoseconds,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                },
                connectTimeout: Self.wirelessHandoffConnectTimeout,
                shellTimeout: Self.wirelessHandoffShellTimeout
            )
        }
        guard ownsAttempt() else { return .failed(.temporarilyUnavailable) }

        if result.connectedAddress == nil,
           legacyWirelessCompatibilityEnabled,
           let recovered = await recoverChangedWiFiAddress(
                for: record,
                ignoreCooldown: networkChanged,
                prioritizeCurrentNetwork: networkChanged
           ) {
            result.connectedAddress = recovered
        }
        guard ownsAttempt() else { return .failed(.temporarilyUnavailable) }

        if let connectedAddress = result.connectedAddress {
            let sessionAddress: String
            if legacyWirelessCompatibilityEnabled,
               Self.shouldStabilizeAutomaticWirelessAddress(
                connectedAddress: connectedAddress,
                hasFreshLiveEndpoint: liveAddress != nil
            ) {
                sessionAddress = await stabilizeAutomaticWirelessAddress(
                    connectedAddress,
                    adb: adb
                )
            } else {
                // Fresh discovery or an already-authorized route is ready now.
                // Do not restart adbd to manufacture :5555 before first frame.
                sessionAddress = connectedAddress
            }
            guard ownsAttempt() else { return .failed(.temporarilyUnavailable) }
            return .connected(sessionAddress: sessionAddress)
        }

        if result.sawNoRouteToHost && !localNetworkPermissionGrantedForOnboarding {
            presentLocalNetworkPermissionHint()
            return .failed(.localNetworkDenied)
        }
        if latestADBStatusText == "adb missing" {
            return .failed(.adbUnavailable)
        }
        if latestHasUnauthorizedUSBDevice {
            return .failed(.unauthorizedUSB)
        }
        let services = await Task.detached { adb.mdnsServices() }.value
        guard ownsAttempt() else { return .failed(.temporarilyUnavailable) }
        if !services.isEmpty, services.allSatisfy({ $0.kind == .pairable }) {
            return .failed(.pairingRequired)
        }
        // The sweep swept and the LAN is silent on :5555. mDNS is silent too
        // (checked just above), so there is no wireless route to find — the
        // phone's listener is gone until a cable re-arms it.
        if wirelessListenerMissingRecordIDs.contains(record.id) {
            return .failed(.wirelessListenerMissing)
        }
        return .failed(.temporarilyUnavailable)
    }

    func stabilizeAutomaticWirelessAddress(
        _ connectedAddress: String,
        adb: ADBController
    ) async -> String {
        guard legacyWirelessCompatibilityEnabled else { return connectedAddress }
        guard Self.shouldPromoteToLegacyTCPIP(connectedAddress: connectedAddress) else {
            return connectedAddress
        }
        switch await Self.promoteToLegacyTCPIP(
            adb: adb,
            sourceSerial: connectedAddress,
            preflightLocalNetworkAccess: { address in
                await Self.preflightLocalNetworkAccess(address: address)
            }
        ) {
        case .promoted(let address):
            return address
        case .unavailable:
            return connectedAddress
        case .transportLost(let legacyAddress):
            let recovered = await Self.connectToRememberedWirelessReadiness(
                adb: adb,
                savedAddress: legacyAddress,
                allowLegacyCompatibility: true,
                readinessAttempts: 2,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                }
            )
            return recovered.connectedAddress ?? connectedAddress
        }
    }

    nonisolated static func shouldStabilizeAutomaticWirelessAddress(
        connectedAddress: String,
        hasFreshLiveEndpoint: Bool
    ) -> Bool {
        !hasFreshLiveEndpoint
            && shouldPromoteToLegacyTCPIP(connectedAddress: connectedAddress)
    }

    func completeAutomaticWirelessReconnect(
        record: PairedPhoneRecord,
        sessionAddress: String,
        taskGeneration: Int,
        attemptGeneration: Int
    ) async -> Bool {
        guard connectionCoordinator.ownsAutomaticReconnectTask(
            taskGeneration: taskGeneration,
            attemptGeneration: attemptGeneration
        ) else { return false }
        // Discovery and the watcher already supplied identity. Avoid another
        // `adb devices -l` subprocess on the verified route before first frame.
        let deviceName = Self.mirrorWindowDeviceTitle(
            name: latestAuthorizedADBDevices.first(where: {
                !$0.isUSB && $0.serial == sessionAddress
            })?.model ?? record.displayName
        )
        let addressToPersist = Self.automaticWirelessAddressToPersist(
            sessionAddress: sessionAddress,
            existingWirelessAddress: record.resolvedWiFiAddress,
            allowLegacyCompatibility: legacyWirelessCompatibilityEnabled
        )
        let touchAddress = addressToPersist
            ?? record.resolvedUSBSerial
            ?? record.lastAddress

        touchPairedPhone(
            id: record.id,
            displayName: deviceName,
            address: touchAddress,
            usbSerial: record.resolvedUSBSerial,
            wifiAddress: addressToPersist
        )
        failedAutoConnectTargets.removeValue(forKey: record.lastAddress)
        failedAutoConnectTargets.removeValue(forKey: sessionAddress)
        activeError = nil
        selectedDevice.adbSerial = sessionAddress
        selectedDevice.name = deviceName
        selectedDevice.network = "Wi-Fi"
        isSelectedDeviceOnline = true
        stopQRCodePairingSession()
        if let until = autoMirrorBackoffUntil, until > Date() {
            let delay = until.timeIntervalSinceNow
            connectionCoordinator.automaticReconnectState = .waiting(
                recordID: record.id,
                retryAt: until,
                failure: .mirrorCrashBackoff
            )
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled,
                  connectionCoordinator.ownsAutomaticReconnectTask(
                    taskGeneration: taskGeneration,
                    attemptGeneration: attemptGeneration
                  ),
                  !isMirroring,
                  !isAutoReconnectSuppressedForManualDisconnect else { return false }
        }
        guard connectionCoordinator.ownsAutomaticReconnectTask(
            taskGeneration: taskGeneration,
            attemptGeneration: attemptGeneration
        ) else { return false }
        launchNativeMirror(serial: sessionAddress)
        return true
    }

    /// Gate for the old "adopt a single visible Wi-Fi target when the paired
    /// store was lost" recovery flow. Deliberately disabled (always false); the
    /// flow itself was removed once the single-flight coordinator became the
    /// only automatic reconnect entry point. Kept so the disable stays
    /// documented and tested rather than silently forgotten.
    nonisolated static func shouldAttemptRecoveredWiFiReconnect(
        hasSavedDevices: Bool,
        explicitDeviceSetupRequired: Bool
    ) -> Bool {
        false
    }

    func connectAndMirror(phone: DiscoveredPhone) {
        guard !explicitDeviceSetupRequired else {
            if transportIntent.requiresWiFi { transportIntent = .automatic }
            return
        }
        guard legacyWirelessCompatibilityEnabled
                || (phone.kind != .legacyTCPIP && !Self.isLegacyWirelessAddress(phone.address))
        else {
            noteConnectionStall(
                .wirelessRouteMissing,
                detail: "Secure Wireless debugging is required. Enable legacy compatibility in Settings only for a phone that cannot use it."
            )
            return
        }
        let address = phone.address
        guard !autoConnectTargetsInFlight.contains(address) else { return }
        autoConnectTargetsInFlight.insert(address)
        let label = displayName(for: phone)

        let adb = self.adb
        let mirrorGeneration = mirrorStartGeneration
        let connectGeneration = connectionCoordinator.beginDiscoveredWiFiConnect()
        connectionCoordinator.discoveredWiFiConnectTask = Task { [weak self] in
            await adb.ensureServerStarted()
            // 4 attempts ≈ 3s: a phone that is advertising over mDNS is awake,
            // but its transport can sit in "offline" for a beat after connect.
            // Giving up too early put good targets into the failure cooldown,
            // which read as "the app never auto-connects".
            let readiness = await Self.waitForADBWirelessTargetReadiness(
                adb: adb,
                address: address,
                attempts: 4,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                },
                tcpPortProbe: { address in
                    await Self.adbTCPPortProbe(address)
                }
            )
            let ready = readiness.isReady

            guard let self else { return }
            guard !Task.isCancelled,
                  self.mirrorStartGeneration == mirrorGeneration,
                  self.connectionCoordinator.isCurrentDiscoveredWiFiConnect(connectGeneration)
            else {
                self.completeDiscoveredWiFiConnect(
                    generation: connectGeneration,
                    address: address,
                    resetManualIntent: true
                )
                return
            }
            self.autoConnectTargetsInFlight.remove(address)
            if readiness.sawNoRouteToHost {
                self.presentLocalNetworkPermissionHint()
            }
            if ready {
                guard !self.explicitDeviceSetupRequired else {
                    self.completeDiscoveredWiFiConnect(
                        generation: connectGeneration,
                        address: address,
                        resetManualIntent: true
                    )
                    return
                }
                // This discovery endpoint has already passed connect plus shell
                // readiness. Promoting it to legacy :5555 restarts adbd and can
                // add several retry windows before first frame, or lose the
                // working transport entirely. Persist and launch the verified
                // endpoint now; route maintenance must not block the mirror.
                let mirrorAddress = address
                guard !Task.isCancelled,
                      self.mirrorStartGeneration == mirrorGeneration,
                      self.connectionCoordinator.isCurrentDiscoveredWiFiConnect(connectGeneration)
                else {
                    self.completeDiscoveredWiFiConnect(
                        generation: connectGeneration,
                        address: address,
                        resetManualIntent: true
                    )
                    return
                }
                self.failedAutoConnectTargets.removeValue(forKey: address)
                self.failedAutoConnectTargets.removeValue(forKey: mirrorAddress)
                // The watcher already owns device-list refreshes. Avoid another
                // `adb devices -l` subprocess between readiness and launch.
                let deviceName = self.latestAuthorizedADBDevices.first(where: {
                    !$0.isUSB && $0.serial == mirrorAddress
                })?.model ?? label
                let matchingRecord = Self.recordForDiscoveredWiFiRoute(
                    records: self.pairedPhones,
                    selectedDevice: self.selectedDevice,
                    phone: phone,
                    deviceName: deviceName
                )
                self.touchPairedPhone(
                    id: matchingRecord?.id ?? phone.id,
                    displayName: matchingRecord?.displayName ?? deviceName,
                    address: mirrorAddress,
                    usbSerial: matchingRecord?.resolvedUSBSerial,
                    wifiAddress: mirrorAddress,
                    wifiMACAddress: matchingRecord?.wifiMACAddress
                )
                self.selectedDevice.adbSerial = mirrorAddress
                self.selectedDevice.name = deviceName
                self.selectedDevice.network = "Wi-Fi"
                self.isSelectedDeviceOnline = true
                self.stopQRCodePairingSession()
                self.completeDiscoveredWiFiConnect(
                    generation: connectGeneration,
                    address: address,
                    resetManualIntent: false
                )
                self.prepareManualMirrorLaunch()
                self.stopDisconnectRecovery()
                self.launchNativeMirror(serial: mirrorAddress)
            } else {
                self.noteAutoConnectFailure(for: phone)
                self.isAutoConnecting = false
                Logger.log("Auto-connect to \(address) failed readiness check")
                self.noteConnectionStall(
                    readiness.sawNoRouteToHost ? .localNetworkDenied : .wirelessTargetUnreachable,
                    detail: "\(address) did not answer the adb readiness probe."
                )
                if readiness.sawReachableNoRoute {
                    self.recoverADBDaemonIfSafe(reason: "reachable port but adb no-route for \(address)")
                }
                self.completeDiscoveredWiFiConnect(
                    generation: connectGeneration,
                    address: address,
                    resetManualIntent: true
                )
            }
        }
    }

    private func completeDiscoveredWiFiConnect(
        generation: Int,
        address: String,
        resetManualIntent: Bool
    ) {
        guard connectionCoordinator.isCurrentDiscoveredWiFiConnect(generation) else { return }
        autoConnectTargetsInFlight.remove(address)
        connectionCoordinator.finishDiscoveredWiFiConnect(generation)
        if resetManualIntent, transportIntent.requiresWiFi {
            transportIntent = .automatic
        }
    }

    func connectAndMirror(record: PairedPhoneRecord) {
        guard !explicitDeviceSetupRequired else { return }
        guard Self.isWirelessRecord(record) else { return }
        let savedAddress = record.resolvedWiFiAddress ?? record.lastAddress
        let liveCandidate = Self.rememberedConnectablePhone(
            for: record,
            in: discoveredPhones,
            allowSingleCandidateFallback: autoConnectEligiblePairedPhones
                .filter(Self.isWirelessRecord)
                .count == 1
        )?.address
        let liveAddress = liveCandidate.flatMap { address in
            legacyWirelessCompatibilityEnabled || !Self.isLegacyWirelessAddress(address)
                ? address
                : nil
        }
        let candidateAddresses = Self.canonicalReconnectCandidateAddresses(
            savedAddress: savedAddress,
            liveAddress: liveAddress,
            allowLegacyCompatibility: legacyWirelessCompatibilityEnabled
        )
        guard !candidateAddresses.isEmpty else {
            noteConnectionStall(
                .wirelessRouteMissing,
                detail: "This saved phone only has a legacy port 5555 route. Pair with Android Wireless debugging or enable legacy compatibility in Settings."
            )
            return
        }
        guard !autoConnectTargetsInFlight.contains(savedAddress) else { return }
        guard !isAutoConnectAddressCoolingDown(savedAddress) else { return }
        autoConnectTargetsInFlight.insert(savedAddress)
        select(record: record)

        let adb = self.adb
        let allowLegacyCompatibility = legacyWirelessCompatibilityEnabled
        Task { [weak self] in
            await adb.ensureServerStarted()
            let result = await Self.connectToRememberedWirelessReadiness(
                adb: adb,
                savedAddress: savedAddress,
                candidateAddresses: candidateAddresses,
                allowLegacyCompatibility: allowLegacyCompatibility,
                restrictDialsToReachableOrStable: true,
                readinessAttempts: 2,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                }
            )

            guard let self else { return }
            guard !self.explicitDeviceSetupRequired else {
                self.autoConnectTargetsInFlight.remove(savedAddress)
                return
            }

            if let connectedAddress = result.connectedAddress {
                self.autoConnectTargetsInFlight.remove(savedAddress)
                await self.completeWirelessAutoConnect(
                    record: record,
                    savedAddress: savedAddress,
                    connectedAddress: connectedAddress
                )
                return
            }

            // A saved route that fails every connect with "No route to host" is a
            // macOS Local Network denial, not an offline phone — surface it
            // instead of collapsing it into a generic readiness failure.
            if result.sawNoRouteToHost {
                self.presentLocalNetworkPermissionHint()
            }

            // Last resort: the saved IP is dead. The phone may just have a new
            // DHCP lease, so hunt for its current IP on the LAN by its MAC. Stays
            // "in flight" across the sweep so presence polls don't stack scans.
            let recovered = await self.recoverChangedWiFiAddress(for: record)
            self.autoConnectTargetsInFlight.remove(savedAddress)
            guard !self.explicitDeviceSetupRequired else { return }

            if let recovered {
                await self.completeWirelessAutoConnect(
                    record: record,
                    savedAddress: savedAddress,
                    connectedAddress: recovered
                )
                return
            }

            self.noteAutoConnectFailure(address: savedAddress)
            self.isAutoConnecting = !self.autoConnectTargetsInFlight.isEmpty
            Logger.log("Auto-connect to saved Wi-Fi route \(savedAddress) failed readiness check")
            self.noteConnectionStall(
                result.sawNoRouteToHost ? .localNetworkDenied : .wirelessTargetUnreachable,
                detail: "Saved route \(savedAddress) did not answer; IP recovery found nothing new."
            )
            if result.sawReachableNoRoute {
                self.recoverADBDaemonIfSafe(reason: "reachable port but adb no-route for \(savedAddress)")
            }
        }
    }

    /// Shared success tail for a wireless auto-connect: clear cooldowns, persist
    /// the (possibly recovered) live route, and start mirroring.
    func completeWirelessAutoConnect(
        record: PairedPhoneRecord,
        savedAddress: String,
        connectedAddress: String
    ) async {
        let adb = self.adb
        self.failedAutoConnectTargets.removeValue(forKey: savedAddress)
        self.failedAutoConnectTargets.removeValue(forKey: connectedAddress)
        let deviceName = await Self.connectedDeviceName(
            adb: adb,
            serial: connectedAddress,
            fallback: record.displayName
        )
        // Pass wifiAddress so a recovered IP replaces the stale one; the stored
        // MAC is preserved (touch keeps the existing MAC when none is supplied).
        self.touchPairedPhone(
            id: record.id,
            displayName: deviceName,
            address: connectedAddress,
            usbSerial: record.resolvedUSBSerial,
            wifiAddress: connectedAddress
        )
        self.selectedDevice.adbSerial = connectedAddress
        self.selectedDevice.name = deviceName
        self.selectedDevice.network = "Wi-Fi"
        self.isSelectedDeviceOnline = true
        self.stopQRCodePairingSession()
        self.startMirroring()
    }

    /// Hunts for a paired phone's current Wi-Fi address after its IP changed,
    /// then verifies the result is adb-ready. Throttled per record so a phone
    /// that's merely away can't trigger repeated whole-subnet scans. Returns the
    /// verified `host:port`, or nil.
    /// True while the user is actively watching the connect screen: the app is
    /// frontmost and the connection window is on-screen, and we're not already
    /// mirroring. When backgrounded — the menu-bar-idle case a phone that's away
    /// would otherwise scan-storm — this is false, so the longer idle cooldown
    /// applies.
    var isConnectionAttemptForegrounded: Bool {
        guard !isMirroring, NSApp.isActive else { return false }
        return connectionWindow?.isVisible ?? false
    }

    var activeWiFiRecoveryCooldown: TimeInterval {
        isConnectionAttemptForegrounded
            ? Self.wifiAddressRecoveryForegroundCooldown
            : Self.wifiAddressRecoveryCooldown
    }

    func recoverChangedWiFiAddress(
        for record: PairedPhoneRecord,
        ignoreCooldown: Bool = false,
        prioritizeCurrentNetwork: Bool = false
    ) async -> String? {
        guard legacyWirelessCompatibilityEnabled,
              let savedAddress = record.resolvedWiFiAddress,
              Self.isLegacyWirelessAddress(savedAddress)
        else { return nil }
        let now = Date()
        if Self.shouldThrottleWiFiRecovery(
            lastAttemptAt: wifiAddressRecoveryAttemptedAt[record.id],
            now: now,
            cooldown: activeWiFiRecoveryCooldown,
            ignoreCooldown: ignoreCooldown
        ) {
            return nil
        }
        wifiAddressRecoveryAttemptedAt[record.id] = now

        // Without a MAC and without a specific name/serial there's nothing to
        // match against, so skip the scan entirely.
        let hasIdentity = record.wifiMACAddress != nil
            || record.resolvedUSBSerial?.isEmpty == false
            || PairedPhoneStore.isSpecificDeviceName(record.displayName)
        guard hasIdentity else { return nil }

        let adb = self.adb
        let target = WiFiAddressRecovery.Target(
            macAddress: record.wifiMACAddress,
            usbSerial: record.resolvedUSBSerial,
            displayName: record.displayName,
            lastKnownIP: record.resolvedWiFiAddress ?? record.lastAddress
        )
        Logger.log("Wi-Fi recovery: hunting for \(record.displayName) (mac=\(record.wifiMACAddress ?? "nil"))")

        let outcome = await WiFiAddressRecovery.recoverDetailed(
            adb: adb,
            target: target,
            prioritizeCurrentNetwork: prioritizeCurrentNetwork
        )
        // This recovery only runs when the record carries a matchable device
        // identity. A completed sweep with no identity match proves that this
        // phone has no usable :5555 listener, even when an unrelated phone or
        // development board happens to expose that port on the same LAN.
        if outcome.address == nil && outcome.didSweep {
            wirelessListenerMissingRecordIDs.insert(record.id)
        } else {
            wirelessListenerMissingRecordIDs.remove(record.id)
        }
        guard let recovered = outcome.address else { return nil }

        let readiness = await Self.connectToRememberedWirelessReadiness(
            adb: adb,
            savedAddress: recovered,
            allowLegacyCompatibility: true,
            readinessAttempts: 2,
            preflightLocalNetworkAccess: { address in
                await Self.preflightLocalNetworkAccess(address: address)
            }
        )
        return readiness.connectedAddress
    }

    func mirrorAuthorizedDevicePreferringWireless(_ device: AuthorizedADBDevice) async {
        guard !isMirroring, !isPairing else { return }
        guard !isAutoMirrorHeldForOnboarding else { return }
        if !device.isUSB,
           Self.isLegacyWirelessAddress(device.serial),
           !legacyWirelessCompatibilityEnabled {
            noteConnectionStall(
                .wirelessRouteMissing,
                detail: "A legacy port 5555 transport is available, but secure Wireless debugging is required unless compatibility is enabled in Settings."
            )
            return
        }
        // A transport already present in `adb devices` wins without another
        // connect. Cancel the automatic resolver before launching so it cannot
        // create or promote a competing route behind the mirror.
        connectionCoordinator.cancelAutomaticReconnect(clearRetryState: false)
        if device.isUSB {
            // Pinned to Wi-Fi ("move to Wi-Fi and stay"): don't fall back to the
            // still-connected cable while we're pursuing the Wi-Fi route.
            guard !isUSBSuppressedByWirelessPin(device.serial) else { return }
            guard let readyUSBDevice = await readyUSBDeviceForMirroring(device) else {
                Logger.log("Skipping USB auto-connect for \(device.serial): USB transport is not ready.")
                noteConnectionStall(
                    .usbNotReady,
                    detail: "\(device.serial) appeared in adb devices but never became shell-ready."
                )
                return
            }
            // A prior arm already proved that this Mac cannot reach the
            // phone's Wi-Fi endpoint. Do not spend another handoff budget or
            // restart adbd again while the breaker is active; preserve the
            // transport the user just plugged in.
            if connectionCoordinator.isLegacyHandoffCoolingDown(serial: readyUSBDevice.serial) {
                Logger.log("Wi-Fi handoff cooling down for \(readyUSBDevice.serial); starting stable USB mirror immediately")
                startMirroringOverUSB(
                    readyUSBDevice,
                    manual: false,
                    prepareWirelessHandoff: false
                )
                return
            }
            let shouldAttemptHandoff = Self.shouldAttemptWirelessHandoff(
                from: readyUSBDevice,
                preferUSBMirroring: preferUSBMirroring,
                backgroundWiFiHandoffEnabled: true,
                hasSavedDevices: !pairedPhones.isEmpty
            )
            guard shouldAttemptHandoff else {
                startMirroringOverUSB(
                    readyUSBDevice,
                    manual: false,
                    prepareWirelessHandoff: false
                )
                return
            }

            // The reliable topology configures and verifies Wi-Fi before any
            // mirror starts. `adb tcpip` restarts adbd, so running it underneath
            // a live USB mirror guarantees a transport loss instead of a handoff.
            let handoffGeneration = connectionCoordinator.beginUSBWiFiHandoff()
            isAutoConnecting = true
            let prepared = await prepareWirelessMirror(
                from: readyUSBDevice,
                activatePreparedMirror: true,
                handoffGeneration: handoffGeneration
            )
            guard connectionCoordinator.isCurrentUSBWiFiHandoff(handoffGeneration) else {
                return
            }
            let recoveryAddress = usbWiFiHandoffCandidate.flatMap { candidate in
                candidate.usbSerial == readyUSBDevice.serial ? candidate.address : nil
            }
            connectionCoordinator.finishUSBWiFiHandoff(handoffGeneration)
            isAutoConnecting = false
            if prepared { return }

            guard let restoredUSBDevice = await restoreUSBTransportAfterFailedHandoff(
                readyUSBDevice,
                wirelessAddress: recoveryAddress
            ) else {
                Logger.log("Wi-Fi handoff failed and USB transport \(readyUSBDevice.serial) could not be restored.")
                noteConnectionStall(
                    .usbNotReady,
                    detail: "Wi-Fi handoff did not become ready and the original USB transport did not return."
                )
                return
            }
            usbWiFiHandoffCandidate = nil
            startMirroringOverUSB(
                restoredUSBDevice,
                manual: false,
                prepareWirelessHandoff: false
            )
            return
        }

        guard !explicitDeviceSetupRequired else { return }
        let adb = self.adb
        guard await Self.isADBDeviceShellReady(
            adb: adb,
            serial: device.serial,
            timeout: Self.wirelessHandoffShellTimeout
        ),
              !Task.isCancelled,
              !isMirroring,
              !isPairing,
              latestAuthorizedADBDevices.contains(where: {
                !$0.isUSB && $0.serial == device.serial
              }) else {
            Logger.log("Skipping Wi-Fi auto-connect for \(device.serial): shell readiness was not proven.")
            return
        }
        select(device: device)
        touchPairedPhone(
            id: device.serial,
            displayName: selectedDisplayName(for: device.model),
            address: device.serial,
            wifiAddress: device.serial
        )
        stopQRCodePairingSession()
        // This exact adb transport already passed a shell sentinel above. Going
        // through startWirelessMirroring would rediscover and reconnect it, then
        // potentially promote it to :5555 before launching. Launch it directly.
        launchNativeMirror(serial: device.serial)
    }

    /// If a configure-first `adb tcpip` attempt did not produce a usable Wi-Fi
    /// route, switch adbd back to USB before launching the fallback mirror.
    /// The exact original serial is required throughout so one phone can never
    /// be substituted for another merely because it appeared first in a scan.
    func restoreUSBTransportAfterFailedHandoff(
        _ usbDevice: AuthorizedADBDevice,
        wirelessAddress: String?
    ) async -> AuthorizedADBDevice? {
        if let ready = await readyUSBDeviceForMirroring(usbDevice) {
            return ready
        }
        guard let wirelessAddress else { return nil }

        let adb = self.adb
        let readiness = await Self.connectToRememberedWirelessReadiness(
            adb: adb,
            savedAddress: wirelessAddress,
            candidateAddresses: [wirelessAddress],
            allowLegacyCompatibility: legacyWirelessCompatibilityEnabled,
            readinessAttempts: 2,
            preflightLocalNetworkAccess: { address in
                await Self.preflightLocalNetworkAccess(address: address)
            },
            maximumDuration: 5,
            connectTimeout: 2,
            shellTimeout: 1.5
        )
        guard let connectedAddress = readiness.connectedAddress else { return nil }
        Logger.log("Restoring USB transport for \(usbDevice.serial) through \(connectedAddress)")
        await Task.detached(priority: .userInitiated) {
            _ = adb.run(["-s", connectedAddress, "usb"], timeout: 3)
        }.value
        await adb.ensureServerStarted()
        return await waitForSpecificUSBDevice(
            usbDevice,
            attempts: 4,
            delayNanoseconds: 500_000_000
        )
    }

    func autoConnectToAvailableRememberedDevice(
        authorizedDevices: [AuthorizedADBDevice] = [],
        livePhones: [DiscoveredPhone]
    ) {
        guard !isMirroring, !isPairing else {
            return
        }
        guard connectionCoordinator.usbConnectTask == nil,
              connectionCoordinator.usbWiFiHandoffTask == nil,
              connectionCoordinator.usbWiFiTakeoverTask == nil,
              connectionCoordinator.wirelessStartTask == nil,
              connectionCoordinator.reconnectTask == nil,
              mirrorLaunchTask == nil else {
            return
        }
        guard !isAutoMirrorHeldForOnboarding else {
            return
        }

        let records = Self.recordsByMostRecent(autoConnectEligiblePairedPhones)
        let liveRememberedPhones = autoConnectablePhones(in: livePhones)
        let liveRememberedPhone = mostRecentPairedPhone(in: liveRememberedPhones)

        if Self.shouldDelayRememberedAutoConnect(
            lastAttemptAt: lastPresenceAutoConnectAttemptAt,
            now: Date(),
            throttle: Self.presenceAutoConnectThrottle,
            hasLiveRememberedPhone: !authorizedDevices.isEmpty || liveRememberedPhone != nil
        ) {
            return
        }

        if let device = Self.scrcpyStyleAutoConnectDevice(
            authorizedDevices: authorizedDevices,
            pairedPhones: records,
            preferUSBMirroring: preferUSBMirroring
        ) {
            lastPresenceAutoConnectAttemptAt = Date()
            Task { [weak self] in
                await self?.mirrorAuthorizedDevicePreferringWireless(device)
            }
            return
        }

        if let phone = liveRememberedPhone,
           !isAutoConnectAddressCoolingDown(phone.address) {
            lastPresenceAutoConnectAttemptAt = Date()
            isAutoConnecting = true
            stopQRCodePairingSession()
            Logger.log("Known Wi-Fi phone discovered via mDNS; verifying before auto-connect address=\(phone.address)")
            requestAutomaticReconnect(trigger: .watcher)
            return
        }

        if let record = Self.rememberedWirelessAutoConnectRecord(
            in: records,
            failedTargets: failedAutoConnectTargets,
            listenerMissingRecordIDs: connectionCoordinator.wirelessListenerMissingRecordIDs
        ) {
            lastPresenceAutoConnectAttemptAt = Date()
            isAutoConnecting = true
            stopQRCodePairingSession()
            Logger.log("Known Wi-Fi phone has saved route; verifying before auto-connect address=\(record.lastAddress)")
            requestAutomaticReconnect(trigger: .watcher)
        }
    }

    func touchPairedPhone(
        id: String,
        displayName: String,
        address: String,
        usbSerial: String? = nil,
        observedWiFiIPAddress: String? = nil,
        wifiAddress: String? = nil,
        wifiMACAddress: String? = nil
    ) {
        // Central persistence guard: an explicit Wi-Fi route may only be a
        // concrete host:port endpoint. A USB serial passed through a handoff
        // callback must update USB metadata without clobbering the remembered
        // wireless route.
        let guardedWiFiAddress = Self.persistableWirelessAddress(wifiAddress).flatMap { candidate in
            Self.isAllowedWirelessAddress(
                candidate,
                allowLegacyCompatibility: legacyWirelessCompatibilityEnabled
            ) ? candidate : nil
        }
        let existingAddress = pairedPhones.first { record in
            record.id == id
                || (usbSerial != nil && record.resolvedUSBSerial == usbSerial)
                || (guardedWiFiAddress != nil && record.resolvedWiFiAddress == guardedWiFiAddress)
        }?.lastAddress
        let guardedAddress: String
        if wifiAddress != nil, guardedWiFiAddress == nil {
            guard let fallback = usbSerial ?? existingAddress else {
                Logger.log("Refusing to persist invalid wireless route \(wifiAddress ?? address)")
                return
            }
            guardedAddress = fallback
        } else if Self.isWirelessADBTarget(address), guardedWiFiAddress == nil {
            guard let fallback = usbSerial ?? existingAddress else {
                Logger.log("Refusing to persist unverified wireless route \(address)")
                return
            }
            guardedAddress = fallback
        } else {
            guardedAddress = address
        }
        clearExplicitDeviceSetupRequirement()
        resumeAutoConnect(matchingID: id, address: guardedAddress)
        pairedPhones = store.touch(
            pairedPhones,
            id: id,
            displayName: displayName,
            address: guardedAddress,
            usbSerial: usbSerial,
            observedWiFiIPAddress: observedWiFiIPAddress,
            wifiAddress: guardedWiFiAddress,
            isVerifiedWirelessEndpoint: guardedWiFiAddress != nil,
            wifiAddressLastVerifiedAt: guardedWiFiAddress == nil ? nil : Date(),
            wifiNetworkFingerprint: guardedWiFiAddress == nil
                ? nil
                : WiFiAddressRecovery.currentNetworkFingerprint(),
            wifiMACAddress: wifiMACAddress
        )
        store.save(pairedPhones)
        if guardedWiFiAddress != nil {
            connectionCoordinator.preferCurrentNetworkForNextReconnect = false
        }
        connectionCoordinator.resetAutomaticRetry(recordID: id)
    }

    func setAutoConnectSuspendedForSelectedDevice(_ suspended: Bool) {
        guard selectedDevice.adbSerial != nil || selectedDevice.id != MirrorDevice.demo.id else { return }
        setAutoConnectSuspended(suspended) { [selectedDevice] record in
            Self.recordMatchesSelectedDevice(record, selectedDevice: selectedDevice)
        }
    }

    func resumeAutoConnect(for record: PairedPhoneRecord) {
        resumeAutoConnect(matchingID: record.id, address: record.lastAddress)
    }

    func setAutoConnectSuspended(
        _ suspended: Bool,
        where matches: (PairedPhoneRecord) -> Bool
    ) {
        let matchingIDs = pairedPhones.filter(matches).map(\.id)
        guard !matchingIDs.isEmpty else { return }
        if suspended {
            sessionAutoConnectSuspendedRecordIDs.formUnion(matchingIDs)
        } else {
            sessionAutoConnectSuspendedRecordIDs.subtract(matchingIDs)
        }
    }

    func resumeAutoConnect(matchingID id: String, address: String) {
        setAutoConnectSuspended(false) { candidate in
            [id, address].contains { value in
                candidate.id == value
                    || candidate.lastAddress == value
                    || candidate.resolvedUSBSerial == value
                    || candidate.resolvedWiFiAddress == value
                    || Self.recordMatchesSelectedADBSerial(candidate, selectedSerial: value)
            }
        }
    }

    #if DEBUG
    func isAutoConnectPausedForSession(record: PairedPhoneRecord) -> Bool {
        sessionAutoConnectSuspendedRecordIDs.contains(record.id)
    }

    /// Test seam: drive either automatic activation or explicit-USB
    /// prepare-only behavior without waiting for the background delay.
    func prepareWirelessHandoffForTesting(
        _ device: AuthorizedADBDevice,
        activatePreparedMirror: Bool = true,
        mirrorGeneration: Int? = nil
    ) async -> Bool {
        await prepareWirelessMirror(
            from: device,
            activatePreparedMirror: activatePreparedMirror,
            mirrorGeneration: mirrorGeneration
        )
    }

    var legacyHandoffFailedSerialsForTesting: Set<String> {
        Set(
            failedLegacyHandoffSerials
                .filter { connectionCoordinator.isLegacyHandoffCoolingDown(serial: $0.key) }
                .keys
        )
    }
    #endif

    nonisolated static func recordMatchesSelectedDevice(
        _ record: PairedPhoneRecord,
        selectedDevice: MirrorDevice
    ) -> Bool {
        if record.id == selectedDevice.id {
            return true
        }
        if let serial = selectedDevice.adbSerial,
           recordMatchesSelectedADBSerial(record, selectedSerial: serial) {
            return true
        }
        return PairedPhoneStore.normalizedDeviceName(record.displayName)
            == PairedPhoneStore.normalizedDeviceName(selectedDevice.name)
    }

    func selectedDisplayName(for fallback: String) -> String {
        Self.specificDeviceName(fallback) ?? Self.specificDeviceName(selectedDevice.name) ?? fallback
    }

    func displayName(for phone: DiscoveredPhone) -> String {
        pairedPhones.first(where: { $0.id == phone.id })
            .flatMap { Self.specificDeviceName($0.displayName) } ?? "Android device"
    }

    // MARK: - Scan / pair flows

    func scanADBDevices() {
        resumeDiscoveryAfterManualConnect()
        isScanning = true
        let adb = self.adb
        Task { [weak self] in
            let output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
            guard let self else { return }
            self.isScanning = false
            self.recordADBHealth(output)
            self.applyADBOutput(output)
        }
    }

    func refreshDevicePresenceAfterManualDisconnect() {
        let adb = self.adb
        Task { [weak self] in
            let output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
            guard let self else { return }
            self.applyDevicePresence(output)
        }
    }

    /// Single `adb devices -l` poll that drives both device-presence tracking
    /// and USB→wireless handoff. Previously these were two independent 1.5s
    /// loops, each spawning its own `adb` process; merging them halves the idle
    /// process churn, and the adaptive interval eases off further when there's
    /// nothing to do — meaningfully lower idle CPU/battery.
    func startDeviceWatcher() {
        guard backgroundServicesEnabled else { return }
        guard connectionCoordinator.deviceWatcherTask == nil else { return }
        let adb = self.adb
        connectionCoordinator.deviceWatcherTask = Task { [weak self] in
            // A cold daemon outlives `adbDeviceListTimeout`, so the first poll
            // after launch was reliably killed mid-`start-server` and reported
            // no devices. Warm it once (shared single-flight with connection
            // workflows) before the loop instead of burning polls on a race.
            await adb.primeServerIfNeeded()
            while !Task.isCancelled {
                let output = await Task.detached {
                    adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
                }.value
                guard let self else { return }
                let authorized = Self.devicesAvailableForCurrentPath(
                    Self.authorizedADBDevices(in: output),
                    isPathLossConfirmed: self.isNetworkPathLossConfirmed
                )
                self.recordADBHealth(output, authorizedDevices: authorized)
                self.updateUSBAuthorizationHint(from: output, authorizedDevices: authorized)
                self.applyDevicePresence(output)
                self.probeSavedWiFiStatusIfNeeded(authorized: authorized)

                if self.isAutoReconnectSuppressedForManualDisconnect {
                    self.isAutoConnecting = false
                    await self.handleManualDisconnectPause(authorized: authorized)
                    let interval = Self.deviceWatcherPollInterval(
                        isPairing: self.isPairing,
                        isMirroring: self.isMirroring,
                        hasAuthorizedDevices: !authorized.isEmpty,
                        hasSavedDevices: !self.pairedPhones.isEmpty,
                        isActivelyConnecting: self.isActivelyConnecting
                    )
                    await self.deviceWatcherSleep(nanoseconds: interval)
                    continue
                }

                // A cable we've pinned to Wi-Fi must not interrupt its own Wi-Fi
                // reconnect — that was the USB↔Wi-Fi ping-pong. Only a non-pinned
                // USB device counts as a genuine interruption. This must run
                // before the cable arm below so a cancelled reconnect is already
                // torn down when the arm checks for idle adb ownership.
                let usbCanInterruptReconnect = authorized.contains { device in
                    device.isUSB && !self.isUSBSuppressedByWirelessPin(device.serial)
                }
                if usbCanInterruptReconnect, Self.shouldUSBInterruptReconnect(
                    authorizedDevices: authorized,
                    isRecoveringConnection: self.isRecoveringConnection,
                    isAwaitingReconnect: self.isAwaitingReconnect,
                    hasReconnectTask: self.connectionCoordinator.reconnectTask != nil,
                    hasWirelessStartTask: self.connectionCoordinator.wirelessStartTask != nil
                        || self.connectionCoordinator.discoveredWiFiConnectTask != nil,
                    hasUSBWiFiTakeoverTask: self.connectionCoordinator.usbWiFiTakeoverTask != nil,
                    disallowUSBFallback: self.transportIntent.requiresWiFi
                ) {
                    Logger.log("USB device interrupted wireless reconnect; cancelling stale reconnect work")
                    self.cancelWirelessReconnectWork()
                    self.isPairing = false
                }

                // Before any auto-connect policy runs: a cable that just
                // appeared is the only chance to re-arm `tcpip 5555`, and that
                // must not depend on whether this phone is going to be mirrored.
                self.armWirelessDebuggingForAttachedUSB(authorized: authorized)

                // The instant a *new* device shows up, drop the presence throttle
                // so the auto-connect below fires this very poll instead of after
                // the next 3s window — no waiting for a freshly-plugged phone.
                let currentSerials = Set(authorized.map(\.serial))
                if !currentSerials.isSubset(of: self.previousAuthorizedSerials) {
                    self.lastPresenceAutoConnectAttemptAt = nil
                }
                self.previousAuthorizedSerials = currentSerials

                let shouldPrioritizeUSBHandoff = Self.shouldPrioritizeUSBHandoff(
                    authorizedDevices: authorized,
                    lastAttemptedSerial: self.lastUSBHandoffSerial,
                    preferUSBMirroring: self.preferUSBMirroring,
                    isMirroring: self.isMirroring,
                    isPairing: self.isPairing,
                    failingWirelessSerials: self.failingWirelessAuthorizedSerials(authorized)
                )

                if Self.shouldRecoverMissingMirrorTransport(
                    isMirroring: self.isMirroring,
                    selectedSerial: self.selectedDevice.adbSerial,
                    pairedPhones: self.pairedPhones,
                    authorizedDevices: authorized
                ) {
                    // Debounce: `adb devices -l` can momentarily drop a healthy
                    // wireless device on a single poll. A genuine transport loss
                    // also kills the scrcpy stream, which the faster keepalive/
                    // stall detector tears down on its own — so only this backup
                    // detector needs the grace, and requiring consecutive misses
                    // stops a one-poll blip from killing a live mirror (a cause of
                    // connect-then-drop loops).
                    self.missingMirrorTransportPollMisses += 1
                    if self.missingMirrorTransportPollMisses >= Self.missingMirrorTransportPollGrace {
                        self.missingMirrorTransportPollMisses = 0
                        self.recoverMissingMirrorTransport()
                    }
                } else {
                    self.missingMirrorTransportPollMisses = 0
                }

                // USB → Wi-Fi handoff: the moment an authorized USB phone shows
                // up while idle, start the USB mirror immediately. If Wi-Fi is
                // stable enough, prepare the wireless route in the background so
                // a later reconnect can use it without making USB wait. Never
                // fires mid-session, and never twice for the same plug-in.
                if shouldPrioritizeUSBHandoff
                    && !self.connectionCoordinator.hasManualConnectionWorkInFlight
                    && self.connectionCoordinator.usbWiFiTakeoverTask == nil
                    && (self.pairedPhones.isEmpty || !self.autoConnectEligiblePairedPhones.isEmpty)
                    && Self.shouldAutoStartAuthorizedUSB(
                        hasSavedDevices: !self.autoConnectEligiblePairedPhones.isEmpty,
                        explicitDeviceSetupRequired: self.explicitDeviceSetupRequired
                    ) {
                    if let usbDevice = Self.usbHandoffCandidate(
                        in: output,
                        lastAttemptedSerial: self.lastUSBHandoffSerial
                    ), !self.isUSBSuppressedByWirelessPin(usbDevice.serial) {
                        self.lastUSBHandoffSerial = usbDevice.serial
                        await self.mirrorAuthorizedDevicePreferringWireless(usbDevice)
                        self.refreshAutoConnectingState(authorized: authorized)
                        let interval = Self.deviceWatcherPollInterval(
                            isPairing: self.isPairing,
                            isMirroring: self.isMirroring,
                            hasAuthorizedDevices: !authorized.isEmpty,
                            hasSavedDevices: !self.pairedPhones.isEmpty,
                            isActivelyConnecting: self.isActivelyConnecting
                        )
                        await self.deviceWatcherSleep(nanoseconds: interval)
                        continue
                    } else if authorized.first(where: \.isUSB) == nil {
                        self.lastUSBHandoffSerial = nil
                    }
                }

                if Self.shouldAutoStartOnlineSelectedDevice(
                    isOnline: self.isSelectedDeviceOnline,
                    isMirroring: self.isMirroring,
                    isPairing: self.isPairing,
                    explicitDeviceSetupRequired: self.explicitDeviceSetupRequired,
                    hasMirrorLaunchTask: self.mirrorLaunchTask != nil,
                    hasWirelessStartTask: self.connectionCoordinator.wirelessStartTask != nil
                        || self.connectionCoordinator.discoveredWiFiConnectTask != nil,
                    hasReconnectTask: self.connectionCoordinator.reconnectTask != nil,
                    hasUSBConnectTask: self.connectionCoordinator.usbConnectTask != nil,
                    isAwaitingReconnect: self.isAwaitingReconnect,
                    selectedSerial: self.selectedDevice.adbSerial
                ), !self.connectionCoordinator.isPreparingWiFiHandoff,
                   let serial = self.selectedDevice.adbSerial,
                   let liveDevice = Self.liveSelectedOrRememberedDevice(
                    selectedSerial: serial,
                    pairedPhones: self.autoConnectEligiblePairedPhones,
                    authorizedDevices: authorized
                   ),
                   // A cable pinned to Wi-Fi must not auto-start a USB mirror.
                   !(liveDevice.isUSB && self.isUSBSuppressedByWirelessPin(liveDevice.serial)) {
                    Logger.log("Online device is idle; auto-starting mirror serial=\(liveDevice.serial)")
                    self.lastPresenceAutoConnectAttemptAt = Date()
                    if liveDevice.isUSB {
                        self.lastUSBHandoffSerial = liveDevice.serial
                    }
                    await self.mirrorAuthorizedDevicePreferringWireless(liveDevice)
                    self.refreshAutoConnectingState(authorized: authorized)
                    let interval = Self.deviceWatcherPollInterval(
                        isPairing: self.isPairing,
                        isMirroring: self.isMirroring,
                        hasAuthorizedDevices: !authorized.isEmpty,
                        hasSavedDevices: !self.pairedPhones.isEmpty,
                        isActivelyConnecting: self.isActivelyConnecting
                    )
                    await self.deviceWatcherSleep(nanoseconds: interval)
                    continue
                }

                if !shouldPrioritizeUSBHandoff && Self.shouldRunPresenceAutoConnect(
                    authorizedDevices: authorized,
                    lastAttemptedSerial: self.lastUSBHandoffSerial,
                    preferUSBMirroring: self.preferUSBMirroring,
                    isMirroring: self.isMirroring,
                    isPairing: self.isPairing
                ) {
                    self.autoConnectToAvailableRememberedDevice(
                        authorizedDevices: authorized,
                        livePhones: self.discoveredPhones
                    )
                }
                self.refreshAutoConnectingState(authorized: authorized)

                let interval = Self.deviceWatcherPollInterval(
                    isPairing: self.isPairing,
                    isMirroring: self.isMirroring,
                    hasAuthorizedDevices: !authorized.isEmpty,
                    hasSavedDevices: !self.pairedPhones.isEmpty,
                    isActivelyConnecting: self.isActivelyConnecting
                )
                await self.deviceWatcherSleep(nanoseconds: interval)
            }
        }
    }

    // MARK: - Event-driven reconnect (Mac wake / network-path restore)

    /// Debounce for system-event reconnect nudges — wake and path-change
    /// callbacks arrive in bursts of several within a couple of seconds.
    nonisolated static let systemEventReconnectDebounce: TimeInterval = 3

    /// Whether a wake/path event should trigger an immediate auto-connect
    /// attempt. A live mirror needs no nudge, a manual Disconnect stays sticky
    /// (system events are not the cable re-plug / phone Wi-Fi re-toggle that
    /// ends the pause), and with no saved wireless route there is nothing to
    /// dial.
    nonisolated static func shouldNudgeReconnectForSystemEvent(
        lastNudgeAt: Date?,
        now: Date,
        debounce: TimeInterval = systemEventReconnectDebounce,
        isMirroring: Bool,
        isSuppressedForManualDisconnect: Bool,
        hasSavedWirelessRoute: Bool
    ) -> Bool {
        guard hasSavedWirelessRoute, !isMirroring, !isSuppressedForManualDisconnect else {
            return false
        }
        guard let lastNudgeAt else { return true }
        return now.timeIntervalSince(lastNudgeAt) >= debounce
    }

    /// Only a transition *to* a usable network is reconnect-worthy. The path
    /// monitor fires once with the current state right after `start()`
    /// (previous == nil) — that must not dial on launch, where
    /// `attemptAutoReconnect` already runs.
    nonisolated static func isReconnectWorthyPathTransition(
        previousSatisfied: Bool?,
        nowSatisfied: Bool
    ) -> Bool {
        nowSatisfied && previousSatisfied == false
    }

    /// Small enough to update the connection surface promptly, but long enough
    /// to ignore the brief `.unsatisfied` pulses NWPathMonitor can emit during a
    /// Wi-Fi handover.
    nonisolated static let networkPathLossConfirmationNanoseconds: UInt64 = 750_000_000

    nonisolated static func isWirelessTransport(serial: String?, network: String) -> Bool {
        if let serial, !serial.isEmpty, isWirelessADBTarget(serial) {
            return true
        }
        return network.localizedCaseInsensitiveContains("wi-fi")
            || network.localizedCaseInsensitiveContains("wifi")
            || network.localizedCaseInsensitiveContains("wireless")
    }

    /// A network-path loss is only authoritative for a live wireless selection.
    /// USB must remain online even when the Mac has no network route.
    nonisolated static func shouldInvalidateConnectionForConfirmedPathLoss(
        isPathLossConfirmed: Bool,
        isSelectedDeviceOnline: Bool,
        isMirroring: Bool,
        selectedSerial: String?,
        selectedNetwork: String
    ) -> Bool {
        guard isPathLossConfirmed, isSelectedDeviceOnline || isMirroring else { return false }
        return isWirelessTransport(serial: selectedSerial, network: selectedNetwork)
    }

    /// adb can retain a wireless serial as `device` briefly after the Mac loses
    /// its route. Once path loss is confirmed, USB remains trustworthy but those
    /// wireless rows must not drive the UI back to Online.
    nonisolated static func devicesAvailableForCurrentPath(
        _ devices: [AuthorizedADBDevice],
        isPathLossConfirmed: Bool
    ) -> [AuthorizedADBDevice] {
        guard isPathLossConfirmed else { return devices }
        return devices.filter(\.isUSB)
    }

    /// Wires the Mac-side events that predict "the phone is reachable again" —
    /// wake from sleep and the network path coming back up — to an immediate
    /// auto-connect attempt. Without these, a lid-open reconnect waits for the
    /// next watcher poll *plus* whatever failure cooldowns accrued while the
    /// network was down; with them it starts the moment the route exists.
    /// Same flows, same guards as the poll path — only the trigger is new.
    func startSystemEventReconnectTriggers() {
        guard backgroundServicesEnabled, networkPathMonitor == nil else { return }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.lastNetworkPathWasSatisfied
                self.lastNetworkPathWasSatisfied = satisfied
                if !satisfied {
                    self.scheduleNetworkPathLossConfirmation()
                    return
                }

                self.networkPathLossConfirmationTask?.cancel()
                self.networkPathLossConfirmationTask = nil
                self.isNetworkPathLossConfirmed = false
                guard Self.isReconnectWorthyPathTransition(
                    previousSatisfied: previous,
                    nowSatisfied: satisfied
                ) else { return }
                self.connectionCoordinator.preferCurrentNetworkForNextReconnect = true
                self.nudgeAutoReconnectAfterSystemEvent(reason: "network path restored")
            }
        }
        monitor.start(queue: DispatchQueue(label: "PhoneRelay.network-path-monitor"))
        networkPathMonitor = monitor

        // A plugged cable is the strongest "scan now" signal there is: wake
        // the watcher instead of letting the plug-in wait out the remaining
        // poll interval. Event-driven, so idle cost stays zero.
        let attachMonitor = USBAttachMonitor { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleUSBDeviceAttached()
            }
        }
        attachMonitor.start()
        usbAttachMonitor = attachMonitor

        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.nudgeAutoReconnectAfterSystemEvent(reason: "mac woke from sleep")
            }
        }
    }

    func stopSystemEventReconnectTriggers() {
        networkPathMonitor?.cancel()
        networkPathMonitor = nil
        networkPathLossConfirmationTask?.cancel()
        networkPathLossConfirmationTask = nil
        isNetworkPathLossConfirmed = false
        usbAttachMonitor?.stop()
        usbAttachMonitor = nil
        if let didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeObserver)
            self.didWakeObserver = nil
        }
    }

    func scheduleNetworkPathLossConfirmation() {
        networkPathLossConfirmationTask?.cancel()
        networkPathLossConfirmationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.networkPathLossConfirmationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.lastNetworkPathWasSatisfied == false
            else { return }

            self.networkPathLossConfirmationTask = nil
            self.confirmNetworkPathLoss()
        }
    }

    func confirmNetworkPathLoss() {
        guard !isNetworkPathLossConfirmed else { return }
        isNetworkPathLossConfirmed = true
        connectionCoordinator.preferCurrentNetworkForNextReconnect = true

        let invalidatesSelectedConnection = Self.shouldInvalidateConnectionForConfirmedPathLoss(
            isPathLossConfirmed: true,
            isSelectedDeviceOnline: isSelectedDeviceOnline,
            isMirroring: isMirroring,
            selectedSerial: selectedDevice.adbSerial,
            selectedNetwork: selectedDevice.network
        )

        // Bonjour results and wireless adb rows describe the previous route.
        // Clear the discovery-backed Online pill immediately and wake the normal
        // watcher so it can refresh USB/presence state without a tighter poll.
        discoveredPhones = []
        latestAuthorizedADBDevices = Self.devicesAvailableForCurrentPath(
            latestAuthorizedADBDevices,
            isPathLossConfirmed: true
        )
        wakeDeviceWatcher()

        guard invalidatesSelectedConnection else { return }
        Logger.log("Network path unavailable; marking selected Wi-Fi device offline")
        isSelectedDeviceOnline = false
        missingMirrorTransportPollMisses = 0

        if isMirroring || mirrorSession != nil || mirrorLaunchTask != nil {
            recoverMissingMirrorTransport()
        } else {
            refreshAutoConnectingState(authorized: latestAuthorizedADBDevices)
        }
    }

    // MARK: - adb daemon recovery (INVARIANTS.md rules 1, 8, 9)

    /// Minimum gap between *automatic* daemon respawns. A user's explicit
    /// Fix Connection press bypasses it (one action, not a storm).
    nonisolated static let adbDaemonRecoveryCooldown: TimeInterval = 600

    /// Pure gate for the stale-daemon remedy: never while any mirror work or
    /// pairing is live (a server restart drops every adb transport), never
    /// re-entrantly, and automatically only outside the cooldown.
    nonisolated static func shouldAttemptADBDaemonRecovery(
        isMirroring: Bool,
        hasMirrorSession: Bool,
        hasMirrorLaunchTask: Bool,
        isPairing: Bool,
        inFlight: Bool,
        lastAttemptAt: Date?,
        now: Date = Date(),
        cooldown: TimeInterval = adbDaemonRecoveryCooldown,
        force: Bool = false
    ) -> Bool {
        guard !isMirroring, !hasMirrorSession, !hasMirrorLaunchTask, !isPairing, !inFlight else {
            return false
        }
        if force { return true }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= cooldown
    }

    /// The stale-daemon remedy as a guarded in-app action: restart the
    /// app-owned adb server so its Local Network attribution is the app's own
    /// (a daemon spawned by a shell inherits that shell's — possibly denied —
    /// identity and silently breaks every Wi-Fi connect). Only ever touches
    /// the daemon the app itself talks to, never mid-mirror, cooldown-limited,
    /// and every step is logged.
    func recoverADBDaemonIfSafe(force: Bool = false, reason: String) {
        guard Self.shouldAttemptADBDaemonRecovery(
            isMirroring: isMirroring,
            hasMirrorSession: mirrorSession != nil,
            hasMirrorLaunchTask: mirrorLaunchTask != nil,
            isPairing: isPairing,
            inFlight: adbDaemonRecoveryInFlight,
            lastAttemptAt: lastADBDaemonRecoveryAt,
            force: force
        ) else {
            Logger.log("adb daemon recovery skipped (\(reason)): mirror/pairing active, already running, or cooling down")
            return
        }
        let generation = connectionCoordinator.beginADBDaemonRecovery()
        let adb = self.adb
        connectionCoordinator.adbDaemonRecoveryTask = Task { [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.connectionCoordinator.isCurrentADBDaemonRecovery(generation)
            else { return }
            guard !self.isMirroring,
                  self.mirrorSession == nil,
                  self.mirrorLaunchTask == nil,
                  !self.isPairing
            else {
                Logger.log("adb daemon recovery cancelled (\(reason)): mirror or pairing became active")
                self.connectionCoordinator.finishADBDaemonRecovery(generation)
                return
            }
            self.lastADBDaemonRecoveryAt = Date()
            Logger.log("adb daemon recovery (\(reason)): step 1/3 restarting app-owned adb server")
            _ = await Task.detached(priority: .userInitiated) {
                adb.run(["kill-server"], timeout: 3)
            }.value
            guard !Task.isCancelled,
                  self.connectionCoordinator.isCurrentADBDaemonRecovery(generation)
            else { return }
            await adb.ensureServerStarted()
            Logger.log("adb daemon recovery (\(reason)): step 2/3 server restarted; rescanning devices")
            let output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
            guard !Task.isCancelled,
                  self.connectionCoordinator.isCurrentADBDaemonRecovery(generation)
            else { return }
            self.connectionCoordinator.finishADBDaemonRecovery(generation)
            self.applyDevicePresence(output)
            // Past failures were evidence about the old daemon — forget them
            // and let the watcher act immediately.
            self.failedAutoConnectTargets.removeAll()
            self.lastPresenceAutoConnectAttemptAt = nil
            self.wakeDeviceWatcher()
            Logger.log("adb daemon recovery (\(reason)): step 3/3 done; devices=\(Self.authorizedADBDevices(in: output).count)")
        }
    }

    /// User-initiated remedy ladder behind the Fix Connection button. Safe by
    /// construction: with a live mirror it only refreshes presence and clears
    /// throttles (never restarts the daemon out from under the stream);
    /// otherwise it forces the daemon respawn + rescan.
    func fixConnection() {
        Logger.log("Fix Connection requested by user")
        hasShownLocalNetworkPermissionHint = false
        failedAutoConnectTargets.removeAll()
        wifiAddressRecoveryAttemptedAt.removeAll()
        lastPresenceAutoConnectAttemptAt = nil
        lastSavedWiFiStatusProbeAt = nil
        if isMirroring || mirrorSession != nil || mirrorLaunchTask != nil {
            Logger.log("Fix Connection: mirror active — refreshing presence only (daemon restart skipped by rule 1)")
            scanADBDevices()
            wakeDeviceWatcher()
            return
        }
        recoverADBDaemonIfSafe(force: true, reason: "fix-connection button")
    }

    // MARK: - USB attach → immediate scan

    /// Attach events arrive in bursts (one phone enumerates several USB
    /// interfaces); one immediate scan per plug-in is enough.
    nonisolated static let usbAttachNudgeDebounce: TimeInterval = 1

    nonisolated static func shouldNudgeForUSBAttach(
        lastNudgeAt: Date?,
        now: Date = Date(),
        debounce: TimeInterval = usbAttachNudgeDebounce
    ) -> Bool {
        guard let lastNudgeAt else { return true }
        return now.timeIntervalSince(lastNudgeAt) >= debounce
    }

    func handleUSBDeviceAttached() {
        guard Self.shouldNudgeForUSBAttach(lastNudgeAt: lastUSBAttachNudgeAt) else { return }
        lastUSBAttachNudgeAt = Date()
        Logger.log("USB device attached; scanning now instead of waiting out the poll interval")
        // Fresh physical evidence — let the presence auto-connect act on the
        // very next poll instead of the 3s throttle window.
        lastPresenceAutoConnectAttemptAt = nil
        wakeDeviceWatcher()
    }

    /// Device-watcher sleep that external events can cut short. All watcher
    /// decisions (manual-disconnect stickiness, pins, cooldowns) stay in the
    /// loop itself — waking early only changes *when* the next poll runs.
    func deviceWatcherSleep(nanoseconds: UInt64) async {
        deviceWatcherSleepGeneration += 1
        let generation = deviceWatcherSleepGeneration
        await withCheckedContinuation { continuation in
            deviceWatcherWakeContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard let self, self.deviceWatcherSleepGeneration == generation else { return }
                self.wakeDeviceWatcher()
            }
        }
    }

    func wakeDeviceWatcher() {
        deviceWatcherWakeContinuation?.resume()
        deviceWatcherWakeContinuation = nil
    }

    func nudgeAutoReconnectAfterSystemEvent(reason: String) {
        guard Self.shouldNudgeReconnectForSystemEvent(
            lastNudgeAt: lastSystemEventReconnectNudgeAt,
            now: Date(),
            isMirroring: isMirroring,
            isSuppressedForManualDisconnect: isAutoReconnectSuppressedForManualDisconnect,
            hasSavedWirelessRoute: autoConnectEligiblePairedPhones.contains(where: Self.isWirelessRecord)
        ) else { return }
        lastSystemEventReconnectNudgeAt = Date()
        Logger.log("System event (\(reason)); nudging the single-flight reconnect coordinator")
        // The event predicts a route change, so past failures are stale
        // evidence — forget them and let the normal presence auto-connect
        // (with all its onboarding / in-flight / pin guards) act this instant.
        failedAutoConnectTargets.removeAll()
        wifiAddressRecoveryAttemptedAt.removeAll()
        lastPresenceAutoConnectAttemptAt = nil
        let eventID = UInt64(Date().timeIntervalSince1970 * 1_000)
        let trigger: ConnectionCoordinator.AutomaticReconnectTrigger =
            reason.localizedCaseInsensitiveContains("network")
                ? .networkRestored(eventID: eventID)
                : .systemWake(eventID: eventID)
        requestAutomaticReconnect(trigger: trigger)
    }

    /// Keeps `isAutoConnecting` in step with whether a connect target is actually
    /// present, so the status indicator reads "Connecting" the moment a saved
    /// phone shows up (USB or wireless) and clears once we're online or it's gone.
    /// Self-clearing by construction, so a stuck flag can never pin the spinner.
    func refreshAutoConnectingState(authorized: [AuthorizedADBDevice]) {
        if isMirroring || isSelectedDeviceOnline {
            launchReconnectDeadline = nil
        }
        let hasActiveReconnectWork = !autoConnectTargetsInFlight.isEmpty
            || connectionCoordinator.hasActiveConnectionAttempt
            || mirrorLaunchTask != nil
        isAutoConnecting = Self.shouldShowAutoConnecting(
            hasSavedDevice: !autoConnectEligiblePairedPhones.isEmpty,
            isOnline: isSelectedDeviceOnline,
            isMirroring: isMirroring,
            hasActiveReconnectWork: hasActiveReconnectWork
        )
    }

    /// Pure decision for the unified "Connecting" indicator: we're auto-connecting
    /// when a saved phone is physically present but not yet online or mirroring.
    nonisolated static func shouldShowAutoConnecting(
        hasSavedDevice: Bool,
        isOnline: Bool,
        isMirroring: Bool,
        hasActiveReconnectWork: Bool
    ) -> Bool {
        guard hasSavedDevice, !isMirroring else { return false }
        return hasActiveReconnectWork
    }

    nonisolated static func shouldRecoverMissingMirrorTransport(
        isMirroring: Bool,
        selectedSerial: String?,
        pairedPhones: [PairedPhoneRecord],
        authorizedDevices: [AuthorizedADBDevice]
    ) -> Bool {
        guard isMirroring, let selectedSerial else { return false }
        return liveSelectedOrRememberedDevice(
            selectedSerial: selectedSerial,
            pairedPhones: pairedPhones,
            authorizedDevices: authorizedDevices
        ) == nil
    }

    nonisolated static func shouldAutoStartOnlineSelectedDevice(
        isOnline: Bool,
        isMirroring: Bool,
        isPairing: Bool,
        explicitDeviceSetupRequired: Bool,
        hasMirrorLaunchTask: Bool,
        hasWirelessStartTask: Bool,
        hasReconnectTask: Bool,
        hasUSBConnectTask: Bool,
        isAwaitingReconnect: Bool,
        selectedSerial: String?
    ) -> Bool {
        guard isOnline,
              !isMirroring,
              !isPairing,
              !explicitDeviceSetupRequired,
              !hasMirrorLaunchTask,
              !hasWirelessStartTask,
              !hasReconnectTask,
              !hasUSBConnectTask,
              !isAwaitingReconnect,
              selectedSerial?.isEmpty == false
        else { return false }
        return true
    }

    nonisolated static func shouldShowReconnectSurface(
        isRecoveringConnection: Bool,
        isAwaitingReconnect: Bool
    ) -> Bool {
        isRecoveringConnection || isAwaitingReconnect
    }

    enum ConnectionLoadingTransport {
        case usb
        case wifi
    }

    nonisolated static func connectionLoadingStatusText(
        hasCompletedSuccessfulMirrorConnection: Bool,
        isRecoveringConnection: Bool,
        isAwaitingReconnect: Bool,
        isLaunchReconnect: Bool,
        transport: ConnectionLoadingTransport?
    ) -> String {
        if isLaunchReconnect {
            return "Connecting..."
        }
        // Transport currently does not affect the copy; kept in the signature so
        // call sites stay symmetric if transport-specific wording is added later.
        if hasCompletedSuccessfulMirrorConnection
            && (isRecoveringConnection || isAwaitingReconnect) {
            return "Reconnecting to"
        }
        return "Connecting to"
    }

    nonisolated static func shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
        isRecoveringConnection: Bool,
        isAwaitingReconnect: Bool
    ) -> Bool {
        // The mirror owns the loading state once launch begins. Keeping the
        // connection card visible creates two identical "Connecting" windows
        // (and multiplies them further if retries overlap).
        false
    }

    nonisolated static func deviceWatcherPollInterval(
        isPairing: Bool,
        isMirroring: Bool,
        hasAuthorizedDevices: Bool,
        hasSavedDevices: Bool,
        isActivelyConnecting: Bool
    ) -> UInt64 {
        if isActivelyConnecting && !isMirroring {
            return 500_000_000
        }
        if isPairing {
            return 750_000_000
        }
        if isMirroring {
            return 2_000_000_000
        }
        if !hasAuthorizedDevices {
            return hasSavedDevices ? 500_000_000 : 2_000_000_000
        }
        if !isMirroring {
            return 250_000_000
        }
        return 1_000_000_000
    }

    /// Keep failed background reconnects quiet briefly so stale Bonjour/adb
    /// entries do not pin the UI in "Connecting" forever.
    // Stage 1 keeps this legacy route-key cooldown intact while the coordinator
    // wraps every trigger. Stage 2 removes it in a separately verifiable change.
    nonisolated static let autoConnectFailureCooldown: TimeInterval = 20

    /// Minimum gap between whole-subnet Wi-Fi address recovery sweeps for the
    /// same phone, so a phone that's simply away can't trigger a scan storm.
    nonisolated static let wifiAddressRecoveryCooldown: TimeInterval = 60
    /// Shorter gap used while the user is actively watching the connect screen
    /// (app frontmost + connection window up). They're waiting on the result, so
    /// re-sweep sooner; the moment they tab away or it backgrounds, the storm-safe
    /// idle cadence above takes over again. (The 20s `autoConnectFailureCooldown`
    /// on the saved address still paces re-entry, so this won't sweep faster than
    /// that even at 15s.)
    nonisolated static let wifiAddressRecoveryForegroundCooldown: TimeInterval = 15
    /// How often the per-cable Wi-Fi address prefill re-reads `ip route` while
    /// the same phone stays plugged in. Once per plug-in used to be the rule,
    /// but a mid-session DHCP change then left the stored Wi-Fi route stale
    /// until the next replug, costing a whole-subnet recovery sweep on the next
    /// reconnect. A periodic re-read keeps the saved route current for the
    /// price of one `ip route` over USB.
    nonisolated static let usbWiFiAddressPrefillRefreshInterval: TimeInterval = 180
    nonisolated static let presenceAutoConnectThrottle: TimeInterval = 3
    nonisolated static let savedWiFiStatusProbeInterval: TimeInterval = 2

    nonisolated static func isAutoConnectFailureCoolingDown(
        failedAt: Date,
        now: Date = Date(),
        cooldown: TimeInterval = autoConnectFailureCooldown
    ) -> Bool {
        now.timeIntervalSince(failedAt) < cooldown
    }

    /// Whether a per-phone Wi-Fi address recovery sweep should be skipped because
    /// the previous sweep for this phone was too recent. The cooldown stops a
    /// phone that is merely away from triggering a whole-subnet scan on every
    /// presence poll. A deliberate, user-initiated reconnect passes
    /// `ignoreCooldown` so a single button press is never throttled — that's one
    /// action, not a poll storm.
    nonisolated static func shouldThrottleWiFiRecovery(
        lastAttemptAt: Date?,
        now: Date = Date(),
        cooldown: TimeInterval = wifiAddressRecoveryCooldown,
        ignoreCooldown: Bool = false
    ) -> Bool {
        guard !ignoreCooldown, let lastAttemptAt else { return false }
        return now.timeIntervalSince(lastAttemptAt) < cooldown
    }

    /// Whether the USB Wi-Fi address prefill should run: a newly plugged serial
    /// always qualifies; the same cable re-qualifies once the refresh interval
    /// elapses so a mid-session DHCP change is picked up without a replug.
    nonisolated static func shouldRefreshUSBWiFiAddressPrefill(
        lastSerial: String?,
        currentSerial: String,
        lastPrefillAt: Date?,
        now: Date = Date(),
        refreshInterval: TimeInterval = usbWiFiAddressPrefillRefreshInterval
    ) -> Bool {
        guard lastSerial == currentSerial, let lastPrefillAt else { return true }
        return now.timeIntervalSince(lastPrefillAt) >= refreshInterval
    }

    nonisolated static func shouldDelayRememberedAutoConnect(
        lastAttemptAt: Date?,
        now: Date = Date(),
        throttle: TimeInterval = presenceAutoConnectThrottle,
        hasLiveRememberedPhone: Bool
    ) -> Bool {
        guard !hasLiveRememberedPhone, let lastAttemptAt else { return false }
        return now.timeIntervalSince(lastAttemptAt) < throttle
    }

    nonisolated static func shouldProbeSavedWiFiStatus(
        hasSavedWiFiRoute: Bool,
        hasLiveWirelessDevice: Bool,
        isPairing: Bool,
        isMirroring: Bool,
        hasWirelessWorkInFlight: Bool,
        isListenerMissing: Bool = false,
        lastProbeAt: Date?,
        now: Date = Date(),
        interval: TimeInterval = savedWiFiStatusProbeInterval
    ) -> Bool {
        guard hasSavedWiFiRoute,
              !hasLiveWirelessDevice,
              !isPairing,
              !isMirroring,
              !hasWirelessWorkInFlight,
              // The sweep already proved this route's listener gone. Probing
              // is just another doomed `adb connect` every interval; the cable
              // arm that clears the verdict re-enables the probe with it.
              !isListenerMissing else {
            return false
        }
        guard let lastProbeAt else { return true }
        return now.timeIntervalSince(lastProbeAt) >= interval
    }

    nonisolated static func rememberedWirelessAutoConnectRecord(
        in records: [PairedPhoneRecord],
        failedTargets: [String: Date],
        listenerMissingRecordIDs: Set<String> = [],
        now: Date = Date(),
        cooldown: TimeInterval = autoConnectFailureCooldown
    ) -> PairedPhoneRecord? {
        records.first { record in
            guard isWirelessRecord(record) else { return false }
            // A swept-and-silent LAN is proof the listener is gone, not a
            // guess: re-selecting this record every presence poll would
            // restart the whole dial cycle. It becomes eligible again the
            // moment a cable arm clears the verdict.
            guard !listenerMissingRecordIDs.contains(record.id) else { return false }
            guard let failedAt = failedTargets[record.lastAddress] else { return true }
            return !isAutoConnectFailureCoolingDown(
                failedAt: failedAt,
                now: now,
                cooldown: cooldown
            )
        }
    }

    nonisolated static func shouldDisableManualUSBConnectButton(
        isPairing: Bool,
        isScanning: Bool,
        isRecoveringConnection: Bool,
        isAwaitingReconnect: Bool,
        isMirroring: Bool,
        isAutoConnecting: Bool
    ) -> Bool {
        isPairing || isScanning || isRecoveringConnection || isAwaitingReconnect || isMirroring
    }

    func ensureQRCodePairingSession() {
        guard !isFirstRunOnboardingActive else {
            suspendQRCodePairingForOnboarding()
            return
        }
        guard !isMirroring, !isRecoveringConnection else { return }
        if qrPairingSession == nil {
            qrPairingSession = .random()
        }
        startQRCodePairingWatcher()
    }

    func restartQRCodePairingSession() {
        guard !isFirstRunOnboardingActive else {
            suspendQRCodePairingForOnboarding()
            return
        }
        guard !isMirroring, !isRecoveringConnection else { return }
        connectionCoordinator.qrPairingTask?.cancel()
        connectionCoordinator.qrPairingTask = nil
        isQRCodePairingWaiting = false
        qrPairingSession = .random()
        startQRCodePairingWatcher()
    }

    func stopQRCodePairingSession() {
        let hadPairingTask = connectionCoordinator.qrPairingTask != nil
        connectionCoordinator.qrPairingTask?.cancel()
        connectionCoordinator.qrPairingTask = nil
        isQRCodePairingWaiting = false
        if hadPairingTask && isPairing {
            isPairing = false
        }
    }

    func suspendQRCodePairingForOnboarding() {
        stopQRCodePairingSession()
        qrPairingSession = nil
    }

    /// Empty QR-discovery polls (750ms apart) before a typed stall is
    /// recorded — ~30s, long enough that slow mDNS isn't misreported.
    nonisolated static let qrEmptyDiscoveryStallPolls = 40

    func startQRCodePairingWatcher() {
        guard !isFirstRunOnboardingActive else {
            suspendQRCodePairingForOnboarding()
            return
        }
        guard connectionCoordinator.qrPairingTask == nil,
              let session = qrPairingSession
        else { return }

        isQRCodePairingWaiting = true

        let adb = self.adb
        connectionCoordinator.qrPairingTask = Task { [weak self] in
            await adb.ensureServerStarted()
            guard !Task.isCancelled else { return }

            // The watcher loops silently while nothing advertises. After ~30s
            // of pure emptiness, record a typed stall (once) so the health
            // panel can answer "I scanned the QR and nothing happened" —
            // usually wrong Wi-Fi or a denied Local Network permission.
            var emptyDiscoveryPolls = 0

            while !Task.isCancelled {
                let phones = await Task.detached { adb.mdnsServices() }.value
                guard !Task.isCancelled else { return }

                guard let self else { return }
                guard self.qrPairingSession == session else { return }

                guard let pairingPhone = ADBQRCodePairingSession.pairingService(
                    named: session.serviceName,
                    in: phones
                ) else {
                    emptyDiscoveryPolls += 1
                    if emptyDiscoveryPolls == Self.qrEmptyDiscoveryStallPolls {
                        self.noteConnectionStall(
                            .qrDiscoveryEmpty,
                            detail: "The QR code has been on screen for a while, but the phone's pairing service never appeared. Check both devices share a Wi-Fi network and that Local Network access is allowed."
                        )
                    }
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    continue
                }

                self.isQRCodePairingWaiting = false
                self.isPairing = true

                let pairOutput = await Task.detached {
                    adb.run(["pair", pairingPhone.address, session.password])
                }.value
                guard !Task.isCancelled else { return }

                guard Self.adbPairSucceeded(pairOutput) else {
                    self.resetQRCodePairingAfterFailure(
                        "QR pairing failed. Scan the new code and try again."
                    )
                    return
                }

                guard let connectablePhone = await Self.waitForConnectableWirelessPhone(
                    adb: adb,
                    preferredAddress: nil,
                    matchingHostOf: pairingPhone.address
                ) else {
                    guard !Task.isCancelled else { return }
                    self.resetQRCodePairingAfterFailure(
                        "Paired, but no wireless debugging connect service appeared. Scan the new code and try again."
                    )
                    return
                }
                guard !Task.isCancelled else { return }

                let connectOutput = await Task.detached {
                    await Self.preflightLocalNetworkAccess(address: connectablePhone.address)
                    return adb.run(["connect", connectablePhone.address])
                }.value
                guard !Task.isCancelled else { return }

                guard Self.adbConnectSucceeded(connectOutput) else {
                    self.resetQRCodePairingAfterFailure(
                        "Paired, but could not connect to \(connectablePhone.address). Scan the new code and try again."
                    )
                    return
                }

                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: connectablePhone.address,
                    fallback: "Android device"
                )
                let hardwareSerial = await Self.connectedHardwareSerial(
                    adb: adb,
                    transportSerial: connectablePhone.address
                )
                guard !Task.isCancelled else { return }
                self.finishQRCodePairing(
                    with: connectablePhone,
                    displayName: deviceName,
                    hardwareSerial: hardwareSerial
                )
                self.prepareQRCodePairingLegacyTCPIPInBackground(
                    phone: connectablePhone,
                    displayName: deviceName,
                    hardwareSerial: hardwareSerial
                )
                return
            }
        }
    }

    func resetQRCodePairingAfterFailure(_ message: String) {
        isPairing = false
        isQRCodePairingWaiting = false
        connectionCoordinator.qrPairingTask = nil
        qrPairingSession = .random()
        startQRCodePairingWatcher()
    }

    func finishQRCodePairing(
        with phone: DiscoveredPhone,
        displayName: String,
        hardwareSerial: String?
    ) {
        isPairing = false
        isQRCodePairingWaiting = false
        connectionCoordinator.qrPairingTask = nil
        qrPairingSession = nil
        let identity = hardwareSerial ?? phone.id
        touchPairedPhone(
            id: identity,
            displayName: displayName,
            address: phone.address,
            usbSerial: hardwareSerial,
            wifiAddress: phone.address
        )
        selectedDevice = MirrorDevice(
            id: identity,
            name: displayName,
            model: "Android",
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: "Wi-Fi",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: phone.address
        )
        // Completing a pairing is a deliberate user action: it clears
        // breakers and bypasses the auto-presentation visibility gate.
        startMirroring(manual: true)
    }

    func prepareQRCodePairingLegacyTCPIPInBackground(
        phone: DiscoveredPhone,
        displayName: String,
        hardwareSerial: String?
    ) {
        guard legacyWirelessCompatibilityEnabled else { return }
        guard Self.shouldPromoteToLegacyTCPIP(connectedAddress: phone.address) else { return }
        let adb = self.adb
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            guard self.legacyWirelessCompatibilityEnabled,
                  !self.isMirroring,
                  self.mirrorLaunchTask == nil,
                  self.selectedDevice.adbSerial == phone.address
            else {
                Logger.log("Skipped QR Wi-Fi reconnect route preparation while mirror is active address=\(phone.address)")
                return
            }
            guard case .promoted(let legacyAddress) = await Self.promoteToLegacyTCPIP(
                adb: adb,
                sourceSerial: phone.address,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                }
            ) else {
                return
            }
            guard !Task.isCancelled else { return }
            self.touchPairedPhone(
                id: hardwareSerial ?? phone.id,
                displayName: displayName,
                address: legacyAddress,
                usbSerial: hardwareSerial,
                wifiAddress: legacyAddress
            )
            Logger.log("Prepared QR Wi-Fi reconnect route address=\(legacyAddress)")
        }
    }

    @discardableResult
    /// - Parameter armWirelessWithoutMirroring: authorizes the destructive
    ///   `adb tcpip` step for a pass that will *not* start a mirror. This is the
    ///   plug-in-and-unplug flow: the cable is present, nothing is mirroring, so
    ///   re-arm `:5555` and persist the route for later Wi-Fi reconnects. Every
    ///   other tcpip guard (no live mirror, closed port, same-LAN proof, the
    ///   failure breaker) still applies — see INVARIANTS.md rule 3.
    func prepareWirelessMirror(
        from usbDevice: AuthorizedADBDevice,
        activatePreparedMirror: Bool = true,
        armWirelessWithoutMirroring: Bool = false,
        handoffGeneration: Int? = nil,
        mirrorGeneration: Int? = nil
    ) async -> Bool {
        let adb = self.adb
        let handoffStartedAt = Date()
        let handoffAttempt = DiagnosticsConnectionAttempt(
            attemptNumber: reconnectAttemptCount + 1,
            isRetry: reconnectAttemptCount > 0
        )
        DiagnosticsService.shared.capture(
            handoffAttempt.isRetry ? .wifiRetryStarted : .wifiHandoffStarted,
            properties: DiagnosticsService.shared.propertiesForAttempt(handoffAttempt, transport: "wifi")
        )
        func remainingBudget() -> TimeInterval {
            Self.remainingWirelessHandoffBudget(startedAt: handoffStartedAt)
        }
        func boundedTimeout(_ requested: TimeInterval) -> TimeInterval? {
            let remaining = remainingBudget()
            guard remaining > 0.05 else { return nil }
            return min(requested, remaining)
        }
        func ownsHandoff() -> Bool {
            guard !Task.isCancelled else { return false }
            if let handoffGeneration,
               !connectionCoordinator.isCurrentUSBWiFiHandoff(handoffGeneration) {
                return false
            }
            if let mirrorGeneration, mirrorStartGeneration != mirrorGeneration {
                return false
            }
            return true
        }
        func mayRecoverADBServerOwnership() -> Bool {
            activatePreparedMirror
                && !isMirroring
                && mirrorSession == nil
                && mirrorLaunchTask == nil
        }
        var connectAttempts = 0
        var noRouteToHostFailures = 0
        guard let routeQueryTimeout = boundedTimeout(Self.wirelessHandoffRouteQueryTimeout) else {
            return false
        }
        let routeOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "ip", "route"], timeout: routeQueryTimeout)
        }.value
        guard ownsHandoff() else { return false }
        if let wifiIP = Self.wifiIPAddress(in: routeOutput) {
            Logger.log("Wi-Fi handoff phase=route-resolved usb=\(usbDevice.serial) ip=\(wifiIP)")
        } else {
            Logger.log("Wi-Fi handoff phase=route-missing usb=\(usbDevice.serial) output=\(routeOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Learn the Wi-Fi MAC over USB so recovery can find the phone after its
        // IP changes. Best-effort: a nil MAC just means recovery falls back to
        // the port-5555 + getprop sweep later. Bounded by the remaining budget
        // so two slow shell reads can't starve the readiness wait that follows.
        let wifiMACAddress: String?
        if let macReadTimeout = boundedTimeout(Self.wirelessHandoffRouteQueryTimeout) {
            wifiMACAddress = await Task.detached {
                Self.resolveWiFiMACAddress(
                    adb: adb,
                    serial: usbDevice.serial,
                    routeOutput: routeOutput,
                    timeout: macReadTimeout
                )
            }.value
            guard ownsHandoff() else { return false }
        } else {
            wifiMACAddress = nil
        }
        Logger.log("Wi-Fi handoff phase=identity-captured usb=\(usbDevice.serial) mac=\(wifiMACAddress ?? "unavailable")")

        if let observedWiFiIP = Self.wifiIPAddress(in: routeOutput) {
            touchPairedPhone(
                id: usbDevice.serial,
                displayName: selectedDisplayName(for: usbDevice.model),
                address: usbDevice.serial,
                usbSerial: usbDevice.serial,
                observedWiFiIPAddress: observedWiFiIP,
                wifiMACAddress: wifiMACAddress
            )
        }

        // Resolve Android's authenticated Wireless-debugging endpoint before
        // considering the compatibility listener. Even when compatibility is
        // enabled, a phone that advertises TLS stays on TLS.
        let tlsAddress: String?
        if let tlsPortTimeout = boundedTimeout(Self.wirelessHandoffRouteQueryTimeout) {
            let tlsPortOutput = await Task.detached {
                adb.run(
                    ["-s", usbDevice.serial, "shell", "getprop", "service.adb.tls.port"],
                    timeout: tlsPortTimeout
                )
            }.value
            guard ownsHandoff() else { return false }
            tlsAddress = Self.wirelessDebuggingAddress(
                routeOutput: routeOutput,
                tlsPortOutput: tlsPortOutput
            )
        } else {
            tlsAddress = nil
        }

        // Port 5555 remains an explicit compatibility path for older phones.
        // Secure Wireless debugging continues below whenever it is advertised.
        if legacyWirelessCompatibilityEnabled,
           tlsAddress == nil,
           let legacyAddress = Self.legacyTCPIPDebuggingAddress(routeOutput: routeOutput) {
            if usbWiFiHandoffCandidate?.usbSerial == usbDevice.serial,
               usbWiFiHandoffCandidate?.address != legacyAddress {
                usbWiFiHandoffCandidate = nil
            }
            // A closed port only means "tcpip is not enabled" when the Mac
            // and phone share a directly routable LAN. On another network the
            // exact same probe result means handoff cannot work, and restarting
            // adbd would only remove the usable USB transport.
            guard Self.localIPv4Address(matchingRemoteAddress: legacyAddress) != nil else {
                Logger.log("Wi-Fi handoff phase=network-mismatch usb=\(usbDevice.serial) address=\(legacyAddress); preserving USB")
                return false
            }

            // Probe 5555 before `adb tcpip`. An explicit USB choice performs
            // this preparation non-destructively: it records identity and uses
            // any listener already available, but never restarts adbd underneath
            // the USB mirror. Automatic USB bootstrap may enable 5555 so the
            // normal Wi-Fi-first handoff can complete.
            let alreadyListening = await Self.adbTCPPortProbe(legacyAddress)
            guard ownsHandoff() else { return false }
            let hasLiveMirror = isMirroring || mirrorSession != nil || mirrorLaunchTask != nil
            let mayRunTCPIP = (activatePreparedMirror || armWirelessWithoutMirroring)
                && !hasLiveMirror
                && !alreadyListening
                && !connectionCoordinator.isLegacyHandoffCoolingDown(serial: usbDevice.serial)

            if mayRunTCPIP {
                let hostRouteUnavailable = await Task.detached {
                    Self.macRouteToWirelessHostIsUnavailable(legacyAddress)
                }.value
                guard ownsHandoff() else { return false }
                if hostRouteUnavailable {
                    connectionCoordinator.noteLegacyHandoffFailure(serial: usbDevice.serial)
                    Logger.log("Wi-Fi handoff phase=host-route-unavailable usb=\(usbDevice.serial) address=\(legacyAddress); preserving USB")
                    return false
                }
            }
            Logger.log("Wi-Fi handoff phase=legacy-probe address=\(legacyAddress) listening=\(alreadyListening) may_enable=\(mayRunTCPIP)")

            if alreadyListening || mayRunTCPIP {
                rememberUSBWiFiHandoffCandidate(
                    usbDevice: usbDevice,
                    address: legacyAddress,
                    displayName: selectedDisplayName(for: usbDevice.model)
                )
                if let primeTimeout = boundedTimeout(Self.wirelessHandoffRoutePrimeTimeout) {
                    await Self.primeADBWirelessRoute(
                        adb: adb,
                        usbSerial: usbDevice.serial,
                        wirelessAddress: legacyAddress,
                        timeout: primeTimeout
                    )
                    guard ownsHandoff() else { return false }
                }

                var wirelessEnabled = alreadyListening
                if mayRunTCPIP {
                    guard ownsHandoff() else { return false }
                    guard let tcpipTimeout = boundedTimeout(Self.wirelessHandoffTCPIPTimeout) else {
                        return false
                    }
                    let tcpipOutput = await Task.detached {
                        adb.run(["-s", usbDevice.serial, "tcpip", "\(Self.legacyADBWirelessPort)"], timeout: tcpipTimeout)
                    }.value
                    guard ownsHandoff() else { return false }
                    let commandResult = Self.adbTCPIPCommandResult(tcpipOutput)
                    // Several Android builds restart adbd before the host receives
                    // the success line, yielding "closed" or a timeout even though
                    // :5555 is coming up. Those ambiguous restart results proceed
                    // to listener verification; definitive failures immediately
                    // fall through to TLS/mDNS instead of consuming the budget.
                    wirelessEnabled = commandResult != .failed
                    if !wirelessEnabled {
                        // A definitive tcpip failure trips the breaker: don't
                        // re-run the destructive restart on the next cycle for
                        // this phone. The bar is time-boxed and escalating
                        // (60s → 5m → 30m) rather than session-long, so a phone
                        // that failed once while adbd was mid-restart can still
                        // be armed later without relaunching the app. Keep the
                        // exact candidate, though: some vendors report an error
                        // after adbd has already changed transports, and the
                        // caller may need this route to issue `adb usb` and
                        // restore the original serial safely.
                        connectionCoordinator.noteLegacyHandoffFailure(serial: usbDevice.serial)
                    }
                    Logger.log("Wi-Fi handoff phase=tcpip-enable usb=\(usbDevice.serial) result=\(String(describing: commandResult)) verifying_listener=\(wirelessEnabled) output=\(tcpipOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
                }

                if wirelessEnabled {
                    let readiness = await Self.waitForADBWirelessTargetReadiness(
                        adb: adb,
                        address: legacyAddress,
                        attempts: Self.wirelessHandoffReadinessAttempts,
                        delayNanoseconds: Self.wirelessHandoffRetryDelayNanoseconds,
                        preflightLocalNetworkAccess: { address in
                            await Self.preflightLocalNetworkAccess(
                                address: address,
                                timeoutNanoseconds: Self.wirelessHandoffPreflightTimeoutNanoseconds
                            )
                        },
                        primeRoute: {
                            let timeout = min(Self.wirelessHandoffRoutePrimeTimeout, remainingBudget())
                            guard timeout > 0.05 else { return }
                            await Self.primeADBWirelessRoute(
                                adb: adb,
                                usbSerial: usbDevice.serial,
                                wirelessAddress: legacyAddress,
                                timeout: timeout
                            )
                        },
                        tcpPortProbe: { address in
                            await Self.adbTCPPortProbe(address)
                        },
                        maximumDuration: remainingBudget(),
                        connectTimeout: Self.wirelessHandoffConnectTimeout,
                        shellTimeout: Self.wirelessHandoffShellTimeout,
                        // Configure-first handoff has no live mirror to disrupt.
                        // If the listener is reachable but `adb connect` gets
                        // macOS' synthetic "No route to host", restart the host
                        // daemon once from the signed app so Local Network TCC
                        // is attributed to Phone Relay. Background preparation
                        // under a live USB mirror never receives this permission.
                        allowADBServerRestart: mayRecoverADBServerOwnership()
                    )
                    connectAttempts += readiness.connectAttempts
                    noRouteToHostFailures += readiness.noRouteToHostFailures
                    Logger.log("Wi-Fi handoff phase=legacy-readiness address=\(legacyAddress) ready=\(readiness.isReady) attempts=\(readiness.connectAttempts) no_route=\(readiness.noRouteToHostFailures)")
                    if readiness.isReady {
                        // Only a current attempt may promote transports; a
                        // stale one stops here. The failure verdict below is
                        // deliberately NOT ownership-gated — see that comment.
                        guard ownsHandoff() else { return false }
                        DiagnosticsService.shared.capture(
                            handoffAttempt.isRetry ? .wifiRetrySucceeded : .wifiHandoffSucceeded,
                            properties: DiagnosticsService.shared.propertiesForCompletedAttempt(handoffAttempt, transport: "wifi")
                        )
                        let deviceName = await Self.connectedDeviceName(
                            adb: adb,
                            serial: legacyAddress,
                            fallback: usbDevice.model
                        )
                        guard ownsHandoff() else { return false }
                        if alreadyListening {
                            if activatePreparedMirror {
                                // Automatic USB bootstrap: Wi-Fi is the default,
                                // so switch once the verified route is ready.
                                promoteActiveMirrorToWirelessHandoff(
                                    usbDevice: usbDevice,
                                    address: legacyAddress,
                                    displayName: deviceName,
                                    wifiMACAddress: wifiMACAddress
                                )
                            } else {
                                // Explicit USB: keep the selected route active,
                                // but retain Wi-Fi for cable-loss takeover.
                                finishWirelessHandoff(
                                    usbDevice: usbDevice,
                                    address: legacyAddress,
                                    displayName: deviceName,
                                    wifiMACAddress: wifiMACAddress,
                                    activatePreparedMirror: false
                                )
                            }
                        } else {
                            // `adb tcpip` dropped the USB mirror; the takeover
                            // (onSessionEnded) brings it back up on Wi-Fi.
                            finishWirelessHandoff(
                                usbDevice: usbDevice,
                                address: legacyAddress,
                                displayName: deviceName,
                                wifiMACAddress: wifiMACAddress,
                                activatePreparedMirror: activatePreparedMirror
                            )
                        }
                        return true
                    }
                    // A cancelled probe is not a verdict: `adb tcpip` drops the
                    // USB mirror, whose session-end starts the takeover — and
                    // the takeover cancels this task. Marking the serial failed
                    // here would disable tcpip for the whole session on a phone
                    // that is actually mid-restart and about to come up.
                    if Task.isCancelled {
                        return false
                    }
                    // Wireless adb is on but unreachable from the Mac; don't keep
                    // restarting adbd (and killing the USB mirror) next time.
                    // Recorded even when the mirror generation moved on: our own
                    // tcpip restart is what bumps it, and gating this verdict on
                    // ownership re-armed tcpip every cycle — a USB mirror that
                    // died every few seconds while Wi-Fi stayed unreachable.
                    if mayRunTCPIP {
                        connectionCoordinator.noteLegacyHandoffFailure(serial: usbDevice.serial)
                    }
                    if !ownsHandoff() {
                        return false
                    }
                    // Configure-first handoff may have restarted adbd and lost
                    // USB even though Wi-Fi readiness timed out. Keep its exact
                    // candidate so the caller can reconnect there and issue
                    // `adb usb`, restoring the cable before falling back.
                    if !mayRunTCPIP,
                       usbWiFiHandoffCandidate?.usbSerial == usbDevice.serial,
                       usbWiFiHandoffCandidate?.address == legacyAddress {
                        usbWiFiHandoffCandidate = nil
                    }
                }
            } else {
                let retryAt = connectionCoordinator.legacyHandoffRetryDate(serial: usbDevice.serial)
                let retryIn = retryAt.map { String(format: "%.0fs", max(0, $0.timeIntervalSinceNow)) } ?? "n/a"
                Logger.log("Skipping adb tcpip for \(usbDevice.serial): wireless handoff failed recently (retry_in=\(retryIn)); trying non-destructive paths")
            }
        }

        guard remainingBudget() > 0.05 else {
            if connectAttempts > 0,
               connectAttempts == noRouteToHostFailures,
               !localNetworkPermissionGrantedForOnboarding {
                presentLocalNetworkPermissionHint()
            }
            return false
        }
        // Android Wireless debugging is the normal path. Its authenticated
        // port may change, so reconnect discovery refreshes the endpoint.
        if let tlsAddress {
            let readiness = await Self.waitForADBWirelessTargetReadiness(
                adb: adb,
                address: tlsAddress,
                attempts: Self.wirelessHandoffReadinessAttempts,
                delayNanoseconds: Self.wirelessHandoffRetryDelayNanoseconds,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(
                        address: address,
                        timeoutNanoseconds: Self.wirelessHandoffPreflightTimeoutNanoseconds
                    )
                },
                primeRoute: {
                    let timeout = min(Self.wirelessHandoffRoutePrimeTimeout, remainingBudget())
                    guard timeout > 0.05 else { return }
                    await Self.primeADBWirelessRoute(
                        adb: adb,
                        usbSerial: usbDevice.serial,
                        wirelessAddress: tlsAddress,
                        timeout: timeout
                    )
                },
                tcpPortProbe: { address in
                    await Self.adbTCPPortProbe(address)
                },
                maximumDuration: remainingBudget(),
                connectTimeout: Self.wirelessHandoffConnectTimeout,
                shellTimeout: Self.wirelessHandoffShellTimeout,
                allowADBServerRestart: mayRecoverADBServerOwnership()
            )
            guard ownsHandoff() else { return false }
            connectAttempts += readiness.connectAttempts
            noRouteToHostFailures += readiness.noRouteToHostFailures
            if readiness.isReady {
                DiagnosticsService.shared.capture(
                    handoffAttempt.isRetry ? .wifiRetrySucceeded : .wifiHandoffSucceeded,
                    properties: DiagnosticsService.shared.propertiesForCompletedAttempt(handoffAttempt, transport: "wifi")
                )
                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: tlsAddress,
                    fallback: usbDevice.model
                )
                guard ownsHandoff() else { return false }
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    address: tlsAddress,
                    displayName: deviceName,
                    wifiMACAddress: wifiMACAddress,
                    activatePreparedMirror: activatePreparedMirror
                )
                return true
            }

        }

        guard remainingBudget() > 0.05 else {
            if connectAttempts > 0,
               connectAttempts == noRouteToHostFailures,
               !localNetworkPermissionGrantedForOnboarding {
                presentLocalNetworkPermissionHint()
            }
            return false
        }
        let discoveredWirelessPhones = await Task.detached {
            adb.connectableMDNSTargets()
        }.value
        guard ownsHandoff() else { return false }
        if let wirelessPhone = Self.wirelessPhoneMatchingUSBRoute(
            routeOutput,
            phones: discoveredWirelessPhones
        ) {
            let readiness = await Self.waitForADBWirelessTargetReadiness(
                adb: adb,
                address: wirelessPhone.address,
                attempts: Self.wirelessHandoffReadinessAttempts,
                delayNanoseconds: Self.wirelessHandoffRetryDelayNanoseconds,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(
                        address: address,
                        timeoutNanoseconds: Self.wirelessHandoffPreflightTimeoutNanoseconds
                    )
                },
                primeRoute: {
                    let timeout = min(Self.wirelessHandoffRoutePrimeTimeout, remainingBudget())
                    guard timeout > 0.05 else { return }
                    await Self.primeADBWirelessRoute(
                        adb: adb,
                        usbSerial: usbDevice.serial,
                        wirelessAddress: wirelessPhone.address,
                        timeout: timeout
                    )
                },
                tcpPortProbe: { address in
                    await Self.adbTCPPortProbe(address)
                },
                maximumDuration: remainingBudget(),
                connectTimeout: Self.wirelessHandoffConnectTimeout,
                shellTimeout: Self.wirelessHandoffShellTimeout,
                allowADBServerRestart: mayRecoverADBServerOwnership()
            )
            guard ownsHandoff() else { return false }
            connectAttempts += readiness.connectAttempts
            noRouteToHostFailures += readiness.noRouteToHostFailures
            if readiness.isReady {
                DiagnosticsService.shared.capture(
                    handoffAttempt.isRetry ? .wifiRetrySucceeded : .wifiHandoffSucceeded,
                    properties: DiagnosticsService.shared.propertiesForCompletedAttempt(handoffAttempt, transport: "wifi")
                )
                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: wirelessPhone.address,
                    fallback: usbDevice.model
                )
                guard ownsHandoff() else { return false }
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    address: wirelessPhone.address,
                    displayName: deviceName,
                    wifiMACAddress: wifiMACAddress,
                    activatePreparedMirror: activatePreparedMirror
                )
                return true
            }

        }

        if connectAttempts > 0,
           connectAttempts == noRouteToHostFailures,
           !localNetworkPermissionGrantedForOnboarding {
            presentLocalNetworkPermissionHint()
        }
        Logger.log("Wi-Fi handoff phase=failed usb=\(usbDevice.serial) connect_attempts=\(connectAttempts) no_route=\(noRouteToHostFailures) budget_remaining=\(String(format: "%.2f", remainingBudget()))")
        DiagnosticsService.shared.capture(
            handoffAttempt.isRetry ? .wifiRetryFailed : .wifiHandoffFailed,
            properties: DiagnosticsService.shared.propertiesForCompletedAttempt(
                handoffAttempt,
                transport: "wifi",
                extra: [
                    "failure_reason": connectAttempts > 0 && connectAttempts == noRouteToHostFailures
                        ? DiagnosticsFailureReason.noRouteToHost.rawValue
                        : DiagnosticsFailureReason.timeout.rawValue
                ]
            )
        )
        return false
    }

    func rememberUSBWiFiHandoffCandidate(
        usbDevice: AuthorizedADBDevice,
        address: String,
        displayName: String
    ) {
        usbWiFiHandoffCandidate = USBWiFiHandoffCandidate(
            usbSerial: usbDevice.serial,
            address: address,
            displayName: displayName
        )
    }

    nonisolated static let localNetworkBlockedErrorTitle = "Local Network may be blocked"
    nonisolated static let usbPhoneNotFoundErrorTitle = "USB phone not found"
    nonisolated static let wifiConnectionNotReadyErrorTitle = "Wi-Fi connection not ready"
    nonisolated static let wifiPairingRequiredErrorTitle = "Wireless debugging needs pairing"
    nonisolated static let wifiListenerMissingErrorTitle = "Plug in once to re-enable Wi-Fi"

    /// "No route to host" on every attempt — while the phone can reach the Mac
    /// — is usually macOS denying this app's Local Network permission, which can
    /// reset on ad-hoc re-signs.
    ///
    /// With USB plugged in, mirroring still works, so keep the diagnosis to the
    /// log and don't cover the connection screen. But when Wi-Fi is the *only*
    /// path — e.g. reopening the app with the cable unplugged — a silent "No route
    /// to host" looks exactly like "it didn't save / just won't reconnect". In
    /// that case surface the real, fixable error so the user can grant access; the
    /// background reconnect loop keeps trying and connects automatically the moment
    /// Local Network is allowed.
    func presentLocalNetworkPermissionHint() {
        if !hasShownLocalNetworkPermissionHint {
            hasShownLocalNetworkPermissionHint = true
            Logger.log("Wi-Fi connects failing with 'No route to host' — likely macOS Local Network permission. Open System Settings > Privacy & Security > Local Network and enable Phone Relay if wireless handoff should be used.")
        }
        guard Self.shouldSurfaceLocalNetworkError(
            isUSBConnectionAvailable: isUSBConnectionAvailable,
            isMirroring: isMirroring,
            currentErrorTitle: activeError?.title
        ) else { return }
        reportError(
            Self.localNetworkBlockedErrorTitle,
            "Phone Relay can’t reach your phone over Wi-Fi — every connection returns “No route to host”, which is usually macOS blocking Local Network access. Turn on Phone Relay in System Settings › Privacy & Security › Local Network and it will reconnect automatically, or connect the phone with USB."
        )
    }

    /// Surface the Local Network error only when Wi-Fi is the sole path (no USB
    /// fallback), we're not already mirroring, and it isn't already on screen.
    nonisolated static func shouldSurfaceLocalNetworkError(
        isUSBConnectionAvailable: Bool,
        isMirroring: Bool,
        currentErrorTitle: String?
    ) -> Bool {
        !isUSBConnectionAvailable
            && !isMirroring
            && currentErrorTitle != localNetworkBlockedErrorTitle
    }

    func finishWirelessHandoff(
        usbDevice: AuthorizedADBDevice,
        address: String,
        displayName: String,
        wifiMACAddress: String? = nil,
        activatePreparedMirror: Bool = true
    ) {
        rememberUSBWiFiHandoffCandidate(
            usbDevice: usbDevice,
            address: address,
            displayName: displayName
        )
        connectionCoordinator.clearLegacyHandoffFailure(serial: usbDevice.serial)
        touchPairedPhone(
            id: usbDevice.serial,
            displayName: displayName,
            address: address,
            usbSerial: usbDevice.serial,
            wifiAddress: address,
            wifiMACAddress: wifiMACAddress
        )
        guard activatePreparedMirror else {
            Logger.log("Prepared Wi-Fi handoff address=\(address) while keeping current USB mirror active")
            return
        }
        if isMirroring || mirrorSession != nil || mirrorLaunchTask != nil {
            // TLS/mDNS fallback routes are non-destructive just like an already
            // listening :5555 route. Automatic USB bootstrap must still honor
            // the global Wi-Fi-first policy instead of calling startMirroring(),
            // which would no-op while the USB session is active.
            promoteActiveMirrorToWirelessHandoff(
                usbDevice: usbDevice,
                address: address,
                displayName: displayName,
                wifiMACAddress: wifiMACAddress
            )
            return
        }
        cancelWirelessReconnectWork()
        selectedDevice.adbSerial = address
        selectedDevice.name = displayName
        selectedDevice.network = "Wi-Fi"
        stopQRCodePairingSession()
        startMirroring()
    }

    /// Switches a still-live USB mirror over to a Wi-Fi route that's already
    /// reachable (5555 was listening, so `adb tcpip` was never run and the USB
    /// session is healthy). `startMirroring()` no-ops while a session is live,
    /// so we tear the USB session down and route through the proven takeover
    /// path rather than racing a second launch.
    func promoteActiveMirrorToWirelessHandoff(
        usbDevice: AuthorizedADBDevice,
        address: String,
        displayName: String,
        wifiMACAddress: String? = nil
    ) {
        rememberUSBWiFiHandoffCandidate(
            usbDevice: usbDevice,
            address: address,
            displayName: displayName
        )
        connectionCoordinator.clearLegacyHandoffFailure(serial: usbDevice.serial)
        touchPairedPhone(
            id: usbDevice.serial,
            displayName: displayName,
            address: address,
            usbSerial: usbDevice.serial,
            wifiAddress: address,
            wifiMACAddress: wifiMACAddress
        )
        guard isMirroring || mirrorSession != nil || mirrorLaunchTask != nil else {
            // No live session after all — fall back to a normal Wi-Fi launch.
            cancelWirelessReconnectWork()
            selectedDevice.adbSerial = address
            selectedDevice.name = displayName
            selectedDevice.network = "Wi-Fi"
            stopQRCodePairingSession()
            startMirroring()
            return
        }
        Logger.log("Switching live USB mirror to already-listening Wi-Fi route \(address)")
        // Commit this phone to Wi-Fi so the still-plugged cable is ignored from
        // here on ("move to Wi-Fi and stay") instead of bouncing back to USB.
        wirelessPinnedUSBSerials.insert(usbDevice.serial)
        isRecoveringConnection = true
        isAwaitingReconnect = true
        isAutoConnecting = true
        activeError = nil
        showConnectionWindow(startsQRCodePairing: false)
        let lostSerial = usbDevice.serial
        let finalFrame = connectionWindow?.frame ?? lastMirrorWindowFrame
        mirrorStartGeneration += 1
        mirrorLaunchTask?.cancel()
        mirrorLaunchTask = nil
        mirrorSession?.onSessionEnded = nil
        mirrorSession?.stop()
        mirrorSession = nil
        isMirroring = false
        restorePresentationModeIfNeeded()
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        }
        _ = startUSBWiFiHandoffTakeoverIfAvailable(
            usbSerial: lostSerial,
            finalMirrorFrame: finalFrame
        )
    }

    func connectViaUSB() {
        if let liveUSBDevice = latestAuthorizedADBDevices.first(where: \.isUSB) {
            if isMirroring || mirrorLaunchTask != nil {
                beginManualUSBConnection(serial: liveUSBDevice.serial)
                if selectedDevice.adbSerial == liveUSBDevice.serial {
                    // The requested route is already active. Keep the choice
                    // one-shot while replacing any automatic promotion flight
                    // with prepare-only work. Handoff remains enabled; this
                    // merely prevents stale work from overriding the click.
                    prepareWirelessHandoffInBackground(
                        from: liveUSBDevice,
                        activatePreparedMirror: false
                    )
                    return
                }
                restartActiveMirrorOverManualUSB(liveUSBDevice)
                return
            }
        }
        guard !isMirroring else { return }
        resumeDiscoveryAfterManualConnect()
        connectionCoordinator.usbConnectTask?.cancel()
        connectionCoordinator.cancelUSBWiFiHandoff()
        connectionCoordinator.usbWiFiTakeoverTask?.cancel()
        connectionCoordinator.usbWiFiTakeoverTask = nil
        usbWiFiHandoffCandidate = nil
        // An explicit reconnect is a clean retry: let the Wi-Fi handoff attempt
        // `adb tcpip` again even if it gave up earlier this session.
        failedLegacyHandoffSerials.removeAll()
        cancelWirelessReconnectWork()
        let generation = mirrorStartGeneration
        isPairing = true

        let adb = self.adb
        connectionCoordinator.usbConnectTask = Task { [weak self] in
            var output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
            guard !Task.isCancelled else { return }
            var authorizedDevices = Self.authorizedADBDevices(in: output)
            var usbDevice = authorizedDevices.first(where: \.isUSB)
            var hasUnauthorizedUSB = Self.hasUnauthorizedUSBDevice(in: output)

            guard let self else { return }
            guard self.mirrorStartGeneration == generation else { return }
            self.recordADBHealth(output, authorizedDevices: authorizedDevices)
            self.updateUSBAuthorizationHint(from: output, authorizedDevices: authorizedDevices)
            if hasUnauthorizedUSB {
                self.reportUSBNotAuthorized()
                self.isPairing = false
                self.connectionCoordinator.usbConnectTask = nil
                return
            }

            if usbDevice == nil {
                Logger.log("Manual USB connect found no USB device; reconnecting offline adb transports once before giving up.")
                // Release the pairing indicator before the targeted retry: an
                // offline transport can cost two full scan timeouts, and the UI
                // must not read "pairing" that long. The coordinator's USB task stays
                // set, so the status pill still shows the attempt as active
                // and auto-connect flows stay blocked while the retry runs.
                self.isPairing = false
                let retry = await Self.usbDevicesAfterTargetedADBReconnect(adb: adb)
                guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
                output = retry.output
                authorizedDevices = retry.authorizedDevices
                usbDevice = retry.usbDevice
                hasUnauthorizedUSB = Self.hasUnauthorizedUSBDevice(in: output)
                self.recordADBHealth(output, authorizedDevices: authorizedDevices)
                self.updateUSBAuthorizationHint(from: output, authorizedDevices: authorizedDevices)
                if hasUnauthorizedUSB {
                    self.reportUSBNotAuthorized()
                    self.isPairing = false
                    self.connectionCoordinator.usbConnectTask = nil
                    return
                }
            }

            guard let usbDevice else {
                let diagnostic = await Self.currentMacUSBDeviceDiagnostic()
                guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
                self.reportError(
                    Self.usbPhoneNotFoundErrorTitle,
                    Self.usbPhoneNotFoundMessage(for: diagnostic)
                )
                self.isPairing = false
                self.connectionCoordinator.usbConnectTask = nil
                return
            }

            guard let readyUSBDevice = await self.readyUSBDeviceForMirroring(usbDevice) else {
                self.reportError(
                    "USB phone not ready",
                    "Phone Relay found the USB device, but adb could not talk to it yet. Keep the phone unlocked, replug the cable, and approve USB debugging on the phone."
                )
                self.isPairing = false
                self.connectionCoordinator.usbConnectTask = nil
                return
            }

            let wifiAddress = await self.prefillWirelessIPFromUSBDevice(readyUSBDevice)
            self.beginManualUSBConnection(serial: readyUSBDevice.serial)
            self.connectionCoordinator.usbConnectTask = nil
            self.startMirroringOverUSB(
                readyUSBDevice,
                manual: true,
                wifiAddress: wifiAddress,
                prepareWirelessHandoff: true
            )
        }
    }

    nonisolated static func usbDevicesAfterTargetedADBReconnect(
        adb: ADBController
    ) async -> (output: String, authorizedDevices: [AuthorizedADBDevice], usbDevice: AuthorizedADBDevice?) {
        await Task.detached(priority: .userInitiated) {
            // Repair only transports adb already considers offline. A global
            // kill-server would discard healthy USB and Wi-Fi routes for every
            // connected phone while trying to discover one missing cable.
            _ = adb.run(["reconnect", "offline"], timeout: 3)
        }.value
        await adb.ensureServerStarted()
        let output = await Task.detached {
            adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
        }.value
        let devices = Self.authorizedADBDevices(in: output)
        return (output, devices, devices.first(where: \.isUSB))
    }

    nonisolated static func usbPhoneNotFoundMessage(for diagnostic: MacUSBDeviceDiagnostic) -> String {
        if diagnostic.hasAndroidLikeDevice {
            let device = diagnostic.deviceName.map { " (\($0))" } ?? ""
            return "macOS can see an Android USB device\(device), but adb cannot see a USB debugging transport yet. Unlock the phone, set USB mode to File Transfer, turn USB debugging off and back on, then tap Allow if Android shows the prompt."
        }
        if diagnostic.hasAnyUSBDevice {
            return "adb did not find a USB debugging phone. If the phone is plugged in, unlock it, choose File Transfer instead of charge-only, enable USB debugging, and use a data-capable cable or direct USB-C port."
        }
        return "macOS is not seeing the phone on USB at all. Use a data-capable cable, plug directly into this Mac, unlock the phone, set USB mode to File Transfer, then enable USB debugging and tap Allow."
    }

    nonisolated static func macUSBDeviceDiagnostic(from ioregOutput: String) -> MacUSBDeviceDiagnostic {
        let lines = ioregOutput.split(whereSeparator: \.isNewline).map(String.init)
        let hasAnyUSBDevice = lines.contains { line in
            line.contains("<class IOUSBHostDevice") || line.contains("\"idVendor\"")
        }
        let androidVendorIDs: Set<Int> = [
            0x04e8, // Samsung
            0x0bb4, // HTC
            0x0fce, // Sony
            0x1004, // LG
            0x12d1, // Huawei
            0x18d1, // Google
            0x22b8, // Motorola
            0x22d9, // Oppo
            0x2717, // Xiaomi
            0x2a70, // OnePlus
            0x2d95  // Vivo
        ]
        let vendorID = lines
            .first { $0.contains("\"idVendor\"") }
            .flatMap(Self.integerValueAfterEquals)
        let deviceName = Self.usbRegistryDeviceName(from: lines)
        let keywords = [
            "android", "adb", "mtp", "samsung", "google", "pixel",
            "galaxy", "oneplus", "xiaomi", "huawei", "motorola",
            "sony", "oppo", "vivo", "nothing phone", "lg "
        ]
        let searchable = ([deviceName].compactMap { $0 } + lines).joined(separator: "\n").lowercased()
        let hasAndroidLikeDevice = vendorID.map(androidVendorIDs.contains) == true
            || keywords.contains { searchable.contains($0) }
        return MacUSBDeviceDiagnostic(
            hasAnyUSBDevice: hasAnyUSBDevice,
            hasAndroidLikeDevice: hasAndroidLikeDevice,
            deviceName: deviceName
        )
    }

    nonisolated static func currentMacUSBDeviceDiagnostic() async -> MacUSBDeviceDiagnostic {
        await Task.detached(priority: .utility) {
            let output = Tooling.run(
                "ioreg",
                arguments: ["-p", "IOUSB", "-r", "-c", "IOUSBHostDevice", "-l", "-w", "0"],
                timeout: 2
            )
            return macUSBDeviceDiagnostic(from: output)
        }.value
    }

    nonisolated static func usbRegistryDeviceName(from lines: [String]) -> String? {
        let preferredKeys = [
            "\"USB Product Name\"",
            "\"Product Name\"",
            "\"kUSBProductString\"",
            "\"USB Vendor Name\"",
            "\"kUSBVendorString\""
        ]
        for key in preferredKeys {
            if let line = lines.first(where: { $0.contains(key) }),
               let value = quotedValueAfterEquals(line),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated static func quotedValueAfterEquals(_ line: String) -> String? {
        guard let equals = line.range(of: "=") else { return nil }
        let value = line[equals.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstQuote = value.firstIndex(of: "\"") else { return nil }
        let remainder = value[value.index(after: firstQuote)...]
        guard let secondQuote = remainder.firstIndex(of: "\"") else { return nil }
        return String(remainder[..<secondQuote])
    }

    nonisolated static func integerValueAfterEquals(_ line: String) -> Int? {
        guard let equals = line.range(of: "=") else { return nil }
        let raw = line[equals.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw.hasPrefix("0x") {
            let hex = raw.dropFirst(2).prefix { $0.isHexDigit }
            return Int(hex, radix: 16)
        }
        let decimal = raw.prefix { $0.isNumber }
        return Int(decimal)
    }

    func connectViaAvailableWireless() {
        guard !isMirroring, !isPairing else { return }
        transportIntent = .manualWiFi
        resumeDiscoveryAfterManualConnect()
        stopQRCodePairingSession()

        if let wirelessDevice = latestAuthorizedADBDevices.first(where: { !$0.isUSB }) {
            select(device: wirelessDevice)
            // The watcher already reports this exact transport as authorized.
            // A manual click should launch it, not rediscover and reconnect it.
            prepareManualMirrorLaunch()
            stopDisconnectRecovery()
            launchNativeMirror(serial: wirelessDevice.serial)
            return
        }

        if let phone = discoveredPhones.first(where: { $0.kind.isConnectable }) {
            connectAndMirror(phone: phone)
            return
        }

        if let record = Self.recordsByMostRecent(pairedPhones).first(where: Self.isWirelessRecord) {
            reconnectOverWiFi(
                preferredRecord: record,
                inlineUntilConnected: true,
                restrictToPreferredRecord: true,
                allowAddressRecovery: true,
                unavailableTitle: "Wi-Fi unavailable",
                unavailableMessage: "Phone Relay could not reach this phone over Wi-Fi. Keep the phone awake, make sure both devices are on the same Wi-Fi, then try Wi-Fi again."
            )
            return
        }

        reportError(
            "Wi-Fi unavailable",
            "Phone Relay could not find a saved or live Wi-Fi route for this phone. Keep the phone awake, make sure both devices are on the same Wi-Fi, then try Wi-Fi again."
        )
        transportIntent = .automatic
    }

    /// Select USB for this immediate launch without turning that choice into a
    /// lasting preference. Wi-Fi discovery and handoff preparation continue,
    /// so the prepared route can take over when adbd restarts or the cable goes.
    func beginManualUSBConnection(serial: String) {
        transportIntent = .manualUSB(serial: serial)
        wirelessPinnedUSBSerials.remove(serial)
        isRecoveringConnection = false
        isAwaitingReconnect = false
        isAutoConnecting = false
    }

    func restartActiveMirrorOverManualUSB(_ usbDevice: AuthorizedADBDevice) {
        mirrorStartGeneration += 1
        mirrorLaunchTask?.cancel()
        mirrorLaunchTask = nil
        mirrorSession?.onSessionEnded = nil
        mirrorSession?.stop()
        mirrorSession = nil
        isMirroring = false
        restorePresentationModeIfNeeded()
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        }
        startMirroringOverUSB(
            usbDevice,
            manual: true,
            wifiAddress: pairedPhones.first(where: { $0.resolvedUSBSerial == usbDevice.serial })?.resolvedWiFiAddress,
            prepareWirelessHandoff: true
        )
    }

    func prefillWirelessIPFromUSBDevice(_ usbDevice: AuthorizedADBDevice) async -> String? {
        let adb = self.adb
        let routeOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "ip", "route"], timeout: Self.wirelessHandoffRouteQueryTimeout)
        }.value
        guard let wifiIP = Self.wifiIPAddress(in: routeOutput) else { return nil }
        manualADBTarget = wifiIP
        return "\(wifiIP):\(Self.legacyADBWirelessPort)"
    }

    func readyUSBDeviceForMirroring(_ usbDevice: AuthorizedADBDevice) async -> AuthorizedADBDevice? {
        let adb = self.adb
        if let ready = await waitForSpecificUSBDevice(
            usbDevice,
            attempts: 2
        ) {
            return ready
        }

        Logger.log("USB device \(usbDevice.serial) appeared in adb devices but was not shell-ready; reconnecting only that transport before USB launch.")
        await Task.detached(priority: .userInitiated) {
            _ = adb.run(["-s", usbDevice.serial, "reconnect"], timeout: 3)
        }.value
        await adb.ensureServerStarted()

        if let ready = await waitForSpecificUSBDevice(
            usbDevice,
            attempts: 3
        ) {
            return ready
        }
        Logger.log("USB device \(usbDevice.serial) is still not shell-ready after its targeted reconnect.")
        return nil
    }

    func waitForSpecificUSBDevice(
        _ expectedDevice: AuthorizedADBDevice,
        attempts: Int,
        delayNanoseconds: UInt64 = 300_000_000
    ) async -> AuthorizedADBDevice? {
        let adb = self.adb
        var candidate = expectedDevice
        for attempt in 0..<max(1, attempts) {
            guard !Task.isCancelled else { return nil }
            if await Self.isADBDeviceShellReady(adb: adb, serial: candidate.serial) {
                return candidate
            }

            let output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
            let devices = Self.authorizedADBDevices(in: output)
            recordADBHealth(output, authorizedDevices: devices)
            guard let exactDevice = devices.first(where: {
                $0.isUSB && $0.serial == expectedDevice.serial
            }) else {
                if attempt + 1 < attempts {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                    continue
                }
                return nil
            }
            candidate = exactDevice
            if attempt + 1 < attempts {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        return nil
    }

    nonisolated static func isADBDeviceShellReady(
        adb: ADBController,
        serial: String,
        timeout: TimeInterval = 2
    ) async -> Bool {
        let sentinel = "phone-relay-usb-ok"
        let result = await Task.detached {
            adb.runResult(["-s", serial, "shell", "echo", sentinel], timeout: timeout)
        }.value
        guard result.succeeded else { return false }
        return result.output
            .split(whereSeparator: \.isNewline)
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == sentinel }
    }

    nonisolated static func adbShellReadinessFailed(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("device '\u{201c}")
            || lower.contains("device '")
            || lower.contains("not found")
            || lower.contains("offline")
            || lower.contains("unauthorized")
            || lower.contains("closed")
            || lower.contains("error:")
            || lower.contains("failed")
    }

    /// The pairing address from "Pair device with pairing code" must include an
    /// explicit port (the random pairing port) — there's no sensible default, so
    /// unlike the connect field we never fall back to 5555.
    nonisolated static func normalizedManualPairingAddress(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let separator = trimmed.lastIndex(of: ":")
        else { return nil }
        let hostPart = String(trimmed[..<separator])
        let portPart = String(trimmed[trimmed.index(after: separator)...])
        guard Self.isIPv4Address(hostPart),
              let port = Int(portPart),
              (1...65_535).contains(port)
        else { return nil }
        return "\(hostPart):\(port)"
    }

    /// Android's Wi-Fi pairing code is always six digits.
    nonisolated static func normalizedWirelessPairingCode(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else { return nil }
        return trimmed
    }

    /// Whether the entered IP:port + code are a valid pairing request.
    var canPairManualWirelessTarget: Bool {
        Self.normalizedManualPairingAddress(manualADBTarget) != nil
            && Self.normalizedWirelessPairingCode(manualWirelessPairingCode) != nil
    }

    /// Pairs with an Android 11+ Wireless-debugging device using the IP:port and
    /// 6-digit code from "Pair device with pairing code", then discovers the
    /// (separate) connect service over mDNS and mirrors — the same proven tail
    /// the QR-code flow uses, just driven by typed input instead of a scan.
    func pairManualWirelessTarget() {
        guard !isMirroring, !isPairing, !isManualWirelessPairing, !isManualADBTargetConnecting else { return }
        guard let pairAddress = Self.normalizedManualPairingAddress(manualADBTarget) else {
            reportError(
                "Enter the pairing IP and port",
                "Open \u{201C}Pair device with pairing code\u{201D} on the phone and type the IP address and port it shows, e.g. 192.168.1.23:37123."
            )
            return
        }
        guard let code = Self.normalizedWirelessPairingCode(manualWirelessPairingCode) else {
            reportError(
                "Enter the 6-digit pairing code",
                "Type the Wi-Fi pairing code shown next to the IP on the phone. It changes every time you open that screen."
            )
            return
        }

        resumeDiscoveryAfterManualConnect()
        connectionCoordinator.reconnectTask?.cancel()
        connectionCoordinator.usbConnectTask?.cancel()
        connectionCoordinator.cancelUSBWiFiHandoff()
        cancelWirelessReconnectWork()
        stopQRCodePairingSession()
        isPairing = true
        isManualWirelessPairing = true

        let adb = self.adb
        let generation = mirrorStartGeneration
        connectionCoordinator.reconnectTask = Task { [weak self] in
            await adb.ensureServerStarted()
            let pairOutput = await Task.detached {
                adb.run(["pair", pairAddress, code], timeout: 20)
            }.value
            guard let self, !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
            Logger.log("Manual Wi-Fi pairing address=\(pairAddress) output=\(pairOutput.trimmingCharacters(in: .whitespacesAndNewlines))")

            guard Self.adbPairSucceeded(pairOutput) else {
                self.failManualWirelessPairing(
                    "Pairing failed",
                    "Could not pair with \(pairAddress). Re-open \u{201C}Pair device with pairing code\u{201D} (the code changes each time), make sure the phone is on the same Wi-Fi, and try again."
                )
                return
            }
            self.manualWirelessPairingCode = ""

            guard let connectablePhone = await Self.waitForConnectableWirelessPhone(
                adb: adb,
                preferredAddress: nil,
                matchingHostOf: pairAddress
            ) else {
                guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
                self.failManualWirelessPairing(
                    "Paired, but no connection appeared",
                    "Paired with the phone, but its wireless-debugging connect service didn't show up. Keep the Wireless debugging screen open and try again."
                )
                return
            }
            guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }

            let connectOutput = await Task.detached {
                await Self.preflightLocalNetworkAccess(address: connectablePhone.address)
                return adb.run(["connect", connectablePhone.address])
            }.value
            guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }

            guard Self.adbConnectSucceeded(connectOutput) else {
                self.failManualWirelessPairing(
                    "Paired, but couldn't connect",
                    "Pairing succeeded, but connecting to \(connectablePhone.address) failed. Try connecting again."
                )
                return
            }

            let deviceName = await Self.connectedDeviceName(
                adb: adb,
                serial: connectablePhone.address,
                fallback: "Android device"
            )
            let hardwareSerial = await Self.connectedHardwareSerial(
                adb: adb,
                transportSerial: connectablePhone.address
            )
            guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
            let pairedPhone: DiscoveredPhone
            if !self.legacyWirelessCompatibilityEnabled {
                pairedPhone = connectablePhone
                self.manualADBTarget = connectablePhone.address
            } else {
                switch await Self.promoteToLegacyTCPIP(
                    adb: adb,
                    sourceSerial: connectablePhone.address,
                    preflightLocalNetworkAccess: { address in
                        await Self.preflightLocalNetworkAccess(address: address)
                    }
                ) {
                case .promoted(let legacyAddress):
                    pairedPhone = DiscoveredPhone(
                        id: legacyAddress,
                        address: legacyAddress,
                        kind: .connectable,
                        lastSeen: .now
                    )
                    self.manualADBTarget = Self.host(in: legacyAddress) ?? legacyAddress
                case .transportLost(let legacyAddress):
                    self.failManualWirelessPairing(
                        "Paired, but Wi-Fi is still starting",
                        "Pairing succeeded and Phone Relay prepared \(legacyAddress), but Android has not finished restarting wireless debugging. Wait a moment and try Wi-Fi again."
                    )
                    return
                case .unavailable:
                    pairedPhone = connectablePhone
                    self.manualADBTarget = connectablePhone.address
                }
            }

            self.connectionCoordinator.reconnectTask = nil
            self.isManualWirelessPairing = false
            self.finishQRCodePairing(
                with: pairedPhone,
                displayName: deviceName,
                hardwareSerial: hardwareSerial
            )
        }
    }

    func failManualWirelessPairing(_ title: String, _ message: String) {
        connectionCoordinator.reconnectTask = nil
        isPairing = false
        isManualWirelessPairing = false
        reportError(title, message)
        showConnectionWindow(startsQRCodePairing: false)
    }

    func connectManualADBTarget() {
        guard !isMirroring, !isPairing, !isManualADBTargetConnecting else { return }
        guard legacyWirelessCompatibilityEnabled else {
            reportError(
                "Legacy Wi-Fi compatibility is off",
                "An IP-only connection uses unencrypted ADB on port 5555. Enable legacy compatibility in Settings only if this phone cannot use secure Wireless debugging."
            )
            return
        }
        guard let address = Self.normalizedManualADBTarget(manualADBTarget) else {
            reportError("Invalid IP address", "Enter the phone IP address using numbers and dots, for example 192.168.1.23.")
            return
        }
        transportIntent = .manualWiFi
        let initialCandidateAddresses = Self.manualADBTargetCandidateAddresses(
            normalizedAddress: address,
            discoveredPhones: discoveredPhones,
            pairedPhones: pairedPhones
        )
        let matchedRecord = pairedRecord(matchingWirelessAddress: address)

        resumeDiscoveryAfterManualConnect()
        connectionCoordinator.reconnectTask?.cancel()
        connectionCoordinator.usbConnectTask?.cancel()
        connectionCoordinator.cancelUSBWiFiHandoff()
        cancelWirelessReconnectWork()
        stopQRCodePairingSession()
        if let matchedRecord {
            select(record: matchedRecord)
        }
        isPairing = true
        isManualADBTargetConnecting = true
        reconnectAttemptCount = 0

        let adb = self.adb
        let generation = mirrorStartGeneration
        let allowLegacyCompatibility = legacyWirelessCompatibilityEnabled
        connectionCoordinator.reconnectTask = Task { [weak self] in
            await adb.ensureServerStarted()
            var candidateAddresses = initialCandidateAddresses
            var result = await Self.connectToRememberedWirelessReadiness(
                adb: adb,
                savedAddress: address,
                candidateAddresses: candidateAddresses,
                allowLegacyCompatibility: allowLegacyCompatibility,
                readinessAttempts: 3,
                delayNanoseconds: 500_000_000,
                preflightLocalNetworkAccess: { target in
                    await Self.preflightLocalNetworkAccess(address: target)
                },
                maximumDuration: 6,
                connectTimeout: 4,
                shellTimeout: 2
            )
            if result.connectedAddress == nil {
                let freshPhones = await Task.detached { adb.connectableMDNSTargets() }.value
                guard let self, !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
                let refreshedCandidates = Self.manualADBTargetCandidateAddresses(
                    normalizedAddress: address,
                    discoveredPhones: freshPhones + self.discoveredPhones,
                    pairedPhones: self.pairedPhones
                )
                self.discoveredPhones = Self.mergedDiscoveredPhones(freshPhones + self.discoveredPhones)
                if refreshedCandidates != candidateAddresses {
                    candidateAddresses = refreshedCandidates
                    result = await Self.connectToRememberedWirelessReadiness(
                        adb: adb,
                        savedAddress: address,
                        candidateAddresses: candidateAddresses,
                        allowLegacyCompatibility: allowLegacyCompatibility,
                        readinessAttempts: 3,
                        delayNanoseconds: 500_000_000,
                        preflightLocalNetworkAccess: { target in
                            await Self.preflightLocalNetworkAccess(address: target)
                        },
                        maximumDuration: 6,
                        connectTimeout: 4,
                        shellTimeout: 2
                    )
                }
            }
            if result.sawNoRouteToHost {
                Logger.log("Manual ADB connect to \(address) failed with only 'No route to host'; restarting adb server once before surfacing failure.")
                await Task.detached(priority: .userInitiated) {
                    _ = adb.run(["kill-server"], timeout: 3)
                }.value
                await adb.ensureServerStarted()
                result = await Self.connectToRememberedWirelessReadiness(
                    adb: adb,
                    savedAddress: address,
                    candidateAddresses: candidateAddresses,
                    allowLegacyCompatibility: allowLegacyCompatibility,
                    readinessAttempts: 3,
                    delayNanoseconds: 500_000_000,
                    preflightLocalNetworkAccess: { target in
                        await Self.preflightLocalNetworkAccess(address: target)
                    },
                    maximumDuration: 6,
                    connectTimeout: 4,
                    shellTimeout: 2
                )
            }

            guard let self, !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
            self.connectionCoordinator.reconnectTask = nil
            self.isPairing = false

            guard let connectedAddress = result.connectedAddress else {
                self.isManualADBTargetConnecting = false
                self.isRecoveringConnection = false
                self.isAwaitingReconnect = false
                self.transportIntent = .automatic
                if result.sawNoRouteToHost {
                    self.presentLocalNetworkPermissionHint()
                    self.reportError(
                        "Local Network may be blocked",
                        "Could not reach \(address) after restarting adb. Allow Phone Relay in System Settings > Privacy & Security > Local Network, then try again."
                    )
                    self.showConnectionWindow(startsQRCodePairing: false)
                    return
                }
                self.reportError(
                    Self.wifiConnectionNotReadyErrorTitle,
                    matchedRecord.map {
                        "Phone Relay could not reach \($0.displayName) at \(address) yet and will keep checking in the background. Keep the phone awake and on the same Wi-Fi, then try again. Use USB only if repeated attempts continue to fail."
                    } ?? "Phone Relay could not reach \(address) yet. Keep the phone awake, on the same Wi-Fi, and make sure Wireless debugging is enabled. Try again or pair with QR; use USB only if the problem continues."
                )
                self.showConnectionWindow(startsQRCodePairing: false)
                return
            }

            let deviceName = await Self.connectedDeviceName(
                adb: adb,
                serial: connectedAddress,
                fallback: "Android device"
            )
            self.selectedDevice = MirrorDevice(
                id: connectedAddress,
                name: deviceName,
                model: "Android",
                battery: self.selectedDevice.battery,
                isCharging: self.selectedDevice.isCharging,
                network: "Manual ADB",
                lastSeen: .now,
                states: [.mirroringReady, .companionConnected],
                adbSerial: connectedAddress
            )
            self.isSelectedDeviceOnline = true
            self.touchPairedPhone(
                id: connectedAddress,
                displayName: deviceName,
                address: connectedAddress,
                wifiAddress: connectedAddress
            )
            self.manualADBTarget = Self.host(in: connectedAddress) ?? self.manualADBTarget
            self.isManualADBTargetConnecting = false
            self.isRecoveringConnection = true
            self.isAwaitingReconnect = false
            self.startMirroring(manual: true)
        }
    }

    func startMirroringOverUSB(
        _ device: AuthorizedADBDevice,
        manual: Bool,
        wifiAddress: String? = nil,
        prepareWirelessHandoff: Bool = true
    ) {
        connectionCoordinator.cancelUSBWiFiHandoff()
        cancelWirelessReconnectWork()
        isPairing = false
        select(device: device)
        touchPairedPhone(
            id: device.serial,
            displayName: selectedDisplayName(for: device.model),
            address: device.serial,
            usbSerial: device.serial,
            observedWiFiIPAddress: wifiAddress.flatMap(Self.host)
        )
        stopQRCodePairingSession()
        startMirroring(manual: manual)
        if prepareWirelessHandoff {
            prepareWirelessHandoffInBackground(
                from: device,
                activatePreparedMirror: false
            )
        }
    }

    /// Minimum gap between cable-arrival arm attempts for the same phone. Long
    /// enough that `adb tcpip`'s own adbd restart — which makes the USB serial
    /// disappear and come back, i.e. a fresh "plug-in" edge — cannot loop us.
    nonisolated static let wirelessArmRetryInterval: TimeInterval = 60

    /// Pure decision: may this USB serial be armed for Wi-Fi right now?
    nonisolated static func shouldArmWirelessForUSBSerial(
        _ serial: String,
        seenSerials: Set<String>,
        lastAttemptAt: Date?,
        now: Date = Date(),
        retryInterval: TimeInterval = wirelessArmRetryInterval
    ) -> Bool {
        guard !seenSerials.contains(serial) else { return false }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= retryInterval
    }

    /// Keeps attach-edge bookkeeping aligned with the USB transports that are
    /// actually present. A detached serial becomes eligible when it returns,
    /// while only the serial whose arm starts is marked as handled.
    nonisolated static func reconciledWirelessArmSeenSerials(
        previouslySeen: Set<String>,
        attachedSerials: Set<String>,
        startingSerial: String? = nil
    ) -> Set<String> {
        var reconciled = previouslySeen.intersection(attachedSerials)
        if let startingSerial {
            reconciled.insert(startingSerial)
        }
        return reconciled
    }

    /// Re-arms `adb tcpip 5555` the moment a cable appears, *without* starting a
    /// mirror.
    ///
    /// `tcpip` mode dies on every phone reboot and can only be switched back on
    /// over USB. Until now the app re-armed it solely as a side effect of the
    /// configure-first USB mirror path, so a phone that was merely plugged in —
    /// to charge, while manually disconnected, or while USB mirroring is pinned
    /// — never regained its Wi-Fi route, and the next cable-free session found
    /// nothing on the LAN. Arming on the plug-in edge makes "plug in for two
    /// seconds, unplug" the whole recovery procedure.
    ///
    /// Deliberately silent: no window, no mirror, no status change. It yields to
    /// every other connection workflow, and to a live mirror above all — `adb
    /// tcpip` restarts adbd and would drop it (INVARIANTS.md rule 3).
    func armWirelessDebuggingForAttachedUSB(authorized: [AuthorizedADBDevice]) {
        // Cable-arrival arming exists only for the unencrypted Android 10-era
        // compatibility transport. Secure Wireless debugging is discovered
        // and connected without restarting adbd.
        guard legacyWirelessCompatibilityEnabled else {
            wirelessArmSeenUSBSerials.removeAll()
            return
        }
        let usbSerials = Set(authorized.filter(\.isUSB).map(\.serial))
        wirelessArmSeenUSBSerials = Self.reconciledWirelessArmSeenSerials(
            previouslySeen: wirelessArmSeenUSBSerials,
            attachedSerials: usbSerials
        )

        // A mirror (or anything else that owns adb) makes this unsafe or
        // redundant: the normal handoff already arms Wi-Fi on the paths that
        // start a session. Note these guards deliberately do *not* mark the
        // serials as seen — a cable plugged in mid-session still deserves its
        // arm once the session ends and nothing else owns adb.
        guard backgroundServicesEnabled,
              !isFirstRunOnboardingActive,
              !isMirroring,
              mirrorSession == nil,
              mirrorLaunchTask == nil,
              !isPairing,
              !connectionCoordinator.hasManualConnectionWorkInFlight,
              connectionCoordinator.disconnectRecoveryTask == nil,
              connectionCoordinator.qrPairingTask == nil
        else { return }

        let now = Date()
        guard let serial = usbSerials.sorted().first(where: { candidate in
            // A user who explicitly asked for *this* cable keeps it: `tcpip`
            // would take the USB transport away underneath their choice.
            guard transportIntent.permitsPreparedWiFiTakeover(for: candidate) else { return false }
            return Self.shouldArmWirelessForUSBSerial(
                candidate,
                seenSerials: wirelessArmSeenUSBSerials,
                lastAttemptAt: lastWirelessArmAttemptAt[candidate],
                now: now
            ) && !connectionCoordinator.isLegacyHandoffCoolingDown(serial: candidate, now: now)
        }) else { return }
        guard let device = authorized.first(where: { $0.isUSB && $0.serial == serial }) else { return }

        // An automatic reconnect that is merely parked in backoff used to keep
        // this arm from ever running: its task stays alive between retries, so
        // the old `automaticReconnectTask == nil` guard starved the cable for
        // the lifetime of a failing route — exactly the state a plug-in is
        // meant to fix. A *failing* reconnect (refused dials, swept-and-silent
        // LAN) is cancelled here so `tcpip` can be re-armed over USB; a healthy
        // one keeps the wire and the arm simply retries on a later poll.
        let hasAutomaticReconnectWork = connectionCoordinator.automaticReconnectTask != nil
            || isRecoveringConnection
            || isAwaitingReconnect
        if hasAutomaticReconnectWork {
            guard isWirelessRouteFailing(forSerial: serial) else { return }
            Logger.log("Cable arrived for \(serial); cancelling failing wireless reconnect so tcpip can be re-armed over USB")
            cancelWirelessReconnectWork()
        }

        // Mark only the arm that actually starts. Other attached phones remain
        // eligible on the next poll, and this serial becomes eligible again
        // after a real detach/replug edge (subject to the retry interval).
        wirelessArmSeenUSBSerials = Self.reconciledWirelessArmSeenSerials(
            previouslySeen: wirelessArmSeenUSBSerials,
            attachedSerials: usbSerials,
            startingSerial: serial
        )

        lastWirelessArmAttemptAt[serial] = now
        let handoffGeneration = connectionCoordinator.beginUSBWiFiHandoff()
        connectionCoordinator.usbWiFiHandoffTask = Task { [weak self] in
            guard let self else { return }
            Logger.log("Cable arrived for \(serial); arming Wi-Fi (tcpip \(Self.legacyADBWirelessPort)) without starting a mirror")
            let armed = await self.prepareWirelessMirror(
                from: device,
                activatePreparedMirror: false,
                armWirelessWithoutMirroring: true,
                handoffGeneration: handoffGeneration
            )
            let recoveryAddress = self.usbWiFiHandoffCandidate.flatMap { candidate in
                candidate.usbSerial == device.serial ? candidate.address : nil
            }
            guard self.connectionCoordinator.isCurrentUSBWiFiHandoff(handoffGeneration) else { return }
            self.connectionCoordinator.finishUSBWiFiHandoff(handoffGeneration)
            self.connectionCoordinator.usbWiFiHandoffTask = nil

            if armed {
                Logger.log("Cable arm succeeded for \(serial); Wi-Fi route is ready and remembered")
                self.clearWirelessListenerMissingState(usbSerial: serial)
                return
            }

            // `adb tcpip` may have dropped the cable on its way to a failed
            // verification. Put adbd back on USB so the user still has the
            // transport they physically plugged in (INVARIANTS.md rule 3).
            Logger.log("Cable arm did not produce a ready Wi-Fi route for \(serial); restoring USB")
            _ = await self.restoreUSBTransportAfterFailedHandoff(
                device,
                wirelessAddress: recoveryAddress
            )
        }
    }

    /// A phone that just proved it can do adb over Wi-Fi is no longer "listener
    /// missing" — drop the verdict and retire the message that told the user to
    /// plug in.
    func clearWirelessListenerMissingState(usbSerial: String) {
        let recordIDs = pairedPhones
            .filter { $0.resolvedUSBSerial == usbSerial || $0.id == usbSerial }
            .map(\.id)
        for id in recordIDs {
            wirelessListenerMissingRecordIDs.remove(id)
        }
        if activeError?.title == Self.wifiListenerMissingErrorTitle {
            activeError = nil
        }
    }

    func prepareWirelessHandoffInBackground(
        from device: AuthorizedADBDevice,
        activatePreparedMirror: Bool = false
    ) {
        let handoffGeneration = connectionCoordinator.beginUSBWiFiHandoff()
        let mirrorGeneration = mirrorStartGeneration
        connectionCoordinator.usbWiFiHandoffTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self else { return }
            guard !Task.isCancelled,
                  self.connectionCoordinator.isCurrentUSBWiFiHandoff(handoffGeneration),
                  self.mirrorStartGeneration == mirrorGeneration,
                  self.isMirroring || self.mirrorLaunchTask != nil
            else {
                self.connectionCoordinator.finishUSBWiFiHandoff(handoffGeneration)
                return
            }
            Logger.log("Preparing USB Wi-Fi handoff in background for \(device.serial)")
            let prepared = await self.prepareWirelessMirror(
                from: device,
                activatePreparedMirror: activatePreparedMirror,
                handoffGeneration: handoffGeneration,
                mirrorGeneration: mirrorGeneration
            )
            guard !Task.isCancelled,
                  self.connectionCoordinator.isCurrentUSBWiFiHandoff(handoffGeneration),
                  self.mirrorStartGeneration == mirrorGeneration else {
                self.connectionCoordinator.finishUSBWiFiHandoff(handoffGeneration)
                return
            }
            self.connectionCoordinator.finishUSBWiFiHandoff(handoffGeneration)
            if case .manualUSB(let serial) = self.transportIntent,
               serial == device.serial {
                self.transportIntent = .automatic
            }
            if !prepared {
                self.noteConnectionStall(
                    .handoffNotReady,
                    detail: "Background Wi-Fi handoff for \(device.serial) found no reachable wireless route; USB mirroring is unaffected."
                )
            }
        }
    }

    func mostRecentPairedPhone(in phones: [DiscoveredPhone]) -> DiscoveredPhone? {
        let allowedPhones = phones.filter {
            legacyWirelessCompatibilityEnabled
                || ($0.kind != .legacyTCPIP && !Self.isLegacyWirelessAddress($0.address))
        }
        let records = Self.recordsByMostRecent(autoConnectEligiblePairedPhones)
            .filter(Self.isWirelessRecord)
        let allowSingleCandidateFallback = records.count == 1
        for record in records {
            if let phone = Self.rememberedConnectablePhone(
                for: record,
                in: allowedPhones,
                allowSingleCandidateFallback: allowSingleCandidateFallback
            ) {
                return phone
            }
        }
        return nil
    }

    func autoConnectablePhones(in phones: [DiscoveredPhone]) -> [DiscoveredPhone] {
        let now = Date()
        failedAutoConnectTargets = failedAutoConnectTargets.filter { _, failedAt in
            Self.isAutoConnectFailureCoolingDown(
                failedAt: failedAt,
                now: now,
                cooldown: Self.autoConnectFailureCooldown
            )
        }
        return phones.filter { phone in
            guard legacyWirelessCompatibilityEnabled
                    || (phone.kind != .legacyTCPIP && !Self.isLegacyWirelessAddress(phone.address))
            else { return false }
            guard let failedAt = failedAutoConnectTargets[phone.address] else { return true }
            return !Self.isAutoConnectFailureCoolingDown(
                failedAt: failedAt,
                now: now,
                cooldown: Self.autoConnectFailureCooldown
            )
        }
    }

    func noteAutoConnectFailure(for phone: DiscoveredPhone) {
        noteAutoConnectFailure(address: phone.address)
    }

    func noteAutoConnectFailure(address: String) {
        failedAutoConnectTargets[address] = Date()
    }

    func updateUSBAuthorizationHint(
        from output: String,
        authorizedDevices: [AuthorizedADBDevice]
    ) {
        guard authorizedDevices.isEmpty,
              Self.hasUnauthorizedUSBDevice(in: output),
              !hasShownUSBAuthorizationHint,
              !isMirroring
        else { return }
        hasShownUSBAuthorizationHint = true
        reportUSBNotAuthorized()
    }

    func reportUSBNotAuthorized() {
        reportError(
            "Authorize USB debugging",
            "The phone is plugged in, but Android has not authorized this Mac yet. Unlock the phone and tap Allow on the USB debugging prompt, or use Wi-Fi debugging if it is already enabled."
        )
    }

    func isAutoConnectAddressCoolingDown(_ address: String) -> Bool {
        guard let failedAt = failedAutoConnectTargets[address] else { return false }
        return Self.isAutoConnectFailureCoolingDown(failedAt: failedAt)
    }

    func applyADBOutput(_ output: String) {
        let devices = Self.devicesAvailableForCurrentPath(
            Self.authorizedADBDevices(in: output),
            isPathLossConfirmed: isNetworkPathLossConfirmed
        )
        recordADBHealth(output, authorizedDevices: devices)
        guard let first = devices.first else {
            selectedDevice.states = [.wirelessDebuggingRequired, .usbAuthorizationRequired, .companionConnected]
            isSelectedDeviceOnline = false
            return
        }

        select(device: first)
    }

    func select(device: AuthorizedADBDevice) {
        isSelectedDeviceOnline = true
        selectedDevice = MirrorDevice(
            id: device.serial,
            name: device.model,
            model: device.product,
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: device.isUSB ? "USB debugging" : "Wi-Fi",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: device.serial
        )
    }

    func select(record: PairedPhoneRecord) {
        isSelectedDeviceOnline = false
        selectedDevice = MirrorDevice(
            id: record.id,
            name: record.displayName,
            model: "Android",
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: Self.isWirelessRecord(record) ? "Wi-Fi" : "USB debugging",
            lastSeen: record.lastConnected,
            states: [.wirelessDebuggingRequired, .companionConnected],
            adbSerial: record.resolvedWiFiAddress ?? record.resolvedUSBSerial ?? record.lastAddress
        )
    }

    func pairedRecord(matchingWirelessAddress address: String) -> PairedPhoneRecord? {
        pairedPhones.first { record in
            guard Self.isWirelessRecord(record) else { return false }
            return Self.wirelessADBAddress(record.resolvedWiFiAddress, matches: address)
                || Self.wirelessADBAddress(record.lastAddress, matches: address)
        }
    }

    func applyDevicePresence(_ output: String) {
        let devices = Self.devicesAvailableForCurrentPath(
            Self.authorizedADBDevices(in: output),
            isPathLossConfirmed: isNetworkPathLossConfirmed
        )
        recordADBHealth(output, authorizedDevices: devices)
        prefillWirelessRouteForPresentUSBDeviceIfNeeded(devices)
        if explicitDeviceSetupRequired,
           let usbDevice = devices.first(where: \.isUSB) {
            select(device: usbDevice)
            return
        }
        guard !explicitDeviceSetupRequired else {
            selectedDevice = .demo
            isSelectedDeviceOnline = false
            return
        }
        guard let serial = selectedDevice.adbSerial else {
            // Nothing selected yet (e.g. fresh onboarding). Adopt the first live
            // device so a working USB/wireless connection advances the UI out of
            // first-run instead of leaving it pinned to the onboarding window.
            if let liveDevice = devices.first {
                select(device: liveDevice)
                rememberLiveAuthorizedDeviceIfNeeded(liveDevice)
                return
            }
            selectedDevice = .demo
            isSelectedDeviceOnline = false
            return
        }

        guard let liveDevice = Self.liveSelectedOrRememberedDevice(
            selectedSerial: serial,
            pairedPhones: pairedPhones,
            authorizedDevices: devices
        ) else {
            isSelectedDeviceOnline = false
            if selectedDevice.states.contains(.mirroringReady) {
                selectedDevice.states = [.wirelessDebuggingRequired, .companionConnected]
            }
            return
        }

        isSelectedDeviceOnline = true
        selectedDevice = MirrorDevice(
            id: liveDevice.serial,
            name: liveDevice.model,
            model: liveDevice.product,
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: liveDevice.isUSB ? "USB debugging" : "Wi-Fi",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: liveDevice.serial
        )
        rememberLiveAuthorizedDeviceIfNeeded(liveDevice)

    }

    func prefillWirelessRouteForPresentUSBDeviceIfNeeded(_ devices: [AuthorizedADBDevice]) {
        guard let usbDevice = devices.first(where: \.isUSB) else {
            connectionCoordinator.usbWiFiAddressPrefillTask?.cancel()
            connectionCoordinator.usbWiFiAddressPrefillTask = nil
            lastUSBWiFiAddressPrefillSerial = nil
            lastUSBWiFiAddressPrefillAt = nil
            return
        }
        guard connectionCoordinator.usbWiFiAddressPrefillTask == nil else { return }
        guard Self.shouldRefreshUSBWiFiAddressPrefill(
            lastSerial: lastUSBWiFiAddressPrefillSerial,
            currentSerial: usbDevice.serial,
            lastPrefillAt: lastUSBWiFiAddressPrefillAt
        ) else { return }

        let isRefresh = lastUSBWiFiAddressPrefillSerial == usbDevice.serial
        lastUSBWiFiAddressPrefillSerial = usbDevice.serial
        lastUSBWiFiAddressPrefillAt = Date()
        let adb = self.adb
        connectionCoordinator.usbWiFiAddressPrefillTask = Task { [weak self] in
            let routeOutput = await Task.detached {
                adb.run(["-s", usbDevice.serial, "shell", "ip", "route"], timeout: Self.wirelessHandoffRouteQueryTimeout)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.connectionCoordinator.usbWiFiAddressPrefillTask = nil

            guard let wifiIP = Self.wifiIPAddress(in: routeOutput) else {
                self.lastUSBWiFiAddressPrefillSerial = nil
                self.lastUSBWiFiAddressPrefillAt = nil
                return
            }
            let matchingRecord = self.pairedPhones.first {
                Self.recordMatchesSelectedADBSerial($0, selectedSerial: usbDevice.serial)
                    || PairedPhoneStore.normalizedDeviceName($0.displayName)
                        == PairedPhoneStore.normalizedDeviceName(usbDevice.model)
            }
            // A same-cable refresh that learned nothing new ends here, so the
            // periodic re-read doesn't clobber the manual-target field or
            // rewrite the store every interval. A missing MAC still falls
            // through: it's the anchor recovery needs, worth re-resolving.
            if isRefresh,
               let matchingRecord,
               matchingRecord.observedWiFiIPAddress == wifiIP,
               matchingRecord.wifiMACAddress != nil {
                return
            }
            self.manualADBTarget = wifiIP

            // An IP learned from `ip route` is observation metadata, not proof
            // that an ADB listener exists at :5555. Keep it for matching and
            // recovery without replacing the last verified endpoint.
            let recordID = matchingRecord?.id ?? usbDevice.serial
            let recordDisplayName = matchingRecord?.displayName ?? self.selectedDisplayName(for: usbDevice.model)
            let recordUSBSerial = matchingRecord?.resolvedUSBSerial ?? usbDevice.serial
            self.touchPairedPhone(
                id: recordID,
                displayName: recordDisplayName,
                address: usbDevice.serial,
                usbSerial: recordUSBSerial,
                observedWiFiIPAddress: wifiIP
            )

            // Learn the Wi-Fi MAC while we have the cable — it's the anchor that
            // lets recovery find the phone after its IP changes.
            let wifiMAC = await Task.detached {
                Self.resolveWiFiMACAddress(adb: adb, serial: usbDevice.serial, routeOutput: routeOutput)
            }.value
            guard !Task.isCancelled, let wifiMAC else { return }

            self.touchPairedPhone(
                id: recordID,
                displayName: recordDisplayName,
                address: usbDevice.serial,
                usbSerial: recordUSBSerial,
                observedWiFiIPAddress: wifiIP,
                wifiMACAddress: wifiMAC
            )
        }
    }

    func rememberLiveAuthorizedDeviceIfNeeded(_ device: AuthorizedADBDevice) {
        guard !explicitDeviceSetupRequired else { return }
        guard device.isUSB else {
            verifyAndPersistLiveWirelessDeviceIfNeeded(device)
            return
        }
        let alreadyRemembered = pairedPhones.contains { record in
            Self.recordMatchesSelectedADBSerial(record, selectedSerial: device.serial)
                || Self.rememberedAuthorizedDevice(for: record, in: [device]) != nil
        }
        guard !alreadyRemembered else { return }

        touchPairedPhone(
            id: device.serial,
            displayName: selectedDisplayName(for: device.model),
            address: device.serial,
            usbSerial: device.serial,
            wifiAddress: nil
        )
    }

    /// An `adb devices` row can remain `device` briefly after a wireless route
    /// has died. Never turn that observation into preferred persistent state
    /// until the exact serial passes a fresh shell sentinel.
    func verifyAndPersistLiveWirelessDeviceIfNeeded(_ device: AuthorizedADBDevice) {
        guard !device.isUSB, Self.isWirelessADBTarget(device.serial) else { return }
        guard connectionCoordinator.wirelessRouteVerificationTask == nil else { return }

        let matchingRecord = pairedPhones.first { record in
            Self.recordMatchesSelectedDevice(record, selectedDevice: selectedDevice)
                || Self.wirelessADBAddress(record.resolvedWiFiAddress, matches: device.serial)
        }
        let currentFingerprint = WiFiAddressRecovery.currentNetworkFingerprint()
        if matchingRecord?.resolvedWiFiAddress == device.serial,
           matchingRecord?.wifiAddressLastVerifiedAt != nil,
           matchingRecord?.wifiNetworkFingerprint == currentFingerprint {
            return
        }

        let verificationGeneration = connectionCoordinator.beginWirelessRouteVerification()
        let mirrorGeneration = mirrorStartGeneration
        let recordID = matchingRecord?.id ?? device.serial
        let adb = self.adb
        connectionCoordinator.wirelessRouteVerificationTask = Task { [weak self] in
            let ready = await Self.isADBDeviceShellReady(
                adb: adb,
                serial: device.serial,
                timeout: Self.wirelessHandoffShellTimeout
            )
            guard let self else { return }
            guard self.connectionCoordinator.isCurrentWirelessRouteVerification(
                verificationGeneration
            ) else { return }
            self.connectionCoordinator.finishWirelessRouteVerification(
                verificationGeneration
            )
            guard !Task.isCancelled,
                  self.mirrorStartGeneration == mirrorGeneration,
                  ready,
                  !self.explicitDeviceSetupRequired,
                  self.latestAuthorizedADBDevices.contains(where: {
                    !$0.isUSB && $0.serial == device.serial
                  }) else { return }

            let currentRecord = self.pairedPhones.first { record in
                record.id == recordID
                    || Self.recordMatchesSelectedDevice(
                        record,
                        selectedDevice: self.selectedDevice
                    )
            }
            Logger.log("Persisting shell-verified Wi-Fi route \(device.serial) for \(recordID)")
            self.touchPairedPhone(
                id: currentRecord?.id ?? recordID,
                displayName: currentRecord?.displayName
                    ?? self.selectedDisplayName(for: device.model),
                address: device.serial,
                usbSerial: currentRecord?.resolvedUSBSerial,
                wifiAddress: device.serial,
                wifiMACAddress: currentRecord?.wifiMACAddress
            )
        }
    }

    nonisolated static func authorizedADBDevices(in output: String) -> [AuthorizedADBDevice] {
        output
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let lower = trimmed.lowercased()
                guard !trimmed.isEmpty,
                      !lower.hasPrefix("list of devices"),
                      !lower.hasPrefix("* daemon")
                else {
                    return nil
                }

                let fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count >= 2,
                      fields[1] == "device",
                      let serial = fields.first
                else {
                    return nil
                }
                let product = value(after: "product:", in: line) ?? "Android"
                let model = value(after: "model:", in: line)?
                    .replacingOccurrences(of: "_", with: " ") ?? "Android device"
                return AuthorizedADBDevice(
                    serial: serial,
                    product: product,
                    model: model,
                    isUSB: line.contains("usb:")
                )
            }
    }

    nonisolated static func hasUnauthorizedUSBDevice(in output: String) -> Bool {
        output
            .split(separator: "\n")
            .map(String.init)
            .contains { line in
                let lower = line.lowercased()
                return lower.contains("unauthorized") && lower.contains("usb:")
            }
    }

    func recordADBHealth(
        _ output: String,
        authorizedDevices: [AuthorizedADBDevice]? = nil
    ) {
        let devices = authorizedDevices ?? Self.authorizedADBDevices(in: output)
        latestAuthorizedADBDevices = devices
        latestHasUnauthorizedUSBDevice = Self.hasUnauthorizedUSBDevice(in: output)
        latestADBStatusText = Self.adbStatusText(output: output, authorizedDevices: devices)
    }

    nonisolated static func adbStatusText(
        output: String,
        authorizedDevices: [AuthorizedADBDevice]
    ) -> String {
        if Tooling.toolPath(named: "adb") == nil {
            return "adb missing"
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "No response"
        }
        let lower = trimmed.lowercased()
        if lower.contains("error") || lower.contains("cannot connect") || lower.contains("failed") {
            return "adb error"
        }
        if !authorizedDevices.isEmpty {
            return "Running"
        }
        if hasUnauthorizedUSBDevice(in: output) {
            return "Waiting for authorization"
        }
        return "Running, no device"
    }

    nonisolated static func singleConnectableRecoveryCandidate(
        in phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind.isConnectable }
        guard connectablePhones.count == 1 else { return nil }
        return connectablePhones[0]
    }

    nonisolated static func shouldAttemptWirelessHandoff(
        from device: AuthorizedADBDevice,
        preferUSBMirroring: Bool,
        backgroundWiFiHandoffEnabled: Bool = true,
        hasSavedDevices: Bool = true
    ) -> Bool {
        // The extra arguments remain for source compatibility. Handoff is now
        // an invariant: every authorized USB connection refreshes and prepares
        // Wi-Fi, including an explicit Connect with USB action.
        _ = preferUSBMirroring
        _ = backgroundWiFiHandoffEnabled
        _ = hasSavedDevices
        return device.isUSB
    }

    enum ScrcpyStyleConnectionPlan: Equatable {
        case manualTCPIP(address: String)
        case usb(serial: String)
        case usbPromoteToTCPIP(serial: String)
        case wireless(serial: String)
        case none
    }

    nonisolated static func normalizedManualADBTarget(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !trimmed.contains(":"),
              Self.isIPv4Address(trimmed)
        else { return nil }

        return "\(trimmed):\(legacyADBWirelessPort)"
    }

    nonisolated static func manualADBTargetCandidateAddresses(
        normalizedAddress: String,
        discoveredPhones: [DiscoveredPhone],
        pairedPhones: [PairedPhoneRecord]
    ) -> [String] {
        [normalizedAddress]
    }

    nonisolated static func manualADBTargetPortScanCandidateAddresses(
        host: String,
        ports: [Int],
        existingCandidates: [String]
    ) -> [String] {
        var candidates = existingCandidates
        for port in ports where (1...65_535).contains(port) {
            let address = "\(host):\(port)"
            if !candidates.contains(address) {
                candidates.append(address)
            }
        }
        return candidates
    }

    nonisolated static func scanLikelyWirelessDebuggingPorts(
        host: String,
        ports: ClosedRange<Int> = 30_000...49_999,
        concurrency: Int = 256,
        timeout: TimeInterval = 0.16
    ) async -> [Int] {
        guard isIPv4Address(host), !ports.isEmpty else { return [] }
        let portList = Array(ports)
        var nextIndex = 0
        var openPorts: [Int] = []

        await withTaskGroup(of: (Int, Bool).self) { group in
            func enqueueNext() {
                guard nextIndex < portList.count else { return }
                let port = portList[nextIndex]
                nextIndex += 1
                group.addTask {
                    let isOpen = await WiFiAddressRecovery.isPortOpen(
                        host: host,
                        port: port,
                        timeout: timeout
                    )
                    return (port, isOpen)
                }
            }

            for _ in 0..<min(max(1, concurrency), portList.count) {
                enqueueNext()
            }
            for await (port, isOpen) in group {
                if isOpen { openPorts.append(port) }
                enqueueNext()
            }
        }
        return openPorts.sorted()
    }

    nonisolated static func mergedDiscoveredPhones(_ phones: [DiscoveredPhone]) -> [DiscoveredPhone] {
        var byID: [String: DiscoveredPhone] = [:]
        var order: [String] = []
        for phone in phones {
            if byID[phone.id] == nil {
                order.append(phone.id)
                byID[phone.id] = phone
                continue
            }
            if let current = byID[phone.id],
               phone.lastSeen >= current.lastSeen || (phone.kind.isConnectable && !current.kind.isConnectable) {
                byID[phone.id] = phone
            }
        }
        return order.compactMap { byID[$0] }
    }

    nonisolated static func isIPv4Address(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let value = Int(part)
            else { return false }
            return (0...255).contains(value)
        }
    }

    nonisolated static func canSubmitPairingCode(address: String, code: String) -> Bool {
        normalizedPairingCodeAddress(address) != nil && normalizedPairingCode(code) != nil
    }

    nonisolated static func normalizedPairingCodeAddress(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              port(in: trimmed) != nil,
              host(in: trimmed)?.isEmpty == false
        else { return nil }
        return trimmed
    }

    nonisolated static func normalizedPairingCode(_ code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6,
              trimmed.allSatisfy(\.isNumber)
        else { return nil }
        return trimmed
    }

    nonisolated static func scrcpyStyleConnectionPlan(
        authorizedDevices: [AuthorizedADBDevice],
        preferUSBMirroring: Bool,
        manualTarget: String?
    ) -> ScrcpyStyleConnectionPlan {
        if let manualTarget,
           let address = normalizedManualADBTarget(manualTarget) {
            return .manualTCPIP(address: address)
        }
        if let usbDevice = authorizedDevices.first(where: \.isUSB) {
            return preferUSBMirroring
                ? .usb(serial: usbDevice.serial)
                : .usbPromoteToTCPIP(serial: usbDevice.serial)
        }
        if let wirelessDevice = authorizedDevices.first(where: { !$0.isUSB }) {
            return .wireless(serial: wirelessDevice.serial)
        }
        return .none
    }

    nonisolated static func scrcpyStyleAutoConnectDevice(
        authorizedDevices: [AuthorizedADBDevice],
        pairedPhones: [PairedPhoneRecord],
        preferUSBMirroring: Bool
    ) -> AuthorizedADBDevice? {
        guard !authorizedDevices.isEmpty else { return nil }
        if preferUSBMirroring {
            return authorizedDevices.first(where: \.isUSB) ?? authorizedDevices.first
        }

        for record in recordsByMostRecent(pairedPhones) {
            if let device = rememberedAuthorizedDevice(for: record, in: authorizedDevices) {
                return device
            }
        }

        return authorizedDevices.first(where: { !$0.isUSB }) ?? authorizedDevices.first
    }

    /// The transport to reconnect on after a manual disconnect, or `nil` to stay
    /// paused. A transport counts as "re-discovered" only when it is *not* among
    /// the serials known to be online when the user disconnected (or that have
    /// stayed online since) — i.e. a cable that was just replugged or a Wi-Fi
    /// route that dropped and came back. When both routes for the selected phone
    /// reappear together, Wi-Fi wins. Routes belonging to other phones are not
    /// allowed to resume the selected phone's paused session.
    nonisolated static func manualDisconnectResumeDevice(
        authorizedDevices: [AuthorizedADBDevice],
        knownSerials: Set<String>,
        selectedDevice: MirrorDevice? = nil,
        pairedPhones: [PairedPhoneRecord] = []
    ) -> AuthorizedADBDevice? {
        let reappeared = authorizedDevices.filter { !knownSerials.contains($0.serial) }
        if let selectedDevice,
           let record = recordsByMostRecent(pairedPhones).first(where: {
               recordMatchesSelectedDevice($0, selectedDevice: selectedDevice)
           }) {
            if let wireless = liveWirelessAuthorizedDevice(for: record, in: reappeared) {
                return wireless
            }
            return liveUSBAuthorizedDevice(for: record, in: reappeared)
        }
        if let selectedDevice {
            let selectedSerial = selectedDevice.adbSerial
            return reappeared.first {
                $0.serial == selectedSerial || $0.serial == selectedDevice.id
            }
        }
        return reappeared.first(where: { !$0.isUSB }) ?? reappeared.first
    }

    nonisolated static func usbHandoffCandidate(
        in devicesOutput: String,
        lastAttemptedSerial: String?
    ) -> AuthorizedADBDevice? {
        guard let usbDevice = authorizedADBDevices(in: devicesOutput).first(where: \.isUSB),
              usbDevice.serial != lastAttemptedSerial
        else { return nil }
        return usbDevice
    }

    nonisolated static func shouldPrioritizeUSBHandoff(
        authorizedDevices: [AuthorizedADBDevice],
        lastAttemptedSerial: String?,
        preferUSBMirroring: Bool,
        isMirroring: Bool,
        isPairing: Bool,
        failingWirelessSerials: Set<String> = []
    ) -> Bool {
        guard !preferUSBMirroring, !isMirroring, !isPairing else {
            return false
        }
        // A live wireless transport keeps Wi-Fi first. A *provably failing*
        // one (dead listener, refused dials) must not veto the USB handoff —
        // otherwise a stale or dying wireless entry pins the policy forever
        // and plugging in the cable does nothing.
        guard !authorizedDevices.contains(where: { device in
            !device.isUSB && !failingWirelessSerials.contains(device.serial)
        }) else {
            return false
        }
        return authorizedDevices.contains { device in
            device.isUSB && device.serial != lastAttemptedSerial
        }
    }

    nonisolated static func shouldAutoStartAuthorizedUSB(
        hasSavedDevices: Bool,
        explicitDeviceSetupRequired: Bool
    ) -> Bool {
        true
    }

    nonisolated static func shouldRunPresenceAutoConnect(
        authorizedDevices: [AuthorizedADBDevice],
        lastAttemptedSerial: String?,
        preferUSBMirroring: Bool,
        isMirroring: Bool,
        isPairing: Bool
    ) -> Bool {
        guard !isMirroring, !isPairing else { return false }
        guard preferUSBMirroring
            || !authorizedDevices.contains(where: \.isUSB)
            || authorizedDevices.contains(where: { !$0.isUSB }) else {
            return false
        }
        return !shouldPrioritizeUSBHandoff(
            authorizedDevices: authorizedDevices,
            lastAttemptedSerial: lastAttemptedSerial,
            preferUSBMirroring: preferUSBMirroring,
            isMirroring: isMirroring,
            isPairing: isPairing
        )
    }

    /// Pure decision: a pinned cable's USB presence is ignored only while we're
    /// actually on / pursuing the Wi-Fi route. Once we stop pursuing Wi-Fi (it
    /// died and recovery gave up), the pin no longer suppresses USB, so USB
    /// remains a working fallback.
    nonisolated static func isUSBPresenceSuppressedByWirelessPin(
        serial: String,
        pinnedSerials: Set<String>,
        isPursuingWirelessRoute: Bool
    ) -> Bool {
        pinnedSerials.contains(serial) && isPursuingWirelessRoute
    }

    /// Pure decision: is the remembered wireless route for this transport
    /// serial provably *failing*? Matches records by USB serial, stored
    /// address, or record ID, and treats a route as failing when either the
    /// LAN sweep proved the adb listener gone (`wirelessListenerMissing`) or
    /// the reconnect loop has recorded at least one failure for it.
    ///
    /// This distinction is what keeps anti-ping-pong protection for a healthy
    /// Wi-Fi route while letting a cable supersede a doomed one: plugging in
    /// is the only procedure that can restore a dead `:5555` listener, so it
    /// must never be starved by the very retry loop that is failing.
    nonisolated static func isWirelessReconnectFailing(
        records: [PairedPhoneRecord],
        serial: String,
        listenerMissingRecordIDs: Set<String>,
        retryFailureCounts: [String: Int]
    ) -> Bool {
        let matchingIDs = records.filter { record in
            record.id == serial
                || record.lastAddress == serial
                || record.resolvedUSBSerial == serial
                || record.resolvedWiFiAddress == serial
        }.map(\.id)
        if matchingIDs.contains(where: listenerMissingRecordIDs.contains) {
            return true
        }
        return matchingIDs.contains { (retryFailureCounts[$0] ?? 0) > 0 }
    }

    /// Instance wrapper: which of these authorized wireless serials are
    /// currently provably failing (see `isWirelessReconnectFailing`)?
    func failingWirelessAuthorizedSerials(
        _ authorizedDevices: [AuthorizedADBDevice]
    ) -> Set<String> {
        let failureCounts = connectionCoordinator.automaticRetryFailureCounts
        return Set(authorizedDevices.filter { !$0.isUSB }.map(\.serial).filter { serial in
            Self.isWirelessReconnectFailing(
                records: pairedPhones,
                serial: serial,
                listenerMissingRecordIDs: connectionCoordinator.wirelessListenerMissingRecordIDs,
                retryFailureCounts: failureCounts
            )
        })
    }

    private func isWirelessRouteFailing(forSerial serial: String) -> Bool {
        Self.isWirelessReconnectFailing(
            records: pairedPhones,
            serial: serial,
            listenerMissingRecordIDs: connectionCoordinator.wirelessListenerMissingRecordIDs,
            retryFailureCounts: connectionCoordinator.automaticRetryFailureCounts
        )
    }

    /// True while a Wi-Fi mirror is live or a handoff/reconnect is mid-flight.
    var isPursuingWirelessRoute: Bool {
        isMirroring
            || isRecoveringConnection
            || isAwaitingReconnect
            || connectionCoordinator.usbWiFiTakeoverTask != nil
            || connectionCoordinator.usbWiFiHandoffTask != nil
            || mirrorLaunchTask != nil
    }

    func isUSBSuppressedByWirelessPin(_ serial: String) -> Bool {
        // The anti-ping-pong pin protects a *healthy* pursued route. Once that
        // route is provably failing (refused dials, swept-and-silent LAN), the
        // pin would block the one recovery action that can restore it — the
        // cable — so it yields.
        if isWirelessRouteFailing(forSerial: serial) {
            return false
        }
        return Self.isUSBPresenceSuppressedByWirelessPin(
            serial: serial,
            pinnedSerials: wirelessPinnedUSBSerials,
            isPursuingWirelessRoute: isPursuingWirelessRoute
        )
    }

    /// True while a USB↔Wi-Fi handoff or reconnect is mid-flight and the app may
    /// momentarily have no window. The app stays alive across that gap, but once
    /// it is idle with no window it quits instead of lurking invisibly in the
    /// background and re-popping mirror windows on the next auto-reconnect.
    var isPerformingMirrorHandoffOrRecovery: Bool {
        // `launchNativeMirror` hides the chooser before it assigns
        // `mirrorLaunchTask`. `isMirroring` and `mirrorSession` are set first,
        // so include them to cover that narrow last-window gap; otherwise
        // AppKit can terminate the app while scrcpy is still opening.
        isMirroring
            || mirrorSession != nil
            || connectionCoordinator.usbWiFiHandoffTask != nil
            || connectionCoordinator.usbWiFiTakeoverTask != nil
            || mirrorLaunchTask != nil
            || isRecoveringConnection
            || isAwaitingReconnect
    }

    nonisolated static func shouldUSBInterruptReconnect(
        authorizedDevices: [AuthorizedADBDevice],
        isRecoveringConnection: Bool,
        isAwaitingReconnect: Bool,
        hasReconnectTask: Bool,
        hasWirelessStartTask: Bool,
        hasUSBWiFiTakeoverTask: Bool = false,
        disallowUSBFallback: Bool = false
    ) -> Bool {
        guard !disallowUSBFallback else { return false }
        guard !hasUSBWiFiTakeoverTask else { return false }
        guard authorizedDevices.contains(where: \.isUSB) else { return false }
        return isRecoveringConnection
            || isAwaitingReconnect
            || hasReconnectTask
            || hasWirelessStartTask
    }

}

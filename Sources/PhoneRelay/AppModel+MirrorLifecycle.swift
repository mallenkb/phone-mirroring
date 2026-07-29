import AppKit
import Foundation

@MainActor
extension AppModel {
    // MARK: - Mirroring lifecycle

    func scheduleMirrorSettingsRestart() {
        guard Self.shouldScheduleMirrorSettingsRestart(
            isMirroring: isMirroring,
            isPairing: isPairing,
            isLaunching: mirrorLaunchTask != nil
        ) else { return }
        mirrorSettingsRestartTask?.cancel()
        mirrorSettingsRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                  let self,
                  Self.shouldScheduleMirrorSettingsRestart(
                    isMirroring: self.isMirroring,
                    isPairing: self.isPairing,
                    isLaunching: self.mirrorLaunchTask != nil
                  ) else { return }
            Logger.log("Restarting mirror to apply updated mirroring settings")
            self.stopMirroring(suspendAutoConnect: false)
            self.startMirroring(manual: true)
        }
    }

    nonisolated static func shouldScheduleMirrorSettingsRestart(
        isMirroring: Bool,
        isPairing: Bool,
        isLaunching: Bool
    ) -> Bool {
        isMirroring && !isPairing && !isLaunching
    }

    func disableMirrorAudioAfterSessionFailure() {
        guard mirrorAudioEnabled else { return }
        mirrorSettingsRestartTask?.cancel()
        suppressMirrorAudioForReconnect = true
        Logger.log("Phone audio failed; suppressing audio for reconnect and continuing video-only.")
    }

    func shouldEnableMirrorAudioForNextSession() -> Bool {
        mirrorAudioEnabled && !suppressMirrorAudioForReconnect
    }

    /// - Parameter manual: `true` for a deliberate user action, which clears
    ///   any crash-loop backoff. Auto-reconnect callers leave it `false` so a
    ///   crashing server isn't relaunched in a tight loop.
    func startMirroring(manual: Bool = false) {
        guard !isMirroring, !isPairing else { return }
        guard !isFirstRunOnboardingActive else { return }
        guard manual || !explicitDeviceSetupRequired else { return }
        guard manual || !isAutoMirrorHeldForOnboarding else { return }

        if manual {
            keepConnectionChooserVisibleForNextMirrorLaunch = true
            resumeDiscoveryAfterManualConnect()
            // A deliberate retry clears backoff.
            setAutoConnectSuspendedForSelectedDevice(false)
            consecutiveQuickMirrorFailures = 0
            autoMirrorBackoffUntil = nil
            suppressMirrorAudioForReconnect = false
            isAwaitingReconnect = false
        } else if let until = autoMirrorBackoffUntil, Date() < until {
            return
        }

        if !manual, !isAppUserVisible {
            Logger.log("Skipping auto mirror start: app has no user-visible window (open the app to resume)")
            return
        }

        stopDisconnectRecovery()

        let serial = selectedDevice.adbSerial
        if let serial, Self.isWirelessADBTarget(serial) {
            startWirelessMirroring(savedTarget: serial)
            return
        }
        launchNativeMirror(serial: serial)
    }

    func startWirelessMirroring(savedTarget: String) {
        guard !isPairing else { return }
        connectionCoordinator.wirelessStartTask?.cancel()

        let selectedID = selectedDevice.id
        let selectedName = selectedDevice.name
        let adb = self.adb
        let generation = mirrorStartGeneration

        isPairing = true

        connectionCoordinator.wirelessStartTask = Task { [weak self] in
            var target: String?
            var refreshedSavedTarget: String?
            var savedRouteSawNoRouteToHost = false

            if savedTarget.contains(":") {
                let result = await Self.connectToRememberedWirelessReadiness(
                    adb: adb,
                    savedAddress: savedTarget,
                    preflightLocalNetworkAccess: { address in
                        await Self.preflightLocalNetworkAccess(address: address)
                    }
                )
                savedRouteSawNoRouteToHost = result.sawNoRouteToHost
                if let connectedAddress = result.connectedAddress {
                    target = connectedAddress
                    if connectedAddress != savedTarget {
                        refreshedSavedTarget = connectedAddress
                    }
                }
            }
            guard !Task.isCancelled else { return }

            guard let self else { return }
            guard self.mirrorStartGeneration == generation else { return }
            if target == nil {
                let livePhones = await Task.detached {
                    adb.connectableMDNSTargets()
                }.value
                guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
                let phones = livePhones + self.discoveredPhones
                let record = Self.recordsByMostRecent(self.pairedPhones).first { record in
                    record.id == selectedID || record.lastAddress == savedTarget
                }
                let refreshedPhone = record.flatMap {
                    Self.rememberedConnectablePhone(for: $0, in: phones)
                } ?? (phones.filter { $0.kind.isConnectable }.count == 1
                    ? phones.first(where: { $0.kind.isConnectable })
                    : nil)

                if let refreshedPhone {
                    let connectOutput = await Task.detached {
                        adb.run(["connect", refreshedPhone.address])
                    }.value
                    if Self.adbConnectSucceeded(connectOutput) {
                        target = refreshedPhone.address
                        let deviceName = await Self.connectedDeviceName(
                            adb: adb,
                            serial: refreshedPhone.address,
                            fallback: record?.displayName ?? selectedName
                        )
                        guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
                        self.touchPairedPhone(
                            id: refreshedPhone.id,
                            displayName: deviceName,
                            address: refreshedPhone.address
                        )
                        self.selectedDevice.name = deviceName
                    }
                }
            }

            self.isPairing = false
            self.connectionCoordinator.wirelessStartTask = nil
            guard let target else {
                if savedRouteSawNoRouteToHost {
                    self.presentLocalNetworkPermissionHint()
                }
                self.noteConnectionStall(
                    savedRouteSawNoRouteToHost ? .localNetworkDenied : .wirelessRouteMissing,
                    detail: "No reachable wireless route for \(savedTarget); saved address and mDNS both came up empty."
                )
                return
            }
            if let refreshedSavedTarget {
                self.touchPairedPhone(
                    id: selectedID,
                    displayName: selectedName,
                    address: refreshedSavedTarget
                )
            }
            self.selectedDevice.adbSerial = target
            self.launchNativeMirror(serial: target)
        }
    }

    func stopMirroring(suspendAutoConnect: Bool = true) {
        if suspendAutoConnect {
            setAutoConnectSuspendedForSelectedDevice(true)
            suppressAutoReconnectForManualDisconnect()
        }
        mirrorStartGeneration += 1
        mirrorLaunchTask?.cancel()
        mirrorLaunchTask = nil
        connectionCoordinator.usbConnectTask?.cancel()
        connectionCoordinator.usbConnectTask = nil
        connectionCoordinator.usbWiFiAddressPrefillTask?.cancel()
        connectionCoordinator.usbWiFiAddressPrefillTask = nil
        connectionCoordinator.cancelUSBWiFiHandoff()
        connectionCoordinator.usbWiFiTakeoverTask?.cancel()
        connectionCoordinator.usbWiFiTakeoverTask = nil
        connectionCoordinator.cancelDiscoveredWiFiConnect()
        usbWiFiHandoffCandidate = nil
        connectionCoordinator.wirelessStartTask?.cancel()
        connectionCoordinator.wirelessStartTask = nil
        if connectionCoordinator.reconnectTask != nil {
            // A deliberate stop also cancels an in-flight manual reconnect and
            // releases its busy flag (its own cleanup is skipped once cancelled).
            connectionCoordinator.reconnectTask?.cancel()
            connectionCoordinator.reconnectTask = nil
            isPairing = false
            reconnectAttemptCount = 0
        }
        mirrorSession?.onSessionEnded = nil
        mirrorSession?.stop()
        mirrorSession = nil
        isMirroring = false
        keepConnectionChooserVisibleForNextMirrorLaunch = false
        restorePresentationModeIfNeeded()
        stopDisconnectRecovery()
        // A deliberate stop clears the crash-loop breaker and the Wi-Fi pin, so
        // the next plug-in starts fresh on USB.
        consecutiveQuickMirrorFailures = 0
        autoMirrorBackoffUntil = nil
        wirelessPinnedUSBSerials.removeAll()
        transportIntent = .automatic
        isAwaitingReconnect = false
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        }
    }

    func recoverMissingMirrorTransport() {
        guard isMirroring || mirrorSession != nil || mirrorLaunchTask != nil else { return }
        Logger.log("Selected mirror transport disappeared; switching to reconnecting screen")
        let lostSerial = selectedDevice.adbSerial
        let wirelessRoute = Self.rememberedWirelessRouteForMissingMirrorTransport(
            selectedDevice: selectedDevice,
            pairedPhones: pairedPhones
        )
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
        if startUSBWiFiHandoffTakeoverIfAvailable(usbSerial: lostSerial, finalMirrorFrame: nil) {
            return
        }
        noteMirrorSessionEnded()
        if let wirelessRoute {
            Logger.log("USB mirror transport disappeared; switching directly to remembered Wi-Fi route \(wirelessRoute.lastAddress)")
            activeError = nil
            isRecoveringConnection = true
            isAwaitingReconnect = true
            select(record: wirelessRoute)
            startWirelessMirroring(savedTarget: wirelessRoute.lastAddress)
            showConnectionWindow(startsQRCodePairing: false)
            return
        }
        startDisconnectRecoveryFallback()
        showConnectionWindow(startsQRCodePairing: false)
    }

    func launchNativeMirror(
        serial: String?,
        keepConnectionWindowVisibleOverride: Bool? = nil
    ) {
        guard !isFirstRunOnboardingActive else {
            Logger.log("Skipping mirror launch while first-run onboarding is on screen")
            return
        }
        guard !isMirroring, mirrorSession == nil, mirrorLaunchTask == nil else {
            Logger.log("Skipping duplicate mirror launch serial=\(serial ?? "default")")
            return
        }

        Logger.log("Launching native mirror serial=\(serial ?? "default")")
        DiagnosticsService.shared.capture(.mirrorStarted, properties: [
            "transport": DiagnosticsService.transportValue(serial: serial, network: selectedDevice.network)
        ])
        let launchFrame = mirrorLaunchFrameForNextSession()
        let keepConnectionWindowVisible = keepConnectionWindowVisibleOverride
            ?? (keepConnectionChooserVisibleForNextMirrorLaunch
                || Self.shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
                    isRecoveringConnection: isRecoveringConnection,
                    isAwaitingReconnect: isAwaitingReconnect
                ))
        keepConnectionChooserVisibleForNextMirrorLaunch = false
        let session = MirrorSession(
            model: self,
            serial: serial,
            launchFrame: launchFrame,
            hostWindow: connectionWindow
        )
        session.onSessionEnded = { [weak self, weak session] finalMirrorFrame in
            guard let self else { return }
            if self.mirrorSession === session {
                self.mirrorSession = nil
            }
            self.isMirroring = false
            if self.isRecording {
                self.isRecording = false
                self.stopScreenRecordingCleanup()
            }
            self.restorePresentationModeIfNeeded()
            let endedSerial = serial ?? self.selectedDevice.adbSerial
            if let finalMirrorFrame {
                self.lastMirrorWindowFrame = finalMirrorFrame
                self.connectionWindow?.setFrame(finalMirrorFrame, display: false)
            }
            if self.startUSBWiFiHandoffTakeoverIfAvailable(
                usbSerial: endedSerial,
                finalMirrorFrame: finalMirrorFrame
            ) {
                return
            }
            self.noteMirrorSessionEnded()
            self.startDisconnectRecoveryFallback()
            self.showConnectionWindow(startsQRCodePairing: false)
        }
        session.onReadyToDisplay = { [weak self, weak session] in
            guard let self, let session, self.mirrorSession === session else { return }
            // Don't mark the connection "completed" on the first frame alone: a
            // load-then-bail (e.g. the S906B crash) reaches one frame then dies,
            // and that must not flip later attempts to "Reconnecting". The flag
            // is set in noteMirrorSessionEnded only once a session proves stable.
            self.stopDisconnectRecovery()
            self.activeError = nil
            self.clearConnectionStall()
            self.transportIntent = .automatic
            self.isRecoveringConnection = false
            self.isAwaitingReconnect = false
            if !session.usesHostWindow {
                self.hideConnectionWindowForNativeMirror()
            }
        }

        mirrorLaunchTask?.cancel()
        mirrorSession = session
        isMirroring = true
        isAwaitingReconnect = false
        selectedDevice.states = [.mirroringReady, .companionConnected]
        lastMirrorStartAt = Date()
        missingMirrorTransportPollMisses = 0
        if !keepConnectionWindowVisible, !session.usesHostWindow {
            hideConnectionWindowForNativeMirror()
        }

        mirrorLaunchTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                try await session.start()
                guard !Task.isCancelled, self.mirrorSession === session else { return }
                self.mirrorLaunchTask = nil
            } catch {
                guard !Task.isCancelled, self.mirrorSession === session else { return }
                session.onSessionEnded = nil
                session.stop()
                self.mirrorSession = nil
                self.isMirroring = false
                self.mirrorLaunchTask = nil
                Logger.log("Mirror launch failed: \(error)")
                let detail = Self.mirrorFailureDetail(for: error)
                let message = Self.mirrorFailureMessage(for: error)
                DiagnosticsService.shared.capture(.mirrorFailed, properties: [
                    "transport": DiagnosticsService.transportValue(serial: serial, network: self.selectedDevice.network),
                    "failure_reason": DiagnosticsService.failureReason(for: detail).rawValue
                ])
                if self.recoverUSBLaunchFailureOverWireless(serial: serial, detail: detail) {
                    return
                }
                if self.transportIntent.requiresWiFi {
                    self.transportIntent = .automatic
                    self.reportError("Couldn’t start Wi-Fi mirroring", message)
                    self.showConnectionWindow(startsQRCodePairing: false)
                    return
                }
                if Self.shouldKeepRetryingMirrorLaunchFailure(message) {
                    Logger.log("Mirror launch will keep retrying without showing connection failure badge: \(message)")
                    self.activeError = nil
                    self.startDisconnectRecoveryFallback()
                    self.showConnectionWindow(startsQRCodePairing: false)
                } else {
                    self.reportError("Couldn’t start mirroring", message)
                    self.showConnectionWindow()
                }
            }
        }
    }

    func mirrorLaunchFrameForNextSession() -> NSRect? {
        let candidate = connectionWindow?.frame ?? lastMirrorWindowFrame
        guard shouldAssertForegroundPresentation,
              let activeScreen = Self.screenContainingPointer() ?? NSScreen.main,
              let candidate else {
            return candidate
        }
        return activeScreen.frame.intersects(candidate) ? candidate : nil
    }

    nonisolated static func screenContainingPointer() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) }
    }

    @discardableResult
    func startUSBWiFiHandoffTakeoverIfAvailable(
        usbSerial: String?,
        finalMirrorFrame: NSRect?
    ) -> Bool {
        guard let usbSerial,
              let candidate = usbWiFiHandoffCandidate,
              candidate.usbSerial == usbSerial,
              transportIntent.permitsPreparedWiFiTakeover(for: usbSerial)
        else { return false }

        Logger.log("USB mirror ended; attempting prepared Wi-Fi handoff address=\(candidate.address)")
        let takeoverAttempt = DiagnosticsConnectionAttempt(attemptNumber: reconnectAttemptCount + 1, isRetry: reconnectAttemptCount > 0)
        DiagnosticsService.shared.capture(.usbRecoveryStarted, properties: [
            "recovery_method": "usb_reset"
        ])
        DiagnosticsService.shared.capture(
            takeoverAttempt.isRetry ? .wifiRetryStarted : .wifiHandoffStarted,
            properties: DiagnosticsService.shared.propertiesForAttempt(takeoverAttempt, transport: "wifi")
        )
        if let finalMirrorFrame {
            lastMirrorWindowFrame = finalMirrorFrame
            connectionWindow?.setFrame(finalMirrorFrame, display: false)
        }
        connectionCoordinator.cancelUSBWiFiHandoff()
        connectionCoordinator.usbWiFiTakeoverTask?.cancel()
        stopQRCodePairingSession()
        isRecoveringConnection = true
        isAwaitingReconnect = true
        isAutoConnecting = true
        activeError = nil
        showConnectionWindow(startsQRCodePairing: false)

        let adb = self.adb
        let generation = mirrorStartGeneration
        connectionCoordinator.usbWiFiTakeoverTask = Task { [weak self] in
            let readiness = await Self.waitForADBWirelessTargetReadiness(
                adb: adb,
                address: candidate.address,
                attempts: Self.wirelessHandoffTakeoverAttempts,
                delayNanoseconds: Self.wirelessHandoffRetryDelayNanoseconds,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(
                        address: address,
                        timeoutNanoseconds: Self.wirelessHandoffPreflightTimeoutNanoseconds
                    )
                },
                tcpPortProbe: { address in
                    await Self.adbTCPPortProbe(address)
                },
                maximumDuration: Self.wirelessHandoffTakeoverMaxDuration,
                connectTimeout: Self.wirelessHandoffConnectTimeout,
                shellTimeout: Self.wirelessHandoffShellTimeout
            )

            guard let self, !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
            self.connectionCoordinator.usbWiFiTakeoverTask = nil
            if readiness.isReady {
                DiagnosticsService.shared.capture(
                    takeoverAttempt.isRetry ? .wifiRetrySucceeded : .wifiHandoffSucceeded,
                    properties: DiagnosticsService.shared.propertiesForCompletedAttempt(takeoverAttempt, transport: "wifi")
                )
                DiagnosticsService.shared.capture(.usbRecoverySucceeded, properties: [
                    "recovery_method": "usb_reset"
                ])
                // The Wi-Fi route came up after all — undo any "blocks
                // adb-over-Wi-Fi" verdict a racing handoff attempt recorded.
                self.failedLegacyHandoffSerials.remove(candidate.usbSerial)
                self.wirelessPinnedUSBSerials.insert(candidate.usbSerial)
                self.touchPairedPhone(
                    id: candidate.usbSerial,
                    displayName: candidate.displayName,
                    address: candidate.address
                )
                self.selectedDevice.adbSerial = candidate.address
                self.selectedDevice.name = candidate.displayName
                self.selectedDevice.network = "Wi-Fi"
                self.isSelectedDeviceOnline = true
                self.isRecoveringConnection = false
                self.isAwaitingReconnect = false
                self.isAutoConnecting = false
                self.activeError = nil
                self.launchNativeMirror(serial: candidate.address)
            } else {
                DiagnosticsService.shared.capture(
                    takeoverAttempt.isRetry ? .wifiRetryFailed : .wifiHandoffFailed,
                    properties: DiagnosticsService.shared.propertiesForCompletedAttempt(
                        takeoverAttempt,
                        transport: "wifi",
                        extra: [
                            "failure_reason": readiness.sawNoRouteToHost
                                ? DiagnosticsFailureReason.noRouteToHost.rawValue
                                : DiagnosticsFailureReason.timeout.rawValue
                        ]
                    )
                )
                if readiness.sawNoRouteToHost {
                    self.presentLocalNetworkPermissionHint()
                }
                Logger.log("Prepared Wi-Fi handoff address=\(candidate.address) was not ready after USB ended")
                self.connectionCoordinator.cancelUSBWiFiHandoff()
                self.usbWiFiHandoffCandidate = nil
                self.lastUSBHandoffSerial = candidate.usbSerial
                self.isAutoConnecting = false
                self.isRecoveringConnection = false
                self.isAwaitingReconnect = false
                self.stopQRCodePairingSession()
                // The prepared Wi-Fi route never came up; genuinely fall back to
                // the cable and release the pin so USB works again. First prove
                // the USB transport is still usable; adb can briefly report a
                // stale USB serial after tcpip/restart or cable movement.
                self.wirelessPinnedUSBSerials.remove(candidate.usbSerial)
                let fallbackUSB = AuthorizedADBDevice(
                    serial: candidate.usbSerial,
                    product: "",
                    model: candidate.displayName,
                    isUSB: true
                )
                guard let readyUSB = await self.readyUSBDeviceForMirroring(fallbackUSB) else {
                    DiagnosticsService.shared.capture(.usbRecoveryFailed, properties: [
                        "recovery_method": "usb_reset",
                        "failure_reason": DiagnosticsFailureReason.adbOffline.rawValue
                    ])
                    Logger.log("Skipping USB fallback for \(candidate.usbSerial): USB transport is not ready after failed Wi-Fi handoff.")
                    self.isSelectedDeviceOnline = false
                    self.startDisconnectRecoveryFallback()
                    return
                }
                self.selectedDevice.adbSerial = readyUSB.serial
                DiagnosticsService.shared.capture(.usbRecoverySucceeded, properties: [
                    "recovery_method": "usb_reset"
                ])
                self.selectedDevice.name = candidate.displayName
                self.selectedDevice.network = "USB"
                self.isSelectedDeviceOnline = true
                self.launchNativeMirror(
                    serial: readyUSB.serial,
                    keepConnectionWindowVisibleOverride: false
                )
            }
        }
        return true
    }

    func recoverUSBLaunchFailureOverWireless(serial: String?, detail: String) -> Bool {
        guard let serial,
              let record = Self.rememberedWirelessRouteForUSBLaunchFailure(
                message: detail,
                failedSerial: serial,
                pairedPhones: pairedPhones
              ) else {
            return false
        }

        Logger.log("USB mirror launch failed because \(serial) disappeared; retrying remembered Wi-Fi route \(record.lastAddress)")
        activeError = nil
        isAwaitingReconnect = true
        select(record: record)
        startWirelessMirroring(savedTarget: record.lastAddress)
        showConnectionWindow(startsQRCodePairing: false)
        return true
    }

    func startDisconnectRecoveryFallback() {
        isRecoveringConnection = true
        isAwaitingReconnect = true
        stopQRCodePairingSession()
        requestAutomaticReconnect(trigger: .disconnectRecovery)
        connectionCoordinator.disconnectRecoveryTask?.cancel()
        connectionCoordinator.disconnectRecoveryTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.disconnectRecoveryGracePeriod)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !self.isMirroring else { return }
            }
            guard !Task.isCancelled, let self, !self.isMirroring else { return }
            self.isRecoveringConnection = false
            self.isAwaitingReconnect = false
            self.ensureQRCodePairingSession()
        }
    }

    func stopDisconnectRecovery() {
        connectionCoordinator.disconnectRecoveryTask?.cancel()
        connectionCoordinator.disconnectRecoveryTask = nil
        isRecoveringConnection = false
        isAwaitingReconnect = false
    }

    /// Called when a native mirror session ends. Distinguishes a stable session
    /// (resets all breakers) from a "quick" failure. Repeated quick failures
    /// arm a growing reconnect backoff.
    func noteMirrorSessionEnded() {
        let lived = lastMirrorStartAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        // One diagnostic line per session end: distinguishes a genuine drop from a
        // load-then-bail crash-loop and names the transport, so a "connects then
        // drops" report can be triaged from the log without guessing.
        Logger.log("Mirror session ended: lived=\(String(format: "%.1f", lived))s serial=\(selectedDevice.adbSerial ?? "default") stable=\(Self.isStableMirrorSession(lived: lived)) priorQuickFailures=\(consecutiveQuickMirrorFailures)")
        DiagnosticsService.shared.capture(.mirrorSessionEnded, properties: [
            "transport": DiagnosticsService.transportValue(serial: selectedDevice.adbSerial, network: selectedDevice.network),
            "duration_ms": max(0, Int(lived * 1000))
        ])
        guard !Self.isStableMirrorSession(lived: lived) else {
            // Stable session — reset the reconnect backoff, and remember that a
            // real connection was achieved so a *subsequent* drop reads
            // "Reconnecting" (set here, before startDisconnectRecoveryFallback,
            // so the recovery surface shows the right word).
            hasCompletedSuccessfulMirrorConnection = true
            consecutiveQuickMirrorFailures = 0
            autoMirrorBackoffUntil = nil
            return
        }

        consecutiveQuickMirrorFailures += 1
        let backoff = Self.mirrorBackoffInterval(forFailureCount: consecutiveQuickMirrorFailures)
        guard backoff > 0 else { return }
        autoMirrorBackoffUntil = Date().addingTimeInterval(backoff)
        isAwaitingReconnect = true
        Logger.log("Mirror keeps disconnecting right after it starts. Pausing auto-reconnect for \(Int(backoff))s.")
    }

    /// Backoff schedule keyed on consecutive quick failures. The first failure
    /// is free (transient drops happen); repeats grow up to a 30s ceiling.
    nonisolated static func mirrorBackoffInterval(forFailureCount count: Int) -> TimeInterval {
        switch count {
        case ..<2: return 0
        case 2: return 10
        case 3: return 20
        default: return 30
        }
    }

    nonisolated static func devicePillStatusText(
        isOnline: Bool,
        hasSavedDevice: Bool,
        isActivelyConnecting: Bool
    ) -> String {
        if isActivelyConnecting { return "Connecting" }
        if isOnline { return "Online" }
        if hasSavedDevice { return "Offline" }
        return "Offline"
    }

    /// The bottom-pill connection states, each with its own label + dot tint
    /// (grey idle, amber connecting, green online, red failed).
    enum ConnectionPillState: Equatable {
        case noPhone
        case offline
        case actionNeeded
        case connecting
        case reconnecting
        case waitingForPhone
        case online
        case failed

        var text: String {
            switch self {
            case .noPhone: return "No phone connected"
            case .offline: return "Offline"
            case .actionNeeded: return "Action needed"
            case .connecting: return "Connecting"
            case .reconnecting: return "Reconnecting"
            case .waitingForPhone: return "Waiting for phone"
            case .online: return "Online"
            case .failed: return "Connection failed"
            }
        }
    }

    nonisolated static func resolveConnectionPillState(
        hasError: Bool,
        needsUserAction: Bool,
        isOnline: Bool,
        hasLivePhone: Bool,
        hasSavedDevice: Bool,
        isActivelyConnecting: Bool,
        isReconnecting: Bool
    ) -> ConnectionPillState {
        if needsUserAction { return .actionNeeded }
        if hasError { return .failed }
        if isActivelyConnecting { return isReconnecting ? .reconnecting : .connecting }
        if isOnline || hasLivePhone { return .online }
        if hasSavedDevice { return .offline }
        return .noPhone
    }

    /// Live pill state for the connection screen, derived from the same unified
    /// connection signals. `reconnecting` only after a connection has actually
    /// been established once this session (otherwise the first attempt reads
    /// `connecting`).
    var connectionPillState: ConnectionPillState {
        // A stale, auto-dismissing error must not outrank a live retry. If the
        // watcher has already started reconnecting, communicate the current
        // work instead of a remedy that may no longer be necessary.
        let hasBlockingError = activeError != nil && !isActivelyConnecting
        if latestADBStatusText != "adb missing",
           !latestHasUnauthorizedUSBDevice,
           activeError?.title != Self.localNetworkBlockedErrorTitle,
           let plateauFailure = automaticReconnectPlateauFailure {
            // Pairing-required is proven (the phone advertises pairing only),
            // so surface the action instead of an open-ended wait.
            return plateauFailure == .pairingRequired ? .actionNeeded : .waitingForPhone
        }
        return Self.resolveConnectionPillState(
            hasError: hasBlockingError,
            needsUserAction: hasBlockingError
                || latestHasUnauthorizedUSBDevice
                || latestADBStatusText == "adb missing",
            isOnline: isSelectedDeviceOnline
                || (!isActivelyConnecting && hasRememberedWiFiHandoffRoute),
            hasLivePhone: isMatchingUSBConnectionAvailable
                || isMatchingLiveWirelessConnectionAvailable,
            hasSavedDevice: !pairedPhones.isEmpty,
            isActivelyConnecting: isActivelyConnecting,
            isReconnecting: hasCompletedSuccessfulMirrorConnection
                && (isRecoveringConnection || isAwaitingReconnect)
        )
    }

    var isAutomaticReconnectAtPlateau: Bool {
        automaticReconnectPlateauFailure != nil
    }

    /// Non-nil once the automatic retry ladder has reached its 30s plateau,
    /// carrying the classified failure so the pill can distinguish a provable
    /// user action (pairing required) from an open-ended wait.
    var automaticReconnectPlateauFailure: ConnectionCoordinator.AutomaticReconnectFailure? {
        guard case .waiting(let recordID, _, let failure) = connectionCoordinator.automaticReconnectState,
              let retry = connectionCoordinator.automaticRetryStates[recordID],
              ConnectionCoordinator.automaticReconnectDelay(
                failureCount: retry.failureCount
              ) >= 30 else { return nil }
        return failure
    }

    var connectionPillText: String {
        Self.connectionPillText(
            state: connectionPillState,
            activeErrorTitle: activeError?.title,
            hasUnauthorizedUSBDevice: latestHasUnauthorizedUSBDevice,
            adbStatusText: latestADBStatusText
        )
    }

    nonisolated static func connectionPillText(
        state: ConnectionPillState,
        activeErrorTitle: String?,
        hasUnauthorizedUSBDevice: Bool,
        adbStatusText: String
    ) -> String {
        if state == .actionNeeded {
            if let activeErrorTitle, !activeErrorTitle.isEmpty {
                if activeErrorTitle == Self.usbPhoneNotFoundErrorTitle {
                    return "Mac can't see USB"
                }
                if activeErrorTitle == Self.localNetworkBlockedErrorTitle {
                    return "Allow Local Network"
                }
                if activeErrorTitle == Self.wifiConnectionNotReadyErrorTitle {
                    return "Wi-Fi not ready"
                }
                if activeErrorTitle == Self.wifiPairingRequiredErrorTitle {
                    return "Pair phone again"
                }
                return "Action needed"
            }
            if hasUnauthorizedUSBDevice {
                return "Allow USB debugging"
            }
            if adbStatusText == "adb missing" {
                return "ADB unavailable"
            }
        }
        return state.text
    }

    nonisolated static func connectionDeviceLabel(
        name: String,
        id: String,
        serial: String?,
        network: String
    ) -> String {
        mirrorWindowDeviceTitle(name: name)
    }

    nonisolated static func connectionHealthSnapshot(
        selectedSerial: String?,
        selectedNetwork: String,
        isSelectedDeviceOnline: Bool,
        isActivelyConnecting: Bool,
        hasUnauthorizedUSBDevice: Bool,
        authorizedDevices: [AuthorizedADBDevice],
        discoveredPhones: [DiscoveredPhone],
        localNetworkPermissionGranted: Bool,
        adbStatusText: String,
        reconnectAttemptCount: Int,
        activeErrorMessage: String?,
        backgroundWiFiHandoffEnabled: Bool = true,
        isPreparingWiFiHandoff: Bool = false,
        lastStall: ConnectionStall? = nil,
        now: Date = Date()
    ) -> ConnectionHealthSnapshot {
        let hasAuthorizedUSB = authorizedDevices.contains(where: \.isUSB)
        let hasWirelessDevice = authorizedDevices.contains { !$0.isUSB }
        let hasWiFiReachability = hasWirelessDevice || discoveredPhones.contains { $0.kind.isConnectable }
        let selectedTransport = selectedTransportLabel(serial: selectedSerial, network: selectedNetwork)

        let usbItem: ConnectionHealthSnapshot.Item
        if hasUnauthorizedUSBDevice {
            usbItem = .init(id: "usb", title: "USB authorization", value: "Action needed", level: .issue)
        } else if hasAuthorizedUSB {
            usbItem = .init(id: "usb", title: "USB authorization", value: "Authorized", level: .ok)
        } else {
            usbItem = .init(id: "usb", title: "USB authorization", value: "No USB device", level: .neutral)
        }

        let wifiItem = ConnectionHealthSnapshot.Item(
            id: "wifi",
            title: "Wi-Fi reachability",
            value: hasWiFiReachability ? "Reachable" : "Not reachable",
            level: hasWiFiReachability ? .ok : .warning
        )
        let permissionItem = ConnectionHealthSnapshot.Item(
            id: "local-network",
            title: "Local network",
            value: localNetworkPermissionGranted ? "Allowed" : "Not confirmed",
            level: localNetworkPermissionGranted ? .ok : .warning
        )
        let adbItem = ConnectionHealthSnapshot.Item(
            id: "adb",
            title: "adb status",
            value: adbStatusText,
            level: adbStatusText == "Running" || adbStatusText == "Running, no device" ? .ok : .issue
        )
        let transportItem = ConnectionHealthSnapshot.Item(
            id: "transport",
            title: "Selected transport",
            value: selectedTransport,
            level: selectedTransport == "None" ? .neutral : .ok
        )
        let handoffItem = wifiHandoffHealthItem(
            enabled: backgroundWiFiHandoffEnabled,
            isPreparing: isPreparingWiFiHandoff,
            hasWirelessDevice: hasWirelessDevice,
            hasWiFiReachability: hasWiFiReachability
        )
        let attemptsItem = ConnectionHealthSnapshot.Item(
            id: "attempts",
            title: "Reconnect attempts",
            value: reconnectAttemptCount == 0 ? "None" : "\(reconnectAttemptCount)",
            level: reconnectAttemptCount == 0 ? .neutral : .warning
        )

        let stallItem = lastStall.map { stall in
            ConnectionHealthSnapshot.Item(
                id: "last-stall",
                title: "Last stopped because",
                value: stallValueText(stall, now: now),
                level: .warning
            )
        }

        return ConnectionHealthSnapshot(
            usbAuthorization: usbItem,
            wifiReachability: wifiItem,
            localNetworkPermission: permissionItem,
            adbStatus: adbItem,
            selectedTransport: transportItem,
            wifiHandoff: handoffItem,
            reconnectAttempts: attemptsItem,
            lastStall: stallItem,
            recommendedFix: nextRecommendedConnectionFix(
                isSelectedDeviceOnline: isSelectedDeviceOnline,
                isActivelyConnecting: isActivelyConnecting,
                hasUnauthorizedUSBDevice: hasUnauthorizedUSBDevice,
                hasAuthorizedUSB: hasAuthorizedUSB,
                hasWiFiReachability: hasWiFiReachability,
                localNetworkPermissionGranted: localNetworkPermissionGranted,
                adbStatusText: adbStatusText,
                activeErrorMessage: activeErrorMessage
            )
        )
    }

    nonisolated static func wifiHandoffHealthItem(
        enabled: Bool,
        isPreparing: Bool,
        hasWirelessDevice: Bool,
        hasWiFiReachability: Bool
    ) -> ConnectionHealthSnapshot.Item {
        // Kept for source compatibility with older diagnostics callers. Wi-Fi
        // handoff is now invariant behavior and cannot be disabled.
        _ = enabled
        if isPreparing {
            return .init(id: "wifi-handoff", title: "Wi-Fi handoff", value: "Preparing", level: .warning)
        }
        if hasWirelessDevice {
            return .init(id: "wifi-handoff", title: "Wi-Fi handoff", value: "Ready", level: .ok)
        }
        return .init(
            id: "wifi-handoff",
            title: "Wi-Fi handoff",
            value: hasWiFiReachability ? "Available" : "Unavailable",
            level: hasWiFiReachability ? .neutral : .warning
        )
    }

    nonisolated static func selectedTransportLabel(serial: String?, network: String) -> String {
        guard let serial, !serial.isEmpty else { return "None" }
        let lowerNetwork = network.lowercased()
        if lowerNetwork.contains("usb") {
            return "USB"
        }
        if lowerNetwork.contains("wi-fi") || lowerNetwork.contains("wifi") || lowerNetwork.contains("wireless") {
            return "Wi-Fi"
        }
        return serial.contains(":") ? "Wi-Fi" : "USB"
    }

    nonisolated static func nextRecommendedConnectionFix(
        isSelectedDeviceOnline: Bool,
        isActivelyConnecting: Bool,
        hasUnauthorizedUSBDevice: Bool,
        hasAuthorizedUSB: Bool,
        hasWiFiReachability: Bool,
        localNetworkPermissionGranted: Bool,
        adbStatusText: String,
        activeErrorMessage: String?
    ) -> String {
        if let activeErrorMessage, !activeErrorMessage.isEmpty {
            return activeErrorMessage
        }
        if adbStatusText == "adb missing" {
            return "Install Android platform-tools or use the bundled app build with adb included."
        }
        if hasUnauthorizedUSBDevice {
            return "Unlock the phone and tap Allow on the USB debugging prompt."
        }
        if !localNetworkPermissionGranted && !hasAuthorizedUSB {
            return localNetworkRecommendedFix
        }
        if isActivelyConnecting {
            return "Keep the phone awake and wait for the current reconnect attempt to finish."
        }
        if isSelectedDeviceOnline {
            return noActionNeededRecommendedFix
        }
        if hasAuthorizedUSB {
            return "Use Connect via USB to refresh the session and Wi-Fi handoff."
        }
        if !hasWiFiReachability {
            return "Put the phone on the same Wi-Fi, enable Wireless debugging, or connect USB once."
        }
        return "Try reconnecting over Wi-Fi, or refresh the pairing with the QR code."
    }

    /// Not private: called from AppModel+ConnectionHelpers.swift (pure-move
    /// split); treat as elsewhere.
    nonisolated static func isSamsungModelCode(_ name: String) -> Bool {
        let normalized = name
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        return normalized.range(of: #"^SM[A-Z0-9]+$"#, options: .regularExpression) != nil
    }

    /// Whether *automatic* flows may put windows on screen. Auto-reconnect
    /// used to order the connection card and mirror chrome above whatever app
    /// the user was in even when Phone Relay had no visible presence — the
    /// "app isn't even open but windows pop over my browser" report
    /// (2026-07-05). Auto work now stays off-screen unless the user can
    /// already see the app; opening it (Dock/Finder) resumes everything.
    nonisolated static func mayAutoPresentWindows(
        appIsActive: Bool,
        hasVisiblePrimaryWindow: Bool
    ) -> Bool {
        appIsActive || hasVisiblePrimaryWindow
    }

    var isAppUserVisible: Bool {
        Self.mayAutoPresentWindows(
            appIsActive: NSApp?.isActive == true,
            hasVisiblePrimaryWindow: NSApp?.windows.contains {
                $0.isVisible && $0.canBecomeMain
            } == true
        )
    }

    /// How the connection window may (re)surface. Mirror sessions start and end
    /// on their own (auto-connect, Wi-Fi drops, reconnect cycles), so the window
    /// must never grab key focus from another app the user is working in —
    /// that turns every reconnect into a focus steal.
    enum ConnectionWindowPresentation: Equatable {
        case activateAndMakeKey
        case orderFrontOnly
    }

    nonisolated static func connectionWindowPresentation(appIsActive: Bool) -> ConnectionWindowPresentation {
        appIsActive ? .activateAndMakeKey : .orderFrontOnly
    }

    func hideConnectionWindow() {
        connectionWindow?.childWindows?.forEach { $0.orderOut(nil) }
        connectionWindow?.orderOut(nil)
    }

    func hideConnectionWindowForNativeMirror() {
        hideConnectionWindow()
        if shouldAssertForegroundPresentation {
            NSApp?.activate(ignoringOtherApps: true)
        }
    }

    func showConnectionWindow(startsQRCodePairing: Bool = true) {
        guard !isShuttingDown else { return }
        // The first-run onboarding card owns the screen; the connection window
        // is revealed by its dismissal, never alongside it.
        guard !isFirstRunOnboardingActive else {
            hideConnectionWindow()
            return
        }
        guard let connectionWindow, !isMirroring, mirrorSession == nil else { return }
        switch Self.connectionWindowPresentation(appIsActive: shouldAssertForegroundPresentation) {
        case .activateAndMakeKey:
            connectionWindow.makeKeyAndOrderFront(nil)
            NSApp?.activate(ignoringOtherApps: true)
        case .orderFrontOnly:
            // Never paint the card over another app's window when Phone Relay
            // has no visible presence — background reconnects stay silent.
            guard connectionWindow.isVisible || isAppUserVisible else { return }
            connectionWindow.orderFront(nil)
        }
        if startsQRCodePairing && !isFirstTimeUSBSetup {
            ensureQRCodePairingSession()
        }
    }

    func clearConnectionWindowPreferredStep() {
        connectionWindowPrefersWirelessDetails = false
    }

    func showWirelessConnectionDetailsFromSettings() {
        connectionWindowPrefersWirelessDetails = true
        showConnectionWindow(startsQRCodePairing: true)
    }

    func updateWiFiIPAddressFromSettings(for record: PairedPhoneRecord) {
        if let host = record.resolvedWiFiAddress.flatMap(Self.host) {
            manualADBTarget = host
        }
        connectionWindowPrefersWirelessDetails = true
        showConnectionWindow(startsQRCodePairing: false)
    }

    func disconnectFromSettings() {
        connectionWindowPrefersWirelessDetails = false
        connectionWindowNavigationResetID += 1
        stopMirroring()
        showConnectionWindow(startsQRCodePairing: false)
        refreshDevicePresenceAfterManualDisconnect()
    }

}

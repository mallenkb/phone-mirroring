import SwiftUI
import AppKit
import Foundation
import Darwin
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedDevice: MirrorDevice = .demo
    @Published var isScanning = false
    @Published var isMirroring = false
    @Published var isRecording = false
    @Published var isPairing = false
    @Published private(set) var isRecoveringConnection = false
    @Published private(set) var isSelectedDeviceOnline = false {
        didSet {
            guard isSelectedDeviceOnline, !oldValue else { return }
            // A live device (USB or wireless) just appeared. Permanently leave
            // first-run onboarding so its fixed default-window sizing can never
            // persist into the connected or mirroring state.
            if !UserDefaults.standard.bool(forKey: "hasSeenFirstTimeUserOnboarding") {
                UserDefaults.standard.set(true, forKey: "hasSeenFirstTimeUserOnboarding")
            }
        }
    }
    @Published var clipboardSyncEnabled: Bool =
        (UserDefaults.standard.object(forKey: "MirrorBehavior.clipboardSyncEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(clipboardSyncEnabled, forKey: "MirrorBehavior.clipboardSyncEnabled")
            mirrorSession?.setClipboardSyncEnabled(clipboardSyncEnabled)
        }
    }
    @Published var keyboardInputEnabled: Bool =
        (UserDefaults.standard.object(forKey: "MirrorBehavior.keyboardInputEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(keyboardInputEnabled, forKey: "MirrorBehavior.keyboardInputEnabled")
        }
    }
    @Published var dragAndDropFileTransferEnabled: Bool =
        (UserDefaults.standard.object(forKey: "MirrorBehavior.dragAndDropFileTransferEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(dragAndDropFileTransferEnabled, forKey: "MirrorBehavior.dragAndDropFileTransferEnabled")
        }
    }
    @Published var captureCue: CaptureCue?

    // MARK: - Mirroring quality (applied to the next mirror session)

    /// Target video bitrate in megabits/sec.
    @Published var mirrorBitRateMbps: Int = (UserDefaults.standard.object(forKey: "MirrorQuality.bitRateMbps") as? Int) ?? 8 {
        didSet {
            UserDefaults.standard.set(mirrorBitRateMbps, forKey: "MirrorQuality.bitRateMbps")
            if !suppressMirrorSettingsRestart {
                scheduleMirrorSettingsRestart()
            }
        }
    }
    /// Cap on the longer screen dimension (px); lower = sharper-feeling + faster.
    @Published var mirrorMaxSize: Int = (UserDefaults.standard.object(forKey: "MirrorQuality.maxSize") as? Int) ?? 1600 {
        didSet {
            UserDefaults.standard.set(mirrorMaxSize, forKey: "MirrorQuality.maxSize")
            if !suppressMirrorSettingsRestart {
                scheduleMirrorSettingsRestart()
            }
        }
    }
    /// Frame-rate ceiling.
    @Published var mirrorMaxFps: Int = (UserDefaults.standard.object(forKey: "MirrorQuality.maxFps") as? Int) ?? 60 {
        didSet {
            UserDefaults.standard.set(mirrorMaxFps, forKey: "MirrorQuality.maxFps")
            if !suppressMirrorSettingsRestart {
                scheduleMirrorSettingsRestart()
            }
        }
    }
    /// Play the phone's audio on the Mac. Defaults on for fresh installs, then
    /// follows the user's saved preference.
    @Published var mirrorAudioEnabled: Bool =
        (UserDefaults.standard.object(forKey: "MirrorQuality.experimentalOpusAudioEnabled") as? Bool) ?? true {
        didSet {
            suppressMirrorAudioForReconnect = false
            UserDefaults.standard.set(mirrorAudioEnabled, forKey: "MirrorQuality.experimentalOpusAudioEnabled")
            if !suppressMirrorSettingsRestart {
                scheduleMirrorSettingsRestart()
            }
        }
    }
    /// Wi-Fi handoff is the default transport behavior; this remains only so
    /// older saved USB preferences do not silently disable handoff.
    var preferUSBMirroring: Bool { false }
    /// Turns the physical phone display off 30 seconds after mirroring starts.
    @Published var mirrorScreenOffAfterThirtySecondsEnabled: Bool =
        (UserDefaults.standard.object(forKey: "MirrorBehavior.screenOffAfterThirtySecondsEnabled") as? Bool)
        ?? (UserDefaults.standard.object(forKey: "MirrorBehavior.screenOffAfterOneMinuteEnabled") as? Bool)
        ?? true {
        didSet {
            UserDefaults.standard.set(
                mirrorScreenOffAfterThirtySecondsEnabled,
                forKey: "MirrorBehavior.screenOffAfterThirtySecondsEnabled"
            )
        }
    }

    /// Last failure worth showing the user (mirroring/pairing/adb problems).
    @Published var activeError: UserFacingError?
    /// Most recent saved screenshot or screen recording, for "reveal in Finder".
    @Published private(set) var lastCaptureURL: URL?

    /// A dismissible, human-readable problem surfaced in the connection UI.
    struct UserFacingError: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    func reportError(_ title: String, _ message: String) {
        Logger.log("User-facing error: \(title) — \(message)")
        activeError = UserFacingError(title: title, message: message)
        // The error banner lives on the connection screen, which is hidden while
        // mirroring — mirror a copy to Notification Center so it's still seen.
        if isMirroring {
            notify(title: title, body: message)
        }
    }

    /// Posts a transient macOS notification (best-effort; silently no-ops if the
    /// user hasn't granted notification permission).
    func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    /// Handles files dropped onto the mirror: `.apk`s are installed, everything
    /// else is pushed to the phone's Download folder.
    func handleDroppedFiles(_ urls: [URL]) {
        let fileURLs = urls.filter { $0.isFileURL }
        guard !fileURLs.isEmpty else { return }
        guard dragAndDropFileTransferEnabled else {
            reportError("File transfer disabled", "Turn on drag-and-drop file transfer in Settings to send files to the phone.")
            return
        }
        guard let serial = selectedDevice.adbSerial else {
            reportError("Can’t send files", "Connect a device before dropping files onto the mirror.")
            return
        }
        Task { [weak self] in
            var installed = 0
            var pushed = 0
            var failure: String?
            for url in fileURLs where failure == nil {
                let isAPK = url.pathExtension.lowercased() == "apk"
                let args = Self.adbDeviceArguments(serial: serial) + (
                    isAPK
                        ? ["install", "-r", url.path]
                        : ["push", url.path, "/sdcard/Download/"]
                )
                let result = await Task.detached {
                    Tooling.runResult("adb", arguments: args, timeout: 300)
                }.value
                let ok = isAPK
                    ? result.output.localizedCaseInsensitiveContains("success")
                    : result.succeeded
                if ok {
                    if isAPK { installed += 1 } else { pushed += 1 }
                } else {
                    failure = Self.oneLine(result.output)
                }
            }
            guard let self else { return }
            if let failure {
                self.reportError("Transfer failed", "Couldn’t send a file to the phone: \(failure)")
            } else {
                var parts: [String] = []
                if installed > 0 { parts.append("Installed \(installed) app\(installed == 1 ? "" : "s")") }
                if pushed > 0 { parts.append("Copied \(pushed) file\(pushed == 1 ? "" : "s") to Download") }
                let summary = parts.joined(separator: " · ")
                Logger.log("Dropped files: \(summary)")
                self.notify(title: "Sent to phone", body: summary)
            }
        }
    }

    func dismissError() {
        activeError = nil
    }

    /// Reveals the most recently saved screenshot or recording in Finder.
    func revealLastCapture() {
        guard let url = lastCaptureURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reveals the rolling diagnostic log in Finder so the user can inspect or
    /// share it when something goes wrong.
    func revealLogFile() {
        let url = Logger.logURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Maps a thrown mirror/host error to a friendly, actionable sentence.
    static func mirrorFailureMessage(for error: Error) -> String {
        let detail: String
        switch error {
        case let hostError as ScrcpyServerHost.HostError: detail = hostError.description
        case let sessionError as MirrorSession.SessionError: detail = sessionError.description
        default: detail = error.localizedDescription
        }
        let lowered = detail.lowercased()
        if lowered.contains("adb is not on path") || lowered.contains("adb is missing") {
            return "adb wasn't found. Install Android platform-tools (e.g. `brew install android-platform-tools`) and try again."
        }
        if lowered.contains("scrcpy-server") {
            return "The mirroring engine file is missing from the app. Reinstall Android Mirroring."
        }
        if lowered.contains("unauthorized") || lowered.contains("device unauthorized") {
            return "This Mac isn't authorized on the phone yet. Unlock the phone and tap “Allow” on the USB-debugging prompt."
        }
        if lowered.contains("offline") || lowered.contains("no devices") || lowered.contains("not found") {
            return "The phone went offline. Reconnect it (USB or Wi-Fi) and try again."
        }
        if lowered.contains("timed out") {
            return "The phone didn’t respond in time. Check the cable or Wi-Fi connection and try again."
        }
        return detail
    }

    static let minimumConnectionWindowSize = NSSize(width: 384, height: 688)
    static var onboardingWindowSize: NSSize {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 390, height: 850)
        return MirrorContentWindowController.initialWrappedShellSize(
            for: MirrorContentWindowController.defaultMirrorSize,
            visibleFrame: visibleFrame,
            maximumHeightBasis: MirrorContentWindowController.resolutionHeight(
                for: NSScreen.main,
                fallbackVisibleFrame: visibleFrame
            )
        )
    }

    @Published private(set) var discoveredPhones: [DiscoveredPhone] = []
    @Published private(set) var pairedPhones: [PairedPhoneRecord] = []
    @Published private(set) var qrPairingSession: ADBQRCodePairingSession?
    @Published private(set) var isQRCodePairingWaiting = false

    private let adb = ADBController()
    private let store = PairedPhoneStore()
    private lazy var discovery = DiscoveryService(adb: adb)

    private weak var connectionWindow: NSWindow?
    private var mirrorSession: MirrorSession?
    private var lastPresenceAutoConnectAttemptAt: Date?
    private var deviceWatcherTask: Task<Void, Never>?
    private var lastUSBHandoffSerial: String?
    private var qrPairingTask: Task<Void, Never>?
    private var usbConnectTask: Task<Void, Never>?
    private var wirelessStartTask: Task<Void, Never>?
    private var disconnectRecoveryTask: Task<Void, Never>?
    private var screenRecordingMonitorTask: Task<Void, Never>?
    private var mirrorSettingsRestartTask: Task<Void, Never>?
    private var suppressMirrorSettingsRestart = false
    private var suppressMirrorAudioForReconnect = false
    /// Holds the currently-playing capture cue sound so it isn't deallocated
    /// mid-playback.
    private var retainedCaptureSound: NSSound?
    // Crash-loop breaker for flaky device-side servers.
    private var lastMirrorStartAt: Date?
    private var consecutiveQuickMirrorFailures = 0
    private var autoMirrorBackoffUntil: Date?
    private var mirrorStartGeneration = 0
    /// True while a mirror session has ended but we're about to retry/reconnect
    /// (e.g. audio→video fallback, or within the backoff window). Keeps the app
    /// from terminating in the windowless gap between sessions.
    private(set) var isAwaitingReconnect = false
    /// A session that dies sooner than this counts as a "quick" failure.
    static let quickMirrorFailureThreshold: TimeInterval = 12
    nonisolated static let disconnectRecoveryGracePeriod: TimeInterval = 5

    var hasActiveMirrorSession: Bool {
        mirrorSession != nil
    }

    enum CaptureCueKind: Equatable {
        case screenshot
        case recordingStarted
        case recordingStopped
    }

    struct CaptureCue: Equatable, Identifiable {
        let id = UUID()
        let kind: CaptureCueKind

        var title: String {
            switch kind {
            case .screenshot: return "Screenshot captured"
            case .recordingStarted: return "Recording started"
            case .recordingStopped: return "Recording saved"
            }
        }

        var symbolName: String {
            switch kind {
            case .screenshot: return "camera.fill"
            case .recordingStarted: return "record.circle.fill"
            case .recordingStopped: return "checkmark.circle.fill"
            }
        }
    }

    init(
        startBackgroundServices: Bool = true,
        pairedPhones previewPairedPhones: [PairedPhoneRecord]? = nil
    ) {
        pairedPhones = previewPairedPhones ?? store.load()
        if let mostRecentRecord = Self.recordsByMostRecent(pairedPhones).first {
            select(record: mostRecentRecord)
        }

        guard startBackgroundServices else { return }

        discovery.start { [weak self] phones in
            guard let self else { return }
            self.discoveredPhones = phones
            self.autoConnectToAvailableRememberedDevice(livePhones: phones)
        }
        startDeviceWatcher()
        attemptAutoReconnect()
    }

    deinit {
        deviceWatcherTask?.cancel()
        qrPairingTask?.cancel()
        usbConnectTask?.cancel()
        wirelessStartTask?.cancel()
        disconnectRecoveryTask?.cancel()
        screenRecordingMonitorTask?.cancel()
        mirrorSettingsRestartTask?.cancel()
    }

    // MARK: - Window registration

    func registerConnectionWindow(_ window: NSWindow?) {
        guard let window else { return }
        connectionWindow = window
    }

    func resetFirstTimeUserOnboardingState() {
        UserDefaults.standard.set(false, forKey: "hasSeenFirstTimeUserOnboarding")
        UserDefaults.standard.removeObject(forKey: PairedPhoneStore.defaultsKey)
        for suiteName in PairedPhoneStore.compatibilitySuites {
            UserDefaults(suiteName: suiteName)?.set(false, forKey: "hasSeenFirstTimeUserOnboarding")
            UserDefaults(suiteName: suiteName)?.removeObject(forKey: PairedPhoneStore.defaultsKey)
        }
        pairedPhones = []
        selectedDevice = .demo
        stopQRCodePairingSession()
    }

    // MARK: - Discovery → auto-reconnect

    /// On launch, try saved adb routes immediately; if needed, give mDNS a few
    /// seconds for a previously-paired phone to advertise its connect service.
    /// Bluetooth-style auto-reconnect.
    private func attemptAutoReconnect() {
        guard !pairedPhones.isEmpty else { return }
        let adb = self.adb
        Task { [weak self] in
            for attempt in 0..<6 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let self else { return }
                if self.isMirroring || self.isPairing {
                    return
                }

                let devicesOutput = await Task.detached { adb.run(["devices", "-l"]) }.value
                let authorizedDevices = Self.authorizedADBDevices(in: devicesOutput)

                let authorizedDevice = self.preferUSBMirroring
                    ? authorizedDevices.first(where: \.isUSB) ?? authorizedDevices.first
                    : authorizedDevices.first
                if let authorizedDevice {
                    await self.mirrorAuthorizedDevicePreferringWireless(authorizedDevice)
                    return
                }

                for record in Self.recordsByMostRecent(self.pairedPhones) {
                    if Self.isWirelessRecord(record) {
                        if let connectedAddress = await Self.connectToRememberedWireless(
                            adb: adb,
                            savedAddress: record.lastAddress
                        ) {
                            self.select(record: record)
                            self.selectedDevice.adbSerial = connectedAddress
                            self.touchPairedPhone(
                                id: record.id,
                                displayName: record.displayName,
                                address: connectedAddress
                            )
                            self.stopQRCodePairingSession()
                            self.startMirroring()
                            return
                        }
                    } else if let rememberedUSB = authorizedDevices.first(where: { device in
                        device.isUSB && (device.serial == record.id || device.serial == record.lastAddress)
                    }) {
                        await self.mirrorAuthorizedDevicePreferringWireless(rememberedUSB)
                        return
                    }
                }

                let livePhones = await Task.detached { adb.connectableMDNSTargets() }.value
                let candidate = self.mostRecentPairedPhone(in: livePhones + self.discoveredPhones)
                if let candidate {
                    self.stopQRCodePairingSession()
                    self.connectAndMirror(phone: candidate)
                    return
                }
            }
        }
    }

    private func connectAndMirror(phone: DiscoveredPhone) {
        let address = phone.address
        let serviceID = phone.id
        let label = displayName(for: phone)

        let adb = self.adb
        Task { [weak self] in
            await adb.restartServer()
            let output = await Task.detached { adb.run(["connect", address]) }.value

            guard let self else { return }
            let lower = output.lowercased()
            let ok = lower.contains("connected") || lower.contains("already")
            if ok {
                let deviceName = await Self.connectedDeviceName(adb: adb, serial: address, fallback: label)
                self.touchPairedPhone(id: serviceID, displayName: deviceName, address: address)
                self.selectedDevice.adbSerial = address
                self.selectedDevice.name = deviceName
                self.stopQRCodePairingSession()
                self.startMirroring()
            } else {
            }
        }
    }

    private func mirrorAuthorizedDevicePreferringWireless(_ device: AuthorizedADBDevice) async {
        guard !isMirroring, !isPairing else { return }

        if device.isUSB {
            guard Self.shouldAttemptWirelessHandoff(from: device, preferUSBMirroring: preferUSBMirroring) else {
                select(device: device)
                touchPairedPhone(
                    id: device.serial,
                    displayName: selectedDisplayName(for: device.model),
                    address: device.serial
                )
                stopQRCodePairingSession()
                startMirroring()
                return
            }

            isPairing = true
            let startedWirelessMirror = await prepareWirelessMirror(from: device)
            if startedWirelessMirror {
                return
            }

            guard !isMirroring else { return }
            showWirelessHandoffRequired(for: device)
            return
        }

        select(device: device)
        touchPairedPhone(
            id: device.serial,
            displayName: selectedDisplayName(for: device.model),
            address: device.serial
        )
        stopQRCodePairingSession()
        startMirroring()
    }

    private func autoConnectToAvailableRememberedDevice(
        authorizedDevices: [AuthorizedADBDevice] = [],
        livePhones: [DiscoveredPhone]
    ) {
        guard !isMirroring, !isPairing, !pairedPhones.isEmpty else {
            return
        }

        if let lastPresenceAutoConnectAttemptAt,
           Date().timeIntervalSince(lastPresenceAutoConnectAttemptAt) < 3 {
            return
        }

        let records = Self.recordsByMostRecent(pairedPhones)

        for record in records {
            if let device = Self.rememberedAuthorizedDevice(for: record, in: authorizedDevices) {
                lastPresenceAutoConnectAttemptAt = Date()
                Task { [weak self] in
                    await self?.mirrorAuthorizedDevicePreferringWireless(device)
                }
                return
            }
        }

        if let phone = mostRecentPairedPhone(in: livePhones) {
            lastPresenceAutoConnectAttemptAt = Date()
            stopQRCodePairingSession()
            connectAndMirror(phone: phone)
            return
        }

        guard let wirelessRecord = records.first(where: Self.isWirelessRecord) else {
            return
        }

        lastPresenceAutoConnectAttemptAt = Date()
        let adb = self.adb
        Task { [weak self] in
            let connectedAddress = await Self.connectToRememberedWireless(
                adb: adb,
                savedAddress: wirelessRecord.lastAddress
            )

            guard let self,
                  !self.isMirroring,
                  !self.isPairing,
                  let connectedAddress
            else { return }

            let deviceName = await Self.connectedDeviceName(
                adb: adb,
                serial: connectedAddress,
                fallback: wirelessRecord.displayName
            )
            self.select(record: wirelessRecord)
            self.selectedDevice.adbSerial = connectedAddress
            self.touchPairedPhone(
                id: wirelessRecord.id,
                displayName: deviceName,
                address: connectedAddress
            )
            self.selectedDevice.name = deviceName
            self.stopQRCodePairingSession()
            self.startMirroring()
        }
    }

    private func touchPairedPhone(id: String, displayName: String, address: String) {
        pairedPhones = store.touch(pairedPhones, id: id, displayName: displayName, address: address)
        store.save(pairedPhones)
    }

    private func selectedDisplayName(for fallback: String) -> String {
        Self.specificDeviceName(fallback) ?? Self.specificDeviceName(selectedDevice.name) ?? fallback
    }

    private func displayName(for phone: DiscoveredPhone) -> String {
        pairedPhones.first(where: { $0.id == phone.id })
            .flatMap { Self.specificDeviceName($0.displayName) } ?? "Android device"
    }

    // MARK: - Scan / pair flows

    func scanADBDevices() {
        isScanning = true
        let adb = self.adb
        Task { [weak self] in
            let output = await Task.detached { adb.run(["devices", "-l"]) }.value
            guard let self else { return }
            self.isScanning = false
            self.applyADBOutput(output)
        }
    }

    /// Single `adb devices -l` poll that drives both device-presence tracking
    /// and USB→wireless handoff. Previously these were two independent 1.5s
    /// loops, each spawning its own `adb` process; merging them halves the idle
    /// process churn, and the adaptive interval eases off further when there's
    /// nothing to do — meaningfully lower idle CPU/battery.
    private func startDeviceWatcher() {
        guard deviceWatcherTask == nil else { return }
        let adb = self.adb
        deviceWatcherTask = Task { [weak self] in
            while !Task.isCancelled {
                let output = await Task.detached { adb.run(["devices", "-l"]) }.value
                guard let self else { return }
                let authorized = Self.authorizedADBDevices(in: output)

                // Presence + remembered-device auto-connect (always; both self-guard).
                self.applyDevicePresence(output)
                self.autoConnectToAvailableRememberedDevice(
                    authorizedDevices: authorized,
                    livePhones: self.discoveredPhones
                )

                // USB → wireless handoff (only when idle, never mid-session).
                if !self.preferUSBMirroring, !self.isMirroring, !self.isPairing {
                    if let usbDevice = Self.usbHandoffCandidate(
                        in: output,
                        lastAttemptedSerial: self.lastUSBHandoffSerial
                    ) {
                        self.isPairing = true
                        let started = await self.prepareWirelessMirror(from: usbDevice)
                        self.lastUSBHandoffSerial = started ? usbDevice.serial : nil
                    } else if authorized.first(where: \.isUSB) == nil {
                        self.lastUSBHandoffSerial = nil
                    }
                }

                let interval: UInt64
                if self.isPairing {
                    interval = 1_000_000_000          // mid-handoff: stay responsive
                } else if self.isMirroring {
                    interval = 2_000_000_000          // only watching for a disconnect
                } else if authorized.isEmpty {
                    interval = 3_000_000_000          // nothing plugged in: ease off
                } else {
                    interval = 1_500_000_000          // connected but idle
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func ensureQRCodePairingSession() {
        guard !isMirroring, !isRecoveringConnection else { return }
        if qrPairingSession == nil {
            qrPairingSession = .random()
        }
        startQRCodePairingWatcher()
    }

    func restartQRCodePairingSession() {
        guard !isMirroring, !isRecoveringConnection else { return }
        qrPairingTask?.cancel()
        qrPairingTask = nil
        isQRCodePairingWaiting = false
        qrPairingSession = .random()
        startQRCodePairingWatcher()
    }

    func stopQRCodePairingSession() {
        let hadPairingTask = qrPairingTask != nil
        qrPairingTask?.cancel()
        qrPairingTask = nil
        isQRCodePairingWaiting = false
        if hadPairingTask && isPairing {
            isPairing = false
        }
    }

    private func startQRCodePairingWatcher() {
        guard qrPairingTask == nil,
              let session = qrPairingSession
        else { return }

        isQRCodePairingWaiting = true

        let adb = self.adb
        qrPairingTask = Task { [weak self] in
            await adb.restartServer()
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                let phones = await Task.detached { adb.mdnsServices() }.value
                guard !Task.isCancelled else { return }

                guard let self else { return }
                guard self.qrPairingSession == session else { return }

                guard let pairingPhone = ADBQRCodePairingSession.pairingService(
                    named: session.serviceName,
                    in: phones
                ) else {
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
                    adb.run(["connect", connectablePhone.address])
                }.value
                guard !Task.isCancelled else { return }

                guard Self.adbConnectSucceeded(connectOutput) else {
                    self.resetQRCodePairingAfterFailure(
                        "Paired, but could not connect to \(connectablePhone.address). Scan the new code and try again."
                    )
                    return
                }

                // Hand the Wireless-debugging session off to a plain `tcpip
                // 5555` listener so future reconnects work on the same Wi-Fi
                // without turning the Wireless-debugging toggle back on. Falls
                // back to the TLS target if the phone won't switch to tcpip.
                let connectedPhone: DiscoveredPhone
                if let legacyAddress = await Self.promoteToLegacyTCPIP(
                    adb: adb,
                    sourceSerial: connectablePhone.address
                ) {
                    connectedPhone = DiscoveredPhone(
                        id: connectablePhone.id,
                        address: legacyAddress,
                        kind: .connectable,
                        lastSeen: .now
                    )
                } else {
                    connectedPhone = connectablePhone
                }
                guard !Task.isCancelled else { return }

                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: connectedPhone.address,
                    fallback: "Android device"
                )
                self.finishQRCodePairing(with: connectedPhone, displayName: deviceName)
                return
            }
        }
    }

    private func resetQRCodePairingAfterFailure(_ message: String) {
        isPairing = false
        isQRCodePairingWaiting = false
        qrPairingTask = nil
        qrPairingSession = .random()
        startQRCodePairingWatcher()
    }

    private func finishQRCodePairing(with phone: DiscoveredPhone, displayName: String) {
        isPairing = false
        isQRCodePairingWaiting = false
        qrPairingTask = nil
        qrPairingSession = nil
        touchPairedPhone(
            id: phone.id,
            displayName: displayName,
            address: phone.address
        )
        selectedDevice = MirrorDevice(
            id: phone.id,
            name: displayName,
            model: "Android",
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: "Wireless debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: phone.address
        )
        startMirroring()
    }

    @discardableResult
    private func prepareWirelessMirror(from usbDevice: AuthorizedADBDevice) async -> Bool {
        select(device: usbDevice)
        touchPairedPhone(
            id: usbDevice.serial,
            displayName: usbDevice.model,
            address: usbDevice.serial
        )

        let adb = self.adb
        let routeOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "ip", "route"])
        }.value

        // Prefer the legacy `adb tcpip 5555` listener. It's the only wireless
        // adb path that stays reachable without the phone's Wireless debugging
        // toggle, so the address we remember keeps working on later "same
        // Wi-Fi" reconnects (until the phone reboots, which drops tcpip mode).
        if let legacyAddress = Self.legacyTCPIPDebuggingAddress(routeOutput: routeOutput) {
            await Self.primeADBWirelessRoute(
                adb: adb,
                usbSerial: usbDevice.serial,
                wirelessAddress: legacyAddress
            )
            let tcpipOutput = await Task.detached {
                adb.run(["-s", usbDevice.serial, "tcpip", "\(Self.legacyADBWirelessPort)"])
            }.value

            if Self.adbTCPIPSucceeded(tcpipOutput) {
                if await Self.waitForADBWirelessTargetReady(
                    adb: adb,
                    address: legacyAddress,
                    attempts: 15,
                    primeRoute: {
                        await Self.primeADBWirelessRoute(
                            adb: adb,
                            usbSerial: usbDevice.serial,
                            wirelessAddress: legacyAddress
                        )
                    }
                ) {
                    isPairing = false
                    let deviceName = await Self.connectedDeviceName(
                        adb: adb,
                        serial: legacyAddress,
                        fallback: usbDevice.model
                    )
                    finishWirelessHandoff(
                        usbDevice: usbDevice,
                        wirelessID: legacyAddress,
                        address: legacyAddress,
                        displayName: deviceName
                    )
                    return true
                }
            }
        }

        // Fallback for phones that block `adb tcpip` but already expose Android
        // 11 Wireless debugging. Its random TLS port stops answering once the
        // toggle is turned off, so we only reach for it if 5555 didn't take.
        let tlsPortOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "getprop", "service.adb.tls.port"])
        }.value
        let tcpPortOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "getprop", "service.adb.tcp.port"])
        }.value
        if let tlsAddress = Self.wirelessDebuggingAddress(
            routeOutput: routeOutput,
            tlsPortOutput: tlsPortOutput,
            tcpPortOutput: tcpPortOutput
        ) {
            if await Self.waitForADBWirelessTargetReady(
                adb: adb,
                address: tlsAddress,
                attempts: 8,
                primeRoute: {
                    await Self.primeADBWirelessRoute(
                        adb: adb,
                        usbSerial: usbDevice.serial,
                        wirelessAddress: tlsAddress
                    )
                }
            ) {
                isPairing = false
                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: tlsAddress,
                    fallback: usbDevice.model
                )
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    wirelessID: tlsAddress,
                    address: tlsAddress,
                    displayName: deviceName
                )
                return true
            }

        }

        let discoveredWirelessPhones = await Task.detached {
            adb.connectableMDNSTargets()
        }.value
        if let wirelessPhone = Self.wirelessPhoneMatchingUSBRoute(
            routeOutput,
            phones: discoveredWirelessPhones
        ) {
            if await Self.waitForADBWirelessTargetReady(
                adb: adb,
                address: wirelessPhone.address,
                attempts: 8,
                primeRoute: {
                    await Self.primeADBWirelessRoute(
                        adb: adb,
                        usbSerial: usbDevice.serial,
                        wirelessAddress: wirelessPhone.address
                    )
                }
            ) {
                isPairing = false
                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: wirelessPhone.address,
                    fallback: usbDevice.model
                )
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    wirelessID: wirelessPhone.id,
                    address: wirelessPhone.address,
                    displayName: deviceName
                )
                return true
            }

        }

        isPairing = false
        return false
    }

    private func finishWirelessHandoff(
        usbDevice: AuthorizedADBDevice,
        wirelessID: String,
        address: String,
        displayName: String
    ) {
        touchPairedPhone(
            id: wirelessID,
            displayName: displayName,
            address: address
        )
        selectedDevice.adbSerial = address
        selectedDevice.name = displayName
        selectedDevice.network = "Wi-Fi debugging"
        stopQRCodePairingSession()
        startMirroring()
    }

    func connectViaUSB() {
        guard !isMirroring else { return }
        usbConnectTask?.cancel()
        let generation = mirrorStartGeneration
        isPairing = true

        let adb = self.adb
        usbConnectTask = Task { [weak self] in
            let output = await Task.detached { adb.run(["devices", "-l"]) }.value
            guard !Task.isCancelled else { return }
            let usbDevice = Self.authorizedADBDevices(in: output).first(where: \.isUSB)
            let hasUnauthorizedUSB = output
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .contains { $0.contains("unauthorized") && $0.contains("usb:") }

            guard let self else { return }
            guard self.mirrorStartGeneration == generation else { return }
            if hasUnauthorizedUSB {
                self.isPairing = false
                self.usbConnectTask = nil
                return
            }

            guard let usbDevice else {
                self.isPairing = false
                self.usbConnectTask = nil
                return
            }

            if self.preferUSBMirroring {
                self.isPairing = false
                self.usbConnectTask = nil
                self.select(device: usbDevice)
                self.touchPairedPhone(
                    id: usbDevice.serial,
                    displayName: self.selectedDisplayName(for: usbDevice.model),
                    address: usbDevice.serial
                )
                self.stopQRCodePairingSession()
                self.startMirroring(manual: true)
                return
            }

            let startedWirelessMirror = await self.prepareWirelessMirror(from: usbDevice)
            guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
            self.usbConnectTask = nil
            guard !startedWirelessMirror else { return }

            self.showWirelessHandoffRequired(for: usbDevice)
        }
    }

    private func showWirelessHandoffRequired(for device: AuthorizedADBDevice) {
        isPairing = false
        select(device: device)
        selectedDevice.states = [.wirelessDebuggingRequired, .companionConnected]
        touchPairedPhone(
            id: device.serial,
            displayName: device.model,
            address: device.serial
        )
        showConnectionWindow()
    }

    private func mostRecentPairedPhone(in phones: [DiscoveredPhone]) -> DiscoveredPhone? {
        for record in Self.recordsByMostRecent(pairedPhones) where Self.isWirelessRecord(record) {
            if let phone = Self.rememberedConnectablePhone(for: record, in: phones) {
                return phone
            }
        }
        return nil
    }

    private func applyADBOutput(_ output: String) {
        guard let first = Self.authorizedADBDevices(in: output).first else {
            selectedDevice.states = [.wirelessDebuggingRequired, .usbAuthorizationRequired, .companionConnected]
            isSelectedDeviceOnline = false
            return
        }

        select(device: first)
    }

    private func select(device: AuthorizedADBDevice) {
        isSelectedDeviceOnline = true
        selectedDevice = MirrorDevice(
            id: device.serial,
            name: device.model,
            model: device.product,
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: device.isUSB ? "USB debugging" : "Wireless debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: device.serial
        )
    }

    private func select(record: PairedPhoneRecord) {
        isSelectedDeviceOnline = false
        selectedDevice = MirrorDevice(
            id: record.id,
            name: record.displayName,
            model: "Android",
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: Self.isWirelessRecord(record) ? "Wireless debugging" : "USB debugging",
            lastSeen: record.lastConnected,
            states: [.wirelessDebuggingRequired, .companionConnected],
            adbSerial: record.lastAddress
        )
    }

    private func applyDevicePresence(_ output: String) {
        let devices = Self.authorizedADBDevices(in: output)
        guard let serial = selectedDevice.adbSerial else {
            // Nothing selected yet (e.g. fresh onboarding). Adopt the first live
            // device so a working USB/wireless connection advances the UI out of
            // first-run instead of leaving it pinned to the onboarding window.
            applyADBOutput(output)
            return
        }

        guard let liveDevice = devices.first(where: { $0.serial == serial }) else {
            isSelectedDeviceOnline = false
            if selectedDevice.states.contains(.mirroringReady) {
                selectedDevice.states = [.wirelessDebuggingRequired, .companionConnected]
            }
            return
        }

        isSelectedDeviceOnline = true
        selectedDevice.lastSeen = .now
        selectedDevice.name = liveDevice.model
        selectedDevice.model = liveDevice.product
        selectedDevice.network = liveDevice.isUSB ? "USB debugging" : "Wireless debugging"
        selectedDevice.states = [.mirroringReady, .companionConnected]
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

    nonisolated static func shouldAttemptWirelessHandoff(
        from device: AuthorizedADBDevice,
        preferUSBMirroring: Bool
    ) -> Bool {
        device.isUSB && !preferUSBMirroring
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

    nonisolated static func adbConnectSucceeded(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("connected to ") || lower.contains("already connected to ")
    }

    /// Wireless addresses to try for a remembered phone, most-preferred first.
    /// Always includes the stable legacy `:5555` port: an older record may have
    /// saved a random Wireless-debugging TLS port that no longer answers once
    /// the toggle is off, whereas a `tcpip` listener on 5555 survives without it.
    nonisolated static func reconnectCandidateAddresses(for savedAddress: String) -> [String] {
        var candidates = [savedAddress]
        if let host = host(in: savedAddress) {
            let legacy = "\(host):\(legacyADBWirelessPort)"
            if !candidates.contains(legacy) {
                candidates.append(legacy)
            }
        }
        return candidates
    }

    /// Tries each candidate address for a remembered phone and returns the first
    /// one adb accepts, or nil. Needs no phone interaction and no Wireless
    /// debugging toggle — just reachability on the current network.
    nonisolated static func connectToRememberedWireless(
        adb: ADBController,
        savedAddress: String
    ) async -> String? {
        for candidate in reconnectCandidateAddresses(for: savedAddress) {
            let output = await Task.detached { adb.run(["connect", candidate]) }.value
            if adbConnectSucceeded(output) {
                return candidate
            }
        }
        return nil
    }

    /// Promotes an already-connected wireless adb device (e.g. one reached via
    /// Android 11 Wireless debugging on a random TLS port) to a plain `tcpip
    /// 5555` listener, so later reconnects work on the same Wi-Fi without the
    /// Wireless-debugging toggle. `adb tcpip` works over any transport, so the
    /// source can itself be a wireless address — no USB cable required. Returns
    /// `host:5555` on success, or nil to keep using the original target.
    nonisolated static func promoteToLegacyTCPIP(
        adb: ADBController,
        sourceSerial: String
    ) async -> String? {
        let routeOutput = await Task.detached {
            adb.run(["-s", sourceSerial, "shell", "ip", "route"])
        }.value
        guard let legacyAddress = legacyTCPIPDebuggingAddress(routeOutput: routeOutput) else {
            return nil
        }
        if legacyAddress == sourceSerial {
            return legacyAddress
        }

        let tcpipOutput = await Task.detached {
            adb.run(["-s", sourceSerial, "tcpip", "\(legacyADBWirelessPort)"])
        }.value
        guard adbTCPIPSucceeded(tcpipOutput) else { return nil }

        // adbd restarts on 5555; the old transport drops, so retry connect.
        let ready = await waitForADBWirelessTargetReady(
            adb: adb,
            address: legacyAddress,
            attempts: 15
        )
        return ready ? legacyAddress : nil
    }

    nonisolated static func adbPairSucceeded(_ output: String) -> Bool {
        output.lowercased().contains("successfully paired")
    }

    nonisolated static func recordsByMostRecent(_ records: [PairedPhoneRecord]) -> [PairedPhoneRecord] {
        records.sorted { $0.lastConnected > $1.lastConnected }
    }

    nonisolated static func rememberedAuthorizedDevice(
        for record: PairedPhoneRecord,
        in devices: [AuthorizedADBDevice]
    ) -> AuthorizedADBDevice? {
        if let exact = devices.first(where: { device in
            device.serial == record.id || device.serial == record.lastAddress
        }) {
            return exact
        }

        guard record.displayName.localizedCaseInsensitiveCompare("Android device") != .orderedSame else {
            return nil
        }

        return devices.first { device in
            device.model.localizedCaseInsensitiveCompare(record.displayName) == .orderedSame
        }
    }

    nonisolated static func isWirelessRecord(_ record: PairedPhoneRecord) -> Bool {
        record.lastAddress.contains(":")
    }

    nonisolated static func rememberedConnectablePhone(
        for record: PairedPhoneRecord,
        in phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind == .connectable }
        if let exact = connectablePhones.first(where: { $0.id == record.id }) {
            return exact
        }
        guard let expectedHost = host(in: record.lastAddress) else {
            return connectablePhones.count == 1 ? connectablePhones.first : nil
        }
        if let sameHost = connectablePhones.first(where: { host(in: $0.address) == expectedHost }) {
            return sameHost
        }
        return connectablePhones.count == 1 ? connectablePhones.first : nil
    }

    nonisolated static func isWirelessADBTarget(_ target: String) -> Bool {
        target.contains(":") || target.contains("._adb") || target.hasPrefix("adb-")
    }

    nonisolated static func wifiIPAddress(in routeOutput: String) -> String? {
        for line in routeOutput.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.contains("wlan"), line.contains(" src ") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let srcIndex = parts.firstIndex(of: "src"),
                  parts.indices.contains(srcIndex + 1)
            else { continue }
            return parts[srcIndex + 1]
        }
        return nil
    }

    nonisolated static func wirelessDebuggingAddress(
        routeOutput: String,
        tlsPortOutput: String,
        tcpPortOutput: String? = nil
    ) -> String? {
        guard let wifiIP = wifiIPAddress(in: routeOutput) else { return nil }
        let port = validPort(in: tlsPortOutput) ?? tcpPortOutput.flatMap(validPort)
        guard let port else { return nil }
        return "\(wifiIP):\(port)"
    }

    nonisolated static let legacyADBWirelessPort = 5555

    nonisolated static func legacyTCPIPDebuggingAddress(routeOutput: String) -> String? {
        wifiIPAddress(in: routeOutput).map { "\($0):\(legacyADBWirelessPort)" }
    }

    private nonisolated static func validPort(in output: String) -> Int? {
        let trimmedPort = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmedPort), (1...65_535).contains(port) else {
            return nil
        }
        return port
    }

    nonisolated static func adbTCPIPSucceeded(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("restarting in tcp mode port")
            || lowercased.contains("already in tcp mode")
    }

    nonisolated static func waitForADBConnect(
        adb: ADBController,
        address: String,
        attempts: Int = 6,
        delayNanoseconds: UInt64 = 600_000_000
    ) async -> Bool {
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            let output = await Task.detached {
                adb.run(["connect", address])
            }.value

            if adbConnectSucceeded(output) {
                return true
            }
        }

        return false
    }

    nonisolated static func waitForADBWirelessTargetReady(
        adb: ADBController,
        address: String,
        attempts: Int = 8,
        delayNanoseconds: UInt64 = 700_000_000,
        primeRoute: (() async -> Void)? = nil
    ) async -> Bool {
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }

            await primeRoute?()

            let connectOutput = await Task.detached {
                adb.run(["connect", address])
            }.value
            Logger.log("ADB Wi-Fi handoff connect attempt \(attempt + 1)/\(attempts) address=\(address) output=\(connectOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            guard adbConnectSucceeded(connectOutput) else {
                continue
            }

            let shellOutput = await Task.detached {
                adb.run(["-s", address, "shell", "echo", "wifi-adb-ok"], timeout: 2)
            }.value
            Logger.log("ADB Wi-Fi handoff shell readiness attempt \(attempt + 1)/\(attempts) address=\(address) output=\(shellOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            if shellOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "wifi-adb-ok" {
                return true
            }
        }

        return false
    }

    nonisolated static func primeADBWirelessRoute(
        adb: ADBController,
        usbSerial: String,
        wirelessAddress: String
    ) async {
        guard let localAddress = localIPv4Address(matchingRemoteAddress: wirelessAddress) else {
            Logger.log("ADB Wi-Fi handoff route prime skipped: no local IPv4 address matches \(wirelessAddress)")
            return
        }

        let output = await Task.detached {
            adb.run(["-s", usbSerial, "shell", "ping", "-c", "1", "-W", "1", localAddress], timeout: 2)
        }.value
        Logger.log("ADB Wi-Fi handoff route prime usb=\(usbSerial) phoneTarget=\(wirelessAddress) macAddress=\(localAddress) output=\(output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    nonisolated static func localIPv4Address(matchingRemoteAddress remoteAddress: String) -> String? {
        guard let remoteHost = host(in: remoteAddress) ?? Optional(remoteAddress),
              let remote = ipv4NetworkValue(remoteHost)
        else { return nil }

        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr,
                  let netmask = current.pointee.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  netmask.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let local = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }

            guard local & mask == remote & mask else { continue }

            var localAddress = in_addr(s_addr: local)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &localAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            return String(cString: buffer)
        }

        return nil
    }

    private nonisolated static func ipv4NetworkValue(_ value: String) -> in_addr_t? {
        var address = in_addr()
        guard inet_pton(AF_INET, value, &address) == 1 else { return nil }
        return address.s_addr
    }

    nonisolated static func wirelessPhoneMatchingUSBRoute(
        _ routeOutput: String,
        phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind == .connectable }
        guard let wifiIP = wifiIPAddress(in: routeOutput) else {
            return connectablePhones.first
        }
        return connectablePhones.first { host(in: $0.address) == wifiIP }
    }

    nonisolated static func connectableWirelessPhone(
        matchingHostOf address: String,
        phones: [DiscoveredPhone]
    ) -> DiscoveredPhone? {
        let connectablePhones = phones.filter { $0.kind == .connectable }
        guard let expectedHost = host(in: address) else {
            return connectablePhones.first
        }
        return connectablePhones.first { host(in: $0.address) == expectedHost }
    }

    private nonisolated static func host(in address: String) -> String? {
        if address.hasPrefix("["),
           let endIndex = address.firstIndex(of: "]") {
            let hostStart = address.index(after: address.startIndex)
            return String(address[hostStart..<endIndex])
        }

        guard let separator = address.lastIndex(of: ":") else {
            return nil
        }
        return String(address[..<separator])
    }

    private static func waitForConnectableWirelessPhone(
        adb: ADBController,
        preferredAddress: String?,
        matchingHostOf address: String? = nil
    ) async -> DiscoveredPhone? {
        for _ in 0..<8 {
            if Task.isCancelled { return nil }
            if let preferredAddress {
                let connectOutput = await Task.detached { adb.run(["connect", preferredAddress]) }.value
                if Task.isCancelled { return nil }
                if adbConnectSucceeded(connectOutput) {
                    return DiscoveredPhone(
                        id: preferredAddress,
                        address: preferredAddress,
                        kind: .connectable,
                        lastSeen: .now
                    )
                }
            }

            let phones = await Task.detached { adb.connectableMDNSTargets() }.value
            if Task.isCancelled { return nil }
            if let address {
                if let matchingPhone = connectableWirelessPhone(matchingHostOf: address, phones: phones) {
                    return matchingPhone
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
                continue
            }
            if let phone = phones.first {
                return phone
            }
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        return nil
    }

    private nonisolated static func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        let tail = line[range.upperBound...]
        return tail.split(separator: " ").first.map(String.init)
    }

    nonisolated static func specificDeviceName(_ name: String) -> String? {
        let normalized = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let genericNames = ["android device", "authorized device", "device", "unknown device", "unknown"]
        return genericNames.contains(normalized.lowercased()) ? nil : normalized
    }

    nonisolated static func connectedDeviceName(
        adb: ADBController,
        serial: String,
        fallback: String
    ) async -> String {
        let output = await Task.detached {
            adb.run(["devices", "-l"])
        }.value
        if let device = authorizedADBDevices(in: output).first(where: { $0.serial == serial }),
           let name = specificDeviceName(device.model) {
            return name
        }
        return specificDeviceName(fallback) ?? "Android device"
    }

    // MARK: - Mirroring lifecycle

    private func scheduleMirrorSettingsRestart() {
        guard isMirroring, !isPairing else { return }
        mirrorSettingsRestartTask?.cancel()
        mirrorSettingsRestartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.isMirroring, !self.isPairing else { return }
            Logger.log("Restarting mirror to apply updated mirroring settings")
            self.stopMirroring()
            self.startMirroring(manual: true)
        }
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

        if manual {
            // A deliberate retry clears backoff.
            consecutiveQuickMirrorFailures = 0
            autoMirrorBackoffUntil = nil
            suppressMirrorAudioForReconnect = false
            isAwaitingReconnect = false
        } else if let until = autoMirrorBackoffUntil, Date() < until {
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

    private func startWirelessMirroring(savedTarget: String) {
        guard !isPairing else { return }
        wirelessStartTask?.cancel()

        let selectedID = selectedDevice.id
        let selectedName = selectedDevice.name
        let adb = self.adb
        let generation = mirrorStartGeneration

        isPairing = true

        wirelessStartTask = Task { [weak self] in
            var target: String?
            var refreshedSavedTarget: String?

            if savedTarget.contains(":") {
                if let connectedAddress = await Self.connectToRememberedWireless(
                    adb: adb,
                    savedAddress: savedTarget
                ) {
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
                } ?? (phones.filter { $0.kind == .connectable }.count == 1
                    ? phones.first(where: { $0.kind == .connectable })
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
            self.wirelessStartTask = nil
            guard let target else {
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

    func stopMirroring() {
        mirrorStartGeneration += 1
        usbConnectTask?.cancel()
        usbConnectTask = nil
        wirelessStartTask?.cancel()
        wirelessStartTask = nil
        mirrorSession?.onSessionEnded = nil
        mirrorSession?.stop()
        mirrorSession = nil
        isMirroring = false
        stopDisconnectRecovery()
        // A deliberate stop clears the crash-loop breaker.
        consecutiveQuickMirrorFailures = 0
        autoMirrorBackoffUntil = nil
        isAwaitingReconnect = false
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        }
    }

    private func launchNativeMirror(serial: String?) {
        Logger.log("Launching native mirror serial=\(serial ?? "default")")
        let session = MirrorSession(model: self, serial: serial)
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
            self.noteMirrorSessionEnded()
            if let finalMirrorFrame {
                self.connectionWindow?.setFrame(finalMirrorFrame, display: false)
            }
            self.showConnectionWindow(startsQRCodePairing: false)
            self.startDisconnectRecoveryFallback()
        }

        do {
            mirrorSession = session
            isMirroring = true
            isAwaitingReconnect = false
            selectedDevice.states = [.mirroringReady, .companionConnected]
            lastMirrorStartAt = Date()
            try session.start()
            activeError = nil
            hideConnectionWindowForNativeMirror()
        } catch {
            session.onSessionEnded = nil
            session.stop()
            if mirrorSession === session {
                mirrorSession = nil
            }
            isMirroring = false
            Logger.log("Mirror launch failed: \(error)")
            reportError("Couldn’t start mirroring", Self.mirrorFailureMessage(for: error))
            showConnectionWindow()
        }
    }

    private func startDisconnectRecoveryFallback() {
        isRecoveringConnection = true
        isAwaitingReconnect = true
        stopQRCodePairingSession()
        disconnectRecoveryTask?.cancel()
        disconnectRecoveryTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.disconnectRecoveryGracePeriod)
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !self.isMirroring else { return }
                if self.isSelectedDeviceOnline {
                    if let until = self.autoMirrorBackoffUntil, Date() < until {
                        let delay = max(0, until.timeIntervalSinceNow)
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        guard !Task.isCancelled, !self.isMirroring else { return }
                    }
                    self.startMirroring()
                    return
                }
            }
            guard !Task.isCancelled, let self, !self.isMirroring else { return }
            self.isRecoveringConnection = false
            self.isAwaitingReconnect = false
            self.ensureQRCodePairingSession()
        }
    }

    private func stopDisconnectRecovery() {
        disconnectRecoveryTask?.cancel()
        disconnectRecoveryTask = nil
        isRecoveringConnection = false
        isAwaitingReconnect = false
    }

    /// Called when a native mirror session ends. Distinguishes a stable session
    /// (resets all breakers) from a "quick" failure. Repeated quick failures
    /// arm a growing reconnect backoff.
    private func noteMirrorSessionEnded() {
        let lived = lastMirrorStartAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard lived < Self.quickMirrorFailureThreshold else {
            // Stable session — reset the reconnect backoff.
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

    private func hideConnectionWindowForNativeMirror() {
        connectionWindow?.childWindows?.forEach { $0.orderOut(nil) }
        connectionWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showConnectionWindow(startsQRCodePairing: Bool = true) {
        guard let connectionWindow, !isMirroring else { return }
        connectionWindow.makeKeyAndOrderFront(nil)
        if startsQRCodePairing {
            ensureQRCodePairingSession()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentCaptureCue(_ kind: CaptureCueKind) {
        captureCue = CaptureCue(kind: kind)
        playCaptureSound(for: kind)
    }

    /// Plays a distinct cue per capture action: the real macOS shutter for
    /// screenshots, and the dedicated screen-recording start/stop chimes for
    /// recording (distinct ascending "begin" and descending "end" tones). These
    /// ship inside CoreAudio.component (not in `NSSound(named:)`'s search path),
    /// so we load them by file path, then fall back to named system sounds, then
    /// a beep. `retainedCaptureSound` keeps the player alive until playback
    /// finishes (a local NSSound would be deallocated immediately).
    private func playCaptureSound(for kind: CaptureCueKind) {
        let fileCandidates: [String]
        let namedFallbacks: [String]
        switch kind {
        case .screenshot:
            fileCandidates = ["Grab.aif", "Shutter.aif"]   // real screenshot shutter
            namedFallbacks = ["Tink", "Pop"]
        case .recordingStarted:
            fileCandidates = ["begin_record.caf"]           // recording-start chime
            namedFallbacks = ["Bottle", "Pop"]
        case .recordingStopped:
            fileCandidates = ["end_record.caf"]             // recording-stop chime
            namedFallbacks = ["Glass", "Submarine"]
        }

        for file in fileCandidates {
            let path = Self.systemSoundsDirectory + file
            if let sound = NSSound(contentsOfFile: path, byReference: true), sound.play() {
                retainedCaptureSound = sound
                return
            }
        }
        for name in namedFallbacks {
            if let sound = NSSound(named: NSSound.Name(name)), sound.play() {
                retainedCaptureSound = sound
                return
            }
        }
        NSSound.beep()
    }

    private static let systemSoundsDirectory =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"

    // MARK: - Resize

    func resizeMirror(scale: CGFloat) {
        mirrorSession?.scaleWindow(by: scale)
    }

    func forwardKeyEventToMirrorSession(_ event: NSEvent) -> Bool {
        guard keyboardInputEnabled,
              mirrorSession != nil,
              MirrorSession.isMirrorCommandShortcut(event)
                || MirrorSession.androidKey(for: event) != nil
                || MirrorSession.androidCommandShortcutKey(for: event) != nil else {
            return false
        }
        mirrorSession?.forwardKeyEvent(event)
        return true
    }

    func centerMirrorWindow() {
        mirrorSession?.centerWindow()
    }

    func connect(record: PairedPhoneRecord) {
        guard !isMirroring, !isPairing else { return }
        select(record: record)
        stopQRCodePairingSession()
        startMirroring(manual: true)
    }

    func forgetPairedPhone(id: PairedPhoneRecord.ID) {
        pairedPhones = store.removing(id, from: pairedPhones)
        store.save(pairedPhones)
        if selectedDevice.id == id {
            selectedDevice = .demo
        }
    }

    func forgetAllPairedPhones() {
        pairedPhones = []
        store.clearAll()
        selectedDevice = .demo
    }

    // MARK: - Android input

    func sendAndroidKey(_ keycode: String) {
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        Task.detached {
            var arguments: [String] = []
            if let serial, !serial.isEmpty {
                arguments.append(contentsOf: ["-s", serial])
            }
            arguments.append(contentsOf: ["shell", "input", "keyevent", keycode])
            adb.run(arguments)
        }
    }

    func takeScreenshot() {
        let serial = selectedDevice.adbSerial
        presentCaptureCue(.screenshot)
        Task {
            let result = await Task.detached { () -> Result<URL, ScreenshotError> in
                guard let adbPath = Tooling.toolPath(named: "adb") else {
                    return .failure(.adbMissing)
                }
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = Self.adbDeviceArguments(serial: serial)
                    + ["exec-out", "screencap", "-p"]
                process.standardOutput = pipe
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard !data.isEmpty else {
                        return .failure(.emptyOutput)
                    }
                    let directory = try Self.mediaOutputDirectory()
                    let url = directory.appendingPathComponent(Self.mediaFilename(
                        kind: "Screenshot",
                        extension: "png"
                    ))
                    try data.write(to: url)
                    return .success(url)
                } catch {
                    return .failure(.runtime(error.localizedDescription))
                }
            }.value

            switch result {
            case .success(let url):
                Logger.log("Saved screenshot: \(url.path)")
                self.lastCaptureURL = url
            case .failure(.adbMissing):
                self.reportError("Screenshot failed", "adb wasn’t found. Install Android platform-tools and try again.")
            case .failure(.emptyOutput):
                self.reportError("Screenshot failed", "The phone returned an empty image. Make sure the screen is on and try again.")
            case .failure(.runtime(let message)):
                Logger.log("Screenshot failed: \(message)")
                self.reportError("Screenshot failed", Self.mirrorFailureMessage(for: NSError(domain: "screenshot", code: 0, userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
    }

    private enum ScreenshotError: Error {
        case adbMissing
        case emptyOutput
        case runtime(String)
    }

    func toggleScreenRecording() {
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        } else {
            startScreenRecording()
        }
    }

    private func startScreenRecording() {
        isRecording = true
        presentCaptureCue(.recordingStarted)
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        Task { [weak self] in
            let alreadyRunning = await Task.detached {
                Self.androidScreenRecordingIsRunning(adb: adb, serial: serial)
            }.value

            guard let self else { return }
            if alreadyRunning {
                self.startScreenRecordingMonitor()
                return
            }

            let output = await Task.detached {
                adb.run(Self.adbDeviceArguments(serial: serial) + [
                    "shell",
                    "rm -f /sdcard/android-mirroring-record.mp4; screenrecord /sdcard/android-mirroring-record.mp4 >/dev/null 2>&1 & echo started"
                ])
            }.value

            guard output.lowercased().contains("started") else {
                self.isRecording = false
                return
            }

            self.isRecording = true
            self.startScreenRecordingMonitor()
        }
    }

    private func stopScreenRecordingCleanup() {
        screenRecordingMonitorTask?.cancel()
        screenRecordingMonitorTask = nil
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        Task { [weak self] in
            await Task.detached {
                _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                    "shell",
                    "pkill -2 screenrecord >/dev/null 2>&1"
                ])
            }.value
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let result = await Task.detached { () -> Result<URL, RecordingError> in
                do {
                    let directory = try Self.mediaOutputDirectory()
                    let url = directory.appendingPathComponent(Self.mediaFilename(
                        kind: "Screen-Recording",
                        extension: "mp4"
                    ))
                    let output = adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "pull", "/sdcard/android-mirroring-record.mp4",
                        url.path
                    ], timeout: 120)
                    _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "shell",
                        "rm -f /sdcard/android-mirroring-record.mp4 >/dev/null 2>&1"
                    ])
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return .failure(.pullFailed(Self.oneLine(output)))
                    }
                    return .success(url)
                } catch {
                    return .failure(.runtime(error.localizedDescription))
                }
            }.value

            switch result {
            case .success(let url):
                Logger.log("Saved screen recording: \(url.path)")
                self?.lastCaptureURL = url
                self?.presentCaptureCue(.recordingStopped)
            case .failure(.pullFailed(let message)):
                Logger.log("Screen recording pull failed: \(message)")
                self?.reportError("Recording didn’t save", "Couldn’t copy the recording off the phone. Keep it connected until the save finishes.")
            case .failure(.runtime(let message)):
                Logger.log("Screen recording save failed: \(message)")
                self?.reportError("Recording didn’t save", Self.mirrorFailureMessage(for: NSError(domain: "recording", code: 0, userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
    }

    private func startScreenRecordingMonitor() {
        screenRecordingMonitorTask?.cancel()
        let adb = self.adb
        let serial = selectedDevice.adbSerial
        screenRecordingMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                let running = await Task.detached {
                    Self.androidScreenRecordingIsRunning(adb: adb, serial: serial)
                }.value
                guard let self else { return }
                if self.isRecording && !running {
                    self.isRecording = false
                    self.screenRecordingMonitorTask = nil
                    self.stopScreenRecordingCleanup()
                    return
                }
            }
        }
    }

    nonisolated private static func androidScreenRecordingIsRunning(adb: ADBController, serial: String?) -> Bool {
        let output = adb.run(Self.adbDeviceArguments(serial: serial) + [
            "shell",
            "if pgrep -x screenrecord >/dev/null 2>&1; then echo running; else echo stopped; fi"
        ])
        return output.lowercased().contains("running")
    }

    private enum RecordingError: Error {
        case pullFailed(String)
        case runtime(String)
    }

    nonisolated private static func adbDeviceArguments(serial: String?) -> [String] {
        guard let serial, !serial.isEmpty else { return [] }
        return ["-s", serial]
    }

    nonisolated private static func mediaOutputDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    nonisolated private static func mediaFilename(kind: String, extension fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Android-Mirroring-\(kind)_\(formatter.string(from: Date())).\(fileExtension)"
    }

    nonisolated static func oneLine(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

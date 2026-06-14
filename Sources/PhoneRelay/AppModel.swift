import SwiftUI
import AppKit
import Foundation
import Darwin
import Network
import UserNotifications

private final class OneShotCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false

    func run(_ work: () -> Void) {
        lock.lock()
        guard !hasRun else {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()
        work()
    }
}

enum MirrorScrollFeel: String, CaseIterable, Identifiable {
    case direct
    case balanced
    case smooth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return "Direct"
        case .balanced: return "Balanced"
        case .smooth: return "Smooth"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    typealias NotificationAuthorizationRequester = (@escaping (Bool, Error?) -> Void) -> Void
    typealias NotificationSettingsOpener = () -> Void
    typealias LocalNetworkPermissionPrompter = (@escaping (Bool) -> Void) -> Void

    nonisolated static let localNetworkPermissionReason =
        "Allow Local Network so PhoneRelay can find your phone on Wi-Fi for wireless pairing, USB-to-Wi-Fi handoff, and automatic reconnect."
    nonisolated static let notificationPermissionReason =
        "Turn on notifications if you want PhoneRelay to show unread notifications from your device on this Mac."
    nonisolated static let localNetworkRecommendedFix =
        "Allow Local Network in macOS Settings, or connect the phone over USB."
    nonisolated static let notificationForwardingDefaultsKey = "MirrorBehavior.notificationForwardingEnabled"
    nonisolated static let privacyPolicyURL = URL(string: "https://mallenkb.github.io/phone-mirroring/privacy.html")!
    nonisolated static let supportURL = URL(string: "https://mallenkb.github.io/phone-mirroring/support.html")!
    nonisolated static let latestReleaseURL = URL(string: "https://github.com/mallenkb/phone-mirroring/releases/latest")!
    nonisolated static let releaseMetadataURL = URL(string: "https://mallenkb.github.io/phone-mirroring/release.json")!
    nonisolated static let mirrorScrollSpeedDefaultsKey = "MirrorBehavior.scrollSpeedPercent"
    nonisolated static let mirrorScrollFeelDefaultsKey = "MirrorBehavior.scrollFeel"
    nonisolated static let mirrorProfileDefaultsKey = "MirrorQuality.profile"
    nonisolated static let screenshotFolderPathDefaultsKey = "Capture.screenshotFolderPath"
    nonisolated static let screenshotFolderBookmarkDefaultsKey = "Capture.screenshotFolderBookmark"
    nonisolated static let recordingFolderPathDefaultsKey = "Capture.recordingFolderPath"
    nonisolated static let recordingFolderBookmarkDefaultsKey = "Capture.recordingFolderBookmark"
    nonisolated static var canUseUserNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
    private nonisolated static let explicitDeviceSetupRequiredDefaultsKey =
        "MirrorBehavior.explicitDeviceSetupRequired"
    private nonisolated static let localNetworkSettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    nonisolated static func defaultNotificationForwardingEnabled(storedValue: Any?) -> Bool {
        (storedValue as? Bool) ?? false
    }

    nonisolated static func defaultMirrorScrollSpeedPercent(storedValue: Any?) -> Int {
        let value = (storedValue as? Int) ?? 20
        return min(100, max(10, value))
    }

    nonisolated static func defaultMirrorScrollFeel(storedValue: Any?) -> MirrorScrollFeel {
        guard let rawValue = storedValue as? String,
              let feel = MirrorScrollFeel(rawValue: rawValue) else {
            return .balanced
        }
        return feel
    }

    nonisolated static func scaledMirrorScrollDelta(_ delta: CGFloat, speedPercent: Int) -> CGFloat {
        delta * CGFloat(defaultMirrorScrollSpeedPercent(storedValue: speedPercent)) / 100
    }

    nonisolated static func shapedMirrorScrollDelta(
        _ delta: CGFloat,
        speedPercent: Int,
        feel: MirrorScrollFeel
    ) -> CGFloat {
        let scaled = scaledMirrorScrollDelta(delta, speedPercent: speedPercent)
        guard scaled != 0 else { return 0 }
        let magnitude = abs(scaled)
        let sign: CGFloat = scaled < 0 ? -1 : 1
        let shapedMagnitude: CGFloat
        switch feel {
        case .direct:
            shapedMagnitude = magnitude
        case .balanced:
            shapedMagnitude = pow(magnitude, 0.92)
        case .smooth:
            shapedMagnitude = pow(magnitude, 0.84)
        }
        return sign * shapedMagnitude
    }

    nonisolated static func defaultMirrorProfile(storedValue: Any?) -> MirrorProfile {
        guard let rawValue = storedValue as? String,
              let profile = MirrorProfile(rawValue: rawValue) else {
            return .recording
        }
        return profile
    }

    nonisolated static func isReleaseVersionNewer(_ latestVersion: String, than currentVersion: String) -> Bool {
        let latestComponents = versionComponents(from: latestVersion)
        let currentComponents = versionComponents(from: currentVersion)
        let componentCount = max(latestComponents.count, currentComponents.count)

        for index in 0..<componentCount {
            let latest = index < latestComponents.count ? latestComponents[index] : 0
            let current = index < currentComponents.count ? currentComponents[index] : 0
            if latest != current {
                return latest > current
            }
        }

        return false
    }

    private nonisolated static func versionComponents(from version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { component in
                guard !component.isEmpty else { return nil }
                return Int(component)
            }
    }

    nonisolated static func canCompleteFirstRunOnboarding(
        hasLocalNetworkPermission: Bool,
        hasNotificationPermission: Bool
    ) -> Bool {
        hasLocalNetworkPermission
    }

    @Published var selectedDevice: MirrorDevice = .demo
    @Published var isScanning = false
    @Published var isMirroring = false
    @Published var isRecording = false
    @Published var isPairing = false
    @Published private(set) var isRecoveringConnection = false
    /// True whenever a connect target is physically present (USB or a remembered
    /// wireless phone advertising on the network) but we aren't online/mirroring
    /// yet. Drives the unified "Connecting" indicator so it lights up the instant
    /// a saved phone appears, and self-clears once we're online or it's gone.
    @Published private(set) var isAutoConnecting = false
    @Published private(set) var isSelectedDeviceOnline = false
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
    @Published var mirrorScrollSpeedPercent: Int =
        AppModel.defaultMirrorScrollSpeedPercent(
            storedValue: UserDefaults.standard.object(forKey: AppModel.mirrorScrollSpeedDefaultsKey)
        ) {
        didSet {
            UserDefaults.standard.set(mirrorScrollSpeedPercent, forKey: Self.mirrorScrollSpeedDefaultsKey)
        }
    }
    @Published var mirrorScrollFeel: MirrorScrollFeel =
        AppModel.defaultMirrorScrollFeel(
            storedValue: UserDefaults.standard.object(forKey: AppModel.mirrorScrollFeelDefaultsKey)
        ) {
        didSet {
            UserDefaults.standard.set(mirrorScrollFeel.rawValue, forKey: Self.mirrorScrollFeelDefaultsKey)
        }
    }
    /// Mirrors Android notifications into macOS Notification Center by polling
    /// `dumpsys notification` over adb — no companion app on the phone. Off by
    /// default, and disabled automatically if macOS notification permission is
    /// denied.
    @Published var notificationForwardingEnabled: Bool =
        AppModel.defaultNotificationForwardingEnabled(
            storedValue: UserDefaults.standard.object(forKey: AppModel.notificationForwardingDefaultsKey)
        ) {
        didSet {
            UserDefaults.standard.set(
                notificationForwardingEnabled,
                forKey: Self.notificationForwardingDefaultsKey
            )
            updateNotificationForwarding()
        }
    }
    @Published private(set) var notificationForwardingPermissionDenied = false
    @Published private(set) var localNetworkPermissionGrantedForOnboarding = false
    @Published private(set) var isAwaitingLocalNetworkSettingsReturn = false
    @Published private(set) var notificationPermissionGrantedForOnboarding = false
    @Published private(set) var latestAuthorizedADBDevices: [AuthorizedADBDevice] = []
    @Published private(set) var latestHasUnauthorizedUSBDevice = false
    @Published private(set) var latestADBStatusText = "Not checked"
    @Published private(set) var reconnectAttemptCount = 0
    @Published var captureCue: CaptureCue?
    @Published private(set) var transferActivity: TransferActivity?
    @Published private(set) var screenshotFolderPath: String? =
        UserDefaults.standard.string(forKey: AppModel.screenshotFolderPathDefaultsKey)
    @Published private(set) var recordingFolderPath: String? =
        UserDefaults.standard.string(forKey: AppModel.recordingFolderPathDefaultsKey)

    // MARK: - Mirroring quality (applied to the next mirror session)

    /// Target video bitrate in megabits/sec.
    @Published var mirrorBitRateMbps: Int = (UserDefaults.standard.object(forKey: "MirrorQuality.bitRateMbps") as? Int) ?? 8 {
        didSet {
            guard oldValue != mirrorBitRateMbps else { return }
            UserDefaults.standard.set(mirrorBitRateMbps, forKey: "MirrorQuality.bitRateMbps")
            if !suppressMirrorSettingsRestart {
                scheduleMirrorSettingsRestart()
            }
        }
    }
    /// Cap on the longer screen dimension (px); lower = sharper-feeling + faster.
    @Published var mirrorMaxSize: Int = (UserDefaults.standard.object(forKey: "MirrorQuality.maxSize") as? Int) ?? 1600 {
        didSet {
            guard oldValue != mirrorMaxSize else { return }
            UserDefaults.standard.set(mirrorMaxSize, forKey: "MirrorQuality.maxSize")
            if !suppressMirrorSettingsRestart {
                scheduleMirrorSettingsRestart()
            }
        }
    }
    /// Frame-rate ceiling. 0 = automatic (match the phone and Mac refresh rates).
    @Published var mirrorMaxFps: Int = (UserDefaults.standard.object(forKey: "MirrorQuality.maxFps") as? Int) ?? 0 {
        didSet {
            guard oldValue != mirrorMaxFps else { return }
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
            guard oldValue != mirrorAudioEnabled else { return }
            suppressMirrorAudioForReconnect = false
            UserDefaults.standard.set(mirrorAudioEnabled, forKey: "MirrorQuality.experimentalOpusAudioEnabled")
            if !suppressMirrorSettingsRestart {
                scheduleMirrorSettingsRestart()
            }
        }
    }
    @Published var selectedMirrorProfile: MirrorProfile =
        AppModel.defaultMirrorProfile(storedValue: UserDefaults.standard.object(forKey: AppModel.mirrorProfileDefaultsKey)) {
        didSet {
            guard oldValue != selectedMirrorProfile else { return }
            UserDefaults.standard.set(selectedMirrorProfile.rawValue, forKey: Self.mirrorProfileDefaultsKey)
            applyMirrorProfile(selectedMirrorProfile)
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
        // The connection screen shows failures in the device status pill. While
        // mirroring, mirror a copy to Notification Center so it's still seen.
        if isMirroring {
            notify(title: title, body: message)
        }
    }

    /// Posts a transient macOS notification (best-effort; silently no-ops if the
    /// user hasn't granted notification permission).
    func notify(title: String, body: String) {
        guard Self.canUseUserNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    enum TransferActivityPhase: Equatable {
        case installing
        case copying
        case completed
        case failed
    }

    struct TransferActivity: Equatable, Identifiable {
        let id = UUID()
        var phase: TransferActivityPhase
        var title: String
        var detail: String

        var isInProgress: Bool {
            phase == .installing || phase == .copying
        }

        var symbolName: String {
            switch phase {
            case .installing: return "square.and.arrow.down.fill"
            case .copying: return "arrow.down.doc.fill"
            case .completed: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
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
            for (index, url) in fileURLs.enumerated() where failure == nil {
                let isAPK = url.pathExtension.lowercased() == "apk"
                self?.transferActivity = Self.transferActivity(
                    for: url,
                    isAPK: isAPK,
                    index: index,
                    total: fileURLs.count
                )
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
                self.transferActivity = TransferActivity(
                    phase: .failed,
                    title: "Transfer failed",
                    detail: failure
                )
                self.reportError("Transfer failed", "Couldn’t send a file to the phone: \(failure)")
            } else {
                var parts: [String] = []
                if installed > 0 { parts.append("Installed \(installed) app\(installed == 1 ? "" : "s")") }
                if pushed > 0 { parts.append("Copied \(pushed) file\(pushed == 1 ? "" : "s") to Download") }
                let summary = parts.joined(separator: " · ")
                self.transferActivity = TransferActivity(
                    phase: .completed,
                    title: summary.isEmpty ? "Transfer complete" : summary,
                    detail: ""
                )
                Logger.log("Dropped files: \(summary)")
                self.notify(title: "Sent to phone", body: summary)
            }
        }
    }

    private nonisolated static func transferActivity(
        for url: URL,
        isAPK: Bool,
        index: Int,
        total: Int
    ) -> TransferActivity {
        let fileName = url.lastPathComponent
        let detail = total <= 1 ? fileName : "\(index + 1) of \(total) · \(fileName)"
        return TransferActivity(
            phase: isAPK ? .installing : .copying,
            title: isAPK ? "Installing APK" : "Copying file",
            detail: detail
        )
    }

    func dismissError() {
        activeError = nil
    }

    func applyMirrorProfile(_ profile: MirrorProfile) {
        suppressMirrorSettingsRestart = true
        mirrorMaxSize = profile.maxSize
        mirrorBitRateMbps = profile.bitRateMbps
        mirrorMaxFps = profile.maxFps
        mirrorAudioEnabled = profile.audioEnabled
        suppressMirrorSettingsRestart = false
        scheduleMirrorSettingsRestart()
    }

    /// Reveals the most recently saved screenshot or recording in Finder.
    func revealLastCapture() {
        guard let url = lastCaptureURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseScreenshotFolder() {
        chooseCaptureFolder(title: "Choose Screenshot Folder") { [weak self] url in
            self?.setScreenshotFolder(url)
        }
    }

    func chooseRecordingFolder() {
        chooseCaptureFolder(title: "Choose Screen Recording Folder") { [weak self] url in
            self?.setRecordingFolder(url)
        }
    }

    func resetScreenshotFolder() {
        clearCaptureFolder(pathKey: Self.screenshotFolderPathDefaultsKey, bookmarkKey: Self.screenshotFolderBookmarkDefaultsKey)
        screenshotFolderPath = nil
    }

    func resetRecordingFolder() {
        clearCaptureFolder(pathKey: Self.recordingFolderPathDefaultsKey, bookmarkKey: Self.recordingFolderBookmarkDefaultsKey)
        recordingFolderPath = nil
    }

    func setScreenshotFolder(_ url: URL) {
        storeCaptureFolder(url, pathKey: Self.screenshotFolderPathDefaultsKey, bookmarkKey: Self.screenshotFolderBookmarkDefaultsKey)
        screenshotFolderPath = url.path
    }

    func setRecordingFolder(_ url: URL) {
        storeCaptureFolder(url, pathKey: Self.recordingFolderPathDefaultsKey, bookmarkKey: Self.recordingFolderBookmarkDefaultsKey)
        recordingFolderPath = url.path
    }

    func screenshotOutputDirectory() -> URL? {
        captureFolder(pathKey: Self.screenshotFolderPathDefaultsKey, bookmarkKey: Self.screenshotFolderBookmarkDefaultsKey)
    }

    func recordingOutputDirectory() -> URL? {
        captureFolder(pathKey: Self.recordingFolderPathDefaultsKey, bookmarkKey: Self.recordingFolderBookmarkDefaultsKey)
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

    private func chooseCaptureFolder(title: String, onSelection: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            onSelection(url)
        }
    }

    private func storeCaptureFolder(_ url: URL, pathKey: String, bookmarkKey: String) {
        UserDefaults.standard.set(url.path, forKey: pathKey)
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        } catch {
            Logger.log("Could not store capture folder bookmark for \(url.path): \(error.localizedDescription)")
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    private func clearCaptureFolder(pathKey: String, bookmarkKey: String) {
        UserDefaults.standard.removeObject(forKey: pathKey)
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    private func captureFolder(pathKey: String, bookmarkKey: String) -> URL? {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                if stale {
                    storeCaptureFolder(url, pathKey: pathKey, bookmarkKey: bookmarkKey)
                }
                return url
            } catch {
                Logger.log("Could not resolve capture folder bookmark: \(error.localizedDescription)")
            }
        }

        guard let path = UserDefaults.standard.string(forKey: pathKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
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
        if lowered.contains("unauthorized") || lowered.contains("device unauthorized") {
            return "This Mac isn't authorized on the phone yet. Unlock the phone and tap “Allow” on the USB-debugging prompt."
        }
        if lowered.contains("offline")
            || lowered.contains("no devices")
            || lowered.contains("not found")
            || lowered.contains("failed to read copy response")
            || lowered.contains("error: closed")
            || lowered.contains("eof") {
            return "The phone went offline. Reconnect it (USB or Wi-Fi) and try again."
        }
        if lowered.contains("scrcpy-server") {
            return "The mirroring engine file is missing from the app. Reinstall PhoneRelay."
        }
        if lowered.contains("timed out") {
            return "The phone didn’t respond in time. Check the cable or Wi-Fi connection and try again."
        }
        return detail
    }

    nonisolated static func shouldKeepRetryingMirrorLaunchFailure(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("offline")
            || lowered.contains("timed out")
            || lowered.contains("closed")
            || lowered.contains("eof")
            || lowered.contains("no route to host")
            || lowered.contains("connection refused")
            || lowered.contains("not found")
            || lowered.contains("didn’t respond")
            || lowered.contains("didn't respond")
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
    private var lastMirrorWindowFrame: NSRect?
    private lazy var notificationForwarder = NotificationForwarder(model: self)
    private let notificationAuthorizationRequester: NotificationAuthorizationRequester
    private let notificationSettingsOpener: NotificationSettingsOpener
    private let localNetworkPermissionPrompter: LocalNetworkPermissionPrompter
    private var isRequestingNotificationAuthorization = false
    private var lastPresenceAutoConnectAttemptAt: Date?
    private var failedAutoConnectTargets: [String: Date] = [:]
    private var autoConnectTargetsInFlight: Set<String> = []
    private var explicitDeviceSetupRequired = false
    private var hasShownLocalNetworkPermissionHint = false
    /// Authorized adb serials seen on the previous device-watcher poll. Lets us
    /// fire an immediate connect the instant a *new* device appears, instead of
    /// waiting out the presence throttle.
    private var previousAuthorizedSerials: Set<String> = []
    private var hasShownUSBAuthorizationHint = false
    /// Serial of the USB phone the watcher last attempted a Wi-Fi handoff for.
    /// Prevents a handoff (or its USB fallback) from re-firing every poll while
    /// the same cable stays plugged in; cleared when the cable is removed.
    private var lastUSBHandoffSerial: String?
    /// On launch we keep the status indicator on "Connecting" until this moment,
    /// so opening the app reads as "finding your last device" rather than
    /// "Offline" while the first reconnect attempts run.
    private var launchReconnectDeadline: Date?
    private var deviceWatcherTask: Task<Void, Never>?
    private var qrPairingTask: Task<Void, Never>?
    private var usbConnectTask: Task<Void, Never>?
    private var usbWiFiHandoffTask: Task<Void, Never>?
    private var wirelessStartTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var disconnectRecoveryTask: Task<Void, Never>?
    private var screenRecordingMonitorTask: Task<Void, Never>?
    private var mirrorLaunchTask: Task<Void, Never>?
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
    private var autoConnectEligiblePairedPhones: [PairedPhoneRecord] {
        pairedPhones.filter { !$0.autoConnectSuspended }
    }
    /// True while a mirror session has ended but we're about to retry/reconnect
    /// (e.g. audio→video fallback, or within the backoff window). Keeps the app
    /// from terminating in the windowless gap between sessions.
    @Published private(set) var isAwaitingReconnect = false
    /// A session that dies sooner than this counts as a "quick" failure.
    static let quickMirrorFailureThreshold: TimeInterval = 12
    nonisolated static let disconnectRecoveryGracePeriod: TimeInterval = 5
    nonisolated static let wirelessHandoffReadinessAttempts = 8
    nonisolated static let wirelessHandoffMaxDuration: TimeInterval = 3
    nonisolated static let wirelessHandoffRetryDelayNanoseconds: UInt64 = 250_000_000
    nonisolated static let wirelessHandoffConnectTimeout: TimeInterval = 0.5
    nonisolated static let wirelessHandoffShellTimeout: TimeInterval = 0.5
    nonisolated static let wirelessHandoffRouteQueryTimeout: TimeInterval = 1
    nonisolated static let wirelessHandoffRoutePrimeTimeout: TimeInterval = 0.5
    nonisolated static let wirelessHandoffTCPIPTimeout: TimeInterval = 1
    nonisolated static let wirelessHandoffPreflightTimeoutNanoseconds: UInt64 = 300_000_000
    nonisolated static let adbDeviceListTimeout: TimeInterval = 2
    /// How long after launch the status indicator keeps reading "Connecting"
    /// while we hunt for the last-known device. Sized to the 3–5s window the
    /// reconnect attempts run in.
    nonisolated static let launchReconnectWindow: TimeInterval = 5

    nonisolated static func remainingWirelessHandoffBudget(startedAt: Date, now: Date = Date()) -> TimeInterval {
        max(0, wirelessHandoffMaxDuration - now.timeIntervalSince(startedAt))
    }

    var hasActiveMirrorSession: Bool {
        mirrorSession != nil
    }

    /// Single source of truth for the pre-connection status, shared by the USB
    /// button's loader and the device pill so they can never disagree. True from
    /// the instant a connect attempt begins — a saved phone appearing, pairing,
    /// recovery, or the launch reconnect window — until it resolves to online.
    var isActivelyConnecting: Bool {
        if mirrorLaunchTask != nil {
            return true
        }
        guard !isMirroring else { return false }
        if isPairing
            || isScanning
            || isRecoveringConnection
            || isAwaitingReconnect
            || isAutoConnecting
            || usbConnectTask != nil
            || usbWiFiHandoffTask != nil
            || wirelessStartTask != nil
            || reconnectTask != nil {
            return true
        }
        return isWithinLaunchReconnectWindow
    }

    var isManualUSBConnectDisabled: Bool {
        Self.shouldDisableManualUSBConnectButton(
            isPairing: isPairing,
            isScanning: isScanning,
            isRecoveringConnection: isRecoveringConnection,
            isAwaitingReconnect: isAwaitingReconnect,
            isMirroring: isMirroring,
            isAutoConnecting: isAutoConnecting
        )
    }

    /// Status word for the device pill, derived from the same unified state.
    var connectionStatusText: String {
        Self.devicePillStatusText(
            isOnline: isSelectedDeviceOnline,
            hasSavedDevice: !pairedPhones.isEmpty,
            isActivelyConnecting: isActivelyConnecting
        )
    }

    var shouldShowReconnectLoadingSurface: Bool {
        Self.shouldShowReconnectSurface(
            isRecoveringConnection: isRecoveringConnection,
            isAwaitingReconnect: isAwaitingReconnect
        )
    }

    var connectionDeviceLabel: String {
        Self.connectionDeviceLabel(
            name: selectedDevice.name,
            id: selectedDevice.id,
            serial: selectedDevice.adbSerial,
            network: selectedDevice.network
        )
    }

    var mirrorWindowDeviceTitle: String {
        Self.mirrorWindowDeviceTitle(name: selectedDevice.name)
    }

    var mirrorLoadingStatusText: String {
        Self.mirrorLoadingStatusText(name: selectedDevice.name)
    }

    var mirrorLoadingDeviceTitle: String {
        Self.mirrorLoadingDeviceTitle(name: selectedDevice.name)
    }

    var connectionHealthSnapshot: ConnectionHealthSnapshot {
        Self.connectionHealthSnapshot(
            selectedSerial: selectedDevice.adbSerial,
            selectedNetwork: selectedDevice.network,
            isSelectedDeviceOnline: isSelectedDeviceOnline,
            isActivelyConnecting: isActivelyConnecting,
            hasUnauthorizedUSBDevice: latestHasUnauthorizedUSBDevice,
            authorizedDevices: latestAuthorizedADBDevices,
            discoveredPhones: discoveredPhones,
            localNetworkPermissionGranted: localNetworkPermissionGrantedForOnboarding,
            adbStatusText: latestADBStatusText,
            reconnectAttemptCount: reconnectAttemptCount,
            activeErrorMessage: activeError?.message
        )
    }

    /// Whether we're still inside the brief post-launch window during which the
    /// UI should read "Connecting" even before a device has been seen.
    private var isWithinLaunchReconnectWindow: Bool {
        guard !isSelectedDeviceOnline, !isMirroring, !pairedPhones.isEmpty,
              let deadline = launchReconnectDeadline else { return false }
        return Date() < deadline
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
        startBackgroundServices: Bool = AppModel.defaultStartBackgroundServices,
        pairedPhones previewPairedPhones: [PairedPhoneRecord]? = nil,
        notificationAuthorizationRequester: @escaping NotificationAuthorizationRequester = AppModel.requestNotificationAuthorization,
        notificationSettingsOpener: @escaping NotificationSettingsOpener = AppModel.openSystemNotificationSettings,
        localNetworkPermissionPrompter: @escaping LocalNetworkPermissionPrompter = AppModel.promptForLocalNetworkPermission
    ) {
        self.notificationAuthorizationRequester = notificationAuthorizationRequester
        self.notificationSettingsOpener = notificationSettingsOpener
        self.localNetworkPermissionPrompter = localNetworkPermissionPrompter
        explicitDeviceSetupRequired = Self.explicitDeviceSetupRequiredPreference()
        if explicitDeviceSetupRequired {
            store.clearAll()
            pairedPhones = []
        } else {
            pairedPhones = previewPairedPhones ?? store.load()
        }
        if let mostRecentRecord = Self.recordsByMostRecent(pairedPhones).first {
            clearExplicitDeviceSetupRequirement()
            select(record: mostRecentRecord)
        }

        guard startBackgroundServices else { return }

        discovery.start { [weak self] phones in
            guard let self else { return }
            guard !(self.pairedPhones.isEmpty && self.explicitDeviceSetupRequired) else {
                self.discoveredPhones = []
                return
            }
            self.discoveredPhones = phones
            self.autoConnectToAvailableRememberedDevice(livePhones: phones)
        }
        startDeviceWatcher()
        attemptAutoReconnect()
        updateNotificationForwarding()
    }

    nonisolated static func shouldStartBackgroundServices(
        environment: [String: String],
        executablePath: String
    ) -> Bool {
        let executableName = URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()
        return executableName != "xctest"
            && environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestBundlePath"] == nil
            && environment["XCTestSessionIdentifier"] == nil
    }

    nonisolated private static var defaultStartBackgroundServices: Bool {
        shouldStartBackgroundServices(
            environment: ProcessInfo.processInfo.environment,
            executablePath: ProcessInfo.processInfo.arguments.first ?? ""
        )
    }

    /// Starts or stops the no-companion-app notification poller to match the
    /// current setting. The poller self-idles until a real device is connected.
    private func updateNotificationForwarding() {
        if notificationForwardingEnabled {
            requestNotificationAuthorizationAndStartForwarding()
        } else {
            notificationForwarder.stop()
        }
    }

    /// Opts into Android notification forwarding from first-run onboarding and
    /// triggers the native macOS notification permission prompt immediately.
    func enableNotificationForwardingFromOnboarding() {
        notificationForwardingEnabled = true
    }

    private func requestNotificationAuthorizationAndStartForwarding() {
        guard !isRequestingNotificationAuthorization else { return }
        isRequestingNotificationAuthorization = true
        notificationAuthorizationRequester { [weak self] granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isRequestingNotificationAuthorization = false

                if let error {
                    Logger.log("Notification authorization error: \(error.localizedDescription)")
                }

                guard granted else {
                    Logger.log("Notification authorization denied; disabling notification forwarding.")
                    self.notificationForwardingPermissionDenied = true
                    self.notificationPermissionGrantedForOnboarding = false
                    if self.notificationForwardingEnabled {
                        self.notificationForwardingEnabled = false
                    } else {
                        self.notificationForwarder.stop()
                    }
                    self.scheduleNotificationAuthorizationRecheck()
                    return
                }
                self.notificationForwardingPermissionDenied = false
                self.notificationPermissionGrantedForOnboarding = true

                guard self.notificationForwardingEnabled else {
                    self.notificationForwarder.stop()
                    return
                }
                self.notificationForwarder.start()
            }
        }
    }

    /// A rebuilt (re-signed) app's first authorization request can come back
    /// denied even though the user approves the system prompt moments later —
    /// macOS answers from the stale identity. One delayed recheck re-enables
    /// forwarding so the user doesn't have to dig the toggle out of Settings
    /// after every rebuild.
    private func scheduleNotificationAuthorizationRecheck() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard let self, !self.notificationForwardingEnabled else { return }
            let status = await Self.currentNotificationAuthorizationStatus()
            guard status == .authorized else { return }
            Logger.log("Notification authorization recovered; re-enabling forwarding.")
            self.notificationForwardingPermissionDenied = false
            self.notificationForwardingEnabled = true
        }
    }

    private nonisolated static func currentNotificationAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    private nonisolated static func requestNotificationAuthorization(
        completion: @escaping (Bool, Error?) -> Void
    ) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            completion(granted, error)
        }
    }

    func openNotificationSettings() {
        notificationSettingsOpener()
    }

    func openLocalNetworkSettings() {
        isAwaitingLocalNetworkSettingsReturn = true
        Self.openSystemLocalNetworkSettings()
    }

    func refreshLocalNetworkPermissionAfterSettingsReturn() {
        guard isAwaitingLocalNetworkSettingsReturn else { return }
        isAwaitingLocalNetworkSettingsReturn = false
        requestLocalNetworkPermissionFromOnboarding()
        scanADBDevices()
    }

    func requestLocalNetworkPermissionFromOnboarding() {
        localNetworkPermissionPrompter { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.localNetworkPermissionGrantedForOnboarding = granted
            }
        }
    }

    private nonisolated static func openSystemNotificationSettings() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.mallenkb.PhoneRelay"
        NSWorkspace.shared.open(notificationSettingsURL(bundleIdentifier: bundleIdentifier))
    }

    private nonisolated static func openSystemLocalNetworkSettings() {
        NSWorkspace.shared.open(localNetworkSettingsURL)
    }

    nonisolated static func notificationSettingsURL(bundleIdentifier: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)")!
    }

    private nonisolated static func promptForLocalNetworkPermission(completion: @escaping (Bool) -> Void) {
        let parameters = NWParameters.tcp
        let browser = NWBrowser(
            for: .bonjour(type: "_adb-tls-connect._tcp", domain: nil),
            using: parameters
        )
        let queue = DispatchQueue(label: "PhoneRelay.local-network-permission")
        let once = OneShotCallback()

        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                once.run {
                    browser.cancel()
                    completion(true)
                }
            case .failed, .waiting:
                once.run {
                    browser.cancel()
                    completion(false)
                }
            case .cancelled:
                break
            default:
                break
            }
        }

        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 2) {
            once.run {
                browser.cancel()
                completion(false)
            }
        }
    }

    deinit {
        deviceWatcherTask?.cancel()
        qrPairingTask?.cancel()
        usbConnectTask?.cancel()
        usbWiFiHandoffTask?.cancel()
        wirelessStartTask?.cancel()
        reconnectTask?.cancel()
        disconnectRecoveryTask?.cancel()
        screenRecordingMonitorTask?.cancel()
        mirrorSettingsRestartTask?.cancel()
    }

    func shutdown() {
        stopMirroring(suspendAutoConnect: false)
        discovery.stop()
        notificationForwarder.stop()
        stopQRCodePairingSession()
        deviceWatcherTask?.cancel()
        deviceWatcherTask = nil
        qrPairingTask?.cancel()
        qrPairingTask = nil
        usbConnectTask?.cancel()
        usbConnectTask = nil
        usbWiFiHandoffTask?.cancel()
        usbWiFiHandoffTask = nil
        wirelessStartTask?.cancel()
        wirelessStartTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnectRecoveryTask?.cancel()
        disconnectRecoveryTask = nil
        screenRecordingMonitorTask?.cancel()
        screenRecordingMonitorTask = nil
        mirrorSettingsRestartTask?.cancel()
        mirrorSettingsRestartTask = nil
        isAutoConnecting = false
        isScanning = false
        isPairing = false
        isRecoveringConnection = false
        isAwaitingReconnect = false
        autoConnectTargetsInFlight.removeAll()
    }

    private func cancelWirelessReconnectWork() {
        reconnectTask?.cancel()
        reconnectTask = nil
        wirelessStartTask?.cancel()
        wirelessStartTask = nil
        disconnectRecoveryTask?.cancel()
        disconnectRecoveryTask = nil
        isRecoveringConnection = false
        isAwaitingReconnect = false
        isAutoConnecting = false
        autoConnectTargetsInFlight.removeAll()
        launchReconnectDeadline = nil
    }

    // MARK: - Window registration

    func registerConnectionWindow(_ window: NSWindow?) {
        guard let window else { return }
        connectionWindow = window
        if isFirstRunOnboardingActive {
            hideConnectionWindow()
        }
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
        isSelectedDeviceOnline = false
        requireExplicitDeviceSetup()
        stopQRCodePairingSession()
    }

    // MARK: - First-run onboarding presentation gate

    /// While the first-run onboarding card is on screen nothing else may
    /// surface: the connection window stays hidden and mirror sessions are not
    /// started, even when a plugged-in phone is detected and connectable in
    /// the background. Set from the app delegate around the onboarding
    /// window's lifetime.
    private(set) var isFirstRunOnboardingActive = false
    /// After onboarding completes, auto-mirror stays paused until this instant
    /// so the freshly revealed connection screen is actually seen before a
    /// mirror session takes over.
    private var postOnboardingMirrorHoldUntil: Date?
    private var postOnboardingRevealTask: Task<Void, Never>?
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

    private var isAutoMirrorHeldForOnboarding: Bool {
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
    private func attemptAutoReconnect() {
        let reconnectRecords = autoConnectEligiblePairedPhones
        guard !reconnectRecords.isEmpty else {
            guard Self.shouldAttemptRecoveredWiFiReconnect(
                hasSavedDevices: !pairedPhones.isEmpty,
                explicitDeviceSetupRequired: explicitDeviceSetupRequired
            ) else { return }
            attemptRecoveredWiFiReconnect()
            return
        }
        // Show "Connecting <last device>" immediately, before the first adb poll
        // returns, so launch reads as actively reconnecting rather than Offline.
        launchReconnectDeadline = Date().addingTimeInterval(Self.launchReconnectWindow)
        isAutoConnecting = true
        let adb = self.adb
        Task { [weak self] in
            for attempt in 0..<6 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let self else { return }
                guard !self.explicitDeviceSetupRequired else { return }
                if self.isMirroring || self.isPairing {
                    return
                }

                let devicesOutput = await Task.detached {
                    adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
                }.value
                let authorizedDevices = Self.authorizedADBDevices(in: devicesOutput)

                let authorizedDevice = self.preferUSBMirroring
                    ? authorizedDevices.first(where: \.isUSB) ?? authorizedDevices.first
                    : authorizedDevices.first(where: { !$0.isUSB }) ?? authorizedDevices.first
                if let authorizedDevice {
                    await self.mirrorAuthorizedDevicePreferringWireless(authorizedDevice)
                    return
                }

                for record in Self.recordsByMostRecent(self.autoConnectEligiblePairedPhones) {
                    if Self.isWirelessRecord(record) {
                        if let connectedAddress = await Self.connectToRememberedWireless(
                            adb: adb,
                            savedAddress: record.lastAddress,
                            preflightLocalNetworkAccess: { address in
                                await Self.preflightLocalNetworkAccess(address: address)
                            }
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
                let candidate = self.mostRecentPairedPhone(
                    in: self.autoConnectablePhones(in: livePhones + self.discoveredPhones)
                )
                if let candidate {
                    self.stopQRCodePairingSession()
                    self.connectAndMirror(phone: candidate)
                    return
                }
            }
        }
    }

    /// Recovery path for builds that lost the UserDefaults paired-phone record:
    /// if ADB/mDNS can see exactly one connectable Wi-Fi target, treat it as the
    /// user's phone, reconnect, then persist it back into the paired store.
    private func attemptRecoveredWiFiReconnect() {
        let adb = self.adb
        Task { [weak self] in
            for attempt in 0..<5 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                guard let self, !self.isMirroring, !self.isPairing, self.pairedPhones.isEmpty else {
                    return
                }
                guard !self.explicitDeviceSetupRequired else {
                    return
                }

                let phones = await Task.detached { adb.connectableMDNSTargets() }.value
                guard let phone = Self.singleConnectableRecoveryCandidate(in: phones) else {
                    continue
                }

                self.isAutoConnecting = true
                self.stopQRCodePairingSession()
                Logger.log("Recovering missing paired-phone record from single connectable ADB target \(phone.id) \(phone.address)")
                self.connectAndMirror(phone: phone)
                return
            }
        }
    }

    nonisolated static func shouldAttemptRecoveredWiFiReconnect(
        hasSavedDevices: Bool,
        explicitDeviceSetupRequired: Bool
    ) -> Bool {
        !hasSavedDevices && !explicitDeviceSetupRequired
    }

    private func connectAndMirror(phone: DiscoveredPhone) {
        guard !explicitDeviceSetupRequired else { return }
        let address = phone.address
        guard !autoConnectTargetsInFlight.contains(address) else { return }
        autoConnectTargetsInFlight.insert(address)
        let serviceID = phone.id
        let label = displayName(for: phone)

        let adb = self.adb
        Task { [weak self] in
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
                }
            )
            let ready = readiness.isReady

            guard let self else { return }
            self.autoConnectTargetsInFlight.remove(address)
            if readiness.sawNoRouteToHost {
                self.presentLocalNetworkPermissionHint()
            }
            if ready {
                guard !self.explicitDeviceSetupRequired else { return }
                self.failedAutoConnectTargets.removeValue(forKey: address)
                let deviceName = await Self.connectedDeviceName(adb: adb, serial: address, fallback: label)
                self.touchPairedPhone(id: serviceID, displayName: deviceName, address: address)
                self.selectedDevice.adbSerial = address
                self.selectedDevice.name = deviceName
                self.stopQRCodePairingSession()
                self.startMirroring()
            } else {
                self.noteAutoConnectFailure(for: phone)
                self.isAutoConnecting = false
                Logger.log("Auto-connect to \(address) failed readiness check")
            }
        }
    }

    private func mirrorAuthorizedDevicePreferringWireless(_ device: AuthorizedADBDevice) async {
        guard !isMirroring, !isPairing else { return }
        guard !isAutoMirrorHeldForOnboarding else { return }
        if device.isUSB {
            startMirroringOverUSB(
                device,
                manual: false,
                prepareWirelessHandoff: Self.shouldAttemptWirelessHandoff(
                    from: device,
                    preferUSBMirroring: preferUSBMirroring
                )
            )
            return
        }

        guard !explicitDeviceSetupRequired else { return }
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
        guard !isMirroring, !isPairing else {
            return
        }
        guard !isAutoMirrorHeldForOnboarding else {
            return
        }

        if pairedPhones.isEmpty {
            guard !explicitDeviceSetupRequired else {
                return
            }
            guard let phone = Self.singleConnectableRecoveryCandidate(in: autoConnectablePhones(in: livePhones)) else {
                return
            }
            lastPresenceAutoConnectAttemptAt = Date()
            isAutoConnecting = true
            stopQRCodePairingSession()
            Logger.log("Recovering missing paired-phone record from discovered ADB target \(phone.id) \(phone.address)")
            connectAndMirror(phone: phone)
            return
        }

        let records = Self.recordsByMostRecent(autoConnectEligiblePairedPhones)
        guard !records.isEmpty else { return }
        let livePhones = autoConnectablePhones(in: livePhones)
        let liveRememberedPhone = mostRecentPairedPhone(in: livePhones)

        if Self.shouldDelayRememberedAutoConnect(
            lastAttemptAt: lastPresenceAutoConnectAttemptAt,
            now: Date(),
            throttle: Self.presenceAutoConnectThrottle,
            hasLiveRememberedPhone: liveRememberedPhone != nil
        ) {
            return
        }

        for record in records {
            if let device = Self.rememberedAuthorizedDevice(for: record, in: authorizedDevices) {
                lastPresenceAutoConnectAttemptAt = Date()
                Task { [weak self] in
                    await self?.mirrorAuthorizedDevicePreferringWireless(device)
                }
                return
            }
        }

        if let phone = liveRememberedPhone {
            lastPresenceAutoConnectAttemptAt = Date()
            stopQRCodePairingSession()
            connectAndMirror(phone: phone)
            return
        }

        if let usbDevice = authorizedDevices.first(where: \.isUSB),
           let wirelessRecord = records.first(where: { record in
               Self.isWirelessRecord(record)
                   || Self.rememberedAuthorizedDevice(for: record, in: [usbDevice]) != nil
           }) {
            lastPresenceAutoConnectAttemptAt = Date()
            let adb = self.adb
            Task { [weak self] in
                guard let connectedAddress = await Self.connectToUSBDeviceOverCurrentWiFi(
                    adb: adb,
                    usbDevice: usbDevice,
                    readinessAttempts: 4,
                    preflightLocalNetworkAccess: { address in
                        await Self.preflightLocalNetworkAccess(address: address)
                    }
                ) else { return }

                guard let self, !self.isMirroring, !self.isPairing else { return }
                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: connectedAddress,
                    fallback: usbDevice.model
                )
                self.select(record: wirelessRecord)
                self.selectedDevice.adbSerial = connectedAddress
                self.selectedDevice.name = deviceName
                self.touchPairedPhone(
                    id: wirelessRecord.id,
                    displayName: deviceName,
                    address: connectedAddress
                )
                self.stopQRCodePairingSession()
                self.startMirroring()
            }
            return
        }

        guard let wirelessRecord = records.first(where: Self.isWirelessRecord) else {
            return
        }
        // The same 20s cooldown the mDNS path gets: an unreachable saved
        // address (phone asleep, off-network, or Local Network permission
        // denied) must not be redialed every presence poll — that's the
        // "reconnecting all the time" churn.
        guard !isAutoConnectAddressCoolingDown(wirelessRecord.lastAddress) else {
            return
        }

        lastPresenceAutoConnectAttemptAt = Date()
        let adb = self.adb
        Task { [weak self] in
            let connectedAddress = await Self.connectToRememberedWireless(
                adb: adb,
                savedAddress: wirelessRecord.lastAddress,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                }
            )

            guard let self, !self.isMirroring, !self.isPairing else { return }
            guard let connectedAddress else {
                self.noteAutoConnectFailure(address: wirelessRecord.lastAddress)
                return
            }
            self.failedAutoConnectTargets.removeValue(forKey: wirelessRecord.lastAddress)
            self.failedAutoConnectTargets.removeValue(forKey: connectedAddress)

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
        clearExplicitDeviceSetupRequirement()
        pairedPhones = store.touch(pairedPhones, id: id, displayName: displayName, address: address)
        store.save(pairedPhones)
    }

    private func setAutoConnectSuspendedForSelectedDevice(_ suspended: Bool) {
        guard selectedDevice.adbSerial != nil || selectedDevice.id != MirrorDevice.demo.id else { return }
        setAutoConnectSuspended(suspended) { [selectedDevice] record in
            Self.recordMatchesSelectedDevice(record, selectedDevice: selectedDevice)
        }
    }

    private func resumeAutoConnect(for record: PairedPhoneRecord) {
        setAutoConnectSuspended(false) { candidate in
            candidate.id == record.id
                || candidate.lastAddress == record.lastAddress
                || Self.recordMatchesSelectedADBSerial(candidate, selectedSerial: record.id)
                || Self.recordMatchesSelectedADBSerial(candidate, selectedSerial: record.lastAddress)
        }
    }

    private func setAutoConnectSuspended(
        _ suspended: Bool,
        where matches: (PairedPhoneRecord) -> Bool
    ) {
        var changed = false
        pairedPhones = pairedPhones.map { record in
            guard matches(record), record.autoConnectSuspended != suspended else { return record }
            changed = true
            var updated = record
            updated.autoConnectSuspended = suspended
            return updated
        }
        if changed {
            store.save(pairedPhones)
        }
    }

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
            let output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
            guard let self else { return }
            self.isScanning = false
            self.recordADBHealth(output)
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
                let output = await Task.detached {
                    adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
                }.value
                guard let self else { return }
                let authorized = Self.authorizedADBDevices(in: output)
                self.recordADBHealth(output, authorizedDevices: authorized)
                self.updateUSBAuthorizationHint(from: output, authorizedDevices: authorized)

                if Self.shouldUSBInterruptReconnect(
                    authorizedDevices: authorized,
                    isRecoveringConnection: self.isRecoveringConnection,
                    isAwaitingReconnect: self.isAwaitingReconnect,
                    hasReconnectTask: self.reconnectTask != nil,
                    hasWirelessStartTask: self.wirelessStartTask != nil
                ) {
                    Logger.log("USB device interrupted wireless reconnect; cancelling stale reconnect work")
                    self.cancelWirelessReconnectWork()
                    self.isPairing = false
                }

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
                    isPairing: self.isPairing
                )

                // Presence tracking always runs so the UI reflects the live
                // device immediately. Active connection ownership is decided
                // below so a fresh USB handoff and remembered-device connect
                // never race in the same watcher poll.
                self.applyDevicePresence(output)
                if Self.shouldRecoverMissingMirrorTransport(
                    isMirroring: self.isMirroring,
                    selectedSerial: self.selectedDevice.adbSerial,
                    pairedPhones: self.pairedPhones,
                    authorizedDevices: authorized
                ) {
                    self.recoverMissingMirrorTransport()
                }

                // USB → Wi-Fi handoff: the moment an authorized USB phone shows
                // up while idle, start the USB mirror immediately. If Wi-Fi is
                // stable enough, prepare the wireless route in the background so
                // a later reconnect can use it without making USB wait. Never
                // fires mid-session, and never twice for the same plug-in.
                if shouldPrioritizeUSBHandoff
                    && (self.pairedPhones.isEmpty || !self.autoConnectEligiblePairedPhones.isEmpty)
                    && Self.shouldAutoStartAuthorizedUSB(
                        hasSavedDevices: !self.autoConnectEligiblePairedPhones.isEmpty,
                        explicitDeviceSetupRequired: self.explicitDeviceSetupRequired
                    ) {
                    if let usbDevice = Self.usbHandoffCandidate(
                        in: output,
                        lastAttemptedSerial: self.lastUSBHandoffSerial
                    ) {
                        self.lastUSBHandoffSerial = usbDevice.serial
                        await self.mirrorAuthorizedDevicePreferringWireless(usbDevice)
                        self.refreshAutoConnectingState(authorized: authorized)
                        let interval: UInt64 = self.isMirroring ? 2_000_000_000 : 1_500_000_000
                        try? await Task.sleep(nanoseconds: interval)
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
                    hasWirelessStartTask: self.wirelessStartTask != nil,
                    hasReconnectTask: self.reconnectTask != nil,
                    hasUSBConnectTask: self.usbConnectTask != nil,
                    isAwaitingReconnect: self.isAwaitingReconnect,
                    selectedSerial: self.selectedDevice.adbSerial
                ), let serial = self.selectedDevice.adbSerial,
                   let liveDevice = Self.liveSelectedOrRememberedDevice(
                    selectedSerial: serial,
                    pairedPhones: self.autoConnectEligiblePairedPhones,
                    authorizedDevices: authorized
                   ) {
                    Logger.log("Online device is idle; auto-starting mirror serial=\(liveDevice.serial)")
                    self.lastPresenceAutoConnectAttemptAt = Date()
                    if liveDevice.isUSB {
                        self.lastUSBHandoffSerial = liveDevice.serial
                    }
                    await self.mirrorAuthorizedDevicePreferringWireless(liveDevice)
                    self.refreshAutoConnectingState(authorized: authorized)
                    let interval: UInt64 = self.isMirroring ? 2_000_000_000 : 1_500_000_000
                    try? await Task.sleep(nanoseconds: interval)
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

                let interval: UInt64
                if self.isPairing {
                    interval = 1_000_000_000          // mid-handoff: stay responsive
                } else if self.isMirroring {
                    interval = 2_000_000_000          // only watching for a disconnect
                } else if authorized.isEmpty {
                    // Nothing plugged in. If a saved phone could reconnect, keep
                    // watching closely so it's caught fast; otherwise ease off.
                    interval = self.pairedPhones.isEmpty
                        ? 3_000_000_000
                        : 1_200_000_000
                } else {
                    interval = 1_500_000_000          // connected but idle
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    /// Keeps `isAutoConnecting` in step with whether a connect target is actually
    /// present, so the status indicator reads "Connecting" the moment a saved
    /// phone shows up (USB or wireless) and clears once we're online or it's gone.
    /// Self-clearing by construction, so a stuck flag can never pin the spinner.
    private func refreshAutoConnectingState(authorized: [AuthorizedADBDevice]) {
        if isMirroring || isSelectedDeviceOnline {
            launchReconnectDeadline = nil
        }
        let hasActiveReconnectWork = !autoConnectTargetsInFlight.isEmpty
            || usbConnectTask != nil
            || usbWiFiHandoffTask != nil
            || reconnectTask != nil
            || wirelessStartTask != nil
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

    nonisolated static func shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
        isRecoveringConnection: Bool,
        isAwaitingReconnect: Bool
    ) -> Bool {
        true
    }

    /// Keep failed background reconnects quiet briefly so stale Bonjour/adb
    /// entries do not pin the UI in "Connecting" forever.
    nonisolated static let autoConnectFailureCooldown: TimeInterval = 20
    nonisolated static let presenceAutoConnectThrottle: TimeInterval = 3

    nonisolated static func isAutoConnectFailureCoolingDown(
        failedAt: Date,
        now: Date = Date(),
        cooldown: TimeInterval = autoConnectFailureCooldown
    ) -> Bool {
        now.timeIntervalSince(failedAt) < cooldown
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

    private func suspendQRCodePairingForOnboarding() {
        stopQRCodePairingSession()
        qrPairingSession = nil
    }

    private func startQRCodePairingWatcher() {
        guard !isFirstRunOnboardingActive else {
            suspendQRCodePairingForOnboarding()
            return
        }
        guard qrPairingTask == nil,
              let session = qrPairingSession
        else { return }

        isQRCodePairingWaiting = true

        let adb = self.adb
        qrPairingTask = Task { [weak self] in
            await adb.ensureServerStarted()
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

                // Hand the Wireless-debugging session off to a plain `tcpip
                // 5555` listener so future reconnects work on the same Wi-Fi
                // without turning the Wireless-debugging toggle back on. Falls
                // back to the TLS target if the phone won't switch to tcpip.
                let connectedPhone: DiscoveredPhone
                if let legacyAddress = await Self.promoteToLegacyTCPIP(
                    adb: adb,
                    sourceSerial: connectablePhone.address,
                    preflightLocalNetworkAccess: { address in
                        await Self.preflightLocalNetworkAccess(address: address)
                    }
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
    private func prepareWirelessMirror(
        from usbDevice: AuthorizedADBDevice,
        activatePreparedMirror: Bool = true
    ) async -> Bool {
        let adb = self.adb
        let handoffStartedAt = Date()
        func remainingBudget() -> TimeInterval {
            Self.remainingWirelessHandoffBudget(startedAt: handoffStartedAt)
        }
        func boundedTimeout(_ requested: TimeInterval) -> TimeInterval? {
            let remaining = remainingBudget()
            guard remaining > 0.05 else { return nil }
            return min(requested, remaining)
        }
        var connectAttempts = 0
        var noRouteToHostFailures = 0
        guard let routeQueryTimeout = boundedTimeout(Self.wirelessHandoffRouteQueryTimeout) else {
            return false
        }
        let routeOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "ip", "route"], timeout: routeQueryTimeout)
        }.value

        // Prefer the legacy `adb tcpip 5555` listener. It's the only wireless
        // adb path that stays reachable without the phone's Wireless debugging
        // toggle, so the address we remember keeps working on later "same
        // Wi-Fi" reconnects (until the phone reboots, which drops tcpip mode).
        if let legacyAddress = Self.legacyTCPIPDebuggingAddress(routeOutput: routeOutput) {
            if let primeTimeout = boundedTimeout(Self.wirelessHandoffRoutePrimeTimeout) {
                await Self.primeADBWirelessRoute(
                    adb: adb,
                    usbSerial: usbDevice.serial,
                    wirelessAddress: legacyAddress,
                    timeout: primeTimeout
                )
            }
            guard let tcpipTimeout = boundedTimeout(Self.wirelessHandoffTCPIPTimeout) else {
                isPairing = false
                return false
            }
            let tcpipOutput = await Task.detached {
                adb.run(["-s", usbDevice.serial, "tcpip", "\(Self.legacyADBWirelessPort)"], timeout: tcpipTimeout)
            }.value

            if Self.adbTCPIPSucceeded(tcpipOutput) {
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
                    maximumDuration: remainingBudget(),
                    connectTimeout: Self.wirelessHandoffConnectTimeout,
                    shellTimeout: Self.wirelessHandoffShellTimeout
                )
                connectAttempts += readiness.connectAttempts
                noRouteToHostFailures += readiness.noRouteToHostFailures
                if readiness.isReady {
                    isPairing = false
                    let deviceName = await Self.connectedDeviceName(
                        adb: adb,
                        serial: legacyAddress,
                        fallback: usbDevice.model
                    )
                    finishWirelessHandoff(
                        usbDevice: usbDevice,
                        address: legacyAddress,
                        displayName: deviceName,
                        activatePreparedMirror: activatePreparedMirror
                    )
                    return true
                }
            }
        }

        guard remainingBudget() > 0.05 else {
            isPairing = false
            if connectAttempts > 0, connectAttempts == noRouteToHostFailures {
                presentLocalNetworkPermissionHint()
            }
            return false
        }
        // Fallback for phones that block `adb tcpip` but already expose Android
        // 11 Wireless debugging. Its random TLS port stops answering once the
        // toggle is turned off, so we only reach for it if 5555 didn't take.
        guard let tlsPortTimeout = boundedTimeout(Self.wirelessHandoffRouteQueryTimeout) else {
            isPairing = false
            return false
        }
        let tlsPortOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "getprop", "service.adb.tls.port"], timeout: tlsPortTimeout)
        }.value
        guard let tcpPortTimeout = boundedTimeout(Self.wirelessHandoffRouteQueryTimeout) else {
            isPairing = false
            return false
        }
        let tcpPortOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "getprop", "service.adb.tcp.port"], timeout: tcpPortTimeout)
        }.value
        if let tlsAddress = Self.wirelessDebuggingAddress(
            routeOutput: routeOutput,
            tlsPortOutput: tlsPortOutput,
            tcpPortOutput: tcpPortOutput
        ) {
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
                maximumDuration: remainingBudget(),
                connectTimeout: Self.wirelessHandoffConnectTimeout,
                shellTimeout: Self.wirelessHandoffShellTimeout
            )
            connectAttempts += readiness.connectAttempts
            noRouteToHostFailures += readiness.noRouteToHostFailures
            if readiness.isReady {
                isPairing = false
                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: tlsAddress,
                    fallback: usbDevice.model
                )
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    address: tlsAddress,
                    displayName: deviceName,
                    activatePreparedMirror: activatePreparedMirror
                )
                return true
            }

        }

        guard remainingBudget() > 0.05 else {
            isPairing = false
            if connectAttempts > 0, connectAttempts == noRouteToHostFailures {
                presentLocalNetworkPermissionHint()
            }
            return false
        }
        let discoveredWirelessPhones = await Task.detached {
            adb.connectableMDNSTargets()
        }.value
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
                maximumDuration: remainingBudget(),
                connectTimeout: Self.wirelessHandoffConnectTimeout,
                shellTimeout: Self.wirelessHandoffShellTimeout
            )
            connectAttempts += readiness.connectAttempts
            noRouteToHostFailures += readiness.noRouteToHostFailures
            if readiness.isReady {
                isPairing = false
                let deviceName = await Self.connectedDeviceName(
                    adb: adb,
                    serial: wirelessPhone.address,
                    fallback: usbDevice.model
                )
                finishWirelessHandoff(
                    usbDevice: usbDevice,
                    address: wirelessPhone.address,
                    displayName: deviceName,
                    activatePreparedMirror: activatePreparedMirror
                )
                return true
            }

        }

        isPairing = false
        if connectAttempts > 0, connectAttempts == noRouteToHostFailures {
            presentLocalNetworkPermissionHint()
        }
        return false
    }

    /// "No route to host" on every attempt — while the phone can reach the Mac
    /// — is usually macOS denying this app's Local Network permission, which can
    /// reset on ad-hoc re-signs. Keep the diagnosis in the log, but don't cover
    /// the connection screen with a failure state because USB mirroring still works.
    private func presentLocalNetworkPermissionHint() {
        guard !hasShownLocalNetworkPermissionHint else { return }
        hasShownLocalNetworkPermissionHint = true
        Logger.log("Wi-Fi connects failing with 'No route to host' — likely macOS Local Network permission. Open System Settings > Privacy & Security > Local Network and enable PhoneRelay if wireless handoff should be used. Suppressing on-screen failure state because USB mirroring remains available.")
    }

    private func finishWirelessHandoff(
        usbDevice: AuthorizedADBDevice,
        address: String,
        displayName: String,
        activatePreparedMirror: Bool = true
    ) {
        cancelWirelessReconnectWork()
        touchPairedPhone(
            id: usbDevice.serial,
            displayName: displayName,
            address: address
        )
        guard activatePreparedMirror else {
            Logger.log("Prepared Wi-Fi handoff address=\(address) while keeping current USB mirror active")
            return
        }
        selectedDevice.adbSerial = address
        selectedDevice.name = displayName
        selectedDevice.network = "Wi-Fi debugging"
        stopQRCodePairingSession()
        startMirroring()
    }

    func connectViaUSB() {
        guard !isMirroring else { return }
        usbConnectTask?.cancel()
        usbWiFiHandoffTask?.cancel()
        usbWiFiHandoffTask = nil
        cancelWirelessReconnectWork()
        let generation = mirrorStartGeneration
        isPairing = true

        let adb = self.adb
        usbConnectTask = Task { [weak self] in
            let output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
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

            self.usbConnectTask = nil
            self.startMirroringOverUSB(
                usbDevice,
                manual: true,
                prepareWirelessHandoff: Self.shouldAttemptWirelessHandoff(
                    from: usbDevice,
                    preferUSBMirroring: self.preferUSBMirroring
                )
            )
        }
    }

    private func startMirroringOverUSB(
        _ device: AuthorizedADBDevice,
        manual: Bool,
        prepareWirelessHandoff: Bool = true
    ) {
        cancelWirelessReconnectWork()
        isPairing = false
        select(device: device)
        touchPairedPhone(
            id: device.serial,
            displayName: selectedDisplayName(for: device.model),
            address: device.serial
        )
        stopQRCodePairingSession()
        startMirroring(manual: manual)
        if prepareWirelessHandoff {
            prepareWirelessHandoffInBackground(from: device)
        }
    }

    private func prepareWirelessHandoffInBackground(from usbDevice: AuthorizedADBDevice) {
        usbWiFiHandoffTask?.cancel()
        let generation = mirrorStartGeneration
        usbWiFiHandoffTask = Task { [weak self] in
            guard let self else { return }
            let prepared = await self.prepareWirelessMirror(
                from: usbDevice,
                activatePreparedMirror: false
            )
            guard !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
            self.usbWiFiHandoffTask = nil
            if prepared {
                Logger.log("USB-to-Wi-Fi handoff prepared for next reconnect")
            }
        }
    }

    private func mostRecentPairedPhone(in phones: [DiscoveredPhone]) -> DiscoveredPhone? {
        for record in Self.recordsByMostRecent(autoConnectEligiblePairedPhones) where Self.isWirelessRecord(record) {
            if let phone = Self.rememberedConnectablePhone(for: record, in: phones) {
                return phone
            }
        }
        return nil
    }

    private func autoConnectablePhones(in phones: [DiscoveredPhone]) -> [DiscoveredPhone] {
        let now = Date()
        failedAutoConnectTargets = failedAutoConnectTargets.filter { _, failedAt in
            Self.isAutoConnectFailureCoolingDown(
                failedAt: failedAt,
                now: now,
                cooldown: Self.autoConnectFailureCooldown
            )
        }
        return phones.filter { phone in
            guard let failedAt = failedAutoConnectTargets[phone.address] else { return true }
            return !Self.isAutoConnectFailureCoolingDown(
                failedAt: failedAt,
                now: now,
                cooldown: Self.autoConnectFailureCooldown
            )
        }
    }

    private func noteAutoConnectFailure(for phone: DiscoveredPhone) {
        noteAutoConnectFailure(address: phone.address)
    }

    private func noteAutoConnectFailure(address: String) {
        failedAutoConnectTargets[address] = Date()
    }

    private func updateUSBAuthorizationHint(
        from output: String,
        authorizedDevices: [AuthorizedADBDevice]
    ) {
        guard authorizedDevices.isEmpty,
              Self.hasUnauthorizedUSBDevice(in: output),
              !hasShownUSBAuthorizationHint,
              !isMirroring
        else { return }
        hasShownUSBAuthorizationHint = true
        reportError(
            "Authorize USB debugging",
            "The phone is plugged in, but Android has not authorized this Mac yet. Unlock the phone and tap Allow on the USB debugging prompt, or use Wi-Fi debugging if it is already enabled."
        )
    }

    private func isAutoConnectAddressCoolingDown(_ address: String) -> Bool {
        guard let failedAt = failedAutoConnectTargets[address] else { return false }
        return Self.isAutoConnectFailureCoolingDown(failedAt: failedAt)
    }

    private func applyADBOutput(_ output: String) {
        recordADBHealth(output)
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

    func applyDevicePresence(_ output: String) {
        let devices = Self.authorizedADBDevices(in: output)
        recordADBHealth(output, authorizedDevices: devices)
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
            network: liveDevice.isUSB ? "USB debugging" : "Wireless debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: liveDevice.serial
        )
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

    private func recordADBHealth(
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
        let connectablePhones = phones.filter { $0.kind == .connectable }
        guard connectablePhones.count == 1 else { return nil }
        return connectablePhones[0]
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

    nonisolated static func shouldPrioritizeUSBHandoff(
        authorizedDevices: [AuthorizedADBDevice],
        lastAttemptedSerial: String?,
        preferUSBMirroring: Bool,
        isMirroring: Bool,
        isPairing: Bool
    ) -> Bool {
        guard !preferUSBMirroring, !isMirroring, !isPairing else {
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

    nonisolated static func shouldUSBInterruptReconnect(
        authorizedDevices: [AuthorizedADBDevice],
        isRecoveringConnection: Bool,
        isAwaitingReconnect: Bool,
        hasReconnectTask: Bool,
        hasWirelessStartTask: Bool
    ) -> Bool {
        guard authorizedDevices.contains(where: \.isUSB) else { return false }
        return isRecoveringConnection
            || isAwaitingReconnect
            || hasReconnectTask
            || hasWirelessStartTask
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
    /// one that's actually usable, or nil. Needs no phone interaction and no
    /// Wireless debugging toggle — just reachability on the current network.
    ///
    /// A bare `adb connect` is not enough: adb happily reports "already connected
    /// to <host>" for a stale entry whose phone is asleep or off the network, and
    /// launching a mirror against it then fails. So every candidate must also pass
    /// a `shell echo` readiness probe before we treat it as connected.
    nonisolated static func connectToRememberedWireless(
        adb: ADBController,
        savedAddress: String,
        readinessAttempts: Int = 1,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil
    ) async -> String? {
        for candidate in reconnectCandidateAddresses(for: savedAddress) {
            if await waitForADBWirelessTargetReady(
                adb: adb,
                address: candidate,
                attempts: readinessAttempts,
                preflightLocalNetworkAccess: preflightLocalNetworkAccess
            ) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func connectToUSBDeviceOverCurrentWiFi(
        adb: ADBController,
        usbDevice: AuthorizedADBDevice,
        readinessAttempts: Int = 1,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil,
        maximumDuration: TimeInterval? = wirelessHandoffMaxDuration
    ) async -> String? {
        let handoffStartedAt = Date()
        func remainingBudget() -> TimeInterval? {
            guard let maximumDuration else { return nil }
            return max(0, maximumDuration - Date().timeIntervalSince(handoffStartedAt))
        }
        func boundedTimeout(_ requested: TimeInterval) -> TimeInterval? {
            guard let remaining = remainingBudget() else { return requested }
            guard remaining > 0.05 else { return nil }
            return min(requested, remaining)
        }
        guard let routeQueryTimeout = boundedTimeout(wirelessHandoffRouteQueryTimeout) else {
            return nil
        }
        let routeOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "shell", "ip", "route"], timeout: routeQueryTimeout)
        }.value
        guard let wirelessAddress = legacyTCPIPDebuggingAddress(routeOutput: routeOutput) else {
            return nil
        }

        if let primeTimeout = boundedTimeout(wirelessHandoffRoutePrimeTimeout) {
            await primeADBWirelessRoute(
                adb: adb,
                usbSerial: usbDevice.serial,
                wirelessAddress: wirelessAddress,
                timeout: primeTimeout
            )
        }

        if await waitForADBWirelessTargetReady(
            adb: adb,
            address: wirelessAddress,
            attempts: readinessAttempts,
            delayNanoseconds: wirelessHandoffRetryDelayNanoseconds,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess,
            primeRoute: {
                let timeout = min(wirelessHandoffRoutePrimeTimeout, remainingBudget() ?? wirelessHandoffRoutePrimeTimeout)
                guard timeout > 0.05 else { return }
                await primeADBWirelessRoute(
                    adb: adb,
                    usbSerial: usbDevice.serial,
                    wirelessAddress: wirelessAddress,
                    timeout: timeout
                )
            },
            maximumDuration: remainingBudget(),
            connectTimeout: wirelessHandoffConnectTimeout,
            shellTimeout: wirelessHandoffShellTimeout
        ) {
            return wirelessAddress
        }

        guard let tcpipTimeout = boundedTimeout(wirelessHandoffTCPIPTimeout) else {
            return nil
        }
        let tcpipOutput = await Task.detached {
            adb.run(["-s", usbDevice.serial, "tcpip", "\(legacyADBWirelessPort)"], timeout: tcpipTimeout)
        }.value
        guard adbTCPIPSucceeded(tcpipOutput) else { return nil }

        return await waitForADBWirelessTargetReady(
            adb: adb,
            address: wirelessAddress,
            attempts: readinessAttempts,
            delayNanoseconds: wirelessHandoffRetryDelayNanoseconds,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess,
            primeRoute: {
                let timeout = min(wirelessHandoffRoutePrimeTimeout, remainingBudget() ?? wirelessHandoffRoutePrimeTimeout)
                guard timeout > 0.05 else { return }
                await primeADBWirelessRoute(
                    adb: adb,
                    usbSerial: usbDevice.serial,
                    wirelessAddress: wirelessAddress,
                    timeout: timeout
                )
            },
            maximumDuration: remainingBudget(),
            connectTimeout: wirelessHandoffConnectTimeout,
            shellTimeout: wirelessHandoffShellTimeout
        ) ? wirelessAddress : nil
    }

    /// Whether a freshly-connected wireless target is worth promoting to a plain
    /// `tcpip 5555` listener. Anything already on 5555 is left alone.
    nonisolated static func shouldPromoteToLegacyTCPIP(connectedAddress: String) -> Bool {
        !connectedAddress.hasSuffix(":\(legacyADBWirelessPort)")
    }

    /// Promotes an already-connected wireless adb device (e.g. one reached via
    /// Android 11 Wireless debugging on a random TLS port) to a plain `tcpip
    /// 5555` listener, so later reconnects work on the same Wi-Fi without the
    /// Wireless-debugging toggle. `adb tcpip` works over any transport, so the
    /// source can itself be a wireless address — no USB cable required. Returns
    /// `host:5555` on success, or nil to keep using the original target.
    nonisolated static func promoteToLegacyTCPIP(
        adb: ADBController,
        sourceSerial: String,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil
    ) async -> String? {
        let handoffStartedAt = Date()
        func remainingBudget() -> TimeInterval {
            remainingWirelessHandoffBudget(startedAt: handoffStartedAt)
        }
        guard remainingBudget() > 0.05 else { return nil }
        let routeOutput = await Task.detached {
            adb.run(
                ["-s", sourceSerial, "shell", "ip", "route"],
                timeout: min(wirelessHandoffRouteQueryTimeout, remainingBudget())
            )
        }.value
        guard let legacyAddress = legacyTCPIPDebuggingAddress(routeOutput: routeOutput) else {
            return nil
        }
        if legacyAddress == sourceSerial {
            return legacyAddress
        }

        guard remainingBudget() > 0.05 else { return nil }
        let tcpipOutput = await Task.detached {
            adb.run(
                ["-s", sourceSerial, "tcpip", "\(legacyADBWirelessPort)"],
                timeout: min(wirelessHandoffTCPIPTimeout, remainingBudget())
            )
        }.value
        guard adbTCPIPSucceeded(tcpipOutput) else { return nil }

        // adbd restarts on 5555; the old transport drops, so retry connect.
        let ready = await waitForADBWirelessTargetReady(
            adb: adb,
            address: legacyAddress,
            attempts: wirelessHandoffReadinessAttempts,
            delayNanoseconds: wirelessHandoffRetryDelayNanoseconds,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess,
            maximumDuration: remainingBudget(),
            connectTimeout: wirelessHandoffConnectTimeout,
            shellTimeout: wirelessHandoffShellTimeout
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
        let exactMatches = devices.filter { device in
            device.serial == record.id || device.serial == record.lastAddress
        }
        // When the same phone is live on both transports, take the wireless
        // one: it mirrors immediately with no tcpip handoff round-trip.
        if let wireless = exactMatches.first(where: { !$0.isUSB }) {
            return wireless
        }
        if let exact = exactMatches.first {
            return exact
        }

        guard record.displayName.localizedCaseInsensitiveCompare("Android device") != .orderedSame else {
            return nil
        }

        let modelMatches = devices.filter { device in
            device.model.localizedCaseInsensitiveCompare(record.displayName) == .orderedSame
        }
        return modelMatches.first(where: { !$0.isUSB }) ?? modelMatches.first
    }

    nonisolated static func liveSelectedOrRememberedDevice(
        selectedSerial: String,
        pairedPhones: [PairedPhoneRecord],
        authorizedDevices: [AuthorizedADBDevice]
    ) -> AuthorizedADBDevice? {
        if let exact = authorizedDevices.first(where: { $0.serial == selectedSerial }) {
            if exact.isUSB {
                for record in recordsByMostRecent(pairedPhones) where
                    Self.recordMatchesSelectedADBSerial(record, selectedSerial: selectedSerial) {
                    if let wireless = rememberedAuthorizedDevice(for: record, in: authorizedDevices),
                       !wireless.isUSB {
                        return wireless
                    }
                }
                if let wireless = authorizedDevices.first(where: { device in
                    !device.isUSB
                        && device.model.localizedCaseInsensitiveCompare(exact.model) == .orderedSame
                        && (exact.product.isEmpty
                            || device.product.isEmpty
                            || device.product.localizedCaseInsensitiveCompare(exact.product) == .orderedSame)
                }) {
                    return wireless
                }
            }
            return exact
        }

        for record in recordsByMostRecent(pairedPhones) {
            if let device = rememberedAuthorizedDevice(for: record, in: authorizedDevices) {
                return device
            }
        }

        return nil
    }

    nonisolated static func recordMatchesSelectedADBSerial(
        _ record: PairedPhoneRecord,
        selectedSerial: String
    ) -> Bool {
        record.id == selectedSerial
            || record.lastAddress == selectedSerial
            || normalizedADBSerial(record.id) == selectedSerial
    }

    private nonisolated static func normalizedADBSerial(_ identifier: String) -> String {
        guard identifier.hasPrefix("adb-") else { return identifier }
        return String(identifier.dropFirst(4))
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

    /// Outcome of a wireless readiness probe. `sawNoRouteToHost` flags the
    /// macOS-side failure pattern where every connect attempt fails with "No
    /// route to host". A single no-route result can also be an ordinary transient
    /// Wi-Fi/routing miss, so don't surface the Local Network hint unless the
    /// whole probe failed that way.
    struct WirelessTargetReadiness {
        var isReady: Bool
        var connectAttempts: Int
        var noRouteToHostFailures: Int

        var sawNoRouteToHost: Bool {
            connectAttempts > 0 && connectAttempts == noRouteToHostFailures
        }
    }

    struct LocalNetworkEndpointParts: Equatable {
        var host: String
        var port: UInt16
    }

    nonisolated static func localNetworkEndpointParts(from address: String) -> LocalNetworkEndpointParts? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.lastIndex(of: ":") else { return nil }

        var host = String(trimmed[..<separator])
        let portText = String(trimmed[trimmed.index(after: separator)...])
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }

        guard !host.isEmpty,
              let port = UInt16(portText),
              port > 0
        else { return nil }

        return LocalNetworkEndpointParts(host: host, port: port)
    }

    nonisolated static func preflightLocalNetworkAccess(
        address: String,
        timeoutNanoseconds: UInt64 = 1_200_000_000
    ) async {
        guard let endpoint = localNetworkEndpointParts(from: address),
              let port = NWEndpoint.Port(rawValue: endpoint.port)
        else { return }

        let connection = NWConnection(
            host: NWEndpoint.Host(endpoint.host),
            port: port,
            using: .tcp
        )
        let queue = DispatchQueue(label: "PhoneRelay.local-network-preflight")
        let completion = OneShotCallback()

        Logger.log("Preflighting Local Network permission for \(address)")
        await withCheckedContinuation { continuation in
            let finish: @Sendable () -> Void = {
                completion.run {
                    connection.cancel()
                    continuation.resume()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready, .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }

            connection.start(queue: queue)
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                finish()
            }
        }
    }

    nonisolated static func outputIndicatesLocalNetworkBlocked(_ output: String) -> Bool {
        output.localizedCaseInsensitiveContains("no route to host")
    }

    nonisolated static func waitForADBWirelessTargetReady(
        adb: ADBController,
        address: String,
        attempts: Int = 8,
        delayNanoseconds: UInt64 = 700_000_000,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil,
        primeRoute: (() async -> Void)? = nil,
        maximumDuration: TimeInterval? = nil,
        connectTimeout: TimeInterval = 5,
        shellTimeout: TimeInterval = 2
    ) async -> Bool {
        await waitForADBWirelessTargetReadiness(
            adb: adb,
            address: address,
            attempts: attempts,
            delayNanoseconds: delayNanoseconds,
            preflightLocalNetworkAccess: preflightLocalNetworkAccess,
            primeRoute: primeRoute,
            maximumDuration: maximumDuration,
            connectTimeout: connectTimeout,
            shellTimeout: shellTimeout
        ).isReady
    }

    nonisolated static func waitForADBWirelessTargetReadiness(
        adb: ADBController,
        address: String,
        attempts: Int = 8,
        delayNanoseconds: UInt64 = 700_000_000,
        preflightLocalNetworkAccess: ((String) async -> Void)? = nil,
        primeRoute: (() async -> Void)? = nil,
        maximumDuration: TimeInterval? = nil,
        connectTimeout: TimeInterval = 5,
        shellTimeout: TimeInterval = 2
    ) async -> WirelessTargetReadiness {
        guard !Task.isCancelled else {
            return WirelessTargetReadiness(
                isReady: false,
                connectAttempts: 0,
                noRouteToHostFailures: 0
            )
        }
        let deadline = maximumDuration.map { Date().addingTimeInterval(max(0, $0)) }
        func remainingBudget() -> TimeInterval? {
            guard let deadline else { return nil }
            return deadline.timeIntervalSinceNow
        }
        func boundedTimeout(_ requested: TimeInterval) -> TimeInterval? {
            guard let remaining = remainingBudget() else { return requested }
            guard remaining > 0.05 else { return nil }
            return min(requested, remaining)
        }

        if let preflightLocalNetworkAccess {
            await preflightLocalNetworkAccess(address)
        }

        var connectAttempts = 0
        var noRouteToHostFailures = 0
        for attempt in 0..<attempts {
            if let remaining = remainingBudget(), remaining <= 0 {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            guard !Task.isCancelled else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            if attempt > 0 {
                let sleepNanoseconds: UInt64
                if let remaining = remainingBudget() {
                    let remainingNanoseconds = UInt64(max(0, remaining) * 1_000_000_000)
                    guard remainingNanoseconds > 0 else {
                        return WirelessTargetReadiness(
                            isReady: false,
                            connectAttempts: connectAttempts,
                            noRouteToHostFailures: noRouteToHostFailures
                        )
                    }
                    sleepNanoseconds = min(delayNanoseconds, remainingNanoseconds)
                } else {
                    sleepNanoseconds = delayNanoseconds
                }
                try? await Task.sleep(nanoseconds: sleepNanoseconds)
            }
            guard !Task.isCancelled else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            guard boundedTimeout(connectTimeout) != nil else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }

            await primeRoute?()
            guard !Task.isCancelled else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }

            guard let connectCommandTimeout = boundedTimeout(connectTimeout) else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            let connectOutput = await Task.detached {
                adb.run(["connect", address], timeout: connectCommandTimeout)
            }.value
            Logger.log("ADB Wi-Fi handoff connect attempt \(attempt + 1)/\(attempts) address=\(address) output=\(connectOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            if outputIndicatesLocalNetworkBlocked(connectOutput) {
                noRouteToHostFailures += 1
            }
            connectAttempts += 1
            guard adbConnectSucceeded(connectOutput) else {
                continue
            }

            guard let shellCommandTimeout = boundedTimeout(shellTimeout) else {
                return WirelessTargetReadiness(
                    isReady: false,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }
            let shellOutput = await Task.detached {
                adb.run(["-s", address, "shell", "echo", "wifi-adb-ok"], timeout: shellCommandTimeout)
            }.value
            Logger.log("ADB Wi-Fi handoff shell readiness attempt \(attempt + 1)/\(attempts) address=\(address) output=\(shellOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            if shellOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "wifi-adb-ok" {
                return WirelessTargetReadiness(
                    isReady: true,
                    connectAttempts: connectAttempts,
                    noRouteToHostFailures: noRouteToHostFailures
                )
            }

            if attempt + 1 < attempts,
               Self.shouldDropStaleWirelessTransport(shellOutput: shellOutput),
               let disconnectTimeout = boundedTimeout(shellTimeout) {
                let disconnectOutput = await Task.detached {
                    adb.run(["disconnect", address], timeout: disconnectTimeout)
                }.value
                Logger.log("ADB Wi-Fi handoff stale transport cleanup address=\(address) output=\(disconnectOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        return WirelessTargetReadiness(
            isReady: false,
            connectAttempts: connectAttempts,
            noRouteToHostFailures: noRouteToHostFailures
        )
    }

    /// Whether a failed readiness probe means the transport is a zombie worth
    /// `adb disconnect`-ing before retrying. A transport that is merely still
    /// settling — `offline` during the post-connect handshake, or
    /// `unauthorized` while the phone shows its trust prompt — must be left
    /// alone: disconnecting it restarts the very handshake we're waiting out.
    nonisolated static func shouldDropStaleWirelessTransport(shellOutput: String) -> Bool {
        let lower = shellOutput.lowercased()
        return !(
            lower.contains("device offline")
            || lower.contains("device unauthorized")
            || lower.contains("device still authorizing")
        )
    }

    nonisolated static func primeADBWirelessRoute(
        adb: ADBController,
        usbSerial: String,
        wirelessAddress: String,
        timeout: TimeInterval = 2
    ) async {
        guard let localAddress = localIPv4Address(matchingRemoteAddress: wirelessAddress) else {
            Logger.log("ADB Wi-Fi handoff route prime skipped: no local IPv4 address matches \(wirelessAddress)")
            return
        }

        let output = await Task.detached {
            adb.run(["-s", usbSerial, "shell", "ping", "-c", "1", "-W", "1", localAddress], timeout: timeout)
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
        let normalized = normalizedDeviceName(name)
        guard !normalized.isEmpty else { return nil }
        let lowercased = normalized.lowercased()
        let genericNames = ["android device", "authorized device", "device", "unknown device", "unknown"]
        guard !genericNames.contains(lowercased) else { return nil }
        guard !lowercased.hasPrefix("pixel ") else { return nil }
        guard !Self.isSamsungModelCode(normalized) else { return nil }
        return normalized
    }

    nonisolated static func mirrorWindowDeviceTitle(name: String) -> String {
        let normalized = normalizedDeviceName(name)
        guard !normalized.isEmpty else { return "Android Device" }
        let lowercased = normalized.lowercased()
        let genericNames = ["android device", "authorized device", "device", "unknown device", "unknown"]
        guard !genericNames.contains(lowercased) else { return "Android Device" }
        return normalized
    }

    nonisolated static func mirrorLoadingStatusText(name: String) -> String {
        "Connecting to your"
    }

    nonisolated static func mirrorLoadingDeviceTitle(name: String) -> String {
        let title = mirrorWindowDeviceTitle(name: name)
        return title == "Android Device" ? "Android phone" : title
    }

    private nonisolated static func normalizedDeviceName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    nonisolated static func connectedDeviceName(
        adb: ADBController,
        serial: String,
        fallback: String
    ) async -> String {
        let output = await Task.detached {
            adb.run(["devices", "-l"], timeout: adbDeviceListTimeout)
        }.value
        if let device = authorizedADBDevices(in: output).first(where: { $0.serial == serial }) {
            let modelName = mirrorWindowDeviceTitle(name: device.model)
            if modelName != "Android Device" {
                return modelName
            }
        }
        return mirrorWindowDeviceTitle(name: fallback)
    }

    // MARK: - Mirroring lifecycle

    private func scheduleMirrorSettingsRestart() {
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
            // A deliberate retry clears backoff.
            setAutoConnectSuspendedForSelectedDevice(false)
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
                    savedAddress: savedTarget,
                    preflightLocalNetworkAccess: { address in
                        await Self.preflightLocalNetworkAccess(address: address)
                    }
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

    func stopMirroring(suspendAutoConnect: Bool = true) {
        if suspendAutoConnect {
            setAutoConnectSuspendedForSelectedDevice(true)
        }
        mirrorStartGeneration += 1
        mirrorLaunchTask?.cancel()
        mirrorLaunchTask = nil
        usbConnectTask?.cancel()
        usbConnectTask = nil
        usbWiFiHandoffTask?.cancel()
        usbWiFiHandoffTask = nil
        wirelessStartTask?.cancel()
        wirelessStartTask = nil
        if reconnectTask != nil {
            // A deliberate stop also cancels an in-flight manual reconnect and
            // releases its busy flag (its own cleanup is skipped once cancelled).
            reconnectTask?.cancel()
            reconnectTask = nil
            isPairing = false
            reconnectAttemptCount = 0
        }
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

    private func recoverMissingMirrorTransport() {
        guard isMirroring || mirrorSession != nil || mirrorLaunchTask != nil else { return }
        Logger.log("Selected mirror transport disappeared; switching to reconnecting screen")
        mirrorStartGeneration += 1
        mirrorLaunchTask?.cancel()
        mirrorLaunchTask = nil
        mirrorSession?.onSessionEnded = nil
        mirrorSession?.stop()
        mirrorSession = nil
        isMirroring = false
        if isRecording {
            isRecording = false
            stopScreenRecordingCleanup()
        }
        noteMirrorSessionEnded()
        startDisconnectRecoveryFallback()
        showConnectionWindow(startsQRCodePairing: false)
    }

    private func launchNativeMirror(serial: String?) {
        guard !isFirstRunOnboardingActive else {
            Logger.log("Skipping mirror launch while first-run onboarding is on screen")
            return
        }
        guard !isMirroring, mirrorSession == nil, mirrorLaunchTask == nil else {
            Logger.log("Skipping duplicate mirror launch serial=\(serial ?? "default")")
            return
        }

        Logger.log("Launching native mirror serial=\(serial ?? "default")")
        let launchFrame = connectionWindow?.frame ?? lastMirrorWindowFrame
        let keepConnectionWindowVisible = Self.shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
            isRecoveringConnection: isRecoveringConnection,
            isAwaitingReconnect: isAwaitingReconnect
        )
        let session = MirrorSession(model: self, serial: serial, launchFrame: launchFrame)
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
                self.lastMirrorWindowFrame = finalMirrorFrame
                self.connectionWindow?.setFrame(finalMirrorFrame, display: false)
            }
            self.startDisconnectRecoveryFallback()
            self.showConnectionWindow(startsQRCodePairing: false)
        }
        session.onReadyToDisplay = { [weak self, weak session] in
            guard let self, let session, self.mirrorSession === session else { return }
            self.stopDisconnectRecovery()
            self.activeError = nil
            self.hideConnectionWindowForNativeMirror()
        }

        mirrorLaunchTask?.cancel()
        mirrorSession = session
        isMirroring = true
        isAwaitingReconnect = false
        selectedDevice.states = [.mirroringReady, .companionConnected]
        lastMirrorStartAt = Date()
        if !keepConnectionWindowVisible {
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
                let message = Self.mirrorFailureMessage(for: error)
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
        activeErrorMessage: String?
    ) -> ConnectionHealthSnapshot {
        let hasAuthorizedUSB = authorizedDevices.contains(where: \.isUSB)
        let hasWirelessDevice = authorizedDevices.contains { !$0.isUSB }
        let hasWiFiReachability = hasWirelessDevice || discoveredPhones.contains { $0.kind == .connectable }
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
        let attemptsItem = ConnectionHealthSnapshot.Item(
            id: "attempts",
            title: "Reconnect attempts",
            value: reconnectAttemptCount == 0 ? "None" : "\(reconnectAttemptCount)",
            level: reconnectAttemptCount == 0 ? .neutral : .warning
        )

        return ConnectionHealthSnapshot(
            usbAuthorization: usbItem,
            wifiReachability: wifiItem,
            localNetworkPermission: permissionItem,
            adbStatus: adbItem,
            selectedTransport: transportItem,
            reconnectAttempts: attemptsItem,
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
            return "No action needed. The selected device is reachable."
        }
        if hasAuthorizedUSB {
            return "Use Connect via USB to refresh the session and Wi-Fi handoff."
        }
        if !hasWiFiReachability {
            return "Put the phone on the same Wi-Fi, enable Wireless debugging, or connect USB once."
        }
        return "Try reconnecting over Wi-Fi, or refresh the pairing with the QR code."
    }

    private nonisolated static func shortDeviceIdentifier(_ value: String) -> String {
        if value.hasPrefix("adb-") {
            return String(value.dropFirst(4))
        }
        return value
    }

    private nonisolated static func isSamsungModelCode(_ name: String) -> Bool {
        let normalized = name
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        return normalized.range(of: #"^SM[A-Z0-9]+$"#, options: .regularExpression) != nil
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

    private func hideConnectionWindow() {
        connectionWindow?.childWindows?.forEach { $0.orderOut(nil) }
        connectionWindow?.orderOut(nil)
    }

    private func hideConnectionWindowForNativeMirror() {
        hideConnectionWindow()
        if NSApp?.isActive == true {
            NSApp?.activate(ignoringOtherApps: true)
        }
    }

    private func showConnectionWindow(startsQRCodePairing: Bool = true) {
        // The first-run onboarding card owns the screen; the connection window
        // is revealed by its dismissal, never alongside it.
        guard !isFirstRunOnboardingActive else {
            hideConnectionWindow()
            return
        }
        guard let connectionWindow, !isMirroring, mirrorSession == nil else { return }
        switch Self.connectionWindowPresentation(appIsActive: NSApp?.isActive == true) {
        case .activateAndMakeKey:
            connectionWindow.makeKeyAndOrderFront(nil)
            NSApp?.activate(ignoringOtherApps: true)
        case .orderFrontOnly:
            connectionWindow.orderFront(nil)
        }
        if startsQRCodePairing {
            ensureQRCodePairingSession()
        }
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
        resumeAutoConnect(for: record)
        if Self.isWirelessRecord(record) {
            // Wireless records get the full, restart-and-retry reconnect path so a
            // deliberate "Connect" recovers a sleeping phone instead of failing
            // silently on the first stale `adb connect`.
            reconnectOverWiFi(preferredRecord: record)
            return
        }
        select(record: record)
        stopQRCodePairingSession()
        startMirroring(manual: true)
    }

    /// Longest a deliberate "Reconnect over Wi-Fi" attempt keeps trying before it
    /// surfaces an actionable error. Keep this short so stale saved addresses
    /// do not make a clearly-online device feel stuck.
    nonisolated static let manualReconnectWindow: TimeInterval = 10

    /// User-initiated Wi-Fi reconnect. Unlike background auto-reconnect it bounces
    /// the adb server first, then retries every saved wireless route — each gated
    /// on a shell-readiness probe — for `manualReconnectWindow` seconds, falling
    /// back to mDNS rediscovery if the phone's address changed. A successful TLS
    /// session is promoted to a stable `:5555` listener so the next reconnect
    /// survives the Wireless-debugging toggle. If every route is dead it explains
    /// why. Never requires a USB cable up front.
    func reconnectOverWiFi(preferredRecord: PairedPhoneRecord? = nil) {
        guard !isMirroring, !isPairing else { return }

        let ordered = Self.recordsByMostRecent(pairedPhones).filter(Self.isWirelessRecord)
        let wirelessRecords: [PairedPhoneRecord]
        if let preferredRecord, Self.isWirelessRecord(preferredRecord) {
            wirelessRecords = [preferredRecord] + ordered.filter { $0.id != preferredRecord.id }
        } else {
            wirelessRecords = ordered
        }

        guard let leadRecord = wirelessRecords.first else {
            reportError(
                "No saved Wi-Fi device",
                "Pair a phone with the QR code, or connect it once over USB while both devices are on the same Wi-Fi, so the app can keep using Wi-Fi automatically."
            )
            return
        }

        resumeAutoConnect(for: leadRecord)
        reconnectTask?.cancel()
        stopQRCodePairingSession()
        select(record: leadRecord)               // names the "Reconnecting to…" overlay
        isPairing = true
        isRecoveringConnection = true
        isAwaitingReconnect = true
        reconnectAttemptCount = 0

        let adb = self.adb
        let generation = mirrorStartGeneration
        reconnectTask = Task { [weak self] in
            await adb.ensureServerStarted()

            let deadline = Date().addingTimeInterval(Self.manualReconnectWindow)
            var sawPairingServiceOnly = false
            var round = 0

            while Date() < deadline {
                if Task.isCancelled { return }
                guard let self, self.mirrorStartGeneration == generation, !self.isMirroring else { return }

                // Saved wireless routes, including the stable :5555 fallback.
                for record in wirelessRecords {
                    if Task.isCancelled { return }
                    self.reconnectAttemptCount += 1
                    if let connectedAddress = await Self.connectToRememberedWireless(
                        adb: adb,
                        savedAddress: record.lastAddress,
                        readinessAttempts: 1,
                        preflightLocalNetworkAccess: { address in
                            await Self.preflightLocalNetworkAccess(address: address)
                        }
                    ) {
                        await self.finishManualReconnect(
                            record: record,
                            connectedAddress: connectedAddress,
                            generation: generation
                        )
                        return
                    }
                }

                // mDNS rediscovery, in case the phone's wireless address changed.
                let livePhones = await Task.detached { adb.connectableMDNSTargets() }.value
                for record in wirelessRecords {
                    if Task.isCancelled { return }
                    guard let phone = Self.rememberedConnectablePhone(for: record, in: livePhones) else { continue }
                    self.reconnectAttemptCount += 1
                    if await Self.waitForADBWirelessTargetReady(
                        adb: adb,
                        address: phone.address,
                        attempts: 1,
                        preflightLocalNetworkAccess: { address in
                            await Self.preflightLocalNetworkAccess(address: address)
                        }
                    ) {
                        await self.finishManualReconnect(
                            record: record,
                            connectedAddress: phone.address,
                            generation: generation
                        )
                        return
                    }
                }

                // Only a pairing service in sight means this Mac isn't paired/connected.
                let services = await Task.detached { adb.mdnsServices() }.value
                if !services.isEmpty, services.allSatisfy({ $0.kind == .pairable }) {
                    sawPairingServiceOnly = true
                }

                round += 1
                if round == 3 {
                    // Keep adb alive without dropping active USB/wireless transports.
                    await adb.ensureServerStarted()
                }
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            guard let self, !Task.isCancelled, self.mirrorStartGeneration == generation, !self.isMirroring else { return }
            self.failManualReconnect(sawPairingServiceOnly: sawPairingServiceOnly)
        }
    }

    private func finishManualReconnect(
        record: PairedPhoneRecord,
        connectedAddress: String,
        generation: Int
    ) async {
        let adb = self.adb

        // Promote a random Wireless-debugging TLS port to a plain `tcpip 5555`
        // listener so the next reconnect works without the toggle (no-op on :5555).
        var address = connectedAddress
        if Self.shouldPromoteToLegacyTCPIP(connectedAddress: connectedAddress),
           let promoted = await Self.promoteToLegacyTCPIP(
               adb: adb,
               sourceSerial: connectedAddress,
               preflightLocalNetworkAccess: { address in
                   await Self.preflightLocalNetworkAccess(address: address)
               }
           ) {
            address = promoted
        }
        let deviceName = await Self.connectedDeviceName(adb: adb, serial: address, fallback: record.displayName)

        guard !Task.isCancelled, mirrorStartGeneration == generation, !isMirroring else { return }
        reconnectTask = nil
        isPairing = false
        reconnectAttemptCount = 0
        select(record: record)
        selectedDevice.adbSerial = address
        selectedDevice.name = deviceName
        touchPairedPhone(id: record.id, displayName: deviceName, address: address)
        stopQRCodePairingSession()
        startMirroring(manual: true)
    }

    private func failManualReconnect(sawPairingServiceOnly: Bool) {
        reconnectTask = nil
        isPairing = false
        isRecoveringConnection = false
        isAwaitingReconnect = false
        if sawPairingServiceOnly {
            reportError(
                "Pair this phone again",
                "Wireless debugging is visible but this Mac isn’t connected to it. Tap Pair with QR code, or connect USB once."
            )
        } else {
            reportError(
                "Phone not reachable over Wi-Fi",
                "Make sure USB debugging is enabled and authorized, the phone is awake, and both devices are on the same Wi-Fi, or connect USB once to refresh the Wi-Fi path."
            )
        }
        showConnectionWindow(startsQRCodePairing: true)
    }

    func forgetPairedPhone(id: PairedPhoneRecord.ID) {
        pairedPhones = store.removing(id, from: pairedPhones)
        store.save(pairedPhones)
        if pairedPhones.isEmpty {
            resetDeviceSelectionAfterClearingAll()
            return
        }
        if selectedDevice.id == id {
            selectedDevice = .demo
            isSelectedDeviceOnline = false
        }
    }

    func forgetAllPairedPhones() {
        store.clearAll()
        resetDeviceSelectionAfterClearingAll()
    }

    private func resetDeviceSelectionAfterClearingAll() {
        let wirelessTargets = Self.wirelessTargetsToDisconnect(
            selectedSerial: selectedDevice.adbSerial,
            selectedID: selectedDevice.id,
            records: pairedPhones
        )
        if isMirroring || mirrorSession != nil || mirrorLaunchTask != nil {
            stopMirroring()
        }
        disconnectForgottenWirelessTargets(wirelessTargets)
        usbConnectTask?.cancel()
        usbConnectTask = nil
        usbWiFiHandoffTask?.cancel()
        usbWiFiHandoffTask = nil
        cancelWirelessReconnectWork()
        stopQRCodePairingSession()
        pairedPhones = []
        discoveredPhones = []
        selectedDevice = .demo
        isSelectedDeviceOnline = false
        isPairing = false
        isScanning = false
        isAutoConnecting = false
        lastPresenceAutoConnectAttemptAt = nil
        failedAutoConnectTargets.removeAll()
        previousAuthorizedSerials.removeAll()
        lastUSBHandoffSerial = nil
        launchReconnectDeadline = nil
        requireExplicitDeviceSetup()
    }

    nonisolated static func wirelessTargetsToDisconnect(
        selectedSerial: String?,
        selectedID: String,
        records: [PairedPhoneRecord]
    ) -> Set<String> {
        var targets = Set<String>()
        if let selectedSerial, isWirelessADBTarget(selectedSerial) {
            targets.insert(selectedSerial)
        }
        if isWirelessADBTarget(selectedID) {
            targets.insert(selectedID)
        }
        for record in records where isWirelessADBTarget(record.lastAddress) {
            targets.insert(record.lastAddress)
        }
        return targets
    }

    private func disconnectForgottenWirelessTargets(_ targets: Set<String>) {
        guard !targets.isEmpty else { return }
        let adb = self.adb
        Task.detached(priority: .utility) {
            for target in targets {
                let output = adb.run(["disconnect", target], timeout: 2)
                Logger.log("Disconnected forgotten wireless ADB target \(target): \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    private func requireExplicitDeviceSetup() {
        explicitDeviceSetupRequired = true
        Self.setExplicitDeviceSetupRequiredPreference(true)
    }

    private func clearExplicitDeviceSetupRequirement() {
        explicitDeviceSetupRequired = false
        Self.setExplicitDeviceSetupRequiredPreference(false)
    }

    nonisolated static func explicitDeviceSetupRequiredPreference() -> Bool {
        if UserDefaults.standard.bool(forKey: explicitDeviceSetupRequiredDefaultsKey) {
            return true
        }
        for suiteName in PairedPhoneStore.compatibilitySuites {
            if UserDefaults(suiteName: suiteName)?.bool(forKey: explicitDeviceSetupRequiredDefaultsKey) == true {
                return true
            }
        }
        return false
    }

    private nonisolated static func setExplicitDeviceSetupRequiredPreference(_ required: Bool) {
        let defaults = [UserDefaults.standard]
            + PairedPhoneStore.compatibilitySuites.compactMap { UserDefaults(suiteName: $0) }
        for defaults in defaults {
            if required {
                defaults.set(true, forKey: explicitDeviceSetupRequiredDefaultsKey)
            } else {
                defaults.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey)
            }
        }
    }

    // MARK: - Android input

    /// Toggles the phone's physical display off/on over the active mirror
    /// session (same control message the automatic 30-second screen-off uses;
    /// mirroring keeps running either way).
    func togglePhoneScreenPower() {
        mirrorSession?.toggleDeviceScreenPower()
    }

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
        let outputDirectory = screenshotOutputDirectory()
        presentCaptureCue(.screenshot)
        Task {
            let result = await Task.detached { () -> Result<URL, MediaCaptureService.ScreenshotError> in
                let didAccess = outputDirectory?.startAccessingSecurityScopedResource() ?? false
                defer {
                    if didAccess {
                        outputDirectory?.stopAccessingSecurityScopedResource()
                    }
                }
                return MediaCaptureService.captureScreenshot(serial: serial, outputDirectory: outputDirectory)
            }.value

            switch result {
            case .success(let url):
                Logger.log("Saved screenshot: \(url.path)")
                self.lastCaptureURL = url
            case .failure(.adbMissing):
                self.reportError("Screenshot failed", "adb wasn’t found. Install Android platform-tools and try again.")
            case .failure(.emptyOutput):
                self.reportError("Screenshot failed", "The phone returned an empty image. Make sure the screen is on and try again.")
            case .failure(.commandFailed(let message)):
                Logger.log("Screenshot failed: \(message)")
                self.reportError("Screenshot failed", Self.mirrorFailureMessage(for: NSError(domain: "screenshot", code: 0, userInfo: [NSLocalizedDescriptionKey: message])))
            }
        }
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
                    "rm -f /sdcard/phonerelay-record.mp4; screenrecord /sdcard/phonerelay-record.mp4 >/dev/null 2>&1 & echo started"
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
        let outputDirectory = recordingOutputDirectory()
        Task { [weak self] in
            await Task.detached {
                _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                    "shell",
                    "pkill -2 screenrecord >/dev/null 2>&1"
                ])
            }.value
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let result = await Task.detached { () -> Result<URL, RecordingError> in
                let didAccess = outputDirectory?.startAccessingSecurityScopedResource() ?? false
                defer {
                    if didAccess {
                        outputDirectory?.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let directory = try MediaCaptureService.outputDirectory(outputDirectory)
                    let url = directory.appendingPathComponent(MediaCaptureService.filename(
                        kind: "Screen-Recording",
                        extension: "mp4"
                    ))
                    let output = adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "pull", "/sdcard/phonerelay-record.mp4",
                        url.path
                    ], timeout: 120)
                    _ = adb.run(Self.adbDeviceArguments(serial: serial) + [
                        "shell",
                        "rm -f /sdcard/phonerelay-record.mp4 >/dev/null 2>&1"
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

    nonisolated static func oneLine(_ text: String) -> String {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

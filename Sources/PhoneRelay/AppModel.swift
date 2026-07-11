import SwiftUI
import AppKit
import Foundation
import Darwin
import Network
import UserNotifications
import AVFoundation

// Not private: used from AppModel+ConnectionHelpers.swift (pure-move split).
final class OneShotCallback: @unchecked Sendable {
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

enum SettingsScrollBarVisibility: String, CaseIterable, Identifiable {
    case always
    case onHover

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: return "Always"
        case .onHover: return "On hover"
        }
    }
}

enum ScreenRecordingTouchSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large
    case max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .max: return "Max"
        }
    }

    var liveDiameterScale: CGFloat {
        switch self {
        case .small: return 0.052
        case .medium: return 0.072
        case .large: return 0.09
        case .max: return 0.11
        }
    }

    var recordingDiameterScale: CGFloat {
        switch self {
        case .small: return 0.045
        case .medium: return 0.062
        case .large: return 0.078
        case .max: return 0.095
        }
    }

    var minimumDiameter: CGFloat {
        switch self {
        case .small: return 28
        case .medium: return 38
        case .large: return 46
        case .max: return 54
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    typealias NotificationAuthorizationRequester = (@escaping (Bool, Error?) -> Void) -> Void
    typealias NotificationSettingsOpener = () -> Void
    typealias LocalNetworkPermissionPrompter = (@escaping (Bool) -> Void) -> Void

    struct ScreenRecordingTouchEvent: Sendable, Equatable {
        let normalizedX: Double
        let normalizedY: Double
        let occurredAt: Date
        let intensity: Double
    }

    struct ScreenRecordingSegmentStart: Sendable, Equatable {
        let index: Int
        let startedAt: Date
    }

    struct ScreenRecordingTouchTimelineEvent: Sendable, Equatable {
        let normalizedX: Double
        let normalizedY: Double
        let seconds: Double
        let intensity: Double
    }

    nonisolated static let localNetworkPermissionReason =
        "Allow Local Network so Phone Relay can find your phone on Wi-Fi for wireless pairing, USB-to-Wi-Fi handoff, and automatic reconnect."
    nonisolated static let notificationPermissionReason =
        "Turn on notifications if you want Phone Relay to show unread notifications from your device on this Mac."
    nonisolated static let localNetworkRecommendedFix =
        "Allow Local Network in macOS Settings, or connect the phone over USB."
    /// Sentinel for the healthy state — the connection-health view hides the
    /// "Next recommended fix" row entirely when this is the recommendation.
    nonisolated static let noActionNeededRecommendedFix =
        "No action needed. The selected device is reachable."
    nonisolated static let notificationForwardingDefaultsKey = "MirrorBehavior.notificationForwardingEnabled"
    nonisolated static let notificationHideBodyDefaultsKey = "Notifications.hideBody"
    nonisolated static let notificationSuppressSecurityCodesDefaultsKey = "Notifications.suppressSecurityCodes"
    nonisolated static let notificationPauseWhileRecordingDefaultsKey = "Notifications.pauseWhileRecording"
    nonisolated static let notificationMutedPackagesDefaultsKey = "Notifications.mutedPackages"
    nonisolated static let notificationKnownAppsDefaultsKey = "Notifications.knownApps"
    nonisolated static let privacyPolicyURL = URL(string: "https://mallenkb.github.io/phone-mirroring/privacy.html")!
    nonisolated static let supportURL = URL(string: "https://mallenkb.github.io/phone-mirroring/support.html")!
    nonisolated static let latestReleaseURL = URL(string: "https://github.com/mallenkb/phone-mirroring/releases/latest")!
    nonisolated static let mirrorScrollSpeedDefaultsKey = "MirrorBehavior.scrollSpeedPercent"
    nonisolated static let mirrorScrollFeelDefaultsKey = "MirrorBehavior.scrollFeel"
    nonisolated static let settingsScrollBarVisibilityDefaultsKey = "Appearance.settingsScrollBarVisibility"
    nonisolated static let backgroundWiFiHandoffDefaultsKey = "MirrorBehavior.backgroundWiFiHandoffEnabled"
    nonisolated static let mirrorAlwaysOnTopDefaultsKey = "MirrorBehavior.alwaysOnTopEnabled"
    nonisolated static let mirrorProfileDefaultsKey = "MirrorQuality.profile"
    nonisolated static let screenshotFolderPathDefaultsKey = "Capture.screenshotFolderPath"
    nonisolated static let screenshotFolderBookmarkDefaultsKey = "Capture.screenshotFolderBookmark"
    nonisolated static let recordingFolderPathDefaultsKey = "Capture.recordingFolderPath"
    nonisolated static let recordingFolderBookmarkDefaultsKey = "Capture.recordingFolderBookmark"
    nonisolated static let recordingMaxMinutesDefaultsKey = "Capture.recordingMaxMinutes"
    nonisolated static let recordingTouchSizeDefaultsKey = "Capture.recordingTouchSize"
    nonisolated static let diagnosticsEnabledDefaultsKey = DiagnosticsService.diagnosticsEnabledDefaultsKey
    /// Default screen-recording length when the user hasn't picked one.
    nonisolated static let recordingMaxMinutesDefault = 30
    /// Clamp range for the configurable recording cap (minutes).
    nonisolated static let recordingMaxMinutesRange = 1...180
    /// Keep each Android screenrecord process below the common 180s device cap.
    nonisolated static let screenRecordingSegmentSeconds = 175
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
        let value = (storedValue as? Int) ?? 10
        return min(100, max(10, value))
    }

    nonisolated static func defaultMirrorScrollFeel(storedValue: Any?) -> MirrorScrollFeel {
        guard let rawValue = storedValue as? String,
              let feel = MirrorScrollFeel(rawValue: rawValue) else {
            return .smooth
        }
        return feel
    }

    nonisolated static func defaultSettingsScrollBarVisibility(storedValue: Any?) -> SettingsScrollBarVisibility {
        guard let rawValue = storedValue as? String,
              let visibility = SettingsScrollBarVisibility(rawValue: rawValue) else {
            return .always
        }
        return visibility
    }

    nonisolated static func defaultScreenRecordingTouchSize(storedValue: Any?) -> ScreenRecordingTouchSize {
        guard let rawValue = storedValue as? String,
              let size = ScreenRecordingTouchSize(rawValue: rawValue) else {
            return .max
        }
        return size
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
    @Published var manualADBTarget = ""
    @Published var isManualADBTargetConnecting = false
    /// The 6-digit code from the phone's "Pair device with pairing code" screen.
    @Published var manualWirelessPairingCode = ""
    @Published var isManualWirelessPairing = false
    @Published var isRecoveringConnection = false
    /// True whenever a connect target is physically present (USB or a remembered
    /// wireless phone advertising on the network) but we aren't online/mirroring
    /// yet. Drives the unified "Connecting" indicator so it lights up the instant
    /// a saved phone appears, and self-clears once we're online or it's gone.
    @Published var isAutoConnecting = false
    @Published var isSelectedDeviceOnline = false
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
    @Published var settingsScrollBarVisibility: SettingsScrollBarVisibility =
        AppModel.defaultSettingsScrollBarVisibility(
            storedValue: UserDefaults.standard.object(forKey: AppModel.settingsScrollBarVisibilityDefaultsKey)
        ) {
        didSet {
            UserDefaults.standard.set(
                settingsScrollBarVisibility.rawValue,
                forKey: Self.settingsScrollBarVisibilityDefaultsKey
            )
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

    /// Privacy: drop the message body from forwarded banners (keeps app + title).
    @Published var notificationHideBodyEnabled: Bool =
        (UserDefaults.standard.object(forKey: AppModel.notificationHideBodyDefaultsKey) as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(notificationHideBodyEnabled, forKey: Self.notificationHideBodyDefaultsKey)
        }
    }
    /// Security: never forward likely one-time / security-code notifications.
    /// Defaults on — a 2FA code shouldn't fan out to the Mac and its sync.
    @Published var notificationSuppressSecurityCodesEnabled: Bool =
        (UserDefaults.standard.object(forKey: AppModel.notificationSuppressSecurityCodesDefaultsKey) as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(notificationSuppressSecurityCodesEnabled, forKey: Self.notificationSuppressSecurityCodesDefaultsKey)
        }
    }
    /// Privacy: pause forwarding while Phone Relay is recording the phone screen.
    @Published var notificationPauseWhileRecordingEnabled: Bool =
        (UserDefaults.standard.object(forKey: AppModel.notificationPauseWhileRecordingDefaultsKey) as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(notificationPauseWhileRecordingEnabled, forKey: Self.notificationPauseWhileRecordingDefaultsKey)
        }
    }
    @Published var anonymousDiagnosticsEnabled: Bool =
        UserDefaults.standard.bool(forKey: AppModel.diagnosticsEnabledDefaultsKey) {
        didSet {
            DiagnosticsService.shared.setEnabled(anonymousDiagnosticsEnabled)
        }
    }
    /// Packages the user has muted; their notifications are tracked (so they stay
    /// in the Settings list) but never posted.
    // Setter not private: mutated from AppModel+NotificationActions.swift
    // (pure-move split); treat as private elsewhere.
    @Published var mutedNotificationPackages: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: AppModel.notificationMutedPackagesDefaultsKey) ?? [])
    /// Apps Phone Relay has seen send notifications, newest first — populates the
    /// per-app mute list in Settings. Persisted so the list survives relaunches.
    // Setter not private: mutated from AppModel+NotificationActions.swift
    // (pure-move split); treat as private elsewhere.
    @Published var knownNotificationApps: [NotificationAppInfo] =
        AppModel.loadKnownNotificationApps()

    @Published private(set) var localNetworkPermissionGrantedForOnboarding = false
    @Published private(set) var isAwaitingLocalNetworkSettingsReturn = false
    @Published private(set) var notificationPermissionGrantedForOnboarding = false
    @Published var latestAuthorizedADBDevices: [AuthorizedADBDevice] = []
    @Published var latestHasUnauthorizedUSBDevice = false
    @Published var latestADBStatusText = "Not checked"
    @Published var reconnectAttemptCount = 0
    @Published var captureCue: CaptureCue?
    @Published private(set) var transferActivity: TransferActivity?
    // Setters not private: written from AppModel+Capture.swift (pure-move
    // split); treat as private elsewhere.
    @Published var screenshotFolderPath: String? =
        UserDefaults.standard.string(forKey: AppModel.screenshotFolderPathDefaultsKey)
    @Published var recordingFolderPath: String? =
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
    /// Maximum screen-recording length in minutes. The recorder splits this into
    /// short Android `screenrecord` processes so devices with a 3-minute cap keep going.
    @Published var recordingMaxMinutes: Int = AppModel.loadRecordingMaxMinutes() {
        didSet {
            let clamped = Self.clampedRecordingMaxMinutes(recordingMaxMinutes)
            if clamped != recordingMaxMinutes {
                recordingMaxMinutes = clamped
                return
            }
            guard oldValue != recordingMaxMinutes else { return }
            UserDefaults.standard.set(recordingMaxMinutes, forKey: Self.recordingMaxMinutesDefaultsKey)
        }
    }
    @Published var screenRecordingTouchSize: ScreenRecordingTouchSize =
        AppModel.defaultScreenRecordingTouchSize(
            storedValue: UserDefaults.standard.object(forKey: AppModel.recordingTouchSizeDefaultsKey)
        ) {
        didSet {
            UserDefaults.standard.set(screenRecordingTouchSize.rawValue, forKey: Self.recordingTouchSizeDefaultsKey)
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
    /// Prepares a Wi-Fi adb route in the background after USB mirroring starts.
    @Published var backgroundWiFiHandoffEnabled: Bool =
        (UserDefaults.standard.object(forKey: AppModel.backgroundWiFiHandoffDefaultsKey) as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(
                backgroundWiFiHandoffEnabled,
                forKey: Self.backgroundWiFiHandoffDefaultsKey
            )
        }
    }
    /// Keeps the active mirror above ordinary windows. This is a Mac-side view
    /// preference, so it can be applied immediately without restarting adb.
    @Published var mirrorAlwaysOnTopEnabled: Bool =
        (UserDefaults.standard.object(forKey: AppModel.mirrorAlwaysOnTopDefaultsKey) as? Bool) ?? false {
        didSet {
            UserDefaults.standard.set(
                mirrorAlwaysOnTopEnabled,
                forKey: Self.mirrorAlwaysOnTopDefaultsKey
            )
        }
    }
    /// Scrcpy-style presentation mode: temporarily enables Android's
    /// `show_touches` developer setting and clears touch indicators when stopped.
    @Published private(set) var presentationModeEnabled = false
    private var presentationModeSerial: String?
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
    /// Why the most recent background connect work stopped (typed, timestamped).
    /// Recorded at the silent dead-ends — failed readiness probes, missing
    /// routes, empty QR discovery — and cleared when a mirror becomes ready,
    /// so "the app is doing nothing" is always explainable from Settings.
    @Published private(set) var lastConnectionStall: ConnectionStall?
    /// Most recent saved screenshot or screen recording, for "reveal in Finder".
    // Setter not private: written from AppModel+Capture.swift (pure-move
    // split); treat as private elsewhere.
    @Published var lastCaptureURL: URL?

    /// A dismissible, human-readable problem surfaced in the connection UI.
    struct UserFacingError: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    struct MacUSBDeviceDiagnostic: Equatable, Sendable {
        var hasAnyUSBDevice: Bool
        var hasAndroidLikeDevice: Bool
        var deviceName: String?
    }

    /// Records a typed dead-end for the Connection Health panel. Unlike
    /// `reportError` this never surfaces a banner — background retries are
    /// normal — it only answers "why isn't anything happening" on demand.
    func noteConnectionStall(_ reason: ConnectionStall.Reason, detail: String) {
        lastConnectionStall = ConnectionStall(reason: reason, detail: detail, at: Date())
        Logger.log("Connection stall recorded: \(reason.rawValue) — \(detail)")
    }

    func clearConnectionStall() {
        lastConnectionStall = nil
    }

    /// Health-panel wording for a stall, with a coarse age so the user can
    /// tell a fresh dead-end from a stale one.
    nonisolated static func stallValueText(_ stall: ConnectionStall, now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(stall.at))
        let ageText: String
        switch age {
        case ..<90: ageText = "just now"
        case ..<3600: ageText = "\(Int(age / 60))m ago"
        default: ageText = "\(Int(age / 3600))h ago"
        }
        return "\(stall.reason.title) (\(ageText))"
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

    func selectMirrorProfile(_ profile: MirrorProfile) {
        if selectedMirrorProfile != profile {
            selectedMirrorProfile = profile
        } else {
            UserDefaults.standard.set(profile.rawValue, forKey: Self.mirrorProfileDefaultsKey)
            applyMirrorProfile(profile)
        }
    }

    /// Everything the redacted diagnostics bundle needs, gathered on the
    /// main actor; the blocking zip write runs in the caller's task.
    func diagnosticsBundleContents() -> DiagnosticsBundleService.Contents {
        let logText = (try? String(contentsOf: Logger.logURL, encoding: .utf8))
            ?? "(log unavailable)"
        let snapshot = connectionHealthSnapshot
        var lines: [String] = []
        for item in [
            snapshot.selectedTransport, snapshot.reconnectAttempts,
            snapshot.usbAuthorization, snapshot.wifiReachability,
            snapshot.wifiHandoff, snapshot.adbStatus,
            snapshot.localNetworkPermission
        ] {
            lines.append("\(item.title): \(item.value)")
        }
        if let stall = lastConnectionStall {
            lines.append("Last stall: \(Self.stallValueText(stall))")
            lines.append("Stall detail: \(stall.detail)")
        }
        lines.append("Recommended fix: \(snapshot.recommendedFix)")
        let actionSummary = NotificationActionMetrics.shared.summaryLines
        lines.append("Banner actions: " + (actionSummary.isEmpty ? "none yet" : actionSummary.joined(separator: " · ")))

        let serials = (pairedPhones.flatMap {
            [$0.id, $0.lastAddress, $0.resolvedUSBSerial ?? "", $0.resolvedWiFiAddress ?? "", $0.wifiMACAddress ?? ""]
        } + [selectedDevice.adbSerial ?? ""]).filter { !$0.isEmpty }
        let names = (pairedPhones.map(\.displayName) + [selectedDevice.name]).filter { !$0.isEmpty }
        let info = Bundle.main.infoDictionary
        let version = "Phone Relay \(info?["CFBundleShortVersionString"] ?? "?") (\(info?["CFBundleVersion"] ?? "?"))"

        return DiagnosticsBundleService.Contents(
            logText: logText,
            connectionSummary: lines.joined(separator: "\n"),
            appVersion: version,
            serials: serials,
            deviceNames: names
        )
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
        let detail = mirrorFailureDetail(for: error)
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
            return "The mirroring engine file is missing from the app. Reinstall Phone Relay."
        }
        if lowered.contains("timed out") {
            return "The phone didn’t respond in time. Check the cable or Wi-Fi connection and try again."
        }
        return detail
    }

    static func mirrorFailureDetail(for error: Error) -> String {
        switch error {
        case let hostError as ScrcpyServerHost.HostError: return hostError.description
        case let sessionError as MirrorSession.SessionError: return sessionError.description
        default: return error.localizedDescription
        }
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

    nonisolated static func rememberedWirelessRouteForUSBLaunchFailure(
        message: String,
        failedSerial: String,
        pairedPhones: [PairedPhoneRecord]
    ) -> PairedPhoneRecord? {
        let lowered = message.lowercased()
        guard !isWirelessADBTarget(failedSerial),
              lowered.contains("not found"),
              lowered.contains(failedSerial.lowercased()) else {
            return nil
        }

        return recordsByMostRecent(pairedPhones).first { record in
            recordMatchesSelectedADBSerial(record, selectedSerial: failedSerial)
                && isWirelessRecord(record)
        }
    }

    nonisolated static func rememberedWirelessRouteForMissingMirrorTransport(
        selectedDevice: MirrorDevice,
        pairedPhones: [PairedPhoneRecord]
    ) -> PairedPhoneRecord? {
        recordsByMostRecent(pairedPhones).first { record in
            recordMatchesSelectedDevice(record, selectedDevice: selectedDevice)
                && isWirelessRecord(record)
        }
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

    @Published var discoveredPhones: [DiscoveredPhone] = []
    @Published var pairedPhones: [PairedPhoneRecord] = []
    @Published var qrPairingSession: ADBQRCodePairingSession?
    @Published var isQRCodePairingWaiting = false

#if DEBUG
    func setDiscoveredPhonesForTesting(_ phones: [DiscoveredPhone]) {
        discoveredPhones = phones
    }
#endif

    // Not private: used from AppModel extension files (pure-move split);
    // treat as private elsewhere.
    let adb = ADBController()
    let store: PairedPhoneStore
    lazy var discovery = DiscoveryService(adb: adb)

    weak var connectionWindow: NSWindow?
    // Not private: read from AppModel extension files (pure-move split);
    // treat as private elsewhere.
    var mirrorSession: MirrorSession?
    let mirrorLifecycle = MirrorLifecycleCoordinator()
    private lazy var notificationForwarder = NotificationForwarder(model: self)
    private let notificationAuthorizationRequester: NotificationAuthorizationRequester
    private let notificationSettingsOpener: NotificationSettingsOpener
    private let localNetworkPermissionPrompter: LocalNetworkPermissionPrompter
    let backgroundServicesEnabled: Bool
    var isShuttingDown = false
    private var isRequestingNotificationAuthorization = false
    let connectionCoordinator = ConnectionCoordinator()
    var explicitDeviceSetupRequired = false
    var hasShownLocalNetworkPermissionHint = false
    var hasShownUSBAuthorizationHint = false
    var foregroundLaunchPresentationActive = false
    var foregroundLaunchPresentationStartedAt: Date?
    var isFirstRunOnboardingActive = false
    var postOnboardingMirrorHoldUntil: Date?
    var postOnboardingRevealTask: Task<Void, Never>?
    /// A short confirmation window keeps transient path churn (for example,
    /// switching access points) from tearing down a healthy wireless mirror.
    /// Once confirmed, wireless rows still cached by adb are ignored until the
    /// path returns, so stale transports cannot flip the UI back to Online.
    var networkPathLossConfirmationTask: Task<Void, Never>?
    var isNetworkPathLossConfirmed = false
    // Not private: used from AppModel+Capture.swift (pure-move split).
    var screenRecordingMonitorTask: Task<Void, Never>?
    var screenRecordingRemotePaths: [String] = []
    /// Per-session token in the on-phone segment filenames, so starting a new
    /// recording can never `rm -f` a previous session's not-yet-pulled file.
    var screenRecordingSessionToken = ""
    /// Tracks Android touch indicators that were enabled only for recording.
    var screenRecordingTouchIndicatorSerial: String?
    var screenRecordingTouchIndicatorsEnabled = false
    var screenRecordingTouchEvents: [ScreenRecordingTouchEvent] = []
    var screenRecordingSegmentStarts: [ScreenRecordingSegmentStart] = []
    var lastScreenRecordingTouchMoveAt: Date?
    var lastScreenRecordingScrollAt: Date?
    /// Holds the currently-playing capture cue sound so it isn't deallocated
    /// mid-playback.
    // Not private: used from AppModel+Capture.swift (pure-move split).
    var retainedCaptureSound: NSSound?
    /// True while a mirror session has ended but we're about to retry/reconnect
    /// (e.g. audio→video fallback, or within the backoff window). Keeps the app
    /// from terminating in the windowless gap between sessions.
    @Published var isAwaitingReconnect = false
    @Published var connectionWindowPrefersWirelessDetails = false
    @Published var connectionWindowNavigationResetID = 0
    /// A session that dies sooner than this counts as a "quick" failure.
    nonisolated static let quickMirrorFailureThreshold: TimeInterval = 12

    /// Consecutive device-watcher polls a live mirror's transport must be absent
    /// from `adb devices -l` before the backup detector tears it down. At the 2s
    /// mirroring poll cadence this tolerates a single ~2s blip while still acting
    /// well inside the time a real loss takes to matter (the stream-death detector
    /// handles genuine disconnects on its own). Keep ≥ 2.
    nonisolated static let missingMirrorTransportPollGrace = 2

    /// Whether a mirror session lived long enough to count as a genuinely stable
    /// connection (rather than a load-then-bail). Used to decide when a later
    /// drop should read "Reconnecting" vs the still-establishing "Connecting".
    nonisolated static func isStableMirrorSession(
        lived: TimeInterval,
        threshold: TimeInterval = quickMirrorFailureThreshold
    ) -> Bool {
        lived >= threshold
    }
    nonisolated static let disconnectRecoveryGracePeriod: TimeInterval = 5
    nonisolated static let wirelessHandoffReadinessAttempts = 8
    /// Whole-handoff ceiling. It must absorb the route/MAC reads over USB
    /// (up to ~4s on a busy phone) *and* the 1–4s adbd takes to come back
    /// up after `adb tcpip` — a 5s budget regularly expired mid-restart and
    /// misfiled healthy phones as "blocks adb-over-Wi-Fi".
    nonisolated static let wirelessHandoffMaxDuration: TimeInterval = 10
    nonisolated static let wirelessHandoffRetryDelayNanoseconds: UInt64 = 250_000_000
    nonisolated static let wirelessHandoffConnectTimeout: TimeInterval = 2
    nonisolated static let wirelessHandoffShellTimeout: TimeInterval = 2
    nonisolated static let wirelessHandoffRouteQueryTimeout: TimeInterval = 2
    nonisolated static let wirelessHandoffRoutePrimeTimeout: TimeInterval = 0.5
    nonisolated static let wirelessHandoffTCPIPTimeout: TimeInterval = 3
    nonisolated static let wirelessHandoffPreflightTimeoutNanoseconds: UInt64 = 1_200_000_000
    nonisolated static let wirelessHandoffTCPProbeTimeoutNanoseconds: UInt64 = 450_000_000
    /// The takeover wait runs right after `adb tcpip` dropped the USB mirror,
    /// so it races the phone's adbd restart (1–4s) plus the first TLS-probe /
    /// connect round-trips. Sized so the attempts cap never binds before the
    /// duration does.
    nonisolated static let wirelessHandoffTakeoverAttempts = 16
    nonisolated static let wirelessHandoffTakeoverMaxDuration: TimeInterval = 10
    nonisolated(unsafe) static var adbTCPPortProbe: @Sendable (String) async -> Bool = { address in
        await AppModel.adbTCPPortAcceptsConnection(address)
    }
    nonisolated(unsafe) static var manualADBPortScanner: @Sendable (String) async -> [Int] = { host in
        await AppModel.scanLikelyWirelessDebuggingPorts(host: host)
    }
    nonisolated static let adbDeviceListTimeout: TimeInterval = 2
    /// How long after launch the status indicator keeps reading "Connecting..."
    /// while we hunt for the last-known device before showing the connection
    /// screen again.
    nonisolated static let launchReconnectWindow: TimeInterval = 3

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
            || connectionCoordinator.hasActiveConnectionAttempt {
            return true
        }
        return isWithinLaunchReconnectWindow
    }

    var isUSBConnectionAvailable: Bool {
        latestAuthorizedADBDevices.contains(where: \.isUSB)
    }

    var isLiveWirelessConnectionAvailable: Bool {
        latestAuthorizedADBDevices.contains { !$0.isUSB }
            || discoveredPhones.contains { $0.kind.isConnectable }
    }

    var isWirelessConnectionAvailable: Bool {
        isLiveWirelessConnectionAvailable
            || hasRememberedWiFiHandoffRoute
    }

    var connectionTransportLabel: String? {
        let hasUSB = isUSBConnectionAvailable || isCurrentSelectedUSBTransport
        let hasWiFi = isLiveWirelessConnectionAvailable || isCurrentSelectedWiFiTransport
        if hasUSB, hasWiFi { return "USB + Wi-Fi" }
        if hasWiFi { return "Wi-Fi" }
        if hasUSB { return "USB" }
        return nil
    }

    private var isCurrentSelectedUSBTransport: Bool {
        guard isSelectedDeviceOnline || isMirroring,
              let serial = selectedDevice.adbSerial,
              !serial.isEmpty else { return false }
        return !Self.isWirelessADBTarget(serial)
            || selectedDevice.network.localizedCaseInsensitiveContains("usb")
    }

    private var isCurrentSelectedWiFiTransport: Bool {
        guard isSelectedDeviceOnline || isMirroring,
              let serial = selectedDevice.adbSerial,
              !serial.isEmpty else {
            return selectedDevice.network.localizedCaseInsensitiveContains("wi-fi")
                || selectedDevice.network.localizedCaseInsensitiveContains("wireless")
        }
        return Self.isWirelessADBTarget(serial)
            || selectedDevice.network.localizedCaseInsensitiveContains("wi-fi")
            || selectedDevice.network.localizedCaseInsensitiveContains("wireless")
    }

    var hasSavedWirelessConnection: Bool {
        !Self.recordsByMostRecent(pairedPhones).filter(Self.isWirelessRecord).isEmpty
    }

    var hasVisibleSavedWirelessConnection: Bool {
        hasSavedWirelessConnection && isWirelessConnectionAvailable
    }

    var isFirstTimeUSBSetup: Bool {
        pairedPhones.isEmpty
    }

    /// Status word for the device pill, derived from the same unified state.
    var connectionStatusText: String {
        Self.devicePillStatusText(
            isOnline: isSelectedDeviceOnline,
            hasSavedDevice: !pairedPhones.isEmpty,
            isActivelyConnecting: isActivelyConnecting
        )
    }

    var shouldShowConnectionLoadingSurface: Bool {
        mirrorLaunchTask != nil
            || (!isMirroring
                && (isRecoveringConnection
                    || isAwaitingReconnect))
    }

    var connectionDeviceLabel: String {
        if selectedDevice.adbSerial == nil,
           !isSelectedDeviceOnline,
           let liveDevice = latestAuthorizedADBDevices.first {
            return Self.connectionDeviceLabel(
                name: liveDevice.model,
                id: liveDevice.serial,
                serial: liveDevice.serial,
                network: liveDevice.isUSB ? "USB debugging" : "Wi-Fi"
            )
        }

        return Self.connectionDeviceLabel(
            name: selectedDevice.name,
            id: selectedDevice.id,
            serial: selectedDevice.adbSerial,
            network: selectedDevice.network
        )
    }

    var mirrorWindowDeviceTitle: String {
        Self.mirrorWindowDeviceTitle(name: selectedDevice.name)
    }

    var connectionWindowTitle: String {
        Self.connectionWindowTitle(
            name: selectedDevice.name,
            isOnline: isSelectedDeviceOnline,
            isMirroring: isMirroring
        )
    }

    var connectionChoiceTitle: String {
        let deviceLabel = connectionDeviceLabel
        let isDeviceConnected = isSelectedDeviceOnline
            || isMirroring
            || !latestAuthorizedADBDevices.isEmpty
        return Self.connectionChoiceTitle(
            deviceLabel: deviceLabel,
            state: connectionPillState,
            isDeviceConnected: isDeviceConnected,
            isFirstTimeUSBSetup: isFirstTimeUSBSetup,
            isWiFiConnectionAvailable: isWirelessConnectionAvailable
        )
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
            activeErrorMessage: activeError?.message,
            backgroundWiFiHandoffEnabled: backgroundWiFiHandoffEnabled,
            isPreparingWiFiHandoff: connectionCoordinator.isPreparingWiFiHandoff,
            lastStall: lastConnectionStall
        )
    }

    var hasRememberedWiFiHandoffRoute: Bool {
        Self.rememberedConnectablePhone(records: pairedPhones, in: discoveredPhones) != nil
    }

    /// Whether we're still inside the brief post-launch window during which the
    /// UI should read "Connecting" even before a device has been seen.
    private var isWithinLaunchReconnectWindow: Bool {
        guard !isSelectedDeviceOnline, !isMirroring, !pairedPhones.isEmpty,
              let deadline = launchReconnectDeadline else { return false }
        return Date() < deadline
    }

    init(
        startBackgroundServices: Bool = AppModel.defaultStartBackgroundServices,
        pairedPhones previewPairedPhones: [PairedPhoneRecord]? = nil,
        store: PairedPhoneStore = PairedPhoneStore(),
        notificationAuthorizationRequester: @escaping NotificationAuthorizationRequester = AppModel.requestNotificationAuthorization,
        notificationSettingsOpener: @escaping NotificationSettingsOpener = AppModel.openSystemNotificationSettings,
        localNetworkPermissionPrompter: @escaping LocalNetworkPermissionPrompter = AppModel.promptForLocalNetworkPermission
    ) {
        self.store = store
        self.notificationAuthorizationRequester = notificationAuthorizationRequester
        self.notificationSettingsOpener = notificationSettingsOpener
        self.localNetworkPermissionPrompter = localNetworkPermissionPrompter
        self.backgroundServicesEnabled = startBackgroundServices
        DiagnosticsService.shared.configure()
        DiagnosticsService.shared.capture(.appLaunched)
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

        guard backgroundServicesEnabled else { return }

        startDiscovery()
        startDeviceWatcher()
        startSystemEventReconnectTriggers()
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
        networkPathLossConfirmationTask?.cancel()
        screenRecordingMonitorTask?.cancel()
    }

    func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        restorePresentationModeIfNeeded(async: false)
        restoreRecordingTouchIndicatorsIfNeeded(async: false)
        stopMirroring(suspendAutoConnect: false)
        discovery.stop()
        notificationForwarder.stop()
        stopQRCodePairingSession()
        stopSystemEventReconnectTriggers()
        connectionCoordinator.reset()
        screenRecordingMonitorTask?.cancel()
        screenRecordingMonitorTask = nil
        mirrorLifecycle.reset()
        isAutoConnecting = false
        isScanning = false
        isPairing = false
        isManualADBTargetConnecting = false
        isRecoveringConnection = false
        isAwaitingReconnect = false
    }

    // MARK: - Resize

    func resizeMirror(scale: CGFloat) {
        mirrorSession?.scaleWindow(by: scale)
    }

    func forwardKeyEventToMirrorSession(_ event: NSEvent) -> Bool {
        guard Self.shouldForwardKeyEventToMirrorSession(
            event,
            keyboardInputEnabled: keyboardInputEnabled,
            hasMirrorSession: mirrorSession != nil,
            appIsActive: NSApp.isActive,
            mirrorAcceptsKeyboardInput: mirrorSession?.acceptsKeyboardInput == true
        ) else {
            return false
        }
        mirrorSession?.forwardKeyEvent(event)
        return true
    }

    static func shouldForwardKeyEventToMirrorSession(
        _ event: NSEvent,
        keyboardInputEnabled: Bool,
        hasMirrorSession: Bool,
        appIsActive: Bool,
        mirrorAcceptsKeyboardInput: Bool
    ) -> Bool {
        if MirrorSession.isMirrorCommandShortcut(event) {
            return hasMirrorSession && appIsActive
        }

        guard keyboardInputEnabled,
              hasMirrorSession,
              appIsActive,
              mirrorAcceptsKeyboardInput else {
            return false
        }

        return MirrorSession.androidKey(for: event) != nil
            || MirrorSession.androidCommandShortcutKey(for: event) != nil
    }

    static func shouldConsumeForwardedKeyEvent(_ event: NSEvent) -> Bool {
        !MirrorSession.isVolumeKeyEvent(event)
    }

    func centerMirrorWindow() {
        mirrorSession?.centerWindow()
    }

    enum SavedConnectionTransport {
        case automatic
        case usb
        case wifi
    }

    func connect(record: PairedPhoneRecord, transport: SavedConnectionTransport = .automatic) {
        guard !isMirroring, !isPairing else { return }
        resumeDiscoveryAfterManualConnect()
        resumeAutoConnect(for: record)
        switch transport {
        case .automatic:
            break
        case .usb:
            connectViaSavedUSB(record: record)
            return
        case .wifi:
            connectViaSavedWiFi(record: record)
            return
        }

        if let wirelessDevice = Self.liveWirelessAuthorizedDevice(
            for: record,
            in: latestAuthorizedADBDevices
        ) {
            stopQRCodePairingSession()
            select(device: wirelessDevice, for: record)
            startMirroring(manual: true)
            return
        }

        if liveUSBDevice(for: record) != nil {
            connectViaSavedUSB(record: record)
            return
        }

        if let phone = Self.rememberedConnectablePhone(for: record, in: discoveredPhones) {
            stopQRCodePairingSession()
            connectAndMirror(phone: phone)
            return
        }
        if Self.isWirelessRecord(record) {
            // Wireless records get the full, restart-and-retry reconnect path so a
            // deliberate "Connect" recovers a sleeping phone instead of failing
            // silently on the first stale `adb connect`.
            reconnectOverWiFi(preferredRecord: record, restrictToPreferredRecord: true)
            return
        }
        select(record: record)
        stopQRCodePairingSession()
        startMirroring(manual: true)
    }

    private func connectViaSavedUSB(record: PairedPhoneRecord) {
        guard let usbSerial = record.resolvedUSBSerial else {
            reportError("USB route unavailable", "Connect the phone with USB once so Phone Relay can save its USB serial.")
            return
        }

        selectedDevice = MirrorDevice(
            id: record.id,
            name: record.displayName,
            model: "Android",
            battery: selectedDevice.battery,
            isCharging: selectedDevice.isCharging,
            network: "USB debugging",
            lastSeen: record.lastConnected,
            states: [.wirelessDebuggingRequired, .companionConnected],
            adbSerial: usbSerial
        )
        isSelectedDeviceOnline = false
        stopQRCodePairingSession()
        isPairing = true
        connectionCoordinator.usbConnectTask?.cancel()

        let adb = self.adb
        let generation = mirrorStartGeneration
        connectionCoordinator.usbConnectTask = Task { [weak self] in
            let output = await Task.detached {
                adb.run(["devices", "-l"], timeout: Self.adbDeviceListTimeout)
            }.value
            guard let self, !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
            let authorizedDevices = Self.authorizedADBDevices(in: output)
            self.recordADBHealth(output, authorizedDevices: authorizedDevices)
            guard let usbDevice = authorizedDevices.first(where: { $0.isUSB && $0.serial == usbSerial }) else {
                self.isPairing = false
                self.connectionCoordinator.usbConnectTask = nil
                self.reportError("USB phone not found", "Connect \(record.displayName) with USB and make sure USB debugging is authorized.")
                return
            }

            guard let readyUSBDevice = await self.readyUSBDeviceForMirroring(usbDevice) else {
                self.isPairing = false
                self.connectionCoordinator.usbConnectTask = nil
                self.reportError("USB phone not ready", "Phone Relay found \(record.displayName), but adb could not talk to it. Replug the cable and approve USB debugging on the phone.")
                return
            }

            let wifiAddress = await self.prefillWirelessIPFromUSBDevice(readyUSBDevice)
                ?? record.resolvedWiFiAddress
            self.pinManualUSBTransport(serial: readyUSBDevice.serial)
            self.connectionCoordinator.usbConnectTask = nil
            self.startMirroringOverUSB(
                readyUSBDevice,
                manual: true,
                wifiAddress: wifiAddress,
                prepareWirelessHandoff: false
            )
        }
    }

    private func connectViaSavedWiFi(record: PairedPhoneRecord) {
        manualUSBPinnedSerials.removeAll()
        guard let wifiAddress = record.resolvedWiFiAddress else {
            reportError("Wi-Fi route unavailable", "Connect the phone with USB once while it is on Wi-Fi so Phone Relay can save its IP address.")
            return
        }
        manualWirelessConnectDisallowsUSBFallback = true

        if let wirelessDevice = Self.liveWirelessAuthorizedDevice(
            for: record,
            in: latestAuthorizedADBDevices
        ) {
            stopQRCodePairingSession()
            select(device: wirelessDevice, for: record)
            startMirroring(manual: true)
            return
        }

        if let usbDevice = liveUSBDevice(for: record) {
            connectSavedWiFiViaUSB(record: record, usbDevice: usbDevice)
            return
        }

        var wirelessRecord = record
        wirelessRecord.lastAddress = wifiAddress
        wirelessRecord.wifiAddress = wifiAddress
        reconnectOverWiFi(preferredRecord: wirelessRecord, restrictToPreferredRecord: true)
    }

    private func liveUSBDevice(for record: PairedPhoneRecord) -> AuthorizedADBDevice? {
        Self.liveUSBAuthorizedDevice(for: record, in: latestAuthorizedADBDevices)
    }

    private func connectSavedWiFiViaUSB(record: PairedPhoneRecord, usbDevice: AuthorizedADBDevice) {
        stopQRCodePairingSession()
        connectionCoordinator.wirelessStartTask?.cancel()
        connectionCoordinator.reconnectTask?.cancel()
        isPairing = true

        let adb = self.adb
        let generation = mirrorStartGeneration
        connectionCoordinator.wirelessStartTask = Task { [weak self] in
            let connectedAddress = await Self.connectToUSBDeviceOverCurrentWiFi(
                adb: adb,
                usbDevice: usbDevice,
                readinessAttempts: Self.wirelessHandoffReadinessAttempts,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                },
                maximumDuration: Self.wirelessHandoffTakeoverMaxDuration
            )

            guard let self, !Task.isCancelled, self.mirrorStartGeneration == generation else { return }
            self.connectionCoordinator.wirelessStartTask = nil
            self.isPairing = false

            guard let connectedAddress else {
                self.reportError(
                    "Wi-Fi route not ready",
                    "Phone Relay found \(record.resolvedWiFiAddress ?? "the saved IP"), but could not connect on port \(Self.legacyADBWirelessPort). Keep USB connected and try Wi-Fi again."
                )
                return
            }

            let deviceName = await Self.connectedDeviceName(
                adb: adb,
                serial: connectedAddress,
                fallback: record.displayName
            )
            self.touchPairedPhone(
                id: record.id,
                displayName: deviceName,
                address: connectedAddress,
                usbSerial: usbDevice.serial,
                wifiAddress: connectedAddress
            )
            self.selectedDevice = MirrorDevice(
                id: record.id,
                name: deviceName,
                model: usbDevice.product.isEmpty ? "Android" : usbDevice.product,
                battery: self.selectedDevice.battery,
                isCharging: self.selectedDevice.isCharging,
                network: "Wi-Fi",
                lastSeen: .now,
                states: [.mirroringReady, .companionConnected],
                adbSerial: connectedAddress
            )
            self.isSelectedDeviceOnline = true
            self.startMirroring(manual: true)
        }
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
    func reconnectOverWiFi(
        preferredRecord: PairedPhoneRecord? = nil,
        inlineUntilConnected: Bool = false,
        restrictToPreferredRecord: Bool = false,
        allowAddressRecovery: Bool = true,
        unavailableTitle: String = "Phone not reachable over Wi-Fi",
        unavailableMessage: String = "Make sure USB debugging is enabled and authorized, the phone is awake, and both devices are on the same Wi-Fi, or connect USB once to refresh the Wi-Fi path."
    ) {
        guard !isMirroring, !isPairing else { return }
        manualUSBPinnedSerials.removeAll()
        manualWirelessConnectDisallowsUSBFallback = true
        resumeDiscoveryAfterManualConnect()

        let ordered = Self.recordsByMostRecent(pairedPhones).filter(Self.isWirelessRecord)
        let wirelessRecords: [PairedPhoneRecord]
        if let preferredRecord, Self.isWirelessRecord(preferredRecord) {
            wirelessRecords = restrictToPreferredRecord
                ? [preferredRecord]
                : [preferredRecord] + ordered.filter { $0.id != preferredRecord.id }
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
        connectionCoordinator.reconnectTask?.cancel()
        stopQRCodePairingSession()
        select(record: leadRecord)               // names the "Reconnecting to…" overlay
        isPairing = true
        if inlineUntilConnected {
            isManualADBTargetConnecting = true
        } else {
            isRecoveringConnection = true
            isAwaitingReconnect = true
        }
        reconnectAttemptCount = 0

        let adb = self.adb
        let generation = mirrorStartGeneration
        connectionCoordinator.reconnectTask = Task { [weak self] in
            await adb.ensureServerStarted()

            let deadline = Date().addingTimeInterval(Self.manualReconnectWindow)
            var sawPairingServiceOnly = false
            var round = 0
            var attemptedWiFiAddressRecovery = false

            while Date() < deadline {
                if Task.isCancelled { return }
                guard let self, self.mirrorStartGeneration == generation, !self.isMirroring else { return }

                // Saved wireless routes, including the stable :5555 fallback.
                for record in wirelessRecords {
                    if Task.isCancelled { return }
                    guard let savedAddress = record.resolvedWiFiAddress else { continue }
                    self.reconnectAttemptCount += 1
                    let result = await Self.connectToRememberedWirelessReadiness(
                        adb: adb,
                        savedAddress: savedAddress,
                        readinessAttempts: 1,
                        preflightLocalNetworkAccess: { address in
                            await Self.preflightLocalNetworkAccess(address: address)
                        }
                    )
                    if let connectedAddress = result.connectedAddress {
                        await self.finishManualReconnect(
                            record: record,
                            connectedAddress: connectedAddress,
                            generation: generation,
                            startedInline: inlineUntilConnected
                        )
                        return
                    }
                    if result.sawNoRouteToHost {
                        self.presentLocalNetworkPermissionHint()
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
                        },
                        tcpPortProbe: { address in
                            await Self.adbTCPPortProbe(address)
                        }
                    ) {
                        await self.finishManualReconnect(
                            record: record,
                            connectedAddress: phone.address,
                            generation: generation,
                            startedInline: inlineUntilConnected
                        )
                        return
                    }
                }

                // The saved address is dead and mDNS is silent — the case the
                // auto-connect path handles but this button historically could
                // not: a plain `tcpip 5555` phone whose DHCP lease moved. Hunt
                // for its current IP by MAC once the cheap rounds have had a pass.
                // A button press is a deliberate action, so it bypasses the
                // per-phone recovery cooldown that throttles background polling.
                if allowAddressRecovery, !attemptedWiFiAddressRecovery, round >= 1 {
                    attemptedWiFiAddressRecovery = true
                    for record in wirelessRecords {
                        if Task.isCancelled { return }
                        // Each sweep can take a couple of seconds, so don't keep
                        // hunting for additional absent phones once the window is
                        // spent — the lead (most-recent) record gets first crack.
                        guard Date() < deadline else { break }
                        guard let recovered = await self.recoverChangedWiFiAddress(
                            for: record,
                            ignoreCooldown: true
                        ) else { continue }
                        await self.finishManualReconnect(
                            record: record,
                            connectedAddress: recovered,
                            generation: generation,
                            startedInline: inlineUntilConnected
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
            self.failManualReconnect(
                sawPairingServiceOnly: sawPairingServiceOnly,
                unavailableTitle: unavailableTitle,
                unavailableMessage: unavailableMessage
            )
        }
    }

    private func finishManualReconnect(
        record: PairedPhoneRecord,
        connectedAddress: String,
        generation: Int,
        startedInline: Bool = false
    ) async {
        let adb = self.adb

        // Promote a random Wireless-debugging TLS port to a plain `tcpip 5555`
        // listener so the next reconnect works without the toggle (no-op on :5555).
        var address = connectedAddress
        if Self.shouldPromoteToLegacyTCPIP(connectedAddress: connectedAddress) {
            switch await Self.promoteToLegacyTCPIP(
                adb: adb,
                sourceSerial: connectedAddress,
                preflightLocalNetworkAccess: { address in
                    await Self.preflightLocalNetworkAccess(address: address)
                }
            ) {
            case .promoted(let promoted):
                address = promoted
            case .unavailable:
                break
            case .transportLost(let legacyAddress):
                // adbd restarted mid-promotion, so the TLS transport we just
                // verified is gone. Retry the 5555 listener before falling
                // back to the original address (whose mirror launch would
                // otherwise fail and re-enter recovery).
                let retry = await Self.connectToRememberedWirelessReadiness(
                    adb: adb,
                    savedAddress: legacyAddress,
                    readinessAttempts: 2,
                    preflightLocalNetworkAccess: { address in
                        await Self.preflightLocalNetworkAccess(address: address)
                    }
                )
                if let recoveredAddress = retry.connectedAddress {
                    address = recoveredAddress
                }
            }
        }
        let deviceName = await Self.connectedDeviceName(adb: adb, serial: address, fallback: record.displayName)

        guard !Task.isCancelled, mirrorStartGeneration == generation, !isMirroring else { return }
        connectionCoordinator.reconnectTask = nil
        isPairing = false
        reconnectAttemptCount = 0
        select(record: record)
        selectedDevice.adbSerial = address
        selectedDevice.name = deviceName
        touchPairedPhone(
            id: record.id,
            displayName: deviceName,
            address: address,
            usbSerial: record.resolvedUSBSerial,
            wifiAddress: address
        )
        stopQRCodePairingSession()
        if startedInline {
            isManualADBTargetConnecting = false
            isRecoveringConnection = true
            isAwaitingReconnect = false
        }
        startMirroring(manual: true)
    }

    private func failManualReconnect(
        sawPairingServiceOnly: Bool,
        unavailableTitle: String = "Phone not reachable over Wi-Fi",
        unavailableMessage: String = "Make sure USB debugging is enabled and authorized, the phone is awake, and both devices are on the same Wi-Fi, or connect USB once to refresh the Wi-Fi path."
    ) {
        connectionCoordinator.reconnectTask = nil
        isPairing = false
        isManualADBTargetConnecting = false
        isRecoveringConnection = false
        isAwaitingReconnect = false
        manualWirelessConnectDisallowsUSBFallback = false
        if sawPairingServiceOnly {
            reportError(
                "Pair this phone again",
                "Wireless debugging is visible but this Mac isn’t connected to it. Tap Pair with QR code, or connect USB once."
            )
        } else {
            reportError(unavailableTitle, unavailableMessage)
        }
        showConnectionWindow(startsQRCodePairing: true)
    }

    func forgetPairedPhone(id: PairedPhoneRecord.ID) {
        sessionAutoConnectSuspendedRecordIDs.remove(id)
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
        connectionCoordinator.usbConnectTask?.cancel()
        connectionCoordinator.usbConnectTask = nil
        connectionCoordinator.usbWiFiHandoffTask?.cancel()
        connectionCoordinator.usbWiFiHandoffTask = nil
        cancelWirelessReconnectWork()
        stopQRCodePairingSession()
        pairedPhones = []
        sessionAutoConnectSuspendedRecordIDs.removeAll()
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
        lastUSBWiFiAddressPrefillSerial = nil
        wirelessPinnedUSBSerials.removeAll()
        launchReconnectDeadline = nil
        requireExplicitDeviceSetup()
        showWirelessConnectionDetailsFromSettings()
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
        for record in records {
            if let wifiAddress = record.resolvedWiFiAddress {
                targets.insert(wifiAddress)
            }
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

    func requireExplicitDeviceSetup() {
        explicitDeviceSetupRequired = true
        Self.setExplicitDeviceSetupRequiredPreference(true)
    }

    func clearExplicitDeviceSetupRequirement() {
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

    func togglePresentationMode() {
        if presentationModeEnabled {
            restorePresentationModeIfNeeded()
        } else {
            enablePresentationMode()
        }
    }

    func toggleMirrorAlwaysOnTop() {
        mirrorAlwaysOnTopEnabled.toggle()
    }

    private func enablePresentationMode() {
        guard !presentationModeEnabled,
              let serial = selectedDevice.adbSerial,
              !serial.isEmpty
        else { return }

        presentationModeEnabled = true
        presentationModeSerial = serial
        let adb = self.adb
        Task { [weak self, adb, serial] in
            guard let self, self.presentationModeEnabled, self.presentationModeSerial == serial else { return }
            await Task.detached(priority: .utility) {
                _ = adb.run(
                    ["-s", serial, "shell", "settings", "put", "system", "show_touches", "1"],
                    timeout: 2
                )
                _ = adb.run(
                    ["-s", serial, "shell", "settings", "put", "system", "pointer_location", "0"],
                    timeout: 2
                )
            }.value
            Logger.log("Presentation mode enabled show_touches for \(serial)")
        }
    }

    func restorePresentationModeIfNeeded(async: Bool = true) {
        guard presentationModeEnabled else { return }
        let serial = presentationModeSerial ?? selectedDevice.adbSerial
        presentationModeEnabled = false
        presentationModeSerial = nil

        // Ownership arbitration mirror of restoreRecordingTouchIndicators:
        // while a recording still owns the touch indicators, leave them on —
        // its cleanup writes the disable when the recording ends.
        guard !screenRecordingTouchIndicatorsEnabled else {
            Logger.log("Presentation Mode released touch indicators; active recording still owns them")
            return
        }

        guard let serial, !serial.isEmpty else { return }
        let adb = self.adb
        let restore = {
            // Stopping Presentation Mode should always remove visible Android
            // touch indicators, regardless of the phone's prior developer setting.
            _ = adb.run(
                ["-s", serial, "shell", "settings", "put", "system", "show_touches", "0"],
                timeout: 2
            )
            _ = adb.run(
                ["-s", serial, "shell", "settings", "put", "system", "pointer_location", "0"],
                timeout: 2
            )
            Logger.log("Presentation mode disabled touch indicators for \(serial)")
        }
        if async {
            Task.detached(priority: .utility) {
                restore()
            }
        } else {
            restore()
        }
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

    // Not private: used from AppModel+Capture.swift (pure-move split).
    nonisolated static func adbDeviceArguments(serial: String?) -> [String] {
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

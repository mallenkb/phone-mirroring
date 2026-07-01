import Foundation
import PostHog

enum DiagnosticsEvent: String, CaseIterable {
    case appLaunched = "app_launched"
    case appUpdated = "app_updated"
    case appCrashed = "app_crashed"
    case settingsDiagnosticsEnabled = "settings_diagnostics_enabled"
    case settingsDiagnosticsDisabled = "settings_diagnostics_disabled"

    case setupStarted = "setup_started"
    case setupSucceeded = "setup_succeeded"
    case setupFailed = "setup_failed"
    case permissionsCheckStarted = "permissions_check_started"
    case permissionsCheckSucceeded = "permissions_check_succeeded"
    case permissionsCheckFailed = "permissions_check_failed"
    case adbCheckStarted = "adb_check_started"
    case adbCheckSucceeded = "adb_check_succeeded"
    case adbCheckFailed = "adb_check_failed"

    case usbDeviceSeen = "usb_device_seen"
    case usbConnectStarted = "usb_connect_started"
    case usbConnectSucceeded = "usb_connect_succeeded"
    case usbConnectFailed = "usb_connect_failed"
    case deviceAuthorizationSeen = "device_authorization_seen"
    case deviceAuthorizationSucceeded = "device_authorization_succeeded"
    case deviceAuthorizationFailed = "device_authorization_failed"

    case wifiHandoffStarted = "wifi_handoff_started"
    case wifiHandoffSucceeded = "wifi_handoff_succeeded"
    case wifiHandoffFailed = "wifi_handoff_failed"
    case wifiRetryStarted = "wifi_retry_started"
    case wifiRetrySucceeded = "wifi_retry_succeeded"
    case wifiRetryFailed = "wifi_retry_failed"

    case usbRecoveryStarted = "usb_recovery_started"
    case usbRecoverySucceeded = "usb_recovery_succeeded"
    case usbRecoveryFailed = "usb_recovery_failed"

    case mirrorStarted = "mirror_started"
    case mirrorFailed = "mirror_failed"
    case mirrorSessionEnded = "mirror_session_ended"

    case recordingStarted = "recording_started"
    case recordingStopped = "recording_stopped"
    case recordingSaved = "recording_saved"
    case recordingDiscarded = "recording_discarded"
    case recordingFailed = "recording_failed"

    case helperProcessStarted = "helper_process_started"
    case helperProcessFailed = "helper_process_failed"
    case backgroundTaskFailed = "background_task_failed"
    case updateCheckFailed = "update_check_failed"
}

enum DiagnosticsFailureReason: String {
    case noRouteToHost = "no_route_to_host"
    case adbOffline = "adb_offline"
    case unauthorized
    case timeout
    case missingTool = "missing_tool"
    case notFound = "not_found"
    case cancelled
    case unknown
}

struct DiagnosticsConnectionAttempt {
    let id: String
    let startedAt: Date
    let attemptNumber: Int
    let isRetry: Bool

    init(id: String = UUID().uuidString, startedAt: Date = Date(), attemptNumber: Int, isRetry: Bool) {
        self.id = id
        self.startedAt = startedAt
        self.attemptNumber = attemptNumber
        self.isRetry = isRetry
    }
}

final class DiagnosticsService {
    static let shared = DiagnosticsService()

    static let diagnosticsEnabledDefaultsKey = "Diagnostics.shareAnonymousDiagnostics"
    static let anonymousSessionIDDefaultsKey = "Diagnostics.currentSessionID"
    static let projectToken = "phc_3LAzuLcLCCmUmoqad8RgHJOEKF7r1C9ZYV5cg9ciDLa"
    static let host = "https://us.i.posthog.com"

    private static let allowedPropertyKeys: Set<String> = [
        "app_version",
        "build_number",
        "macos_version",
        "arch",
        "transport",
        "failure_reason",
        "duration_ms",
        "attempt_number",
        "is_retry",
        "connection_attempt_id",
        "session_id",
        "recovery_method",
        "permission_type",
        "adb_state"
    ]

    private var hasConfiguredSDK = false
    private let defaults: UserDefaults
    private let sessionID: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sessionID = UUID().uuidString
        defaults.set(sessionID, forKey: Self.anonymousSessionIDDefaultsKey)
    }

    var isEnabled: Bool {
        defaults.bool(forKey: Self.diagnosticsEnabledDefaultsKey)
    }

    func configure() {
        guard !hasConfiguredSDK else {
            applyOptOutState()
            return
        }

        let config = PostHogConfig(projectToken: Self.projectToken, host: Self.host)
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.enableSwizzling = false
        config.setDefaultPersonProperties = false
        config.personProfiles = .identifiedOnly
        config.optOut = !isEnabled
        PostHogSDK.shared.setup(config)
        hasConfiguredSDK = true
        applyOptOutState()
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabled
        if !enabled, wasEnabled {
            PostHogSDK.shared.capture(
                DiagnosticsEvent.settingsDiagnosticsDisabled.rawValue,
                properties: baseProperties()
            )
            PostHogSDK.shared.flush()
        }

        defaults.set(enabled, forKey: Self.diagnosticsEnabledDefaultsKey)
        configure()
        applyOptOutState()

        if enabled, !wasEnabled {
            capture(.settingsDiagnosticsEnabled)
        }
    }

    func capture(_ event: DiagnosticsEvent, properties: [String: Any] = [:]) {
        configure()
        guard isEnabled else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: sanitizedProperties(properties))
    }

    func propertiesForAttempt(
        _ attempt: DiagnosticsConnectionAttempt,
        transport: String,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var properties = extra
        properties["connection_attempt_id"] = attempt.id
        properties["attempt_number"] = attempt.attemptNumber
        properties["is_retry"] = attempt.isRetry
        properties["transport"] = transport
        return properties
    }

    func propertiesForCompletedAttempt(
        _ attempt: DiagnosticsConnectionAttempt,
        transport: String,
        extra: [String: Any] = [:],
        endedAt: Date = Date()
    ) -> [String: Any] {
        var properties = propertiesForAttempt(attempt, transport: transport, extra: extra)
        properties["duration_ms"] = max(0, Int(endedAt.timeIntervalSince(attempt.startedAt) * 1000))
        return properties
    }

    static func failureReason(for message: String) -> DiagnosticsFailureReason {
        let lowered = message.lowercased()
        if lowered.contains("no route to host") { return .noRouteToHost }
        if lowered.contains("unauthorized") { return .unauthorized }
        if lowered.contains("offline") { return .adbOffline }
        if lowered.contains("timed out") || lowered.contains("timeout") { return .timeout }
        if lowered.contains("not found") || lowered.contains("no devices") { return .notFound }
        if lowered.contains("adb is not on path") || lowered.contains("adb is missing") { return .missingTool }
        return .unknown
    }

    static func transportValue(serial: String?, network: String) -> String {
        let lowered = network.lowercased()
        if lowered.contains("wi-fi") || lowered.contains("wifi") || serial?.contains(":") == true {
            return "wifi"
        }
        if lowered.contains("usb") || serial != nil {
            return "usb"
        }
        return "unknown"
    }

    private func applyOptOutState() {
        if isEnabled {
            PostHogSDK.shared.optIn()
        } else {
            PostHogSDK.shared.optOut()
        }
    }

    private func sanitizedProperties(_ properties: [String: Any]) -> [String: Any] {
        var sanitized = baseProperties()
        for (key, value) in properties where Self.allowedPropertyKeys.contains(key) {
            sanitized[key] = value
        }
        return sanitized
    }

    private func baseProperties() -> [String: Any] {
        [
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build_number": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "macos_version": Self.coarseOSVersion(),
            "arch": Self.architecture(),
            "session_id": sessionID
        ]
    }

    private static func coarseOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).x"
    }

    private static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

import AppKit
import Foundation

/// Owns non-observable mirror lifecycle state. AppModel remains the SwiftUI
/// facade, while launch cancellation, restart debouncing, crash-loop backoff,
/// and transport-loss debounce share one explicit lifetime.
@MainActor
final class MirrorLifecycleCoordinator {
    var lastWindowFrame: NSRect?
    var launchTask: Task<Void, Never>?
    var settingsRestartTask: Task<Void, Never>?
    var suppressSettingsRestart = false
    var suppressAudioForReconnect = false
    var lastStartAt: Date?
    var consecutiveQuickFailures = 0
    var autoBackoffUntil: Date?
    var missingTransportPollMisses = 0
    var startGeneration = 0
    var hasCompletedSuccessfulConnection = false

    var isLaunching: Bool { launchTask != nil }
    var isInBackoff: Bool {
        guard let autoBackoffUntil else { return false }
        return Date() < autoBackoffUntil
    }

    deinit {
        launchTask?.cancel()
        settingsRestartTask?.cancel()
    }

    func cancelLaunch() {
        launchTask?.cancel()
        launchTask = nil
    }

    func cancelSettingsRestart() {
        settingsRestartTask?.cancel()
        settingsRestartTask = nil
    }

    func reset() {
        cancelLaunch()
        cancelSettingsRestart()
        lastWindowFrame = nil
        suppressSettingsRestart = false
        suppressAudioForReconnect = false
        lastStartAt = nil
        consecutiveQuickFailures = 0
        autoBackoffUntil = nil
        missingTransportPollMisses = 0
        startGeneration &+= 1
        hasCompletedSuccessfulConnection = false
    }
}

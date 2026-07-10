import AppKit
import Foundation

/// AppModel-facing names for state owned by MirrorLifecycleCoordinator.
@MainActor
extension AppModel {
    var lastMirrorWindowFrame: NSRect? {
        get { mirrorLifecycle.lastWindowFrame }
        set { mirrorLifecycle.lastWindowFrame = newValue }
    }

    var mirrorLaunchTask: Task<Void, Never>? {
        get { mirrorLifecycle.launchTask }
        set { mirrorLifecycle.launchTask = newValue }
    }

    var mirrorSettingsRestartTask: Task<Void, Never>? {
        get { mirrorLifecycle.settingsRestartTask }
        set { mirrorLifecycle.settingsRestartTask = newValue }
    }

    var suppressMirrorSettingsRestart: Bool {
        get { mirrorLifecycle.suppressSettingsRestart }
        set { mirrorLifecycle.suppressSettingsRestart = newValue }
    }

    var suppressMirrorAudioForReconnect: Bool {
        get { mirrorLifecycle.suppressAudioForReconnect }
        set { mirrorLifecycle.suppressAudioForReconnect = newValue }
    }

    var lastMirrorStartAt: Date? {
        get { mirrorLifecycle.lastStartAt }
        set { mirrorLifecycle.lastStartAt = newValue }
    }

    var consecutiveQuickMirrorFailures: Int {
        get { mirrorLifecycle.consecutiveQuickFailures }
        set { mirrorLifecycle.consecutiveQuickFailures = newValue }
    }

    var autoMirrorBackoffUntil: Date? {
        get { mirrorLifecycle.autoBackoffUntil }
        set { mirrorLifecycle.autoBackoffUntil = newValue }
    }

    var missingMirrorTransportPollMisses: Int {
        get { mirrorLifecycle.missingTransportPollMisses }
        set { mirrorLifecycle.missingTransportPollMisses = newValue }
    }

    var mirrorStartGeneration: Int {
        get { mirrorLifecycle.startGeneration }
        set { mirrorLifecycle.startGeneration = newValue }
    }

    var hasCompletedSuccessfulMirrorConnection: Bool {
        get { mirrorLifecycle.hasCompletedSuccessfulConnection }
        set { mirrorLifecycle.hasCompletedSuccessfulConnection = newValue }
    }
}

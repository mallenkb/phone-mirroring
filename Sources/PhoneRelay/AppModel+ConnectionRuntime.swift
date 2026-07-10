import AppKit
import Foundation
import Network

/// Compatibility surface between the observable AppModel facade and the
/// connection subsystem. Storage lives in ConnectionCoordinator; keeping these
/// names on AppModel lets the orchestration code stay readable while the state
/// owner remains explicit and independently testable.
@MainActor
extension AppModel {
    typealias USBWiFiHandoffCandidate = ConnectionCoordinator.USBWiFiHandoffCandidate

    var isAutoReconnectSuppressedForManualDisconnect: Bool {
        get { connectionCoordinator.isAutoReconnectSuppressedForManualDisconnect }
        set { connectionCoordinator.isAutoReconnectSuppressedForManualDisconnect = newValue }
    }

    var manualDisconnectKnownSerials: Set<String>? {
        get { connectionCoordinator.manualDisconnectKnownSerials }
        set { connectionCoordinator.manualDisconnectKnownSerials = newValue }
    }

    var manualDisconnectBaselineSerials: Set<String> {
        get { connectionCoordinator.manualDisconnectBaselineSerials }
        set { connectionCoordinator.manualDisconnectBaselineSerials = newValue }
    }

    var manualDisconnectWiFiProbeInFlight: Bool {
        get { connectionCoordinator.manualDisconnectWiFiProbeInFlight }
        set { connectionCoordinator.manualDisconnectWiFiProbeInFlight = newValue }
    }

    var lastPresenceAutoConnectAttemptAt: Date? {
        get { connectionCoordinator.lastPresenceAutoConnectAttemptAt }
        set { connectionCoordinator.lastPresenceAutoConnectAttemptAt = newValue }
    }

    var failedAutoConnectTargets: [String: Date] {
        get { connectionCoordinator.failedAutoConnectTargets }
        set { connectionCoordinator.failedAutoConnectTargets = newValue }
    }

    var autoConnectTargetsInFlight: Set<String> {
        get { connectionCoordinator.autoConnectTargetsInFlight }
        set { connectionCoordinator.autoConnectTargetsInFlight = newValue }
    }

    var wifiAddressRecoveryAttemptedAt: [String: Date] {
        get { connectionCoordinator.wifiAddressRecoveryAttemptedAt }
        set { connectionCoordinator.wifiAddressRecoveryAttemptedAt = newValue }
    }

    var savedWiFiStatusProbeInFlight: Bool {
        get { connectionCoordinator.savedWiFiStatusProbeInFlight }
        set { connectionCoordinator.savedWiFiStatusProbeInFlight = newValue }
    }

    var lastSavedWiFiStatusProbeAt: Date? {
        get { connectionCoordinator.lastSavedWiFiStatusProbeAt }
        set { connectionCoordinator.lastSavedWiFiStatusProbeAt = newValue }
    }

    var previousAuthorizedSerials: Set<String> {
        get { connectionCoordinator.previousAuthorizedSerials }
        set { connectionCoordinator.previousAuthorizedSerials = newValue }
    }

    var lastUSBHandoffSerial: String? {
        get { connectionCoordinator.lastUSBHandoffSerial }
        set { connectionCoordinator.lastUSBHandoffSerial = newValue }
    }

    var wirelessPinnedUSBSerials: Set<String> {
        get { connectionCoordinator.wirelessPinnedUSBSerials }
        set { connectionCoordinator.wirelessPinnedUSBSerials = newValue }
    }

    var manualUSBPinnedSerials: Set<String> {
        get { connectionCoordinator.manualUSBPinnedSerials }
        set { connectionCoordinator.manualUSBPinnedSerials = newValue }
    }

    var manualWirelessConnectDisallowsUSBFallback: Bool {
        get { connectionCoordinator.manualWirelessConnectDisallowsUSBFallback }
        set { connectionCoordinator.manualWirelessConnectDisallowsUSBFallback = newValue }
    }

    var lastUSBWiFiAddressPrefillSerial: String? {
        get { connectionCoordinator.lastUSBWiFiAddressPrefillSerial }
        set { connectionCoordinator.lastUSBWiFiAddressPrefillSerial = newValue }
    }

    var lastUSBWiFiAddressPrefillAt: Date? {
        get { connectionCoordinator.lastUSBWiFiAddressPrefillAt }
        set { connectionCoordinator.lastUSBWiFiAddressPrefillAt = newValue }
    }

    var launchReconnectDeadline: Date? {
        get { connectionCoordinator.launchReconnectDeadline }
        set { connectionCoordinator.launchReconnectDeadline = newValue }
    }

    var lastADBDaemonRecoveryAt: Date? {
        get { connectionCoordinator.lastADBDaemonRecoveryAt }
        set { connectionCoordinator.lastADBDaemonRecoveryAt = newValue }
    }

    var adbDaemonRecoveryInFlight: Bool {
        get { connectionCoordinator.adbDaemonRecoveryInFlight }
        set { connectionCoordinator.adbDaemonRecoveryInFlight = newValue }
    }

    var sessionAutoConnectSuspendedRecordIDs: Set<PairedPhoneRecord.ID> {
        get { connectionCoordinator.sessionAutoConnectSuspendedRecordIDs }
        set { connectionCoordinator.sessionAutoConnectSuspendedRecordIDs = newValue }
    }

    var usbWiFiHandoffCandidate: USBWiFiHandoffCandidate? {
        get { connectionCoordinator.usbWiFiHandoffCandidate }
        set { connectionCoordinator.usbWiFiHandoffCandidate = newValue }
    }

    var failedLegacyHandoffSerials: Set<String> {
        get { connectionCoordinator.failedLegacyHandoffSerials }
        set { connectionCoordinator.failedLegacyHandoffSerials = newValue }
    }

    var networkPathMonitor: NWPathMonitor? {
        get { connectionCoordinator.networkPathMonitor }
        set { connectionCoordinator.networkPathMonitor = newValue }
    }

    var lastNetworkPathWasSatisfied: Bool? {
        get { connectionCoordinator.lastNetworkPathWasSatisfied }
        set { connectionCoordinator.lastNetworkPathWasSatisfied = newValue }
    }

    var didWakeObserver: NSObjectProtocol? {
        get { connectionCoordinator.didWakeObserver }
        set { connectionCoordinator.didWakeObserver = newValue }
    }

    var lastSystemEventReconnectNudgeAt: Date? {
        get { connectionCoordinator.lastSystemEventReconnectNudgeAt }
        set { connectionCoordinator.lastSystemEventReconnectNudgeAt = newValue }
    }

    var usbAttachMonitor: USBAttachMonitor? {
        get { connectionCoordinator.usbAttachMonitor }
        set { connectionCoordinator.usbAttachMonitor = newValue }
    }

    var lastUSBAttachNudgeAt: Date? {
        get { connectionCoordinator.lastUSBAttachNudgeAt }
        set { connectionCoordinator.lastUSBAttachNudgeAt = newValue }
    }

    var deviceWatcherWakeContinuation: CheckedContinuation<Void, Never>? {
        get { connectionCoordinator.deviceWatcherWakeContinuation }
        set { connectionCoordinator.deviceWatcherWakeContinuation = newValue }
    }

    var deviceWatcherSleepGeneration: Int {
        get { connectionCoordinator.deviceWatcherSleepGeneration }
        set { connectionCoordinator.deviceWatcherSleepGeneration = newValue }
    }

    var autoConnectEligiblePairedPhones: [PairedPhoneRecord] {
        pairedPhones.filter { !sessionAutoConnectSuspendedRecordIDs.contains($0.id) }
    }
}

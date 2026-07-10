import AppKit
import Foundation
import Network

/// Owns the lifetime of AppModel's connection workflows.
///
/// Connection state still belongs to `AppModel`; this coordinator is the
/// narrower first extraction boundary for mutually-dependent task handles and
/// their cancellation invariants. A task is cleared in the same operation that
/// cancels it, so stale handles cannot keep the UI in a connecting state.
@MainActor
final class ConnectionCoordinator {
    struct USBWiFiHandoffCandidate {
        var usbSerial: String
        var address: String
        var displayName: String
    }

    // Runtime state for reconnect, handoff, and transport-selection policy.
    // AppModel exposes observable outcomes; this object owns the mutable
    // bookkeeping that makes those outcomes deterministic.
    var isAutoReconnectSuppressedForManualDisconnect = false
    var manualDisconnectKnownSerials: Set<String>?
    var manualDisconnectBaselineSerials: Set<String> = []
    var manualDisconnectWiFiProbeInFlight = false
    var lastPresenceAutoConnectAttemptAt: Date?
    var failedAutoConnectTargets: [String: Date] = [:]
    var autoConnectTargetsInFlight: Set<String> = []
    var wifiAddressRecoveryAttemptedAt: [String: Date] = [:]
    var savedWiFiStatusProbeInFlight = false
    var lastSavedWiFiStatusProbeAt: Date?
    var previousAuthorizedSerials: Set<String> = []
    var lastUSBHandoffSerial: String?
    var wirelessPinnedUSBSerials: Set<String> = []
    var manualUSBPinnedSerials: Set<String> = []
    var manualWirelessConnectDisallowsUSBFallback = false
    var lastUSBWiFiAddressPrefillSerial: String?
    var lastUSBWiFiAddressPrefillAt: Date?
    var launchReconnectDeadline: Date?
    var lastADBDaemonRecoveryAt: Date?
    var adbDaemonRecoveryInFlight = false
    var sessionAutoConnectSuspendedRecordIDs = Set<PairedPhoneRecord.ID>()
    var usbWiFiHandoffCandidate: USBWiFiHandoffCandidate?
    var failedLegacyHandoffSerials: Set<String> = []

    // Event sources and watcher suspension belong to the same lifecycle as the
    // connection tasks. Keeping them here prevents AppModel teardown from
    // needing to know every monitor/task pair.
    var networkPathMonitor: NWPathMonitor?
    var lastNetworkPathWasSatisfied: Bool?
    var didWakeObserver: NSObjectProtocol?
    var lastSystemEventReconnectNudgeAt: Date?
    var usbAttachMonitor: USBAttachMonitor?
    var lastUSBAttachNudgeAt: Date?
    var deviceWatcherWakeContinuation: CheckedContinuation<Void, Never>?
    var deviceWatcherSleepGeneration = 0

    var deviceWatcherTask: Task<Void, Never>?
    var qrPairingTask: Task<Void, Never>?
    var usbConnectTask: Task<Void, Never>?
    var usbWiFiAddressPrefillTask: Task<Void, Never>?
    var usbWiFiHandoffTask: Task<Void, Never>?
    var usbWiFiTakeoverTask: Task<Void, Never>?
    var wirelessStartTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var disconnectRecoveryTask: Task<Void, Never>?

    deinit {
        deviceWatcherTask?.cancel()
        qrPairingTask?.cancel()
        usbConnectTask?.cancel()
        usbWiFiAddressPrefillTask?.cancel()
        usbWiFiHandoffTask?.cancel()
        usbWiFiTakeoverTask?.cancel()
        wirelessStartTask?.cancel()
        reconnectTask?.cancel()
        disconnectRecoveryTask?.cancel()
        networkPathMonitor?.cancel()
        usbAttachMonitor?.stop()
        if let didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeObserver)
        }
    }

    var hasActiveConnectionAttempt: Bool {
        usbConnectTask != nil
            || usbWiFiHandoffTask != nil
            || usbWiFiTakeoverTask != nil
            || wirelessStartTask != nil
            || reconnectTask != nil
    }

    var hasWirelessWorkInFlight: Bool {
        wirelessStartTask != nil
            || reconnectTask != nil
            || usbWiFiHandoffTask != nil
            || usbWiFiTakeoverTask != nil
    }

    var isPreparingWiFiHandoff: Bool {
        usbWiFiHandoffTask != nil
            || usbWiFiTakeoverTask != nil
            || wirelessStartTask != nil
            || reconnectTask != nil
    }

    /// Cancels every workflow owned by this coordinator. Mirror launch,
    /// recording, and presentation tasks intentionally remain separate
    /// lifecycles and are cancelled by their owning AppModel subsystems.
    func cancelAll() {
        cancel(&deviceWatcherTask)
        cancel(&qrPairingTask)
        cancel(&usbConnectTask)
        cancel(&usbWiFiAddressPrefillTask)
        cancel(&usbWiFiHandoffTask)
        cancel(&usbWiFiTakeoverTask)
        cancel(&wirelessStartTask)
        cancel(&reconnectTask)
        cancel(&disconnectRecoveryTask)
    }

    /// Preserves the existing reconnect cancellation boundary: an explicit
    /// route decision stops reconnect/recovery/takeover work without killing
    /// device watching, QR pairing, USB connection, or handoff preparation.
    func cancelWirelessReconnectWork() {
        cancel(&reconnectTask)
        cancel(&wirelessStartTask)
        cancel(&disconnectRecoveryTask)
        cancel(&usbWiFiTakeoverTask)
        autoConnectTargetsInFlight.removeAll()
        launchReconnectDeadline = nil
    }

    func reset() {
        cancelAll()
        stopEventMonitoring()
        isAutoReconnectSuppressedForManualDisconnect = false
        manualDisconnectKnownSerials = nil
        manualDisconnectBaselineSerials.removeAll()
        manualDisconnectWiFiProbeInFlight = false
        lastPresenceAutoConnectAttemptAt = nil
        failedAutoConnectTargets.removeAll()
        autoConnectTargetsInFlight.removeAll()
        wifiAddressRecoveryAttemptedAt.removeAll()
        savedWiFiStatusProbeInFlight = false
        lastSavedWiFiStatusProbeAt = nil
        previousAuthorizedSerials.removeAll()
        lastUSBHandoffSerial = nil
        wirelessPinnedUSBSerials.removeAll()
        manualUSBPinnedSerials.removeAll()
        manualWirelessConnectDisallowsUSBFallback = false
        lastUSBWiFiAddressPrefillSerial = nil
        lastUSBWiFiAddressPrefillAt = nil
        launchReconnectDeadline = nil
        lastADBDaemonRecoveryAt = nil
        adbDaemonRecoveryInFlight = false
        sessionAutoConnectSuspendedRecordIDs.removeAll()
        usbWiFiHandoffCandidate = nil
        failedLegacyHandoffSerials.removeAll()
    }

    func stopEventMonitoring() {
        networkPathMonitor?.cancel()
        networkPathMonitor = nil
        usbAttachMonitor?.stop()
        usbAttachMonitor = nil
        if let didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(didWakeObserver)
            self.didWakeObserver = nil
        }
        lastNetworkPathWasSatisfied = nil
        lastSystemEventReconnectNudgeAt = nil
        lastUSBAttachNudgeAt = nil
        deviceWatcherSleepGeneration &+= 1
        let continuation = deviceWatcherWakeContinuation
        deviceWatcherWakeContinuation = nil
        continuation?.resume()
    }

    private func cancel(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}

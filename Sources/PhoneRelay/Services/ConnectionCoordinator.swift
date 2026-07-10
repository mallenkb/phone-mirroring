import Foundation

/// Owns the lifetime of AppModel's connection workflows.
///
/// Connection state still belongs to `AppModel`; this coordinator is the
/// narrower first extraction boundary for mutually-dependent task handles and
/// their cancellation invariants. A task is cleared in the same operation that
/// cancels it, so stale handles cannot keep the UI in a connecting state.
@MainActor
final class ConnectionCoordinator {
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
    }

    private func cancel(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}

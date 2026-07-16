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
    // Same-channel transport reappearance after a manual Disconnect is
    // deliberately NOT a trigger here: the reappeared device is already a
    // verified `adb devices` transport, so `handleManualDisconnectPause`
    // mirrors it directly instead of routing through the wireless resolver.
    enum AutomaticReconnectTrigger: Hashable, Sendable {
        case launch
        case discovery(address: String, eventID: UInt64)
        case watcher
        case networkRestored(eventID: UInt64)
        case systemWake(eventID: UInt64)
        case disconnectRecovery

        var evidenceKey: String? {
            switch self {
            case .launch, .watcher, .disconnectRecovery:
                return nil
            case .discovery(let address, let eventID):
                return "discovery:\(eventID):\(address)"
            case .networkRestored(let eventID):
                return "network:\(eventID)"
            case .systemWake(let eventID):
                return "wake:\(eventID)"
            }
        }
    }

    enum AutomaticReconnectFailure: String, Equatable, Sendable {
        case temporarilyUnavailable
        case localNetworkDenied
        case pairingRequired
        case adbUnavailable
        case unauthorizedUSB
        case mirrorCrashBackoff
    }

    enum AutomaticReconnectState: Equatable, Sendable {
        case idle
        case manuallyDisconnected
        case attempting(recordID: String, generation: Int)
        case waiting(recordID: String, retryAt: Date, failure: AutomaticReconnectFailure)
        case connected(recordID: String?)
    }

    struct AutomaticRetryState: Equatable, Sendable {
        var failureCount = 0
        var nextRetryAt: Date?
        var lastFailure: AutomaticReconnectFailure?
        var consumedEvidenceKeys: Set<String> = []
    }

    struct USBWiFiHandoffCandidate {
        var usbSerial: String
        var address: String
        var displayName: String
    }

    /// A user's transport choice applies only to the connection currently being
    /// launched. It is deliberately separate from `wirelessPinnedUSBSerials`,
    /// which is internal anti-ping-pong state while an established Wi-Fi route
    /// is active or being recovered.
    enum TransportIntent: Equatable {
        case automatic
        case manualUSB(serial: String)
        case manualWiFi

        var requiresWiFi: Bool {
            if case .manualWiFi = self { return true }
            return false
        }

        func permitsPreparedWiFiTakeover(for usbSerial: String) -> Bool {
            switch self {
            case .automatic:
                return true
            case .manualUSB(let selectedSerial):
                return selectedSerial != usbSerial
            case .manualWiFi:
                return false
            }
        }
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
    var transportIntent: TransportIntent = .automatic
    var lastUSBWiFiAddressPrefillSerial: String?
    var lastUSBWiFiAddressPrefillAt: Date?
    var launchReconnectDeadline: Date?
    var lastADBDaemonRecoveryAt: Date?
    var adbDaemonRecoveryInFlight = false
    var sessionAutoConnectSuspendedRecordIDs = Set<PairedPhoneRecord.ID>()
    var usbWiFiHandoffCandidate: USBWiFiHandoffCandidate?
    var failedLegacyHandoffSerials: Set<String> = []
    private(set) var usbWiFiHandoffGeneration = 0
    private(set) var discoveredWiFiConnectGeneration = 0

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
    var discoveredWiFiConnectTask: Task<Void, Never>?
    var wirelessStartTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var disconnectRecoveryTask: Task<Void, Never>?
    var automaticReconnectTask: Task<Void, Never>?
    var automaticReconnectState: AutomaticReconnectState = .idle
    var automaticReconnectGeneration = 0
    var automaticDiscoveryEventID: UInt64 = 0
    var automaticRetryStates: [String: AutomaticRetryState] = [:]
    var automaticReconnectBypassPending = false
    var pendingAutomaticEvidenceKeys: Set<String> = []
    var automaticReconnectWakeContinuation: CheckedContinuation<Void, Never>?
    var automaticReconnectSleepGeneration = 0

    deinit {
        deviceWatcherTask?.cancel()
        qrPairingTask?.cancel()
        usbConnectTask?.cancel()
        usbWiFiAddressPrefillTask?.cancel()
        usbWiFiHandoffTask?.cancel()
        usbWiFiTakeoverTask?.cancel()
        discoveredWiFiConnectTask?.cancel()
        wirelessStartTask?.cancel()
        reconnectTask?.cancel()
        disconnectRecoveryTask?.cancel()
        automaticReconnectTask?.cancel()
        automaticReconnectWakeContinuation?.resume()
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
            || discoveredWiFiConnectTask != nil
            || wirelessStartTask != nil
            || reconnectTask != nil
            || automaticReconnectTask != nil
    }

    var hasWirelessWorkInFlight: Bool {
        wirelessStartTask != nil
            || discoveredWiFiConnectTask != nil
            || reconnectTask != nil
            || usbWiFiHandoffTask != nil
            || usbWiFiTakeoverTask != nil
            || automaticReconnectTask != nil
    }

    var isPreparingWiFiHandoff: Bool {
        usbWiFiHandoffTask != nil
            || usbWiFiTakeoverTask != nil
            || discoveredWiFiConnectTask != nil
            || wirelessStartTask != nil
            || reconnectTask != nil
    }

    /// Explicit user-initiated connection work. The automatic reconnect task is
    /// deliberately excluded: it consults this before starting or dialing, so a
    /// manual flow always owns the wire and two connect flights for the same
    /// phone can never race.
    var hasManualConnectionWorkInFlight: Bool {
        usbConnectTask != nil
            || discoveredWiFiConnectTask != nil
            || usbWiFiHandoffTask != nil
            || usbWiFiTakeoverTask != nil
            || wirelessStartTask != nil
            || reconnectTask != nil
    }

    /// True only while the automatic reconnect flight is actively dialing —
    /// a loop parked in retry backoff (`waiting`) keeps its task alive but is
    /// not on the wire, so cheap status probes may run without racing it.
    var isAutomaticReconnectDialing: Bool {
        if case .attempting = automaticReconnectState { return true }
        return false
    }

    /// Cancels every workflow owned by this coordinator. Mirror launch,
    /// recording, and presentation tasks intentionally remain separate
    /// lifecycles and are cancelled by their owning AppModel subsystems.
    func cancelAll() {
        cancel(&deviceWatcherTask)
        cancel(&qrPairingTask)
        cancel(&usbConnectTask)
        cancel(&usbWiFiAddressPrefillTask)
        cancelUSBWiFiHandoff()
        cancel(&usbWiFiTakeoverTask)
        cancelDiscoveredWiFiConnect()
        cancel(&wirelessStartTask)
        cancel(&reconnectTask)
        cancel(&disconnectRecoveryTask)
        cancelAutomaticReconnect(clearRetryState: false)
    }

    /// Preserves the existing reconnect cancellation boundary: an explicit
    /// route decision stops reconnect/recovery/takeover work without killing
    /// device watching, QR pairing, USB connection, or handoff preparation.
    func cancelWirelessReconnectWork() {
        cancel(&reconnectTask)
        cancelDiscoveredWiFiConnect()
        cancel(&wirelessStartTask)
        cancel(&disconnectRecoveryTask)
        cancel(&usbWiFiTakeoverTask)
        cancelAutomaticReconnect(clearRetryState: false)
        autoConnectTargetsInFlight.removeAll()
        launchReconnectDeadline = nil
    }

    /// Starts a new handoff ownership epoch. A cancelled task may still resume
    /// after a non-cooperative adb call, so generation ownership—not the task
    /// handle alone—decides whether it may mutate connection state.
    func beginUSBWiFiHandoff() -> Int {
        cancelUSBWiFiHandoff()
        return usbWiFiHandoffGeneration
    }

    func isCurrentUSBWiFiHandoff(_ generation: Int) -> Bool {
        usbWiFiHandoffGeneration == generation
    }

    func finishUSBWiFiHandoff(_ generation: Int) {
        guard isCurrentUSBWiFiHandoff(generation) else { return }
        usbWiFiHandoffTask = nil
    }

    func cancelUSBWiFiHandoff() {
        usbWiFiHandoffGeneration &+= 1
        cancel(&usbWiFiHandoffTask)
    }

    func beginDiscoveredWiFiConnect() -> Int {
        cancelDiscoveredWiFiConnect()
        return discoveredWiFiConnectGeneration
    }

    func isCurrentDiscoveredWiFiConnect(_ generation: Int) -> Bool {
        discoveredWiFiConnectGeneration == generation
    }

    func finishDiscoveredWiFiConnect(_ generation: Int) {
        guard isCurrentDiscoveredWiFiConnect(generation) else { return }
        discoveredWiFiConnectTask = nil
    }

    func cancelDiscoveredWiFiConnect() {
        discoveredWiFiConnectGeneration &+= 1
        cancel(&discoveredWiFiConnectTask)
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
        transportIntent = .automatic
        lastUSBWiFiAddressPrefillSerial = nil
        lastUSBWiFiAddressPrefillAt = nil
        launchReconnectDeadline = nil
        lastADBDaemonRecoveryAt = nil
        adbDaemonRecoveryInFlight = false
        sessionAutoConnectSuspendedRecordIDs.removeAll()
        usbWiFiHandoffCandidate = nil
        failedLegacyHandoffSerials.removeAll()
        automaticReconnectState = .idle
        automaticReconnectGeneration = 0
        automaticDiscoveryEventID = 0
        automaticRetryStates.removeAll()
        automaticReconnectBypassPending = false
        pendingAutomaticEvidenceKeys.removeAll()
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
        wakeAutomaticReconnect()
    }

    nonisolated static func automaticReconnectDelay(failureCount: Int) -> TimeInterval {
        switch failureCount {
        case ..<1: return 0
        case 1: return 5
        case 2: return 10
        case 3: return 20
        default: return 30
        }
    }

    func enterManualDisconnect() {
        isAutoReconnectSuppressedForManualDisconnect = true
        cancelAutomaticReconnect(clearRetryState: false)
        automaticReconnectState = .manuallyDisconnected
    }

    func nextAutomaticDiscoveryEventID() -> UInt64 {
        automaticDiscoveryEventID &+= 1
        return automaticDiscoveryEventID
    }

    func leaveManualDisconnect() {
        isAutoReconnectSuppressedForManualDisconnect = false
        if automaticReconnectState == .manuallyDisconnected {
            automaticReconnectState = .idle
        }
    }

    func beginAutomaticReconnect(recordID: String) -> Int? {
        guard !isAutoReconnectSuppressedForManualDisconnect,
              automaticReconnectState != .manuallyDisconnected else { return nil }
        automaticReconnectGeneration &+= 1
        let generation = automaticReconnectGeneration
        automaticReconnectState = .attempting(recordID: recordID, generation: generation)
        return generation
    }

    func isCurrentAutomaticReconnect(recordID: String, generation: Int) -> Bool {
        automaticReconnectState == .attempting(recordID: recordID, generation: generation)
            && automaticReconnectGeneration == generation
            && !isAutoReconnectSuppressedForManualDisconnect
    }

    func mayAttemptAutomaticReconnect(
        recordID: String,
        trigger: AutomaticReconnectTrigger,
        now: Date = Date(),
        notBefore: Date? = nil
    ) -> Bool {
        guard !isAutoReconnectSuppressedForManualDisconnect,
              automaticReconnectState != .manuallyDisconnected else { return false }
        var retry = automaticRetryStates[recordID] ?? AutomaticRetryState()
        let retryAt = max(retry.nextRetryAt ?? .distantPast, notBefore ?? .distantPast)
        guard now < retryAt else { return true }
        guard let evidenceKey = trigger.evidenceKey,
              !retry.consumedEvidenceKeys.contains(evidenceKey) else { return false }
        retry.consumedEvidenceKeys.insert(evidenceKey)
        automaticRetryStates[recordID] = retry
        return true
    }

    @discardableResult
    func recordAutomaticReconnectFailure(
        recordID: String,
        failure: AutomaticReconnectFailure,
        now: Date = Date(),
        notBefore: Date? = nil
    ) -> Date {
        var retry = automaticRetryStates[recordID] ?? AutomaticRetryState()
        retry.consumedEvidenceKeys.formUnion(pendingAutomaticEvidenceKeys)
        pendingAutomaticEvidenceKeys.removeAll()
        retry.failureCount += 1
        retry.lastFailure = failure
        let scheduled = now.addingTimeInterval(
            Self.automaticReconnectDelay(failureCount: retry.failureCount)
        )
        let retryAt = max(scheduled, notBefore ?? scheduled)
        retry.nextRetryAt = retryAt
        automaticRetryStates[recordID] = retry
        automaticReconnectState = .waiting(
            recordID: recordID,
            retryAt: retryAt,
            failure: failure
        )
        return retryAt
    }

    func recordAutomaticReconnectSuccess(recordID: String?) {
        if let recordID {
            automaticRetryStates.removeValue(forKey: recordID)
        }
        automaticReconnectState = .connected(recordID: recordID)
        pendingAutomaticEvidenceKeys.removeAll()
    }

    func resetAutomaticRetry(recordID: String? = nil) {
        if let recordID {
            automaticRetryStates.removeValue(forKey: recordID)
        } else {
            automaticRetryStates.removeAll()
        }
        if automaticReconnectState != .manuallyDisconnected {
            automaticReconnectState = .idle
        }
        wakeAutomaticReconnect()
    }

    func requestAutomaticReconnectWake(
        recordID: String,
        trigger: AutomaticReconnectTrigger,
        now: Date = Date()
    ) {
        // Watcher and timer polls coalesce into the active flight but never
        // bypass its deadline. Only a uniquely identified evidence event may
        // wake the retry early.
        guard let evidenceKey = trigger.evidenceKey else { return }
        if pendingAutomaticEvidenceKeys.contains(evidenceKey) { return }
        guard mayAttemptAutomaticReconnect(recordID: recordID, trigger: trigger, now: now) else {
            return
        }
        pendingAutomaticEvidenceKeys.insert(evidenceKey)
        automaticReconnectBypassPending = true
        wakeAutomaticReconnect()
    }

    func consumeAutomaticReconnectBypass() -> Bool {
        let pending = automaticReconnectBypassPending
        automaticReconnectBypassPending = false
        pendingAutomaticEvidenceKeys.removeAll()
        return pending
    }

    func cancelAutomaticReconnect(clearRetryState: Bool) {
        automaticReconnectTask?.cancel()
        automaticReconnectTask = nil
        automaticReconnectSleepGeneration &+= 1
        let continuation = automaticReconnectWakeContinuation
        automaticReconnectWakeContinuation = nil
        continuation?.resume()
        if clearRetryState {
            automaticRetryStates.removeAll()
        }
        automaticReconnectBypassPending = false
        if automaticReconnectState != .manuallyDisconnected {
            automaticReconnectState = .idle
        }
    }

    func sleepUntilAutomaticReconnect(_ date: Date) async {
        let delay = max(0, date.timeIntervalSinceNow)
        guard delay > 0 else { return }
        automaticReconnectSleepGeneration &+= 1
        let generation = automaticReconnectSleepGeneration
        await withCheckedContinuation { continuation in
            automaticReconnectWakeContinuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self,
                      self.automaticReconnectSleepGeneration == generation else { return }
                self.wakeAutomaticReconnect()
            }
        }
    }

    func wakeAutomaticReconnect() {
        automaticReconnectSleepGeneration &+= 1
        let continuation = automaticReconnectWakeContinuation
        automaticReconnectWakeContinuation = nil
        continuation?.resume()
    }

    private func cancel(_ task: inout Task<Void, Never>?) {
        task?.cancel()
        task = nil
    }
}

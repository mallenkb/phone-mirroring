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
        /// The address sweep proved nothing on this LAN answers on the adb
        /// port. `tcpip 5555` does not survive a phone reboot and cannot be
        /// re-enabled over the air, so only a cable clears this one.
        case wirelessListenerMissing
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

    /// Circuit-breaker state for the destructive `adb tcpip` step, per USB
    /// serial. `adb tcpip` restarts adbd and drops the cable, so a phone that
    /// genuinely cannot do wireless adb must not be restarted on every cycle
    /// (that was the "USB mirror dies every few seconds" pathology). The
    /// verdict used to last the whole session, which also meant one transient
    /// failure — adbd mid-restart after a phone reboot, a Wi-Fi blip — disabled
    /// the *only* path this app has to re-arm `:5555` until relaunch. So the
    /// breaker now escalates instead: retry is allowed after a delay that grows
    /// steeply, capping at 30 minutes.
    struct LegacyHandoffFailureState: Equatable, Sendable {
        var failureCount = 0
        var retryAt = Date.distantPast
    }

    nonisolated static func legacyHandoffRetryDelay(failureCount: Int) -> TimeInterval {
        switch failureCount {
        case ..<1: return 0
        case 1: return 60
        case 2: return 300
        default: return 1800
        }
    }

    /// True while `adb tcpip` is barred for this serial. A serial that has
    /// never failed, or whose escalating delay has elapsed, may try again.
    func isLegacyHandoffCoolingDown(serial: String, now: Date = Date()) -> Bool {
        guard let state = failedLegacyHandoffSerials[serial] else { return false }
        return now < state.retryAt
    }

    func legacyHandoffRetryDate(serial: String) -> Date? {
        failedLegacyHandoffSerials[serial]?.retryAt
    }

    @discardableResult
    func noteLegacyHandoffFailure(serial: String, now: Date = Date()) -> Date {
        var state = failedLegacyHandoffSerials[serial] ?? LegacyHandoffFailureState()
        state.failureCount += 1
        state.retryAt = now.addingTimeInterval(
            Self.legacyHandoffRetryDelay(failureCount: state.failureCount)
        )
        failedLegacyHandoffSerials[serial] = state
        return state.retryAt
    }

    /// A proven-good wireless route clears the verdict outright: the phone can
    /// evidently do adb over Wi-Fi, so the next cable deserves a clean slate.
    func clearLegacyHandoffFailure(serial: String) {
        failedLegacyHandoffSerials.removeValue(forKey: serial)
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
    /// Records whose last address sweep found *no* host on the LAN listening on
    /// the adb port. That is the phone's `tcpip` listener being gone rather than
    /// its IP having moved, so the fix is a cable, not more waiting.
    var wirelessListenerMissingRecordIDs: Set<String> = []
    var savedWiFiStatusProbeInFlight = false
    var lastSavedWiFiStatusProbeAt: Date?
    var previousAuthorizedSerials: Set<String> = []
    /// USB serials already considered for a cable-arrival Wi-Fi arm, so the
    /// arm fires on the plug-in edge instead of on every watcher poll.
    var wirelessArmSeenUSBSerials: Set<String> = []
    var lastWirelessArmAttemptAt: [String: Date] = [:]
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
    var failedLegacyHandoffSerials: [String: LegacyHandoffFailureState] = [:]
    private(set) var usbWiFiHandoffGeneration = 0
    private(set) var activeUSBWiFiHandoffGeneration: Int?
    private(set) var discoveredWiFiConnectGeneration = 0
    private(set) var wirelessRouteVerificationGeneration = 0
    private(set) var adbDaemonRecoveryGeneration = 0

    // Event sources and watcher suspension belong to the same lifecycle as the
    // connection tasks. Keeping them here prevents AppModel teardown from
    // needing to know every monitor/task pair.
    var networkPathMonitor: NWPathMonitor?
    var lastNetworkPathWasSatisfied: Bool?
    var preferCurrentNetworkForNextReconnect = false
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
    var wirelessRouteVerificationTask: Task<Void, Never>?
    var wirelessStartTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    var disconnectRecoveryTask: Task<Void, Never>?
    var adbDaemonRecoveryTask: Task<Void, Never>?
    var automaticReconnectTask: Task<Void, Never>?
    var automaticReconnectState: AutomaticReconnectState = .idle
    var automaticReconnectGeneration = 0
    private(set) var automaticReconnectTaskGeneration = 0
    var automaticReconnectRecordCursor = 0
    var automaticReconnectPreferredRecordID: String?
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
        wirelessRouteVerificationTask?.cancel()
        wirelessStartTask?.cancel()
        reconnectTask?.cancel()
        disconnectRecoveryTask?.cancel()
        adbDaemonRecoveryTask?.cancel()
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
            || activeUSBWiFiHandoffGeneration != nil
            || usbWiFiHandoffTask != nil
            || usbWiFiTakeoverTask != nil
            || discoveredWiFiConnectTask != nil
            || wirelessStartTask != nil
            || reconnectTask != nil
            || adbDaemonRecoveryTask != nil
            || automaticReconnectTask != nil
    }

    var hasWirelessWorkInFlight: Bool {
        wirelessStartTask != nil
            || discoveredWiFiConnectTask != nil
            || reconnectTask != nil
            || activeUSBWiFiHandoffGeneration != nil
            || usbWiFiHandoffTask != nil
            || usbWiFiTakeoverTask != nil
            || automaticReconnectTask != nil
    }

    var isPreparingWiFiHandoff: Bool {
        activeUSBWiFiHandoffGeneration != nil
            || usbWiFiHandoffTask != nil
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
            || activeUSBWiFiHandoffGeneration != nil
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

    /// Per-record failure counts from the retry states, keyed by record ID.
    /// A nonzero count is proof the pursued wireless route is *failing*, which
    /// lets cable-arrival work (re-arm `tcpip`, USB interrupt) supersede the
    /// parked loop without disturbing a healthy first attempt.
    var automaticRetryFailureCounts: [String: Int] {
        automaticRetryStates.mapValues(\.failureCount)
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
        cancelWirelessRouteVerification()
        cancel(&wirelessStartTask)
        cancel(&reconnectTask)
        cancel(&disconnectRecoveryTask)
        cancelADBDaemonRecovery()
        cancelAutomaticReconnect(clearRetryState: false)
    }

    /// Preserves the existing reconnect cancellation boundary: an explicit
    /// route decision stops reconnect/recovery/takeover work without killing
    /// device watching, QR pairing, USB connection, or handoff preparation.
    func cancelWirelessReconnectWork() {
        cancel(&reconnectTask)
        cancelDiscoveredWiFiConnect()
        cancelWirelessRouteVerification()
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
        activeUSBWiFiHandoffGeneration = usbWiFiHandoffGeneration
        return usbWiFiHandoffGeneration
    }

    func isCurrentUSBWiFiHandoff(_ generation: Int) -> Bool {
        usbWiFiHandoffGeneration == generation
            && activeUSBWiFiHandoffGeneration == generation
    }

    func finishUSBWiFiHandoff(_ generation: Int) {
        guard isCurrentUSBWiFiHandoff(generation) else { return }
        activeUSBWiFiHandoffGeneration = nil
        usbWiFiHandoffTask = nil
    }

    func cancelUSBWiFiHandoff() {
        usbWiFiHandoffGeneration &+= 1
        activeUSBWiFiHandoffGeneration = nil
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

    func beginWirelessRouteVerification() -> Int {
        cancelWirelessRouteVerification()
        return wirelessRouteVerificationGeneration
    }

    func isCurrentWirelessRouteVerification(_ generation: Int) -> Bool {
        wirelessRouteVerificationGeneration == generation
    }

    func finishWirelessRouteVerification(_ generation: Int) {
        guard isCurrentWirelessRouteVerification(generation) else { return }
        wirelessRouteVerificationTask = nil
    }

    func cancelWirelessRouteVerification() {
        wirelessRouteVerificationGeneration &+= 1
        cancel(&wirelessRouteVerificationTask)
    }

    func beginADBDaemonRecovery() -> Int {
        cancelADBDaemonRecovery()
        adbDaemonRecoveryInFlight = true
        return adbDaemonRecoveryGeneration
    }

    func isCurrentADBDaemonRecovery(_ generation: Int) -> Bool {
        adbDaemonRecoveryInFlight && adbDaemonRecoveryGeneration == generation
    }

    func finishADBDaemonRecovery(_ generation: Int) {
        guard isCurrentADBDaemonRecovery(generation) else { return }
        adbDaemonRecoveryInFlight = false
        adbDaemonRecoveryTask = nil
    }

    func cancelADBDaemonRecovery() {
        adbDaemonRecoveryGeneration &+= 1
        adbDaemonRecoveryInFlight = false
        cancel(&adbDaemonRecoveryTask)
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
        wirelessListenerMissingRecordIDs.removeAll()
        savedWiFiStatusProbeInFlight = false
        lastSavedWiFiStatusProbeAt = nil
        previousAuthorizedSerials.removeAll()
        wirelessArmSeenUSBSerials.removeAll()
        lastWirelessArmAttemptAt.removeAll()
        lastUSBHandoffSerial = nil
        wirelessPinnedUSBSerials.removeAll()
        transportIntent = .automatic
        lastUSBWiFiAddressPrefillSerial = nil
        lastUSBWiFiAddressPrefillAt = nil
        launchReconnectDeadline = nil
        lastADBDaemonRecoveryAt = nil
        adbDaemonRecoveryInFlight = false
        preferCurrentNetworkForNextReconnect = false
        sessionAutoConnectSuspendedRecordIDs.removeAll()
        usbWiFiHandoffCandidate = nil
        failedLegacyHandoffSerials.removeAll()
        automaticReconnectState = .idle
        // Ownership generations stay monotonic across reset so a cancelled,
        // non-cooperative adb call can never regain an old epoch by ABA.
        automaticReconnectRecordCursor = 0
        automaticReconnectPreferredRecordID = nil
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

    /// Owns the task handle itself, independently of the per-attempt generation.
    /// A cancelled adb process can return after a replacement task has started;
    /// only the replacement owner may clear the handle or mutate shared state.
    func beginAutomaticReconnectTask() -> Int {
        automaticReconnectTaskGeneration &+= 1
        return automaticReconnectTaskGeneration
    }

    func ownsAutomaticReconnectTask(
        taskGeneration: Int,
        attemptGeneration: Int? = nil
    ) -> Bool {
        guard automaticReconnectTaskGeneration == taskGeneration,
              !isAutoReconnectSuppressedForManualDisconnect else { return false }
        if let attemptGeneration {
            return automaticReconnectGeneration == attemptGeneration
        }
        return true
    }

    func finishAutomaticReconnectTask(_ taskGeneration: Int) {
        guard automaticReconnectTaskGeneration == taskGeneration else { return }
        automaticReconnectTask = nil
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
        notBefore: Date? = nil,
        maximumDelay: TimeInterval? = nil
    ) -> Date {
        var retry = automaticRetryStates[recordID] ?? AutomaticRetryState()
        retry.consumedEvidenceKeys.formUnion(pendingAutomaticEvidenceKeys)
        pendingAutomaticEvidenceKeys.removeAll()
        retry.failureCount += 1
        retry.lastFailure = failure
        let backoff = Self.automaticReconnectDelay(failureCount: retry.failureCount)
        let scheduled = now.addingTimeInterval(
            maximumDelay.map { min(backoff, max(0, $0)) } ?? backoff
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
        automaticReconnectBypassPending = false
        automaticReconnectPreferredRecordID = nil
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
        automaticReconnectTaskGeneration &+= 1
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
        automaticReconnectPreferredRecordID = nil
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

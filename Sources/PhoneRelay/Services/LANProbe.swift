import Foundation
import Network

/// TCP reachability probes for phones on the LAN.
///
/// macOS can deny Local Network access to the app process while still allowing
/// the adb daemon the app launched. The two are matched against different
/// Local Network privacy records, and with many stale "Phone Relay" rows left
/// in System Settings by older builds, the in-process record can stay denied
/// even though every visible toggle is on (observed 2026-10-04: in-process
/// `NWBrowser` got `PolicyDenied` on every launch while `adb connect` reached
/// the same LAN). An in-process probe then reports every phone as closed, the
/// subnet sweep "proves" no listener exists, and reconnect parks the phone.
///
/// When the connection path reports `localNetworkDenied`, the probe re-runs in
/// a child process, which is attributed the same way as the adb daemon that
/// will actually dial the phone.
enum LANProbe {
    enum Outcome: Equatable, Sendable {
        case open
        case closed
        case localNetworkDenied
    }

    /// After a denial, skip the in-process attempt for this long before
    /// checking again, so a sweep doesn't pay for two probes per host while
    /// still noticing when the user fixes the permission.
    nonisolated static let inProcessDenialRecheckInterval: TimeInterval = 60

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var inProcessDeniedAt: Date?

    /// Replaceable in tests so they never touch the real network.
    nonisolated(unsafe) static var inProcessProbe: @Sendable (String, UInt16, TimeInterval) async -> Outcome = {
        host, port, timeout in
        await probeInProcess(host: host, port: port, timeout: timeout)
    }
    nonisolated(unsafe) static var helperProbe: @Sendable (String, UInt16, TimeInterval) async -> Bool = {
        host, port, timeout in
        await probeWithHelperProcess(host: host, port: port, timeout: timeout)
    }

    static var isInProcessAccessDenied: Bool {
        stateLock.withLock { inProcessDeniedAt != nil }
    }

    static func resetForTesting() {
        stateLock.withLock { inProcessDeniedAt = nil }
    }

    static func shouldSkipInProcessProbe(deniedAt: Date?, now: Date) -> Bool {
        guard let deniedAt else { return false }
        return now.timeIntervalSince(deniedAt) < inProcessDenialRecheckInterval
    }

    /// True when `host:port` accepted a TCP connection.
    static func isPortOpen(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        let skipInProcess = stateLock.withLock {
            shouldSkipInProcessProbe(deniedAt: inProcessDeniedAt, now: Date())
        }
        if !skipInProcess {
            switch await inProcessProbe(host, port, timeout) {
            case .open:
                stateLock.withLock { inProcessDeniedAt = nil }
                return true
            case .closed:
                return false
            case .localNetworkDenied:
                let isFirstDenial = stateLock.withLock { () -> Bool in
                    let first = inProcessDeniedAt == nil
                    inProcessDeniedAt = Date()
                    return first
                }
                if isFirstDenial {
                    Logger.log("Local Network: macOS denied the app process; probing through a helper process. Remove stale Phone Relay rows in System Settings > Privacy & Security > Local Network to fix.")
                    LocalNetworkDenialReporter.report(source: "port probe")
                }
            }
        }
        return await helperProbe(host, port, timeout)
    }

    private static func probeInProcess(host: String, port: UInt16, timeout: TimeInterval) async -> Outcome {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return .closed }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "PhoneRelay.lan-probe", qos: .utility)
        let once = OneShotCallback()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let finish: @Sendable (Outcome) -> Void = { outcome in
                once.run {
                    connection.cancel()
                    continuation.resume(returning: outcome)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.open)
                case .waiting, .failed:
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        finish(.localNetworkDenied)
                    } else if case .failed = state {
                        finish(.closed)
                    }
                    // A plain `.waiting` (no route yet, ARP pending) keeps
                    // waiting for the timeout, matching the old probe.
                case .cancelled:
                    finish(.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    finish(.localNetworkDenied)
                } else {
                    finish(.closed)
                }
            }
        }
    }

    /// `nc -z` exits 0 only when the port accepted the connection. Its `-G`
    /// connect timeout takes whole seconds, so sub-second probes round up.
    static func helperArguments(host: String, port: UInt16, timeout: TimeInterval) -> [String] {
        let seconds = max(1, Int(timeout.rounded(.up)))
        return ["-z", "-G", String(seconds), host, String(port)]
    }

    private static func probeWithHelperProcess(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        let arguments = helperArguments(host: host, port: port, timeout: timeout)
        let processTimeout = max(1, timeout.rounded(.up)) + 0.5
        return await Task.detached(priority: .utility) {
            Tooling.runResult("nc", arguments: arguments, timeout: processTimeout).succeeded
        }.value
    }
}

/// Reports, once per launch, that macOS denied the app process Local Network
/// access. Discovery and probes keep working through adb and the helper
/// process, so this is guidance for the user rather than an error.
enum LocalNetworkDenialReporter {
    nonisolated(unsafe) static var handler: (@Sendable (_ source: String) -> Void)?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var didReport = false

    static func report(source: String) {
        let shouldReport = lock.withLock { () -> Bool in
            guard !didReport else { return false }
            didReport = true
            return true
        }
        guard shouldReport else { return }
        handler?(source)
    }

    static func resetForTesting() {
        lock.withLock { didReport = false }
    }
}

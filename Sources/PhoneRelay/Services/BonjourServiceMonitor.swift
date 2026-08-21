import Foundation
import Network

/// Persistent Bonjour browsers for the adb service types. Replaces the
/// spawn-and-kill `dns-sd -B` sweeps: the browsers stay subscribed, so macOS
/// pushes add/remove events the instant a phone starts or stops advertising,
/// and the idle cost is zero — no processes, no per-poll browse windows.
/// Discovery still resolves a service to `host:port` with one short
/// `dns-sd -L` when it first appears; `ADBController` caches that until the
/// service disappears.
final class BonjourServiceMonitor: @unchecked Sendable {
    static let shared = BonjourServiceMonitor()

    enum ServiceSnapshot {
        /// Browsers are starting and have not yet produced a complete view.
        case warming
        /// Every browser is ready, including a valid empty result.
        case available([ADBController.DNSService])
        /// At least one browser is waiting, failed, or cancelled.
        case unavailable
    }

    /// Same set (and semantics) as the legacy sweep in
    /// `ADBController.dnsServiceDiscoveredPhones`.
    nonisolated static let serviceTypes = [
        "_adb-tls-connect._tcp",
        "_adb._tcp",
        "_adb-tls-pairing._tcp"
    ]

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "phonerelay.bonjour-monitor", qos: .utility)
    private var browsers: [NWBrowser] = []
    private var started = false
    /// Types whose browser hit `.failed`. While any browser is down the
    /// monitor reports unavailable so callers use the legacy dns-sd sweep —
    /// a partial view would silently hide, say, pairable phones from the QR
    /// flow.
    private var failedTypes: Set<String> = []
    private var unavailableTypes: Set<String> = []
    /// Types whose browser is currently `.ready`. A browser that is merely
    /// `.waiting` — which is exactly what a denied Local Network permission
    /// looks like — reports no services at all, and treating that as "nothing
    /// is advertised" made discovery look permanently stuck with no fallback.
    /// Anything short of ready for every type is therefore unavailable, so
    /// callers drop to the legacy dns-sd sweep until the browsers recover.
    private var readyTypes: Set<String> = []
    private var servicesByType: [String: Set<String>] = [:]

    /// Whether the browser set can be trusted to answer for *all* service
    /// types. Split out from `currentServices()` so the rule is testable
    /// without standing up real `NWBrowser`s.
    nonisolated static func isAvailable(readyTypes: Set<String>, failedTypes: Set<String>) -> Bool {
        failedTypes.isEmpty && Set(serviceTypes).isSubset(of: readyTypes)
    }

    /// The currently-advertised adb services, or nil when the monitor can't
    /// provide a trustworthy answer (a browser failed, or hasn't come up) and
    /// the caller should fall back to the legacy sweep. Starts the browsers on
    /// first call.
    func currentServices() -> [ADBController.DNSService]? {
        guard case .available(let services) = serviceSnapshot() else { return nil }
        return services
    }

    /// Distinguishes ordinary browser warm-up from an actual unavailable
    /// browser. Callers can wait for the event-driven result during warm-up
    /// instead of blocking on several legacy dns-sd subprocesses.
    func serviceSnapshot() -> ServiceSnapshot {
        startIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        if Self.isAvailable(readyTypes: readyTypes, failedTypes: failedTypes) {
            let services = servicesByType
            .flatMap { type, names in
                names.map { ADBController.DNSService(instance: $0, serviceType: type) }
            }
            .sorted { ($0.instance, $0.serviceType) < ($1.instance, $1.serviceType) }
            return .available(services)
        }
        return failedTypes.isEmpty && unavailableTypes.isEmpty ? .warming : .unavailable
    }

    private func startIfNeeded() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        for type in Self.serviceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.apply(results: results, forType: type)
            }
            browser.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.lock.lock()
                switch state {
                case .failed(let error):
                    self.failedTypes.insert(type)
                    self.unavailableTypes.insert(type)
                    self.readyTypes.remove(type)
                    self.lock.unlock()
                    ADBController.notifyDiscoveryObservers()
                    Logger.log("Bonjour monitor browser failed type=\(type) error=\(error)")
                case .ready:
                    self.failedTypes.remove(type)
                    self.unavailableTypes.remove(type)
                    self.readyTypes.insert(type)
                    self.lock.unlock()
                    ADBController.notifyDiscoveryObservers()
                case .waiting(let error):
                    // Local Network denied, no interface, etc. The browser
                    // still reports zero services, so stop claiming authority
                    // and let the caller sweep instead of showing nothing.
                    self.unavailableTypes.insert(type)
                    self.readyTypes.remove(type)
                    self.lock.unlock()
                    ADBController.notifyDiscoveryObservers()
                    Logger.log("Bonjour monitor browser waiting type=\(type) error=\(error)")
                case .cancelled:
                    self.unavailableTypes.insert(type)
                    self.readyTypes.remove(type)
                    self.lock.unlock()
                    ADBController.notifyDiscoveryObservers()
                default:
                    self.lock.unlock()
                }
            }
            browser.start(queue: queue)
            lock.lock()
            browsers.append(browser)
            lock.unlock()
        }
    }

    private func apply(results: Set<NWBrowser.Result>, forType type: String) {
        let names = Set(results.compactMap { result -> String? in
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            return name
        })
        lock.lock()
        let changed = servicesByType[type] != names
        servicesByType[type] = names
        lock.unlock()
        if changed {
            ADBController.notifyDiscoveryObservers()
        }
    }
}

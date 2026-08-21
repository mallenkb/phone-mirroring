import Foundation

/// Thin wrapper around the `adb` CLI. All methods are blocking — call them
/// from a detached Task and route results back via @MainActor.
struct ADBController: Sendable {
    private static let commandLock = NSLock()

    enum ExecutionPolicy: Equatable, Sendable {
        case concurrent
        case serialized
    }

    /// adb subcommands that mutate daemon or transport state. Only these are
    /// serialized, so concurrent connect/pair flows can't race the server.
    /// Read-only queries (`devices`, `shell`, `mdns`) run unlocked — blocking
    /// them behind a 5s `connect` to a dead address stalled the device
    /// watcher and made USB plug-in detection feel slow.
    nonisolated static let serializedCommands: Set<String> = [
        "connect", "disconnect", "pair", "tcpip", "usb",
        "reconnect", "kill-server", "start-server"
    ]

    /// The adb subcommand in an argument vector, skipping option flags and
    /// their values (e.g. `["-s", "X", "tcpip", "5555"]` → `"tcpip"`).
    nonisolated static func commandWord(in arguments: [String]) -> String? {
        var skipNext = false
        for argument in arguments {
            if skipNext {
                skipNext = false
                continue
            }
            if argument == "-s" || argument == "-t" || argument == "-L" {
                skipNext = true
                continue
            }
            if argument.hasPrefix("-") { continue }
            return argument
        }
        return nil
    }

    /// Explicit, deterministic policy used by both production execution and
    /// tests. Keeping this separate from wall-clock behavior means USB watcher
    /// responsiveness is a contract, not a latency threshold vulnerable to CI
    /// scheduler noise.
    nonisolated static func executionPolicy(for arguments: [String]) -> ExecutionPolicy {
        guard let command = commandWord(in: arguments),
              serializedCommands.contains(command)
        else { return .concurrent }
        return .serialized
    }

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval? = nil) -> String {
        let command = Self.commandWord(in: arguments)
        let output: String
        if Self.executionPolicy(for: arguments) == .serialized {
            Self.commandLock.lock()
            output = Tooling.run("adb", arguments: arguments, timeout: timeout)
            Self.commandLock.unlock()
        } else {
            output = Tooling.run("adb", arguments: arguments, timeout: timeout)
        }
        if command == "kill-server" {
            Self.invalidateServerPrime()
        }
        return output
    }

    /// Executes adb while preserving its process result. Readiness checks must
    /// prove success from the exit status and timeout bit, not infer it from
    /// the absence of an error substring in merged output.
    func runResult(_ arguments: [String], timeout: TimeInterval? = nil) -> Tooling.RunResult {
        let command = Self.commandWord(in: arguments)
        let result: Tooling.RunResult
        if Self.executionPolicy(for: arguments) == .serialized {
            Self.commandLock.lock()
            result = Tooling.runResult("adb", arguments: arguments, timeout: timeout)
            Self.commandLock.unlock()
        } else {
            result = Tooling.runResult("adb", arguments: arguments, timeout: timeout)
        }
        if command == "kill-server" {
            Self.invalidateServerPrime()
        }
        return result
    }

    /// Starts adb if needed without killing existing USB or Wi-Fi transports.
    /// Use this before normal connect/pair flows. A cold start can take a few
    /// seconds, so it must not be interrupted mid-spawn.
    func ensureServerStarted() async {
        await Self.sharedServerPrimeTask(for: self).value
    }

    /// Single-flight prewarm of the adb daemon, shared by the device watcher
    /// and connection workflows. Bonjour discovery is intentionally independent
    /// so network presence can surface while a cold adb daemon is starting.
    /// Concurrent adb callers await the *same* start rather than racing their
    /// own daemon processes.
    private static let serverPrimeLock = NSLock()
    nonisolated(unsafe) private static var serverPrimeTask: Task<Void, Never>?
    nonisolated(unsafe) private static var serverPrimeInFlight = false
    nonisolated(unsafe) private static var serverPrimeCompletedAt: Date?
    /// Reuse a just-completed warm-up across launch, discovery, and reconnect.
    /// Later connection work still refreshes adb normally, and `kill-server`
    /// invalidates this state immediately.
    nonisolated static let serverPrimeReuseWindow: TimeInterval = 2

    private static func finishServerPrime() {
        serverPrimeLock.lock()
        serverPrimeInFlight = false
        serverPrimeCompletedAt = Date()
        serverPrimeLock.unlock()
    }

    private static func invalidateServerPrime() {
        serverPrimeLock.lock()
        serverPrimeTask = nil
        serverPrimeInFlight = false
        serverPrimeCompletedAt = nil
        serverPrimeLock.unlock()
    }

    /// Synchronous so the lock is never held across a suspension point.
    private static func sharedServerPrimeTask(for controller: ADBController) -> Task<Void, Never> {
        serverPrimeLock.lock()
        defer { serverPrimeLock.unlock() }
        if serverPrimeInFlight, let existing = serverPrimeTask {
            return existing
        }
        if let completedAt = serverPrimeCompletedAt,
           Date().timeIntervalSince(completedAt) < serverPrimeReuseWindow,
           let existing = serverPrimeTask {
            return existing
        }
        serverPrimeInFlight = true
        let task = Task.detached(priority: .userInitiated) {
            let startedAt = DispatchTime.now().uptimeNanoseconds
            _ = controller.run(["start-server"], timeout: 6)
            let elapsedMilliseconds = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            Logger.log("ADB server prime phase=started duration_ms=\(elapsedMilliseconds)")
            Self.finishServerPrime()
        }
        serverPrimeTask = task
        return task
    }

    func primeServerIfNeeded() async {
        await Self.sharedServerPrimeTask(for: self).value
    }

    /// When Bonjour is unavailable, `adb mdns services` is the first fallback.
    /// Keep it bounded so a wedged daemon cannot stall the fallback cycle.
    nonisolated static let mdnsServicesTimeout: TimeInterval = 2

    func mdnsServices() -> [DiscoveredPhone] {
        let snapshot = BonjourServiceMonitor.shared.serviceSnapshot()
        switch snapshot {
        case .available(let services):
            // Resolution completion emits a wake event, so a newly-seen
            // service does not need either a one-second poll delay or an adb
            // subprocess on this path.
            return Self.resolvedPhones(for: services)

        case .warming:
            // Do not launch the three sequential legacy dns-sd sweeps while
            // NWBrowser is merely starting. Its ready/result event wakes the
            // discovery service immediately, usually within the same second.
            return []

        case .unavailable:
            break
        }

        let adbPhones = Self.parseMDNSServices(
            run(["mdns", "services"], timeout: Self.mdnsServicesTimeout)
        )
        guard adbPhones.isEmpty else { return adbPhones }
        return Self.rateLimitedDNSServiceDiscoveredPhones()
    }

    /// The `dns-sd` fallback spawns (and timeout-kills) one process per service
    /// type plus one per resolve — ~3s of process churn per call. The discovery
    /// poller calls every second whenever `adb mdns services` comes back empty
    /// (the idle no-phone state), so cache the fallback result briefly instead
    /// of re-browsing the network on every poll.
    nonisolated static let dnsSDFallbackCacheWindow: TimeInterval = 4
    private static let dnsSDFallbackLock = NSLock()
    nonisolated(unsafe) private static var dnsSDFallbackFetchedAt: Date?
    nonisolated(unsafe) private static var dnsSDFallbackPhones: [DiscoveredPhone] = []

    static func rateLimitedDNSServiceDiscoveredPhones(now: Date = Date()) -> [DiscoveredPhone] {
        // Fast path: the persistent Bonjour browsers already know what's
        // advertised, so a newly appearing phone is seen on the next 1s poll
        // instead of after the legacy sweep's 4s cache + ~4s browse windows.
        // Only *resolution* to host:port may still shell out, once per newly
        // seen service.
        if let services = BonjourServiceMonitor.shared.currentServices() {
            return resolvedPhones(for: services, now: now)
        }

        // Legacy sweep — only when a persistent browser failed outright.
        dnsSDFallbackLock.lock()
        if let fetchedAt = dnsSDFallbackFetchedAt,
           now.timeIntervalSince(fetchedAt) < dnsSDFallbackCacheWindow {
            let cached = dnsSDFallbackPhones
            dnsSDFallbackLock.unlock()
            return cached
        }
        dnsSDFallbackLock.unlock()

        let phones = dnsServiceDiscoveredPhones()
        dnsSDFallbackLock.lock()
        dnsSDFallbackFetchedAt = now
        dnsSDFallbackPhones = phones
        dnsSDFallbackLock.unlock()
        return phones
    }

    // MARK: - Browser-backed resolve cache

    /// Resolved `host:port` per advertised service, kept until the service
    /// stops advertising — so steady state costs zero process spawns per poll.
    /// Dropping the entry on disappearance means a phone that comes back on a
    /// new IP re-resolves fresh.
    private static let resolveCacheLock = NSLock()
    nonisolated(unsafe) private static var resolvedPhonesByService: [DNSService: DiscoveredPhone] = [:]
    nonisolated(unsafe) private static var failedResolveAt: [DNSService: Date] = [:]
    /// Services with a resolve currently running off-poll, so a 1s poll can't
    /// queue a second `dns-sd -L` for a service already being resolved.
    nonisolated(unsafe) private static var resolvesInFlight: Set<DNSService> = []
    /// Last known advertised set, so an off-poll resolve that lands after its
    /// service stopped advertising is discarded instead of surfacing a phone
    /// that is already gone (and inviting a connect to a dead address).
    nonisolated(unsafe) private static var advertisedServices: Set<DNSService> = []
    /// Failed resolves retry on this cadence rather than every 1s poll.
    nonisolated static let resolveRetryInterval: TimeInterval = 5

    /// Every `dns-sd -L` spawn runs here, never on the discovery poll. New
    /// service types resolve concurrently, bounded by Bonjour's three adb
    /// types, so a phone advertising both TLS and legacy endpoints is not
    /// serialized behind several one-second resolver windows.
    private static let resolveQueue = DispatchQueue(
        label: "phonerelay.discovery.resolve",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Event-driven discovery wakeups

    private static let discoveryObserverLock = NSLock()
    nonisolated(unsafe) private static var discoveryObservers: [UUID: @Sendable () -> Void] = [:]

    static func addDiscoveryObserver(
        _ observer: @escaping @Sendable () -> Void
    ) -> UUID {
        let id = UUID()
        discoveryObserverLock.lock()
        discoveryObservers[id] = observer
        discoveryObserverLock.unlock()
        return id
    }

    static func removeDiscoveryObserver(_ id: UUID) {
        discoveryObserverLock.lock()
        discoveryObservers.removeValue(forKey: id)
        discoveryObserverLock.unlock()
    }

    static func notifyDiscoveryObservers() {
        discoveryObserverLock.lock()
        let observers = Array(discoveryObservers.values)
        discoveryObserverLock.unlock()
        observers.forEach { $0() }
    }

    nonisolated static func defaultResolveScheduler(_ work: @escaping @Sendable () -> Void) {
        resolveQueue.async(execute: work)
    }

    @Sendable
    nonisolated static func defaultServiceResolver(_ service: DNSService) -> DiscoveredPhone? {
        let resolved = Tooling.runResult(
            "dns-sd",
            arguments: ["-L", service.instance, service.serviceType, "local"],
            timeout: 1
        )
        return parseDNSServiceResolveOutput(
            resolved.output,
            instance: service.instance,
            serviceType: service.serviceType
        )
    }

    /// Returns only what is already resolved, and schedules resolution of
    /// anything new off-poll. Never blocks the caller on a `dns-sd` spawn.
    static func resolvedPhones(
        for services: [DNSService],
        now: Date = Date(),
        resolve: @escaping @Sendable (DNSService) -> DiscoveredPhone? = defaultServiceResolver,
        schedule: (@escaping @Sendable () -> Void) -> Void = defaultResolveScheduler
    ) -> [DiscoveredPhone] {
        let current = Set(services)
        resolveCacheLock.lock()
        advertisedServices = current
        // Forget services that stopped advertising so their return re-resolves.
        resolvedPhonesByService = resolvedPhonesByService.filter { current.contains($0.key) }
        failedResolveAt = failedResolveAt.filter { current.contains($0.key) }
        resolveCacheLock.unlock()

        var phones: [DiscoveredPhone] = []
        var pending: [DNSService] = []
        for service in services {
            resolveCacheLock.lock()
            let cached = resolvedPhonesByService[service]
            let lastFailure = failedResolveAt[service]
            let isInFlight = resolvesInFlight.contains(service)
            if cached == nil,
               !isInFlight,
               !(lastFailure.map { now.timeIntervalSince($0) < resolveRetryInterval } ?? false) {
                resolvesInFlight.insert(service)
                pending.append(service)
            }
            resolveCacheLock.unlock()

            if var phone = cached {
                phone.lastSeen = now
                phones.append(phone)
            }
        }

        for service in pending {
            schedule {
                let resolved = resolve(service)
                var didChange = false
                resolveCacheLock.lock()
                resolvesInFlight.remove(service)
                // Dropped from the advertised set while we were resolving —
                // discard rather than surface a phone that has gone away.
                if advertisedServices.contains(service) {
                    if let resolved {
                        resolvedPhonesByService[service] = resolved
                        failedResolveAt.removeValue(forKey: service)
                        didChange = true
                    } else {
                        failedResolveAt[service] = now
                    }
                }
                resolveCacheLock.unlock()
                if didChange {
                    notifyDiscoveryObservers()
                }
            }
        }

        return dedupeMDNSPhones(phones)
    }

    #if DEBUG
    static func resetResolveCacheForTesting() {
        resolveCacheLock.lock()
        resolvedPhonesByService = [:]
        failedResolveAt = [:]
        resolvesInFlight = []
        advertisedServices = []
        resolveCacheLock.unlock()
    }
    #endif

    func connectableMDNSTargets() -> [DiscoveredPhone] {
        mdnsServices().filter { $0.kind.isConnectable }
    }

    /// Parses `adb mdns services` output into a deduped list of phones.
    /// If both pairing and connect services exist for the same instance,
    /// keep the connect entry (more useful for the UI).
    static func parseMDNSServices(_ output: String) -> [DiscoveredPhone] {
        var byID: [String: DiscoveredPhone] = [:]
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.lowercased().hasPrefix("list of"),
                  !trimmed.lowercased().contains("error") else { continue }
            let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 3,
                  let address = parts.last,
                  address.contains(":") else { continue }
            let instance = parts[0]
            let typeField = parts.dropFirst().joined(separator: " ")
            let kind: DiscoveredPhone.Kind?
            if typeField.contains("_adb-tls-pairing._tcp") {
                kind = .pairable
            } else if typeField.contains("_adb-tls-connect._tcp") {
                kind = .wirelessDebugging
            } else if typeField.contains("_adb._tcp") {
                // Legacy `adb tcpip 5555` mode — no pairing required.
                kind = .legacyTCPIP
            } else {
                kind = nil
            }
            guard let kind else { continue }
            let phone = DiscoveredPhone(
                id: instance,
                address: address,
                kind: kind,
                lastSeen: .now
            )
            if let existing = byID[instance] {
                if existing.kind == .pairable && kind.isConnectable {
                    byID[instance] = phone
                }
            } else {
                byID[instance] = phone
            }
        }
        return byID.values.sorted(by: { $0.id < $1.id })
    }

    struct DNSService: Equatable, Hashable {
        var instance: String
        var serviceType: String
    }

    static func dnsServiceDiscoveredPhones() -> [DiscoveredPhone] {
        let serviceTypes = [
            "_adb-tls-connect._tcp",
            "_adb._tcp",
            "_adb-tls-pairing._tcp"
        ]
        var phones: [DiscoveredPhone] = []

        for serviceType in serviceTypes {
            let browse = Tooling.runResult(
                "dns-sd",
                arguments: ["-B", serviceType, "local"],
                timeout: 1
            )
            let services = parseDNSServiceBrowseOutput(browse.output, serviceType: serviceType)
            for service in services {
                let resolved = Tooling.runResult(
                    "dns-sd",
                    arguments: ["-L", service.instance, service.serviceType, "local"],
                    timeout: 1
                )
                if let phone = parseDNSServiceResolveOutput(
                    resolved.output,
                    instance: service.instance,
                    serviceType: service.serviceType
                ) {
                    phones.append(phone)
                }
            }
        }

        return dedupeMDNSPhones(phones)
    }

    static func parseDNSServiceBrowseOutput(_ output: String, serviceType: String) -> [DNSService] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.contains(" Add "),
                  line.contains(serviceType)
            else { return nil }

            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let typeIndex = parts.firstIndex(where: { $0 == "\(serviceType)." || $0 == serviceType }),
                  typeIndex + 1 < parts.count
            else { return nil }
            let instance = parts[(typeIndex + 1)...].joined(separator: " ")
            guard !instance.isEmpty else { return nil }
            return DNSService(instance: instance, serviceType: serviceType)
        }
    }

    static func parseDNSServiceResolveOutput(
        _ output: String,
        instance: String,
        serviceType: String
    ) -> DiscoveredPhone? {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = line.range(of: " can be reached at ") else { continue }
            let target = line[range.upperBound...]
                .split(whereSeparator: \.isWhitespace)
                .first
                .map(String.init) ?? ""
            guard let address = normalizedDNSServiceAddress(target), address.contains(":") else {
                continue
            }
            return DiscoveredPhone(
                id: instance,
                address: address,
                kind: Self.discoveredPhoneKind(forServiceType: serviceType),
                lastSeen: .now
            )
        }
        return nil
    }

    static func normalizedDNSServiceAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.lastIndex(of: ":") else { return nil }
        var host = String(trimmed[..<colon])
        let port = String(trimmed[trimmed.index(after: colon)...])
        while host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty, !port.isEmpty else { return nil }
        return "\(host):\(port)"
    }

    private static func dedupeMDNSPhones(_ phones: [DiscoveredPhone]) -> [DiscoveredPhone] {
        var byID: [String: DiscoveredPhone] = [:]
        for phone in phones {
            if let existing = byID[phone.id] {
                if existing.kind == .pairable && phone.kind.isConnectable {
                    byID[phone.id] = phone
                }
            } else {
                byID[phone.id] = phone
            }
        }
        return byID.values.sorted(by: { $0.id < $1.id })
    }

    private static func discoveredPhoneKind(forServiceType serviceType: String) -> DiscoveredPhone.Kind {
        if serviceType == "_adb-tls-pairing._tcp" {
            return .pairable
        }
        if serviceType == "_adb._tcp" {
            return .legacyTCPIP
        }
        return .wirelessDebugging
    }
}

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
        guard Self.executionPolicy(for: arguments) == .serialized else {
            return Tooling.run("adb", arguments: arguments, timeout: timeout)
        }
        Self.commandLock.lock()
        defer { Self.commandLock.unlock() }
        return Tooling.run("adb", arguments: arguments, timeout: timeout)
    }

    /// Starts adb if needed without killing existing USB or Wi-Fi transports.
    /// Use this before normal connect/pair flows. A cold start can take a few
    /// seconds, so it must not be interrupted mid-spawn.
    func ensureServerStarted() async {
        // A cold `adb start-server` regularly takes longer than 2s; killing it
        // mid-spawn left connect flows racing a half-started daemon.
        _ = await Task.detached(priority: .userInitiated) {
            self.run(["start-server"], timeout: 6)
        }.value
    }

    /// Single-flight prewarm of the adb daemon, shared by every background
    /// poller. Without it the first `adb devices -l` after launch is killed at
    /// its 2s timeout while a cold `start-server` is still spawning, and the
    /// first few `adb mdns services` polls answer from an empty backend — the
    /// phone only shows up seconds later. Concurrent callers await the *same*
    /// start rather than each racing their own.
    private static let serverPrimeLock = NSLock()
    nonisolated(unsafe) private static var serverPrimeTask: Task<Void, Never>?

    /// Synchronous so the lock is never held across a suspension point.
    private static func sharedServerPrimeTask(for controller: ADBController) -> Task<Void, Never> {
        serverPrimeLock.lock()
        defer { serverPrimeLock.unlock() }
        if let existing = serverPrimeTask { return existing }
        let task = Task.detached(priority: .userInitiated) {
            _ = controller.run(["start-server"], timeout: 6)
        }
        serverPrimeTask = task
        return task
    }

    func primeServerIfNeeded() async {
        await Self.sharedServerPrimeTask(for: self).value
    }

    /// `adb mdns services` sits on the 1s discovery poll's critical path, so it
    /// gets an explicit short timeout instead of Tooling's 5s adb default. A
    /// wedged daemon used to stretch a "1 second" poll cycle past 6s.
    nonisolated static let mdnsServicesTimeout: TimeInterval = 2

    func mdnsServices() -> [DiscoveredPhone] {
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

    /// Every `dns-sd -L` spawn runs here, never on the discovery poll. A first
    /// sighting therefore costs one extra poll (~1s) instead of blocking the
    /// poll for up to 1s per unresolved service — three service types for one
    /// phone used to add ~3s to the cycle that first saw it.
    private static let resolveQueue = DispatchQueue(
        label: "phonerelay.discovery.resolve",
        qos: .utility
    )

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
                resolveCacheLock.lock()
                resolvesInFlight.remove(service)
                // Dropped from the advertised set while we were resolving —
                // discard rather than surface a phone that has gone away.
                if advertisedServices.contains(service) {
                    if let resolved {
                        resolvedPhonesByService[service] = resolved
                        failedResolveAt.removeValue(forKey: service)
                    } else {
                        failedResolveAt[service] = now
                    }
                }
                resolveCacheLock.unlock()
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

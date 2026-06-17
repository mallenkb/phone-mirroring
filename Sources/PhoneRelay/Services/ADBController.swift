import Foundation

/// Thin wrapper around the `adb` CLI. All methods are blocking — call them
/// from a detached Task and route results back via @MainActor.
struct ADBController: Sendable {
    private static let commandLock = NSLock()

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

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval? = nil) -> String {
        guard let command = Self.commandWord(in: arguments),
              Self.serializedCommands.contains(command)
        else {
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

    func mdnsServices() -> [DiscoveredPhone] {
        let adbPhones = Self.parseMDNSServices(run(["mdns", "services"]))
        guard adbPhones.isEmpty else { return adbPhones }
        return Self.dnsServiceDiscoveredPhones()
    }

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

import Foundation
import Network

/// Finds a paired phone's current Wi-Fi address after its IP has changed.
///
/// The remembered `host:port` goes stale the moment the phone gets a new DHCP
/// lease, and mDNS only helps when Wireless debugging is advertising. This
/// recovers the new IP on the local network using a stable anchor:
///
///   1. Sweep the local IPv4 subnet with short TCP probes to port 5555. This
///      both reveals which hosts speak adb *and* makes the kernel resolve every
///      reachable host's MAC into the ARP cache.
///   2. Primary match: the phone's saved Wi-Fi MAC (persistent per-SSID on
///      Android) against the ARP table → its current IP.
///   3. Fallback: for hosts with 5555 open, `adb connect` + `getprop` and match
///      the serial / model — covers phones whose MAC we never captured or whose
///      MAC randomizes.
///
/// Pure helpers are split out so the matching logic is unit-testable without
/// touching the network.
enum WiFiAddressRecovery {
    static let defaultPort = 5555
    static let defaultProbeTimeout: TimeInterval = 0.7
    /// Each probe is a single lightweight TCP SYN that spends almost all of its
    /// life idle-waiting on the 0.7s timeout, so the sweep is I/O-bound, not
    /// CPU-bound — a high fan-out just shrinks wall-clock time. This matters now
    /// that recovery expands to the interface's full netmask: a `/22` mesh LAN is
    /// ~1000 hosts, which at the old fan-out of 32 took ~20s (≈8 timeout waves per
    /// `/24` × 4 subnets) and routinely blew the reconnect time budget. 128 keeps
    /// peak open sockets well under the default file-descriptor limit while
    /// bringing a `/22` down to a few seconds.
    static let defaultConcurrency = 128
    /// Caps how many `/24` slices one interface's netmask may expand to. The
    /// mesh-LAN `/22` (4 slices) is the intended worst case; anything larger —
    /// a corporate `/16`, or the self-assigned `169.254/16` a Mac puts on idle
    /// bridge/Ethernet interfaces — would mean tens of thousands of probes and
    /// a sweep measured in minutes, so those interfaces fall back to their own
    /// `/24` instead.
    static let maxPrefixesPerInterface = 8
    /// Hard ceiling on `/24` prefixes per recovery run across all interfaces
    /// (priority order keeps the last-known subnet first), bounding a full
    /// sweep to ~2k hosts ≈ a few seconds at the default fan-out.
    static let maxTotalPrefixes = 8

    /// What we know about the phone we're hunting for.
    struct Target {
        var macAddress: String?
        var usbSerial: String?
        var displayName: String
        var lastKnownIP: String?
    }

    /// Resolves the phone's current `host:port`, or nil if it can't be found on
    /// the local network. The returned address is *not* yet verified as
    /// adb-ready — the caller should run its normal readiness probe.
    static func recover(
        adb: ADBController,
        target: Target,
        port: Int = defaultPort,
        sweep: ((_ hosts: [String]) async -> [String])? = nil,
        readARP: (() -> [String: String])? = nil,
        localSubnets: (() -> [String])? = nil
    ) async -> String? {
        let prefixes = Array(
            subnetPrefixes(
                lastKnownIP: target.lastKnownIP,
                localSubnets: (localSubnets ?? Self.localIPv4Subnets)()
            ).prefix(maxTotalPrefixes)
        )
        guard !prefixes.isEmpty else {
            Logger.log("Wi-Fi recovery: no candidate IPv4 subnet to scan")
            return nil
        }

        let runSweep = sweep ?? { hostList in
            await sweepForOpenPort(hostList, port: port)
        }
        let readARPTable = readARP ?? Self.readARPTable

        // Sweep one prefix at a time, last-known subnet first, checking the
        // stable MAC anchor after each slice — the phone usually keeps its
        // old /24, so this returns in one slice instead of paying for the
        // whole LAN before the first ARP lookup.
        var openHosts: [String] = []
        var scannedHosts = 0
        for (index, prefix) in prefixes.enumerated() {
            let hosts = subnetHosts(prefix: prefix)
            scannedHosts += hosts.count
            openHosts.append(contentsOf: await runSweep(hosts))
            let arp = readARPTable()
            if let ip = matchIP(forMAC: target.macAddress, in: arp, preferring: Set(openHosts)) {
                Logger.log("Wi-Fi recovery: MAC \(target.macAddress ?? "?") resolved to \(ip) after \(index + 1)/\(prefixes.count) subnet(s)")
                return "\(ip):\(port)"
            }
        }
        Logger.log("Wi-Fi recovery: scanned \(scannedHosts) hosts across \(prefixes.count) subnet(s); \(openHosts.count) with :\(port) open, no MAC match")

        // Fallback: confirm by adb identity on the hosts that answer on 5555.
        if let ip = await matchByADBIdentity(adb: adb, openHosts: openHosts, target: target, port: port) {
            Logger.log("Wi-Fi recovery: adb identity matched \(target.displayName) at \(ip)")
            return "\(ip):\(port)"
        }

        Logger.log("Wi-Fi recovery: no match for \(target.displayName)")
        return nil
    }

    // MARK: - Subnet math (pure)

    /// Candidate `/24` prefixes to scan, last-known subnet first, then the Mac's
    /// own LAN subnets expanded from their real netmasks. Deduped, preserving
    /// priority order.
    static func subnetPrefixes(lastKnownIP: String?, localSubnets: [String]) -> [String] {
        var prefixes: [String] = []
        func add(_ prefix: String?) {
            guard let prefix, !prefixes.contains(prefix) else { return }
            prefixes.append(prefix)
        }
        add(lastKnownIP.flatMap(ipv4Host(in:)).flatMap(subnetPrefix(forIPv4:)))
        localSubnets.forEach(add)
        return prefixes
    }

    /// "192.168.1.42" → "192.168.1." ; nil for non-IPv4 input.
    static func subnetPrefix(forIPv4 ip: String) -> String? {
        guard isIPv4(ip) else { return nil }
        let octets = ip.split(separator: ".")
        return octets.dropLast().joined(separator: ".") + "."
    }

    /// All host addresses .1–.254 for a "a.b.c." prefix.
    static func subnetHosts(prefix: String) -> [String] {
        (1...254).map { "\(prefix)\($0)" }
    }

    /// Expands an interface address/netmask into the `/24` prefixes it covers.
    /// A common mesh LAN such as `192.168.68.54/22` spans `.68` through `.71`;
    /// scanning only the host's own `/24` would miss a phone that DHCP moved to
    /// a neighboring slice of the same LAN.
    static func subnetPrefixes(forIPv4 ip: String, netmask: String) -> [String] {
        guard let address = IPv4Address(ip), let mask = IPv4Address(netmask) else { return [] }
        let maskValue = mask.value
        let network = address.value & maskValue
        let broadcast = network | ~maskValue
        guard broadcast > network else { return [] }

        var prefixes: [String] = []
        var current = network
        while current <= broadcast {
            if let prefix = subnetPrefix(forIPv4: IPv4Address(current).string), !prefixes.contains(prefix) {
                prefixes.append(prefix)
            }
            let next = (current & 0xffff_ff00) + 0x100
            if next <= current { break }
            current = next
        }
        return prefixes
    }

    /// Strips an optional `:port` from an IPv4 address. Returns nil if the host
    /// part isn't IPv4 (e.g. an IPv6 literal or an `adb-…` mDNS instance).
    static func ipv4Host(in address: String) -> String? {
        let host = address.split(separator: ":").first.map(String.init) ?? address
        return isIPv4(host) ? host : nil
    }

    static func isIPv4(_ string: String) -> Bool {
        let octets = string.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard octet.count >= 1, octet.count <= 3, octet.allSatisfy(\.isNumber),
                  let value = Int(octet) else { return false }
            return (0...255).contains(value)
        }
    }

    // MARK: - Matching (pure)

    /// The IP whose ARP entry equals the target MAC. When several map to the
    /// same MAC (rare), an open-on-5555 host wins.
    static func matchIP(forMAC mac: String?, in arp: [String: String], preferring openHosts: Set<String>) -> String? {
        guard let mac = PairedPhoneRecord.normalizedMACAddress(mac) else { return nil }
        let matches = arp.filter { $0.value == mac }.map(\.key)
        guard !matches.isEmpty else { return nil }
        return matches.first(where: openHosts.contains) ?? matches.sorted().first
    }

    /// Parses `arp -a -n` into an ip→mac map, skipping incomplete entries.
    /// Sample line: `? (192.168.1.10) at 8c:85:90:1a:2b:3c on en0 ifscope [ethernet]`
    static func parseARPTable(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let openParen = line.firstIndex(of: "("),
                  let closeParen = line.firstIndex(of: ")"),
                  openParen < closeParen else { continue }
            let ip = String(line[line.index(after: openParen)..<closeParen])
            guard isIPv4(ip) else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let atIndex = parts.firstIndex(of: "at"),
                  parts.indices.contains(atIndex + 1),
                  let mac = PairedPhoneRecord.normalizedMACAddress(parts[atIndex + 1])
            else { continue }
            map[ip] = mac
        }
        return map
    }

    // MARK: - Network side effects

    static func readARPTable() -> [String: String] {
        parseARPTable(Tooling.run("arp", arguments: ["-a", "-n"], timeout: 3))
    }

    static func localIPv4Subnets() -> [String] {
        var subnets: [String] = []
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0 else { return [] }
        defer { freeifaddrs(ifaddrPointer) }

        var cursor = ifaddrPointer
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let flags = Int32(interface.pointee.ifa_flags)
            // Up, not loopback, and broadcast-capable — the last test skips
            // point-to-point VPN tunnels (utun) that aren't a LAN we can sweep.
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  (flags & IFF_BROADCAST) == IFF_BROADCAST,
                  let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address, socklen_t(address.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let hostAddress = String(cString: host)
            // Self-assigned link-local (Thunderbolt bridge, idle Ethernet):
            // a phone's adb listener never lives there, and its /16 netmask
            // would expand to a 65k-host sweep.
            guard !hostAddress.hasPrefix("169.254.") else { continue }
            var maskHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let maskResult = interface.pointee.ifa_netmask.map {
                getnameinfo(
                    $0, socklen_t($0.pointee.sa_len),
                    &maskHost, socklen_t(maskHost.count),
                    nil, 0, NI_NUMERICHOST
                )
            } ?? -1

            var prefixes: [String]
            if maskResult == 0 {
                prefixes = subnetPrefixes(forIPv4: hostAddress, netmask: String(cString: maskHost))
            } else {
                prefixes = subnetPrefix(forIPv4: hostAddress).map { [$0] } ?? []
            }
            // A netmask wider than the mesh-LAN case can't be swept in useful
            // time — keep just the interface's own /24, where DHCP is most
            // likely to have kept the phone anyway.
            if prefixes.count > maxPrefixesPerInterface {
                prefixes = subnetPrefix(forIPv4: hostAddress).map { [$0] } ?? []
            }
            for prefix in prefixes where !subnets.contains(prefix) {
                subnets.append(prefix)
            }
        }
        return subnets
    }

    /// Probes `hosts` for an open TCP port with bounded concurrency, returning
    /// the ones that answered. The probe attempts populate the ARP cache as a
    /// side effect (the kernel resolves each reachable host's MAC to send SYNs).
    static func sweepForOpenPort(
        _ hosts: [String],
        port: Int = defaultPort,
        concurrency: Int = defaultConcurrency,
        timeout: TimeInterval = defaultProbeTimeout,
        probe: (@Sendable (String, Int, TimeInterval) async -> Bool)? = nil
    ) async -> [String] {
        guard !hosts.isEmpty else { return [] }
        let runProbe = probe ?? { host, port, timeout in await isPortOpen(host: host, port: port, timeout: timeout) }
        var openHosts: [String] = []
        var nextIndex = 0

        await withTaskGroup(of: (String, Bool).self) { group in
            func enqueueNext() {
                guard nextIndex < hosts.count else { return }
                let host = hosts[nextIndex]
                nextIndex += 1
                group.addTask { (host, await runProbe(host, port, timeout)) }
            }
            for _ in 0..<min(concurrency, hosts.count) { enqueueNext() }
            for await (host, isOpen) in group {
                if isOpen { openHosts.append(host) }
                enqueueNext()
            }
        }
        return openHosts
    }

    /// One TCP connection attempt with a hard timeout. `.ready` = open; refused,
    /// failed, or timed-out = closed. Either way the SYN has triggered ARP.
    static func isPortOpen(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "WiFiAddressRecovery.probe")
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let settled = OnceFlag()
            let finish: @Sendable (Bool) -> Void = { open in
                guard settled.set() else { return }
                connection.cancel()
                continuation.resume(returning: open)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled, .waiting:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Connects to each open host and matches its adb identity to the target.
    /// Non-matches are disconnected so we don't leave stray transports behind.
    private static func matchByADBIdentity(
        adb: ADBController,
        openHosts: [String],
        target: Target,
        port: Int
    ) async -> String? {
        // The hardware serial (`ro.serialno`) is the reliable anchor — it equals
        // the USB serial. A device *name* only disambiguates when it's specific,
        // never a generic "Android device".
        let wantedSerial = (target.usbSerial?.isEmpty == false) ? target.usbSerial : nil
        let wantedName = PairedPhoneStore.isSpecificDeviceName(target.displayName)
            ? PairedPhoneStore.normalizedDeviceName(target.displayName)
            : nil
        guard wantedSerial != nil || wantedName != nil else { return nil }

        for host in openHosts {
            let address = "\(host):\(port)"
            let matched = await Task.detached(priority: .utility) { () -> Bool in
                let connectOutput = adb.run(["connect", address], timeout: 4)
                guard AppModel.adbConnectSucceeded(connectOutput) else {
                    adb.run(["disconnect", address], timeout: 2)
                    return false
                }
                let serial = adb.run(["-s", address, "shell", "getprop", "ro.serialno"], timeout: 3)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let model = adb.run(["-s", address, "shell", "getprop", "ro.product.model"], timeout: 3)
                let serialMatches = wantedSerial.map { $0 == serial } ?? false
                let nameMatches = wantedName.map { PairedPhoneStore.normalizedDeviceName(model) == $0 } ?? false
                if serialMatches || nameMatches {
                    return true
                }
                adb.run(["disconnect", address], timeout: 2)
                return false
            }.value
            if matched { return host }
        }
        return nil
    }
}

private struct IPv4Address {
    var value: UInt32

    init?(_ string: String) {
        let octets = string.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard let part = UInt32(octet), part <= 255 else { return nil }
            value = (value << 8) | part
        }
        self.value = value
    }

    init(_ value: UInt32) {
        self.value = value
    }

    var string: String {
        [
            (value >> 24) & 0xff,
            (value >> 16) & 0xff,
            (value >> 8) & 0xff,
            value & 0xff,
        ].map(String.init).joined(separator: ".")
    }
}

/// Single-fire latch so a continuation resumes exactly once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}

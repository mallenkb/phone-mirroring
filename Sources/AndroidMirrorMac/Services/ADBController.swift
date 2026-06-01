import Foundation

/// Thin wrapper around the `adb` CLI. All methods are blocking — call them
/// from a detached Task and route results back via @MainActor.
struct ADBController {
    private static let connectLock = NSLock()

    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval? = nil) -> String {
        if arguments.first == "connect" {
            Self.connectLock.lock()
            defer { Self.connectLock.unlock() }
            return Tooling.run("adb", arguments: arguments, timeout: timeout)
        }
        return Tooling.run("adb", arguments: arguments, timeout: timeout)
    }

    @discardableResult
    func runInteractive(_ arguments: [String], input: String) -> String {
        Tooling.runInteractive("adb", arguments: arguments, input: input)
    }

    /// Bounce the adb server. A stale daemon caches "No route to host"
    /// failures across networks, so we restart before connect/pair flows.
    func restartServer() async {
        run(["kill-server"])
        try? await Task.sleep(nanoseconds: 400_000_000)
        run(["start-server"])
    }

    func mdnsServices() -> [DiscoveredPhone] {
        Self.parseMDNSServices(run(["mdns", "services"]))
    }

    func connectableMDNSTargets() -> [DiscoveredPhone] {
        mdnsServices().filter { $0.kind == .connectable }
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
                kind = .connectable
            } else if typeField.contains("_adb._tcp") {
                // Legacy `adb tcpip 5555` mode — no pairing required.
                kind = .connectable
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
                if existing.kind == .pairable && kind == .connectable {
                    byID[instance] = phone
                }
            } else {
                byID[instance] = phone
            }
        }
        return byID.values.sorted(by: { $0.id < $1.id })
    }
}

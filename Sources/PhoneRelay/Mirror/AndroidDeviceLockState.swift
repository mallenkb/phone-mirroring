import Foundation

enum AndroidDeviceLockState: Equatable {
    case locked
    case unlocked
    case unknown
}

/// Reads Android's keyguard state over the mirror session's existing ADB
/// transport. ADB's `-s` selector accepts both physical USB serials and
/// wireless `host:port` serials, so the probe is transport-neutral.
struct AndroidDeviceLockStateProbe {
    nonisolated static let pollingIntervalNanoseconds: UInt64 = 1_000_000_000

    nonisolated static func adbArguments(serial: String?) -> [String] {
        var arguments: [String] = []
        if let serial, !serial.isEmpty {
            arguments += ["-s", serial]
        }
        arguments += ["shell", "dumpsys", "window", "policy"]
        return arguments
    }

    nonisolated static func parse(_ output: String) -> AndroidDeviceLockState {
        let fields = output
            .split(whereSeparator: \Character.isNewline)
            .map { line in
                line
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: " ", with: "")
                    .lowercased()
            }

        // Prefer KeyguardStateMonitor's value when available. Samsung and
        // AOSP builds both expose this field, while nearby fields such as
        // `showingAndNotOccluded` are not the lock state and must be ignored.
        for key in ["misshowing", "iskeyguardshowing", "mshowinglockscreen", "showing"] {
            let values = fields.compactMap { field -> Bool? in
                guard field.hasPrefix("\(key)=") else { return nil }
                let value = field.dropFirst(key.count + 1)
                if value.hasPrefix("true") { return true }
                if value.hasPrefix("false") { return false }
                return nil
            }
            if values.contains(true) { return .locked }
            if values.contains(false) { return .unlocked }
        }

        return .unknown
    }

    nonisolated static func currentState(serial: String?) async -> AndroidDeviceLockState {
        let arguments = adbArguments(serial: serial)
        return await Task.detached(priority: .utility) {
            let output = Tooling.run("adb", arguments: arguments, timeout: 2)
            return parse(output)
        }.value
    }
}

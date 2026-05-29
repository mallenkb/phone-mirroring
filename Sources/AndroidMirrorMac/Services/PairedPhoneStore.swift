import Foundation

/// UserDefaults-backed persistence for paired phones. Equivalent to the
/// per-device record Bluetooth keeps between sessions.
struct PairedPhoneStore {
    private static let defaultsKey = "AndroidMirror.PairedPhones.v1"
    private static let compatibilitySuites = [
        "com.mallenkb.AndroidMirrorMac",
        "com.mallenkb.AndroidMirrorScrcpy",
        "local.androidmirrormac",
        "AndroidMirrorMac"
    ]
    private let primaryDefaults: UserDefaults
    private let suiteNames: [String]

    init(
        primaryDefaults: UserDefaults = .standard,
        suiteNames: [String] = Self.compatibilitySuites
    ) {
        self.primaryDefaults = primaryDefaults
        self.suiteNames = suiteNames
    }

    func load() -> [PairedPhoneRecord] {
        var storedRecords = records(in: primaryDefaults)

        for suite in suiteNames {
            guard let defaults = UserDefaults(suiteName: suite) else { continue }
            for record in records(in: defaults) where !storedRecords.contains(where: { existing in
                existing.id == record.id || existing.lastAddress == record.lastAddress
            }) {
                storedRecords.append(record)
            }
        }

        if !storedRecords.isEmpty {
            save(storedRecords)
        }

        return storedRecords
    }

    func save(_ records: [PairedPhoneRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        primaryDefaults.set(data, forKey: Self.defaultsKey)
        for suite in suiteNames {
            UserDefaults(suiteName: suite)?.set(data, forKey: Self.defaultsKey)
        }
    }

    func clearAll() {
        primaryDefaults.removeObject(forKey: Self.defaultsKey)
        for suite in suiteNames {
            UserDefaults(suiteName: suite)?.removeObject(forKey: Self.defaultsKey)
        }
    }

    func removing(_ id: PairedPhoneRecord.ID, from records: [PairedPhoneRecord]) -> [PairedPhoneRecord] {
        records.filter { $0.id != id }
    }

    private func records(in defaults: UserDefaults) -> [PairedPhoneRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([PairedPhoneRecord].self, from: data)
        else { return [] }
        return decoded
    }

    /// Returns the records with `id` inserted or refreshed.
    func touch(
        _ records: [PairedPhoneRecord],
        id: String,
        displayName: String,
        address: String,
        now: Date = .now
    ) -> [PairedPhoneRecord] {
        var updated = records
        if let idx = updated.firstIndex(where: { $0.id == id }) {
            updated[idx].displayName = displayName
            updated[idx].lastAddress = address
            updated[idx].lastConnected = now
        } else {
            updated.append(.init(
                id: id,
                displayName: displayName,
                lastAddress: address,
                firstPaired: now,
                lastConnected: now
            ))
        }
        return updated
    }
}

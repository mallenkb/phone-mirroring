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

        storedRecords = deduplicated(storedRecords)

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
        let matchingIndexes = matchingRecordIndexes(
            in: records,
            id: id,
            displayName: displayName,
            address: address
        )

        guard !matchingIndexes.isEmpty else {
            return records + [.init(
                id: id,
                displayName: displayName,
                lastAddress: address,
                firstPaired: now,
                lastConnected: now
            )]
        }

        let firstPaired = matchingIndexes
            .map { records[$0].firstPaired }
            .min() ?? now
        let refreshed = PairedPhoneRecord(
            id: id,
            displayName: displayName,
            lastAddress: address,
            firstPaired: firstPaired,
            lastConnected: now
        )

        return records.enumerated().compactMap { index, record in
            guard matchingIndexes.contains(index) else { return record }
            guard index == matchingIndexes[0] else { return nil }
            return refreshed
        }
    }

    private func deduplicated(_ records: [PairedPhoneRecord]) -> [PairedPhoneRecord] {
        records.reduce(into: []) { result, record in
            if let idx = matchingRecordIndex(
                in: result,
                id: record.id,
                displayName: record.displayName,
                address: record.lastAddress
            ) {
                result[idx] = merged(result[idx], with: record)
            } else {
                result.append(record)
            }
        }
    }

    private func merged(_ existing: PairedPhoneRecord, with incoming: PairedPhoneRecord) -> PairedPhoneRecord {
        let latest = existing.lastConnected >= incoming.lastConnected ? existing : incoming
        return PairedPhoneRecord(
            id: latest.id,
            displayName: latest.displayName,
            lastAddress: latest.lastAddress,
            firstPaired: min(existing.firstPaired, incoming.firstPaired),
            lastConnected: max(existing.lastConnected, incoming.lastConnected)
        )
    }

    private func matchingRecordIndex(
        in records: [PairedPhoneRecord],
        id: String,
        displayName: String,
        address: String
    ) -> Int? {
        matchingRecordIndexes(in: records, id: id, displayName: displayName, address: address).first
    }

    private func matchingRecordIndexes(
        in records: [PairedPhoneRecord],
        id: String,
        displayName: String,
        address: String
    ) -> [Int] {
        let exactMatches = records.indices.filter { index in
            let record = records[index]
            return record.id == id
                || record.lastAddress == address
                || (
                    Self.isSpecificDeviceName(displayName)
                    && record.displayName.localizedCaseInsensitiveCompare(displayName) == .orderedSame
                )
        }
        if !exactMatches.isEmpty {
            return exactMatches
        }

        guard !Self.isSpecificDeviceName(displayName) else { return [] }
        let genericMatches = records.indices.filter { index in
            !Self.isSpecificDeviceName(records[index].displayName)
        }
        guard let latestGenericIndex = genericMatches.max(by: {
            records[$0].lastConnected < records[$1].lastConnected
        }) else { return [] }
        return [latestGenericIndex]
    }

    private static func isSpecificDeviceName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.localizedCaseInsensitiveCompare("Android device") != .orderedSame
    }
}

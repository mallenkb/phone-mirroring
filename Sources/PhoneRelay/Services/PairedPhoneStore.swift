import Foundation

/// UserDefaults-backed persistence for paired phones. Equivalent to the
/// per-device record Bluetooth keeps between sessions.
struct PairedPhoneStore {
    static let defaultsKey = "AndroidMirror.PairedPhones.v1"
    static let compatibilitySuites = [
        "com.mallenkb.AndroidMirrorScrcpy",
        "org.example.PhoneRelay",
        "org.example.AndroidMirrorScrcpy",
        "local.phonerelay",
        "PhoneRelay"
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
            // One-time migration: clear the legacy copy after merging so a
            // phone the user later removes can't resurrect from an abandoned
            // domain (save() no longer mirrors into these suites).
            defaults.removeObject(forKey: Self.defaultsKey)
        }

        storedRecords = deduplicated(storedRecords)

        if !storedRecords.isEmpty {
            save(storedRecords)
        }

        return storedRecords
    }

    /// Legacy compatibility suites are read-only migration sources (drained in
    /// `load()`); new state is written solely to the primary defaults.
    func save(_ records: [PairedPhoneRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        primaryDefaults.set(data, forKey: Self.defaultsKey)
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
        usbSerial: String? = nil,
        wifiAddress: String? = nil,
        now: Date = .now
    ) -> [PairedPhoneRecord] {
        let sanitizedDisplayName = Self.sanitizedDisplayName(displayName)
        let resolvedUSBSerial = Self.resolvedUSBSerial(address: address, explicitUSBSerial: usbSerial)
        let resolvedWiFiAddress = Self.resolvedWiFiAddress(address: address, explicitWiFiAddress: wifiAddress)
        let matchingIndexes = matchingRecordIndexes(
            in: records,
            id: id,
            displayName: sanitizedDisplayName,
            address: address,
            usbSerial: resolvedUSBSerial,
            wifiAddress: resolvedWiFiAddress
        )

        guard !matchingIndexes.isEmpty else {
            return records + [.init(
                id: id,
                displayName: sanitizedDisplayName,
                lastAddress: Self.preferredLastAddress(
                    incoming: address,
                    existing: [],
                    wifiAddress: resolvedWiFiAddress
                ),
                usbSerial: resolvedUSBSerial,
                wifiAddress: resolvedWiFiAddress,
                firstPaired: now,
                lastConnected: now
            )]
        }

        let firstPaired = matchingIndexes
            .map { records[$0].firstPaired }
            .min() ?? now
        let refreshed = PairedPhoneRecord(
            id: id,
            displayName: sanitizedDisplayName,
            lastAddress: Self.preferredLastAddress(
                incoming: address,
                existing: matchingIndexes.map { records[$0].lastAddress },
                wifiAddress: resolvedWiFiAddress ?? matchingIndexes.compactMap { records[$0].resolvedWiFiAddress }.first
            ),
            usbSerial: resolvedUSBSerial ?? matchingIndexes.compactMap { records[$0].resolvedUSBSerial }.first,
            wifiAddress: resolvedWiFiAddress ?? matchingIndexes.compactMap { records[$0].resolvedWiFiAddress }.first,
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
                address: record.lastAddress,
                usbSerial: record.resolvedUSBSerial,
                wifiAddress: record.resolvedWiFiAddress
            ) {
                result[idx] = merged(result[idx], with: record)
            } else {
                result.append(record)
            }
        }
    }

    private func merged(_ existing: PairedPhoneRecord, with incoming: PairedPhoneRecord) -> PairedPhoneRecord {
        let latest = existing.lastConnected >= incoming.lastConnected ? existing : incoming
        let older = existing.lastConnected >= incoming.lastConnected ? incoming : existing
        let specificName = [incoming.displayName, existing.displayName]
            .map(Self.sanitizedDisplayName)
            .first(where: Self.isSpecificDeviceName)
        let displayName = specificName ?? Self.sanitizedDisplayName(latest.displayName)
        return PairedPhoneRecord(
            id: latest.id,
            displayName: displayName,
            lastAddress: Self.preferredLastAddress(
                incoming: latest.lastAddress,
                existing: [older.lastAddress],
                wifiAddress: latest.resolvedWiFiAddress ?? older.resolvedWiFiAddress
            ),
            usbSerial: latest.resolvedUSBSerial ?? older.resolvedUSBSerial,
            wifiAddress: latest.resolvedWiFiAddress ?? older.resolvedWiFiAddress,
            firstPaired: min(existing.firstPaired, incoming.firstPaired),
            lastConnected: max(existing.lastConnected, incoming.lastConnected),
            autoConnectSuspended: latest.autoConnectSuspended
        )
    }

    /// A bare USB serial must never overwrite a remembered wireless
    /// `host:port`: the wireless address is what launch and presence
    /// auto-reconnect dial after the cable is unplugged, and a USB session
    /// has no wireless address of its own to contribute.
    static func preferredLastAddress(incoming: String, existing: [String], wifiAddress: String? = nil) -> String {
        if let wifiAddress { return wifiAddress }
        if PairedPhoneRecord.isWirelessADBAddress(incoming) { return incoming }
        return existing.first(where: PairedPhoneRecord.isWirelessADBAddress) ?? incoming
    }

    private func matchingRecordIndex(
        in records: [PairedPhoneRecord],
        id: String,
        displayName: String,
        address: String,
        usbSerial: String? = nil,
        wifiAddress: String? = nil
    ) -> Int? {
        matchingRecordIndexes(
            in: records,
            id: id,
            displayName: displayName,
            address: address,
            usbSerial: usbSerial,
            wifiAddress: wifiAddress
        ).first
    }

    private func matchingRecordIndexes(
        in records: [PairedPhoneRecord],
        id: String,
        displayName: String,
        address: String,
        usbSerial: String? = nil,
        wifiAddress: String? = nil
    ) -> [Int] {
        let addressHost = Self.host(in: address)
        let wifiHost = wifiAddress.flatMap(Self.host)
        let exactMatches = records.indices.filter { index in
            let record = records[index]
            return record.id == id
                || record.lastAddress == address
                || record.resolvedUSBSerial == usbSerial
                || record.resolvedUSBSerial == id
                || record.resolvedWiFiAddress == wifiAddress
                || (addressHost != nil && Self.host(in: record.lastAddress) == addressHost)
                || (wifiHost != nil && record.resolvedWiFiAddress.flatMap(Self.host) == wifiHost)
                || (
                    Self.isSpecificDeviceName(displayName)
                    && Self.normalizedDeviceName(record.displayName) == Self.normalizedDeviceName(displayName)
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
        let trimmed = sanitizedDisplayName(name)
        guard !trimmed.isEmpty else { return false }
        return !genericDisplayNames.contains(normalizedDeviceName(trimmed))
    }

    private static let genericDisplayNames: Set<String> = [
        "android device",
        "authorized device",
        "device",
        "unknown device",
        "unknown"
    ]

    private static func sanitizedDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Android device" }
        return trimmed
    }

    private static func resolvedUSBSerial(address: String, explicitUSBSerial: String?) -> String? {
        if let explicitUSBSerial = sanitizedRouteValue(explicitUSBSerial) {
            return explicitUSBSerial
        }
        return PairedPhoneRecord.isWirelessADBAddress(address) ? nil : address
    }

    private static func resolvedWiFiAddress(address: String, explicitWiFiAddress: String?) -> String? {
        if let explicitWiFiAddress = sanitizedRouteValue(explicitWiFiAddress) {
            return explicitWiFiAddress
        }
        return PairedPhoneRecord.isWirelessADBAddress(address) ? address : nil
    }

    private static func sanitizedRouteValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func normalizedDeviceName(_ name: String) -> String {
        sanitizedDisplayName(name)
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func host(in address: String) -> String? {
        if address.hasPrefix("["),
           let endIndex = address.firstIndex(of: "]") {
            let hostStart = address.index(after: address.startIndex)
            return String(address[hostStart..<endIndex])
        }

        guard let separator = address.lastIndex(of: ":") else {
            return nil
        }
        return String(address[..<separator])
    }
}

import XCTest
@testable import AndroidMirrorMac

final class PairedPhoneStoreTests: XCTestCase {
    private let store = PairedPhoneStore()
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testTouchInsertsNewRecord() {
        let updated = store.touch([], id: "phone-1", displayName: "Pixel", address: "198.51.100.5:5555", now: referenceDate)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].id, "phone-1")
        XCTAssertEqual(updated[0].displayName, "Pixel")
        XCTAssertEqual(updated[0].lastAddress, "198.51.100.5:5555")
        XCTAssertEqual(updated[0].firstPaired, referenceDate)
        XCTAssertEqual(updated[0].lastConnected, referenceDate)
    }

    func testTouchUpdatesExistingRecordWithoutChangingFirstPaired() {
        let initial = store.touch([], id: "phone-1", displayName: "Pixel", address: "198.51.100.5:5555", now: referenceDate)
        let later = referenceDate.addingTimeInterval(3600)
        let updated = store.touch(initial, id: "phone-1", displayName: "Pixel Renamed", address: "198.51.100.5:6000", now: later)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].displayName, "Pixel Renamed")
        XCTAssertEqual(updated[0].lastAddress, "198.51.100.5:6000")
        XCTAssertEqual(updated[0].firstPaired, referenceDate, "firstPaired should be sticky once set")
        XCTAssertEqual(updated[0].lastConnected, later)
    }

    func testTouchUpdatesExistingSpecificDeviceNameWhenPortChanges() {
        let initial = store.touch(
            [],
            id: "adb-old-session",
            displayName: "SM S906B",
            address: "192.0.2.51:33883",
            now: referenceDate
        )
        let later = referenceDate.addingTimeInterval(3600)

        let updated = store.touch(
            initial,
            id: "adb-new-session",
            displayName: "SM S906B",
            address: "192.0.2.57:39757",
            now: later
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].id, "adb-new-session")
        XCTAssertEqual(updated[0].displayName, "SM S906B")
        XCTAssertEqual(updated[0].lastAddress, "192.0.2.57:39757")
        XCTAssertEqual(updated[0].firstPaired, referenceDate)
        XCTAssertEqual(updated[0].lastConnected, later)
    }

    func testTouchRefreshesLatestGenericAndroidDeviceName() {
        let initial = store.touch(
            [],
            id: "adb-first",
            displayName: "Android device",
            address: "192.0.2.51:33883",
            now: referenceDate
        )

        let updated = store.touch(
            initial,
            id: "adb-second",
            displayName: "Android device",
            address: "192.0.2.57:39757",
            now: referenceDate.addingTimeInterval(3600)
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].id, "adb-second")
        XCTAssertEqual(updated[0].displayName, "Android device")
        XCTAssertEqual(updated[0].lastAddress, "192.0.2.57:39757")
        XCTAssertEqual(updated[0].firstPaired, referenceDate)
        XCTAssertEqual(updated[0].lastConnected, referenceDate.addingTimeInterval(3600))
    }

    func testTouchCollapsesAllMatchingSpecificDeviceRecords() {
        let older = PairedPhoneRecord(
            id: "adb-old-session",
            displayName: "SM S906B",
            lastAddress: "192.0.2.51:33883",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let newer = PairedPhoneRecord(
            id: "adb-new-session",
            displayName: "SM S906B",
            lastAddress: "RFCT10ZLTAJ",
            firstPaired: referenceDate.addingTimeInterval(60),
            lastConnected: referenceDate.addingTimeInterval(120)
        )
        let latest = referenceDate.addingTimeInterval(3600)

        let updated = store.touch(
            [older, newer],
            id: "192.0.2.53:5555",
            displayName: "SM S906B",
            address: "192.0.2.53:5555",
            now: latest
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].id, "192.0.2.53:5555")
        XCTAssertEqual(updated[0].displayName, "SM S906B")
        XCTAssertEqual(updated[0].lastAddress, "192.0.2.53:5555")
        XCTAssertEqual(updated[0].firstPaired, referenceDate)
        XCTAssertEqual(updated[0].lastConnected, latest)
    }

    func testTouchReplacesGenericRecordForSameHostWithSpecificNameAndNewPort() {
        let generic = PairedPhoneRecord(
            id: "adb-generic",
            displayName: "Authorized Device",
            lastAddress: "192.0.2.54:34921",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let later = referenceDate.addingTimeInterval(3600)

        let updated = store.touch(
            [generic],
            id: "adb-specific",
            displayName: "SM S906B",
            address: "192.0.2.54:46313",
            now: later
        )

        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].id, "adb-specific")
        XCTAssertEqual(updated[0].displayName, "SM S906B")
        XCTAssertEqual(updated[0].lastAddress, "192.0.2.54:46313")
        XCTAssertEqual(updated[0].firstPaired, referenceDate)
        XCTAssertEqual(updated[0].lastConnected, later)
    }

    // Mirroring over the cable must not erase the remembered Wi-Fi address —
    // it is what launch/presence auto-reconnect dial after the cable comes out.
    func testTouchWithUSBSerialPreservesRememberedWirelessAddress() {
        let wireless = store.touch(
            [],
            id: "192.0.2.51:5555",
            displayName: "SM S906B",
            address: "192.0.2.51:5555",
            now: referenceDate
        )
        let later = referenceDate.addingTimeInterval(3600)

        let touchedOverUSB = store.touch(
            wireless,
            id: "RFTESTSERIAL",
            displayName: "SM S906B",
            address: "RFTESTSERIAL",
            now: later
        )

        XCTAssertEqual(touchedOverUSB.count, 1)
        XCTAssertEqual(touchedOverUSB[0].lastAddress, "192.0.2.51:5555")
        XCTAssertEqual(touchedOverUSB[0].id, "RFTESTSERIAL")
        XCTAssertEqual(touchedOverUSB[0].lastConnected, later)
    }

    func testTouchWithNewWirelessAddressReplacesOldOne() {
        let wireless = store.touch(
            [],
            id: "192.0.2.51:5555",
            displayName: "SM S906B",
            address: "192.0.2.51:5555",
            now: referenceDate
        )

        let moved = store.touch(
            wireless,
            id: "192.0.2.77:5555",
            displayName: "SM S906B",
            address: "192.0.2.77:5555",
            now: referenceDate.addingTimeInterval(3600)
        )

        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(moved[0].lastAddress, "192.0.2.77:5555")
    }

    func testPreferredLastAddressKeepsWirelessOverBareSerial() {
        XCTAssertEqual(
            PairedPhoneStore.preferredLastAddress(
                incoming: "RFTESTSERIAL",
                existing: ["192.0.2.51:5555"]
            ),
            "192.0.2.51:5555"
        )
        XCTAssertEqual(
            PairedPhoneStore.preferredLastAddress(
                incoming: "192.0.2.77:5555",
                existing: ["192.0.2.51:5555"]
            ),
            "192.0.2.77:5555"
        )
        XCTAssertEqual(
            PairedPhoneStore.preferredLastAddress(
                incoming: "RFTESTSERIAL",
                existing: ["OTHERSERIAL"]
            ),
            "RFTESTSERIAL"
        )
    }

    func testRoundTripCoding() throws {
        let record = PairedPhoneRecord(
            id: "phone-1",
            displayName: "Pixel",
            lastAddress: "198.51.100.5:5555",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let encoded = try JSONEncoder().encode([record])
        let decoded = try JSONDecoder().decode([PairedPhoneRecord].self, from: encoded)
        XCTAssertEqual(decoded, [record])
    }

    func testLoadMigratesRecordFromCompatibilitySuite() {
        let primarySuite = "AndroidMirrorMacTests.primary.\(UUID().uuidString)"
        let compatibilitySuite = "AndroidMirrorMacTests.compat.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: primarySuite)
            UserDefaults.standard.removePersistentDomain(forName: compatibilitySuite)
        }
        guard let primaryDefaults = UserDefaults(suiteName: primarySuite),
              let compatibilityDefaults = UserDefaults(suiteName: compatibilitySuite)
        else {
            return XCTFail("Expected test UserDefaults suites to be available")
        }

        let record = PairedPhoneRecord(
            id: "phone-1",
            displayName: "Pixel",
            lastAddress: "198.51.100.5:5555",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        PairedPhoneStore(primaryDefaults: compatibilityDefaults, suiteNames: [])
            .save([record])

        let store = PairedPhoneStore(
            primaryDefaults: primaryDefaults,
            suiteNames: [compatibilitySuite]
        )

        XCTAssertEqual(store.load(), [record])
        XCTAssertEqual(
            PairedPhoneStore(primaryDefaults: primaryDefaults, suiteNames: []).load(),
            [record]
        )
        // The legacy suite is drained by the migration, not left as a stale copy.
        XCTAssertEqual(
            PairedPhoneStore(primaryDefaults: compatibilityDefaults, suiteNames: []).load(),
            []
        )
    }

    func testRemovedPhoneDoesNotResurrectFromLegacySuite() {
        let primarySuite = "AndroidMirrorMacTests.primary.\(UUID().uuidString)"
        let compatibilitySuite = "AndroidMirrorMacTests.compat.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: primarySuite)
            UserDefaults.standard.removePersistentDomain(forName: compatibilitySuite)
        }
        guard let primaryDefaults = UserDefaults(suiteName: primarySuite),
              let compatibilityDefaults = UserDefaults(suiteName: compatibilitySuite)
        else {
            return XCTFail("Expected test UserDefaults suites to be available")
        }

        let record = PairedPhoneRecord(
            id: "phone-1",
            displayName: "Pixel",
            lastAddress: "198.51.100.5:5555",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        PairedPhoneStore(primaryDefaults: compatibilityDefaults, suiteNames: [])
            .save([record])

        let store = PairedPhoneStore(
            primaryDefaults: primaryDefaults,
            suiteNames: [compatibilitySuite]
        )
        XCTAssertEqual(store.load(), [record])

        store.save(store.removing(record.id, from: [record]))

        XCTAssertEqual(store.load(), [], "deleted phone must stay deleted across reloads")
    }

    func testLoadDeduplicatesSpecificDeviceNameAndKeepsLatestPort() {
        let primarySuite = "AndroidMirrorMacTests.primary.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: primarySuite)
        }
        guard let primaryDefaults = UserDefaults(suiteName: primarySuite) else {
            return XCTFail("Expected test UserDefaults suite to be available")
        }

        let older = PairedPhoneRecord(
            id: "adb-old-session",
            displayName: "SM S906B",
            lastAddress: "192.0.2.51:33883",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let newer = PairedPhoneRecord(
            id: "adb-new-session",
            displayName: "SM S906B",
            lastAddress: "192.0.2.57:39757",
            firstPaired: referenceDate.addingTimeInterval(60),
            lastConnected: referenceDate.addingTimeInterval(3600)
        )
        PairedPhoneStore(primaryDefaults: primaryDefaults, suiteNames: [])
            .save([older, newer])

        let loaded = PairedPhoneStore(primaryDefaults: primaryDefaults, suiteNames: []).load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "adb-new-session")
        XCTAssertEqual(loaded[0].lastAddress, "192.0.2.57:39757")
        XCTAssertEqual(loaded[0].firstPaired, referenceDate)
        XCTAssertEqual(loaded[0].lastConnected, referenceDate.addingTimeInterval(3600))
    }

    func testLoadCollapsesGenericAndSpecificRecordsForSameHost() {
        let primarySuite = "AndroidMirrorMacTests.primary.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: primarySuite)
        }
        guard let primaryDefaults = UserDefaults(suiteName: primarySuite) else {
            return XCTFail("Expected test UserDefaults suite to be available")
        }

        let generic = PairedPhoneRecord(
            id: "adb-generic",
            displayName: "Android device",
            lastAddress: "192.0.2.54:34921",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let specific = PairedPhoneRecord(
            id: "adb-specific",
            displayName: "SM S906B",
            lastAddress: "192.0.2.54:46313",
            firstPaired: referenceDate.addingTimeInterval(60),
            lastConnected: referenceDate.addingTimeInterval(3600)
        )
        PairedPhoneStore(primaryDefaults: primaryDefaults, suiteNames: [])
            .save([generic, specific])

        let loaded = PairedPhoneStore(primaryDefaults: primaryDefaults, suiteNames: []).load()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].id, "adb-specific")
        XCTAssertEqual(loaded[0].displayName, "SM S906B")
        XCTAssertEqual(loaded[0].lastAddress, "192.0.2.54:46313")
        XCTAssertEqual(loaded[0].firstPaired, referenceDate)
        XCTAssertEqual(loaded[0].lastConnected, referenceDate.addingTimeInterval(3600))
    }

    func testSaveWritesOnlyToPrimaryDefaults() {
        let primarySuite = "AndroidMirrorMacTests.primary.\(UUID().uuidString)"
        let compatibilitySuite = "AndroidMirrorMacTests.compat.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: primarySuite)
            UserDefaults.standard.removePersistentDomain(forName: compatibilitySuite)
        }
        guard let primaryDefaults = UserDefaults(suiteName: primarySuite),
              let compatibilityDefaults = UserDefaults(suiteName: compatibilitySuite)
        else {
            return XCTFail("Expected test UserDefaults suites to be available")
        }

        let record = PairedPhoneRecord(
            id: "phone-1",
            displayName: "Pixel",
            lastAddress: "198.51.100.5:5555",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let store = PairedPhoneStore(
            primaryDefaults: primaryDefaults,
            suiteNames: [compatibilitySuite]
        )

        store.save([record])

        XCTAssertEqual(
            PairedPhoneStore(primaryDefaults: primaryDefaults, suiteNames: []).load(),
            [record]
        )
        // Abandoned domains must not keep accumulating device names/addresses.
        XCTAssertNil(compatibilityDefaults.data(forKey: PairedPhoneStore.defaultsKey))
    }

    func testClearRemovesRecordsFromPrimaryAndCompatibilitySuites() {
        let primarySuite = "AndroidMirrorMacTests.primary.\(UUID().uuidString)"
        let compatibilitySuite = "AndroidMirrorMacTests.compat.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: primarySuite)
            UserDefaults.standard.removePersistentDomain(forName: compatibilitySuite)
        }
        guard let primaryDefaults = UserDefaults(suiteName: primarySuite),
              let compatibilityDefaults = UserDefaults(suiteName: compatibilitySuite)
        else {
            return XCTFail("Expected test UserDefaults suites to be available")
        }

        let record = PairedPhoneRecord(
            id: "phone-1",
            displayName: "Pixel",
            lastAddress: "198.51.100.5:5555",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let store = PairedPhoneStore(
            primaryDefaults: primaryDefaults,
            suiteNames: [compatibilitySuite]
        )

        store.save([record])
        // Seed the legacy suite directly so clearAll's suite sweep is exercised.
        PairedPhoneStore(primaryDefaults: compatibilityDefaults, suiteNames: [])
            .save([record])
        store.clearAll()

        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(
            PairedPhoneStore(primaryDefaults: compatibilityDefaults, suiteNames: []).load(),
            []
        )
    }
}

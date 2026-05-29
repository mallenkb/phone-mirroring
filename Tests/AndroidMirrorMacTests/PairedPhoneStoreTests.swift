import XCTest
@testable import AndroidMirrorMac

final class PairedPhoneStoreTests: XCTestCase {
    private let store = PairedPhoneStore()
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testTouchInsertsNewRecord() {
        let updated = store.touch([], id: "phone-1", displayName: "Pixel", address: "10.0.0.5:5555", now: referenceDate)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].id, "phone-1")
        XCTAssertEqual(updated[0].displayName, "Pixel")
        XCTAssertEqual(updated[0].lastAddress, "10.0.0.5:5555")
        XCTAssertEqual(updated[0].firstPaired, referenceDate)
        XCTAssertEqual(updated[0].lastConnected, referenceDate)
    }

    func testTouchUpdatesExistingRecordWithoutChangingFirstPaired() {
        let initial = store.touch([], id: "phone-1", displayName: "Pixel", address: "10.0.0.5:5555", now: referenceDate)
        let later = referenceDate.addingTimeInterval(3600)
        let updated = store.touch(initial, id: "phone-1", displayName: "Pixel Renamed", address: "10.0.0.5:6000", now: later)
        XCTAssertEqual(updated.count, 1)
        XCTAssertEqual(updated[0].displayName, "Pixel Renamed")
        XCTAssertEqual(updated[0].lastAddress, "10.0.0.5:6000")
        XCTAssertEqual(updated[0].firstPaired, referenceDate, "firstPaired should be sticky once set")
        XCTAssertEqual(updated[0].lastConnected, later)
    }

    func testRoundTripCoding() throws {
        let record = PairedPhoneRecord(
            id: "phone-1",
            displayName: "Pixel",
            lastAddress: "10.0.0.5:5555",
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
            lastAddress: "10.0.0.5:5555",
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
    }

    func testSaveWritesRecordToCompatibilitySuite() {
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
            lastAddress: "10.0.0.5:5555",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let store = PairedPhoneStore(
            primaryDefaults: primaryDefaults,
            suiteNames: [compatibilitySuite]
        )

        store.save([record])

        XCTAssertEqual(
            PairedPhoneStore(primaryDefaults: compatibilityDefaults, suiteNames: []).load(),
            [record]
        )
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
            lastAddress: "10.0.0.5:5555",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let store = PairedPhoneStore(
            primaryDefaults: primaryDefaults,
            suiteNames: [compatibilitySuite]
        )

        store.save([record])
        store.clearAll()

        XCTAssertEqual(store.load(), [])
        XCTAssertEqual(
            PairedPhoneStore(primaryDefaults: compatibilityDefaults, suiteNames: []).load(),
            []
        )
    }
}

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
}

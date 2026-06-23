import XCTest
@testable import PhoneRelay

final class PairedPhoneRecordMACTests: XCTestCase {
    private let store = PairedPhoneStore(primaryDefaults: UserDefaults(suiteName: "PairedPhoneRecordMACTests")!, suiteNames: [])
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testRoundTripPreservesNormalizedMAC() throws {
        let record = PairedPhoneRecord(
            id: "phone-1",
            displayName: "Pixel 8",
            lastAddress: "192.168.1.5:5555",
            wifiMACAddress: "AA:BB:CC:DD:EE:FF",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        XCTAssertEqual(record.wifiMACAddress, "aa:bb:cc:dd:ee:ff")

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(PairedPhoneRecord.self, from: data)
        XCTAssertEqual(decoded.wifiMACAddress, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(decoded, record)
    }

    func testDecodingLegacyJSONWithoutMACField() throws {
        let record = PairedPhoneRecord(
            id: "phone-1",
            displayName: "Pixel 8",
            lastAddress: "192.168.1.5:5555",
            firstPaired: referenceDate,
            lastConnected: referenceDate
        )
        let data = try JSONEncoder().encode(record)
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "wifiMACAddress")
        let legacy = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(PairedPhoneRecord.self, from: legacy)
        XCTAssertNil(decoded.wifiMACAddress)
        XCTAssertEqual(decoded.id, "phone-1")
        XCTAssertEqual(decoded.lastAddress, "192.168.1.5:5555")
    }

    func testTouchStoresNormalizedMAC() {
        let updated = store.touch(
            [],
            id: "phone-1",
            displayName: "Pixel",
            address: "192.168.1.5:5555",
            wifiMACAddress: "AA-BB-CC-DD-EE-FF",
            now: referenceDate
        )
        XCTAssertEqual(updated[0].wifiMACAddress, "aa:bb:cc:dd:ee:ff")
    }

    func testTouchPreservesExistingMACWhenNoneSupplied() {
        let initial = store.touch(
            [],
            id: "phone-1",
            displayName: "Pixel",
            address: "192.168.1.5:5555",
            wifiMACAddress: "aa:bb:cc:dd:ee:ff",
            now: referenceDate
        )
        // A later touch (e.g. a recovered IP) carries no MAC — the stored one
        // must survive so future recoveries still have their anchor.
        let later = store.touch(
            initial,
            id: "phone-1",
            displayName: "Pixel",
            address: "192.168.1.99:5555",
            wifiAddress: "192.168.1.99:5555",
            now: referenceDate.addingTimeInterval(3600)
        )
        XCTAssertEqual(later.count, 1)
        XCTAssertEqual(later[0].wifiAddress, "192.168.1.99:5555")
        XCTAssertEqual(later[0].wifiMACAddress, "aa:bb:cc:dd:ee:ff")
    }
}

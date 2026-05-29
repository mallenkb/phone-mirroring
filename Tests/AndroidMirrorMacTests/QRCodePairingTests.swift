import XCTest
@testable import AndroidMirrorMac

final class QRCodePairingTests: XCTestCase {
    func testQRCodePairingPayloadUsesADBWifiFormat() {
        let session = ADBQRCodePairingSession(
            serviceName: "studio-Abc123xyZ9",
            password: "0123456789ab"
        )

        XCTAssertEqual(
            session.payload,
            "WIFI:T:ADB;S:studio-Abc123xyZ9;P:0123456789ab;;"
        )
    }

    func testRandomQRCodePairingSessionUsesStudioServiceAndSafeSecret() {
        let session = ADBQRCodePairingSession.random()
        let safeCharacters = CharacterSet.alphanumerics

        XCTAssertTrue(session.serviceName.hasPrefix("studio-"))
        XCTAssertEqual(session.serviceName.count, 17)
        XCTAssertEqual(session.password.count, 12)
        XCTAssertTrue(session.serviceName.dropFirst("studio-".count).allSatisfy { character in
            character.unicodeScalars.allSatisfy { safeCharacters.contains($0) }
        })
        XCTAssertTrue(session.password.allSatisfy { character in
            character.unicodeScalars.allSatisfy { safeCharacters.contains($0) }
        })
        XCTAssertEqual(
            session.payload,
            "WIFI:T:ADB;S:\(session.serviceName);P:\(session.password);;"
        )
    }

    func testQRCodePairingServiceMatchesRequestedPairingServiceOnly() {
        let expected = DiscoveredPhone(
            id: "studio-Abc123xyZ9",
            address: "192.168.1.42:39555",
            kind: .pairable,
            lastSeen: Date(timeIntervalSince1970: 200)
        )
        let sameHostConnectable = DiscoveredPhone(
            id: "adb-XYZ",
            address: "192.168.1.42:42111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )
        let otherPairing = DiscoveredPhone(
            id: "studio-Other1234",
            address: "192.168.1.43:39555",
            kind: .pairable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            ADBQRCodePairingSession.pairingService(
                named: "studio-Abc123xyZ9",
                in: [sameHostConnectable, otherPairing, expected]
            ),
            expected
        )
    }

    func testConnectableWirelessPhonePrefersSameHostAsPairingService() {
        let otherHost = DiscoveredPhone(
            id: "adb-other",
            address: "192.168.1.99:42111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )
        let expected = DiscoveredPhone(
            id: "adb-XYZ",
            address: "192.168.1.42:42111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 200)
        )
        let pairingOnly = DiscoveredPhone(
            id: "studio-Abc123xyZ9",
            address: "192.168.1.42:39555",
            kind: .pairable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(
            AppModel.connectableWirelessPhone(
                matchingHostOf: pairingOnly.address,
                phones: [otherHost, expected, pairingOnly]
            ),
            expected
        )
    }
}

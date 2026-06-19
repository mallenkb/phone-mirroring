import XCTest
@testable import PhoneRelay

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
            address: "192.0.2.42:39555",
            kind: .pairable,
            lastSeen: Date(timeIntervalSince1970: 200)
        )
        let sameHostConnectable = DiscoveredPhone(
            id: "adb-XYZ",
            address: "192.0.2.42:42111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )
        let otherPairing = DiscoveredPhone(
            id: "studio-Other1234",
            address: "192.0.2.43:39555",
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
            address: "192.0.2.99:42111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )
        let expected = DiscoveredPhone(
            id: "adb-XYZ",
            address: "192.0.2.42:42111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 200)
        )
        let pairingOnly = DiscoveredPhone(
            id: "studio-Abc123xyZ9",
            address: "192.0.2.42:39555",
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

    func testQRCodePairingStartsMirrorBeforeLegacyTCPIPPromotion() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/PhoneRelay/AppModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let watcher = try XCTUnwrap(
            source.range(
                of: "private func startQRCodePairingWatcher()",
                options: [],
                range: source.startIndex..<source.endIndex
            )
        )
        let reset = try XCTUnwrap(
            source.range(
                of: "private func resetQRCodePairingAfterFailure",
                options: [],
                range: watcher.upperBound..<source.endIndex
            )
        )
        let body = String(source[watcher.lowerBound..<reset.lowerBound])

        let finishRange = try XCTUnwrap(body.range(of: "self.finishQRCodePairing"))
        let promotionRange = try XCTUnwrap(body.range(of: "prepareQRCodePairingLegacyTCPIPInBackground"))

        XCTAssertLessThan(
            finishRange.lowerBound,
            promotionRange.lowerBound,
            "QR pairing should start the mirror on the verified wireless target before preparing the optional :5555 reconnect route."
        )
        XCTAssertFalse(
            body.contains("await Self.promoteToLegacyTCPIP"),
            "QR pairing must not block initial mirroring on legacy tcpip promotion."
        )
    }

    func testWirelessScreenShowsIPOnlyManualConnect() throws {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/PhoneRelay/Views/FigmaMirrorExperienceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        let ipRange = try XCTUnwrap(source.range(of: "WiFi Only"))
        let qrRange = try XCTUnwrap(source.range(of: "Wireless Debugging (scan QR)"))
        XCTAssertLessThan(ipRange.lowerBound, qrRange.lowerBound)
        XCTAssertTrue(source.contains("e.g. 192.168.1.23"))
        XCTAssertTrue(source.contains("Enter the phone Wifi IP address only"))
        XCTAssertTrue(source.contains("Connect via WiFi only"))
        XCTAssertTrue(source.contains("Connect via Wireless Debugging"))
        XCTAssertTrue(source.contains("On your phone: Settings → Developer options → Wireless debugging → Pair device with QR code."))
        XCTAssertFalse(source.contains("Pair with code"))
        XCTAssertFalse(source.contains("Pairing IP:port"))
        XCTAssertFalse(source.contains("6-digit code"))
        XCTAssertFalse(source.contains("Debugging IP:port"))
        XCTAssertFalse(source.contains("Pair and connect"))
    }

    func testPairingCodeInputsRequireAddressAndSixDigits() {
        XCTAssertTrue(AppModel.canSubmitPairingCode(address: "192.168.68.54:44355", code: "017098"))
        XCTAssertTrue(AppModel.canSubmitPairingCode(address: " 192.168.68.54:44355 ", code: " 017098 "))
        XCTAssertFalse(AppModel.canSubmitPairingCode(address: "", code: "017098"))
        XCTAssertFalse(AppModel.canSubmitPairingCode(address: "192.168.68.54:44355", code: "17098"))
        XCTAssertFalse(AppModel.canSubmitPairingCode(address: "192.168.68.54:44355", code: "01709a"))
    }
}

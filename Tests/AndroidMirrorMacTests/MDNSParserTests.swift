import XCTest
@testable import AndroidMirrorMac

final class MDNSParserTests: XCTestCase {
    func testEmptyOutput() {
        XCTAssertEqual(ADBController.parseMDNSServices(""), [])
    }

    func testIgnoresHeaderAndErrors() {
        let output = """
        List of discovered mdns services
        ERROR: mdns is down
        """
        XCTAssertEqual(ADBController.parseMDNSServices(output), [])
    }

    func testParsesPairingService() {
        let output = "adb-XYZ\t_adb-tls-pairing._tcp.\t192.168.1.42:39555"
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.count, 1)
        XCTAssertEqual(phones.first?.kind, .pairable)
        XCTAssertEqual(phones.first?.address, "192.168.1.42:39555")
    }

    func testParsesConnectService() {
        let output = "adb-XYZ\t_adb-tls-connect._tcp.\t192.168.1.42:5555"
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.first?.kind, .connectable)
    }

    func testParsesLegacyTCPService() {
        let output = "adb-XYZ\t_adb._tcp.\t192.168.1.42:5555"
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.first?.kind, .connectable, "Legacy _adb._tcp should be treated as connectable")
    }

    func testConnectServicePreemptsPairingForSameInstance() {
        let output = """
        adb-XYZ\t_adb-tls-pairing._tcp.\t192.168.1.42:39555
        adb-XYZ\t_adb-tls-connect._tcp.\t192.168.1.42:5555
        """
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.count, 1)
        XCTAssertEqual(phones.first?.kind, .connectable)
        XCTAssertEqual(phones.first?.address, "192.168.1.42:5555")
    }

    func testIgnoresEntriesWithoutAddress() {
        let output = "adb-XYZ\t_adb-tls-connect._tcp."
        XCTAssertEqual(ADBController.parseMDNSServices(output), [])
    }

    func testSortsByID() {
        let output = """
        adb-ZZZ\t_adb-tls-connect._tcp.\t192.168.1.42:5555
        adb-AAA\t_adb-tls-connect._tcp.\t192.168.1.41:5555
        """
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.map(\.id), ["adb-AAA", "adb-ZZZ"])
    }

}

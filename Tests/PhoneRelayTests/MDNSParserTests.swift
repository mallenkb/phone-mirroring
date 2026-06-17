import XCTest
@testable import PhoneRelay

final class MDNSParserTests: XCTestCase {
    func testDiscoveryPollsEverySecondForFastWiFiStartup() {
        XCTAssertEqual(DiscoveryService.pollIntervalNanoseconds, 1_000_000_000)
    }

    @MainActor
    func testDiscoveryPollingDoesNotBlockMainActor() async {
        let pollStarted = LockedFlag()
        let pollFinished = LockedFlag()
        let ping = LockedFlag()
        let discovery = DiscoveryService {
            pollStarted.set()
            Thread.sleep(forTimeInterval: 2)
            pollFinished.set()
            return []
        }
        defer { discovery.stop() }

        discovery.start { _ in }
        let didStart = await waitForFlag(pollStarted)
        XCTAssertTrue(didStart)

        Task { @MainActor in
            ping.set()
        }

        let didPing = await waitForFlag(ping, timeout: 1)
        XCTAssertTrue(didPing, "mDNS discovery polling must not run blocking adb work on the main actor.")
        XCTAssertFalse(pollFinished.value)
    }

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
        let output = "adb-XYZ\t_adb-tls-pairing._tcp.\t192.0.2.42:39555"
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.count, 1)
        XCTAssertEqual(phones.first?.kind, .pairable)
        XCTAssertEqual(phones.first?.address, "192.0.2.42:39555")
    }

    func testParsesConnectService() {
        let output = "adb-XYZ\t_adb-tls-connect._tcp.\t192.0.2.42:5555"
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.first?.kind, .wirelessDebugging)
    }

    func testParsesLegacyTCPService() {
        let output = "adb-XYZ\t_adb._tcp.\t192.0.2.42:5555"
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.first?.kind, .legacyTCPIP, "Legacy _adb._tcp should stay separate from Wireless debugging")
    }

    func testParsesDNSServiceBrowseOutput() {
        let output = """
        Browsing for _adb._tcp.local
        DATE: ---Tue 09 Jun 2026---
        17:04:24.694  ...STARTING...
        Timestamp     A/R    Flags  if Domain               Service Type         Instance Name
        17:04:24.694  Add        2  15 local.               _adb._tcp.           adb-RFCT10ZLTAJ
        """

        let services = ADBController.parseDNSServiceBrowseOutput(output, serviceType: "_adb._tcp")

        XCTAssertEqual(services, [ADBController.DNSService(instance: "adb-RFCT10ZLTAJ", serviceType: "_adb._tcp")])
    }

    func testParsesDNSServiceResolveOutputAsConnectablePhone() {
        let output = """
        Lookup adb-RFCT10ZLTAJ._adb._tcp.local
        DATE: ---Tue 09 Jun 2026---
        17:04:40.597  ...STARTING...
        17:04:40.597  adb-RFCT10ZLTAJ._adb._tcp.local. can be reached at Android.local.:5555 (interface 15)
         api= name=SM-S906B v=1
        """

        let phone = ADBController.parseDNSServiceResolveOutput(
            output,
            instance: "adb-RFCT10ZLTAJ",
            serviceType: "_adb._tcp"
        )

        XCTAssertEqual(phone?.id, "adb-RFCT10ZLTAJ")
        XCTAssertEqual(phone?.address, "Android.local:5555")
        XCTAssertEqual(phone?.kind, .legacyTCPIP)
    }

    func testConnectServicePreemptsPairingForSameInstance() {
        let output = """
        adb-XYZ\t_adb-tls-pairing._tcp.\t192.0.2.42:39555
        adb-XYZ\t_adb-tls-connect._tcp.\t192.0.2.42:5555
        """
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.count, 1)
        XCTAssertEqual(phones.first?.kind, .wirelessDebugging)
        XCTAssertEqual(phones.first?.address, "192.0.2.42:5555")
    }

    func testIgnoresEntriesWithoutAddress() {
        let output = "adb-XYZ\t_adb-tls-connect._tcp."
        XCTAssertEqual(ADBController.parseMDNSServices(output), [])
    }

    func testSortsByID() {
        let output = """
        adb-ZZZ\t_adb-tls-connect._tcp.\t192.0.2.42:5555
        adb-AAA\t_adb-tls-connect._tcp.\t192.0.2.41:5555
        """
        let phones = ADBController.parseMDNSServices(output)
        XCTAssertEqual(phones.map(\.id), ["adb-AAA", "adb-ZZZ"])
    }

}

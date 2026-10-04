import Network
import XCTest
@testable import PhoneRelay

/// Finding a phone by its hardware serial, so a changing Wi-Fi IP or a
/// randomized MAC address can't stop automatic reconnect.
final class WiFiSerialDiscoveryTests: XCTestCase {

    private func record(
        id: String = "RFCT10ZLTAJ",
        lastAddress: String = "RFCT10ZLTAJ",
        usbSerial: String? = "RFCT10ZLTAJ",
        observedWiFiIPAddress: String? = nil,
        wifiAddress: String? = nil,
        wifiMACAddress: String? = nil
    ) -> PairedPhoneRecord {
        PairedPhoneRecord(
            id: id,
            displayName: "SM S906B",
            lastAddress: lastAddress,
            usbSerial: usbSerial,
            observedWiFiIPAddress: observedWiFiIPAddress,
            wifiAddress: wifiAddress,
            wifiMACAddress: wifiMACAddress,
            firstPaired: Date(timeIntervalSince1970: 0),
            lastConnected: Date(timeIntervalSince1970: 0)
        )
    }

    private func phone(_ instance: String, _ address: String, _ kind: DiscoveredPhone.Kind = .legacyTCPIP) -> DiscoveredPhone {
        DiscoveredPhone(id: instance, address: address, kind: kind, lastSeen: Date())
    }

    // MARK: - mDNS instance names

    func testMDNSInstanceMatchesLegacyAndWirelessDebuggingNames() {
        XCTAssertTrue(AppModel.mdnsInstance("adb-RFCT10ZLTAJ", matchesSerial: "RFCT10ZLTAJ"))
        XCTAssertTrue(AppModel.mdnsInstance("adb-RFCT10ZLTAJ-a1B2c3", matchesSerial: "RFCT10ZLTAJ"))
    }

    func testMDNSInstanceRejectsPrefixCollisionsAndNonSerials() {
        XCTAssertFalse(AppModel.mdnsInstance("adb-RFCT10ZLTAJ", matchesSerial: "RFCT10"))
        XCTAssertFalse(AppModel.mdnsInstance("adb-OTHERPHONE", matchesSerial: "RFCT10ZLTAJ"))
        XCTAssertFalse(AppModel.mdnsInstance("adb-RFCT10ZLTAJ", matchesSerial: ""))
        XCTAssertFalse(AppModel.mdnsInstance("adb-192.168.1.5:5555", matchesSerial: "192.168.1.5:5555"))
    }

    // MARK: - Matching a saved phone to discovery

    func testRecordWithoutWiFiAddressMatchesDiscoveryBySerial() {
        let saved = record(wifiMACAddress: "12:f7:73:7c:97:dc")
        let phones = [
            phone("adb-SOMEONEELSE", "192.168.68.20:5555"),
            phone("adb-RFCT10ZLTAJ", "192.168.68.77:5555")
        ]
        let match = AppModel.rememberedConnectablePhone(
            for: saved,
            in: phones,
            allowSingleCandidateFallback: false
        )
        XCTAssertEqual(match?.address, "192.168.68.77:5555")
    }

    func testSerialMatchWinsOverStaleSavedHost() {
        // The saved endpoint's host now belongs to another phone.
        let saved = record(wifiAddress: "192.168.68.64:5555")
        let phones = [
            phone("adb-SOMEONEELSE", "192.168.68.64:5555"),
            phone("adb-RFCT10ZLTAJ", "192.168.68.90:5555")
        ]
        let match = AppModel.rememberedConnectablePhone(for: saved, in: phones)
        XCTAssertEqual(match?.address, "192.168.68.90:5555")
    }

    func testPairingOnlyServiceIsNotAConnectableMatch() {
        let saved = record()
        let phones = [phone("adb-RFCT10ZLTAJ-x1y2z3", "192.168.68.77:37000", .pairable)]
        XCTAssertNil(AppModel.serialMatchedPhone(for: saved, in: phones))
    }

    // MARK: - Which records automatic reconnect works on

    func testVerifiedEndpointRecordIsCandidate() {
        XCTAssertTrue(AppModel.isAutomaticWirelessReconnectCandidate(
            record(wifiAddress: "192.168.68.64:5555"),
            allowLegacyCompatibility: false,
            discoveredPhones: []
        ))
    }

    func testRecordSeenOnWiFiIsCandidateInLegacyModeWithoutVerifiedEndpoint() {
        let seen = record(observedWiFiIPAddress: "192.168.68.64", wifiMACAddress: "12:f7:73:7c:97:dc")
        XCTAssertTrue(AppModel.isAutomaticWirelessReconnectCandidate(
            seen,
            allowLegacyCompatibility: true,
            discoveredPhones: []
        ))
        XCTAssertFalse(AppModel.isAutomaticWirelessReconnectCandidate(
            seen,
            allowLegacyCompatibility: false,
            discoveredPhones: []
        ))
    }

    func testUSBOnlyRecordBecomesCandidateOnlyWhenItAdvertisesBySerial() {
        let usbOnly = record()
        XCTAssertFalse(AppModel.isAutomaticWirelessReconnectCandidate(
            usbOnly,
            allowLegacyCompatibility: true,
            discoveredPhones: []
        ))
        XCTAssertTrue(AppModel.isAutomaticWirelessReconnectCandidate(
            usbOnly,
            allowLegacyCompatibility: false,
            discoveredPhones: [phone("adb-RFCT10ZLTAJ-q9w8e7", "192.168.68.77:41234", .wirelessDebugging)]
        ))
    }

    func testRecordWithoutAnyIdentityIsNeverCandidate() {
        let anonymous = record(id: "192.168.68.64:5555", lastAddress: "192.168.68.64:5555", usbSerial: nil)
        // A host:port id is a verified endpoint, so it stays a candidate the old way.
        XCTAssertTrue(AppModel.isAutomaticWirelessReconnectCandidate(
            anonymous,
            allowLegacyCompatibility: true,
            discoveredPhones: []
        ))
        XCTAssertEqual(AppModel.identitySerials(for: anonymous), [])
    }

    // MARK: - adb server warm-up

    func testDaemonManagementCommandsNeverWaitForWarmUp() {
        XCTAssertFalse(ADBController.shouldWaitForServerPrime(command: "start-server"))
        XCTAssertFalse(ADBController.shouldWaitForServerPrime(command: "kill-server"))
        XCTAssertTrue(ADBController.shouldWaitForServerPrime(command: "devices"))
        XCTAssertTrue(ADBController.shouldWaitForServerPrime(command: "mdns"))
        XCTAssertTrue(ADBController.shouldWaitForServerPrime(command: "shell"))
    }

    // MARK: - Bonjour denial

    func testPolicyDeniedErrorIsRecognized() {
        XCTAssertTrue(BonjourServiceMonitor.isPolicyDenial(.dns(-65570)))
        XCTAssertFalse(BonjourServiceMonitor.isPolicyDenial(.dns(-65563)))
        XCTAssertFalse(BonjourServiceMonitor.isPolicyDenial(.posix(.EHOSTUNREACH)))
    }

    func testDNSSDFallbackSlowsDownWhileBrowsersAreDenied() {
        XCTAssertGreaterThan(
            ADBController.dnsSDFallbackCacheWindow(policyDenied: true),
            ADBController.dnsSDFallbackCacheWindow(policyDenied: false)
        )
    }
}

/// Port probes must keep working when macOS denies the app process Local
/// Network access but still lets its child processes reach the LAN.
final class LANProbeTests: XCTestCase {
    private var originalInProcess: (@Sendable (String, UInt16, TimeInterval) async -> LANProbe.Outcome)!
    private var originalHelper: (@Sendable (String, UInt16, TimeInterval) async -> Bool)!

    override func setUp() {
        super.setUp()
        originalInProcess = LANProbe.inProcessProbe
        originalHelper = LANProbe.helperProbe
        LANProbe.resetForTesting()
    }

    override func tearDown() {
        LANProbe.inProcessProbe = originalInProcess
        LANProbe.helperProbe = originalHelper
        LANProbe.resetForTesting()
        super.tearDown()
    }

    func testOpenAndClosedInProcessResultsSkipTheHelper() async {
        LANProbe.helperProbe = { _, _, _ in
            XCTFail("helper must not run when the in-process probe has an answer")
            return false
        }
        LANProbe.inProcessProbe = { _, _, _ in .open }
        let open = await LANProbe.isPortOpen(host: "192.0.2.1", port: 5555, timeout: 0.5)
        XCTAssertTrue(open)
        LANProbe.inProcessProbe = { _, _, _ in .closed }
        let closed = await LANProbe.isPortOpen(host: "192.0.2.1", port: 5555, timeout: 0.5)
        XCTAssertFalse(closed)
    }

    func testDenialFallsBackToHelperAndSkipsInProcessUntilRecheck() async {
        let calls = ProbeCallCounter()
        LANProbe.inProcessProbe = { _, _, _ in
            calls.increment()
            return .localNetworkDenied
        }
        LANProbe.helperProbe = { host, _, _ in host == "192.0.2.7" }

        let first = await LANProbe.isPortOpen(host: "192.0.2.7", port: 5555, timeout: 0.5)
        let second = await LANProbe.isPortOpen(host: "192.0.2.8", port: 5555, timeout: 0.5)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertEqual(calls.value, 1, "after a denial the sweep should not pay for two probes per host")
        XCTAssertTrue(LANProbe.isInProcessAccessDenied)
    }

    func testRecheckWindow() {
        let now = Date()
        XCTAssertFalse(LANProbe.shouldSkipInProcessProbe(deniedAt: nil, now: now))
        XCTAssertTrue(LANProbe.shouldSkipInProcessProbe(deniedAt: now.addingTimeInterval(-5), now: now))
        XCTAssertFalse(LANProbe.shouldSkipInProcessProbe(
            deniedAt: now.addingTimeInterval(-LANProbe.inProcessDenialRecheckInterval - 1),
            now: now
        ))
    }

    func testHelperArgumentsRoundTimeoutUpToWholeSeconds() {
        XCTAssertEqual(
            LANProbe.helperArguments(host: "192.0.2.7", port: 5555, timeout: 0.45),
            ["-z", "-G", "1", "192.0.2.7", "5555"]
        )
        XCTAssertEqual(
            LANProbe.helperArguments(host: "192.0.2.7", port: 5555, timeout: 2.2),
            ["-z", "-G", "3", "192.0.2.7", "5555"]
        )
    }
}

private final class ProbeCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

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

/// Telling a lost USB transport apart from an unplugged cable.
final class USBTransportHealingTests: XCTestCase {
    func testADBUSBSerialsIncludeEveryCableStateButNotWiFi() {
        let output = """
        List of devices attached
        RFCT10ZLTAJ            device usb:34603008X product:g0sxxx model:SM_S906B device:g0s transport_id:1
        OTHERPHONE             unauthorized usb:2-1 transport_id:3
        192.168.68.50:5555     device product:g0sxxx model:SM_S906B device:g0s transport_id:2
        adb-RFCT10ZLTAJ-x._adb-tls-connect._tcp device product:g0sxxx transport_id:4
        """
        XCTAssertEqual(AppModel.adbUSBSerials(in: output), ["RFCT10ZLTAJ", "OTHERPHONE"])
    }

    func testIORegSerialNumbersAreParsed() {
        let output = """
        +-o SAMSUNG_Android@02100000  <class IOUSBHostDevice, id 0x100022b6a>
            "USB Product Name" = "SAMSUNG_Android"
            "USB Serial Number" = "RFCT10ZLTAJ"
            "kUSBSerialNumberString" = "RFCT10ZLTAJ"
        +-o Keyboard@01100000  <class IOUSBHostDevice>
            "USB Serial Number" = "KB123"
        """
        XCTAssertEqual(AppModel.usbSerialNumbers(inIORegOutput: output), ["RFCT10ZLTAJ", "KB123"])
    }

    func testOnlyPairedPhonesOnTheCableWithoutAnADBTransportNeedRepair() {
        XCTAssertEqual(
            AppModel.usbPhonesMissingFromADB(
                macUSBSerials: ["RFCT10ZLTAJ", "KB123"],
                adbUSBSerials: [],
                pairedUSBSerials: ["RFCT10ZLTAJ"]
            ),
            ["RFCT10ZLTAJ"]
        )
        // Unplugged: macOS no longer sees it, nothing to repair.
        XCTAssertEqual(
            AppModel.usbPhonesMissingFromADB(macUSBSerials: ["KB123"], adbUSBSerials: [], pairedUSBSerials: ["RFCT10ZLTAJ"]),
            []
        )
        // Healthy, including an unauthorized row.
        XCTAssertEqual(
            AppModel.usbPhonesMissingFromADB(macUSBSerials: ["RFCT10ZLTAJ"], adbUSBSerials: ["RFCT10ZLTAJ"], pairedUSBSerials: ["RFCT10ZLTAJ"]),
            []
        )
    }
}

/// The first adb command starts the shared daemon warm-up instead of letting
/// the client auto-start a second daemon.
final class ADBServerPrimeTests: XCTestCase {
    func testFirstCommandStartsServerBeforeRunning() throws {
        let fake = try FakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        exit 0
        """)
        defer { fake.cleanup() }
        let original = ADBController.primesServerBeforeFirstCommand
        ADBController.primesServerBeforeFirstCommand = true
        defer { ADBController.primesServerBeforeFirstCommand = original }

        let adb = ADBController()
        _ = adb.run(["kill-server"], timeout: 2)   // resets the warm-up state
        _ = adb.run(["devices", "-l"], timeout: 2)
        _ = adb.run(["devices", "-l"], timeout: 2)

        let calls = (try? String(contentsOf: fake.log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        XCTAssertEqual(calls, ["kill-server", "start-server", "devices -l", "devices -l"])
    }

    /// Notification polling and mirror start call adb straight through
    /// Tooling; at launch they auto-started a second daemon.
    func testDirectToolingCallsAlsoWaitForTheWarmUp() throws {
        let fake = try FakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        exit 0
        """)
        defer { fake.cleanup() }
        let original = ADBController.primesServerBeforeFirstCommand
        ADBController.primesServerBeforeFirstCommand = true
        defer { ADBController.primesServerBeforeFirstCommand = original }

        _ = ADBController().run(["kill-server"], timeout: 2)
        _ = Tooling.runResult("adb", arguments: ["-s", "X", "shell", "dumpsys", "notification"], timeout: 2)

        let calls = (try? String(contentsOf: fake.log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        XCTAssertEqual(calls, ["kill-server", "start-server", "-s X shell dumpsys notification"])
    }
}

/// Small rules behind the 2026-10-04 reliability pass.
final class ConnectionPolishTests: XCTestCase {
    func testFixConnectionIgnoresRepeatPressesForAFewSeconds() {
        let now = Date()
        XCTAssertTrue(AppModel.shouldAcceptFixConnection(lastPressAt: nil, now: now))
        XCTAssertFalse(AppModel.shouldAcceptFixConnection(lastPressAt: now.addingTimeInterval(-1), now: now))
        XCTAssertTrue(AppModel.shouldAcceptFixConnection(
            lastPressAt: now.addingTimeInterval(-AppModel.fixConnectionDebounce - 0.1), now: now))
    }

    func testUSBRefreshRereadsTheMACPeriodically() {
        let now = Date()
        XCTAssertTrue(AppModel.shouldRefreshUSBWiFiMAC(lastRefreshedAt: nil, now: now))
        XCTAssertFalse(AppModel.shouldRefreshUSBWiFiMAC(lastRefreshedAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(AppModel.shouldRefreshUSBWiFiMAC(
            lastRefreshedAt: now.addingTimeInterval(-AppModel.usbWiFiMACRefreshInterval), now: now))
    }

    func testRecentWirelessVerificationIsReusedOnlyBriefly() {
        let original = AppModel.reusesRecentWirelessVerification
        AppModel.reusesRecentWirelessVerification = true
        defer { AppModel.reusesRecentWirelessVerification = original }
        let address = "192.0.2.201:5555"
        let now = Date()
        AppModel.noteWirelessRouteVerified(address, at: now)
        XCTAssertTrue(AppModel.wasWirelessRouteVerifiedRecently(address, now: now.addingTimeInterval(1)))
        XCTAssertFalse(AppModel.wasWirelessRouteVerifiedRecently(
            address, now: now.addingTimeInterval(AppModel.recentWirelessVerificationWindow + 0.1)))
        AppModel.noteWirelessRouteVerified(address, at: now)
        AppModel.forgetWirelessRouteVerification(address)
        XCTAssertFalse(AppModel.wasWirelessRouteVerifiedRecently(address, now: now))
    }

    func testNotificationPollingRelaxesOnlyAfterAQuietStretch() {
        XCTAssertEqual(NotificationForwarder.pollInterval(unchangedPolls: 0, base: 3), 3)
        XCTAssertEqual(
            NotificationForwarder.pollInterval(unchangedPolls: NotificationForwarder.quietAfterUnchangedPolls - 1, base: 3),
            3
        )
        XCTAssertEqual(
            NotificationForwarder.pollInterval(unchangedPolls: NotificationForwarder.quietAfterUnchangedPolls, base: 3),
            NotificationForwarder.quietPollInterval
        )
    }

    func testLocalNetworkDenialIsReportedOncePerLaunch() {
        LocalNetworkDenialReporter.resetForTesting()
        let counter = ProbeCallCounter2()
        let original = LocalNetworkDenialReporter.handler
        LocalNetworkDenialReporter.handler = { _ in counter.increment() }
        defer {
            LocalNetworkDenialReporter.handler = original
            LocalNetworkDenialReporter.resetForTesting()
        }
        LocalNetworkDenialReporter.report(source: "Bonjour")
        LocalNetworkDenialReporter.report(source: "port probe")
        XCTAssertEqual(counter.value, 1)
    }
}

private final class ProbeCallCounter2: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// A sweep that missed a sleeping phone must not park a phone adb lists live.
final class ListenerMissingVerdictTests: XCTestCase {
    @MainActor
    func testLiveWiFiTransportClearsTheVerdict() {
        let isolated = IsolatedPairedPhoneStore()
        defer { isolated.cleanup() }
        let record = PairedPhoneRecord(
            id: "RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "192.168.68.50:5555",
            usbSerial: "RFCT10ZLTAJ",
            wifiAddress: "192.168.68.50:5555",
            firstPaired: Date(timeIntervalSince1970: 0),
            lastConnected: Date(timeIntervalSince1970: 0)
        )
        let model = AppModel(startBackgroundServices: false, pairedPhones: [record], store: isolated.store)
        model.connectionCoordinator.wirelessListenerMissingRecordIDs = ["RFCT10ZLTAJ"]

        model.clearListenerMissingVerdictForLiveWirelessPhones([
            AuthorizedADBDevice(serial: "RFCT10ZLTAJ", product: "g0sxxx", model: "SM S906B", isUSB: true)
        ])
        XCTAssertEqual(model.connectionCoordinator.wirelessListenerMissingRecordIDs, ["RFCT10ZLTAJ"],
                       "a USB row says nothing about the Wi-Fi listener")

        model.clearListenerMissingVerdictForLiveWirelessPhones([
            AuthorizedADBDevice(serial: "192.168.68.50:5555", product: "g0sxxx", model: "SM S906B", isUSB: false)
        ])
        XCTAssertTrue(model.connectionCoordinator.wirelessListenerMissingRecordIDs.isEmpty)
    }
}

/// Detecting Phone Relay Helper and its permission from adb output.
final class HelperAppDetectionTests: XCTestCase {
    func testHelperInstalledIsAnExactPackageMatch() {
        XCTAssertTrue(AppModel.isHelperInstalled(packageListOutput: "package:com.mallenkb.phonerelay.helper\n"))
        XCTAssertFalse(AppModel.isHelperInstalled(packageListOutput: "package:com.mallenkb.phonerelay.helper.other\n"))
        XCTAssertFalse(AppModel.isHelperInstalled(packageListOutput: ""))
    }

    func testPermissionGrantIsReadFromDumpsys() {
        let granted = """
          runtime permissions:
            android.permission.WRITE_SECURE_SETTINGS: granted=true
        """
        let denied = """
            android.permission.WRITE_SECURE_SETTINGS: granted=false
        """
        XCTAssertTrue(AppModel.isHelperPermissionGranted(dumpsysPackageOutput: granted))
        XCTAssertFalse(AppModel.isHelperPermissionGranted(dumpsysPackageOutput: denied))
    }
}

/// The audio-data watchdog that turns a silent Wi-Fi drop into a disconnect.
final class StreamStallTests: XCTestCase {
    func testStallLimitIsThreeSecondsCheckedTwicePerSecond() {
        XCTAssertEqual(ScrcpyVideoStream.stallTimeout, 3)
        XCTAssertEqual(ScrcpyVideoStream.stallCheckInterval, 0.5)
        let start = Date()
        XCTAssertFalse(ScrcpyVideoStream.isStalled(lastDataAt: start, now: start.addingTimeInterval(2.9)))
        XCTAssertTrue(ScrcpyVideoStream.isStalled(lastDataAt: start, now: start.addingTimeInterval(3.1)))
    }
}

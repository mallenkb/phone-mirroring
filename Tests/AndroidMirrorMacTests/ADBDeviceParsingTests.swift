import XCTest
@testable import AndroidMirrorMac

final class ADBDeviceParsingTests: XCTestCase {
    func testAuthorizedADBDevicesIncludesUSBDeviceDetails() {
        let output = """
        List of devices attached
        R5CT123ABC device usb:336592896X product:raven model:Pixel_6_Pro device:raven transport_id:1
        192.168.1.22:5555 device product:oriole model:Pixel_6 device:oriole transport_id:2
        """

        let devices = AppModel.authorizedADBDevices(in: output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serial, "R5CT123ABC")
        XCTAssertEqual(devices[0].model, "Pixel 6 Pro")
        XCTAssertEqual(devices[0].product, "raven")
        XCTAssertTrue(devices[0].isUSB)
        XCTAssertFalse(devices[1].isUSB)
    }

    func testAuthorizedADBDevicesExcludesUnauthorizedAndOfflineDevices() {
        let output = """
        List of devices attached
        R5CT123ABC unauthorized usb:336592896X transport_id:1
        R5CT456DEF offline usb:336592897X transport_id:2
        R5CT789GHI device usb:336592898X product:cheetah model:Pixel_7_Pro device:cheetah transport_id:3
        """

        let devices = AppModel.authorizedADBDevices(in: output)

        XCTAssertEqual(devices.map(\.serial), ["R5CT789GHI"])
    }

    func testAuthorizedADBDevicesIgnoresDaemonStartupNoiseAndHeader() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        192.168.68.54:5555 device product:g0sxxx model:SM_S906B device:g0s transport_id:1
        """

        let devices = AppModel.authorizedADBDevices(in: output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "192.168.68.54:5555")
        XCTAssertEqual(devices[0].model, "SM S906B")
    }

    func testAuthorizedADBDevicesDoesNotTreatHeaderAsDeviceWhenDaemonNoisePrecedesIt() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        """

        XCTAssertTrue(AppModel.authorizedADBDevices(in: output).isEmpty)
    }

    func testADBConnectResultParsing() {
        XCTAssertTrue(AppModel.adbConnectSucceeded("connected to 192.168.68.57:5555"))
        XCTAssertTrue(AppModel.adbConnectSucceeded("already connected to 192.168.68.57:5555"))
        XCTAssertFalse(AppModel.adbConnectSucceeded("failed to connect to '192.168.68.57:5555': No route to host"))
    }

    func testADBNotificationParsingExtractsPackageTitleAndBody() {
        let output = """
          NotificationRecord(0xabc: pkg=com.google.android.gm user=UserHandle{0} id=42 tag=null)
            key=0|com.google.android.gm|42|null|10012
            extras={
              android.title=String (Inbox update)
              android.text=String (New message from Sam)
            }
          NotificationRecord(0xdef: pkg=com.android.systemui user=UserHandle{0} id=9 tag=null)
            key=0|com.android.systemui|9|null|1000
            extras={
              android.title=String (System UI)
              android.text=String (Ignored)
            }
        """

        let summaries = AppModel.parsedADBNotificationSummariesForTesting(output)

        XCTAssertEqual(summaries, ["Gm|Inbox update|New message from Sam"])
    }

    func testRecordsByMostRecentIncludesUSBAndWireless() {
        let olderWireless = PairedPhoneRecord(
            id: "wifi-phone",
            displayName: "Wi-Fi Pixel",
            lastAddress: "192.168.1.22:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let newerUSB = PairedPhoneRecord(
            id: "R5CT123ABC",
            displayName: "USB Pixel",
            lastAddress: "R5CT123ABC",
            firstPaired: Date(timeIntervalSince1970: 300),
            lastConnected: Date(timeIntervalSince1970: 900)
        )

        let selected = AppModel.recordsByMostRecent([olderWireless, newerUSB])

        XCTAssertEqual(selected.map(\.id), ["R5CT123ABC", "wifi-phone"])
        XCTAssertFalse(AppModel.isWirelessRecord(newerUSB))
        XCTAssertTrue(AppModel.isWirelessRecord(olderWireless))
    }

    func testRememberedAuthorizedDeviceMatchesSerialOrAddress() {
        let record = PairedPhoneRecord(
            id: "R5CT123ABC",
            displayName: "Pixel",
            lastAddress: "R5CT123ABC",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let device = AuthorizedADBDevice(
            serial: "R5CT123ABC",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        XCTAssertEqual(
            AppModel.rememberedAuthorizedDevice(for: record, in: [device]),
            device
        )
    }

    func testRememberedAuthorizedDeviceFallsBackToSpecificModelName() {
        let record = PairedPhoneRecord(
            id: "adb-old-session",
            displayName: "SM S906B",
            lastAddress: "192.168.68.51:33883",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let device = AuthorizedADBDevice(
            serial: "192.168.68.57:39757",
            product: "g0s",
            model: "SM S906B",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.rememberedAuthorizedDevice(for: record, in: [device]),
            device
        )
    }

    func testRememberedAuthorizedDeviceDoesNotMatchGenericAndroidDeviceName() {
        let record = PairedPhoneRecord(
            id: "adb-old-session",
            displayName: "Android device",
            lastAddress: "192.168.68.51:33883",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let device = AuthorizedADBDevice(
            serial: "192.168.68.57:39757",
            product: "g0s",
            model: "Android device",
            isUSB: false
        )

        XCTAssertNil(AppModel.rememberedAuthorizedDevice(for: record, in: [device]))
    }

    func testRememberedConnectablePhonePrefersStoredServiceID() {
        let record = PairedPhoneRecord(
            id: "adb-samsung",
            displayName: "Samsung",
            lastAddress: "192.168.1.44:42111",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let matching = DiscoveredPhone(
            id: "adb-samsung",
            address: "192.168.1.44:39001",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )
        let sameHostDifferentID = DiscoveredPhone(
            id: "adb-other",
            address: "192.168.1.44:42111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 400)
        )

        let selected = AppModel.rememberedConnectablePhone(
            for: record,
            in: [sameHostDifferentID, matching]
        )

        XCTAssertEqual(selected, matching)
    }

    func testRememberedConnectablePhoneFallsBackToStoredHost() {
        let record = PairedPhoneRecord(
            id: "adb-samsung",
            displayName: "Samsung",
            lastAddress: "192.168.1.44:42111",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let matching = DiscoveredPhone(
            id: "adb-new-id",
            address: "192.168.1.44:39001",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )

        let selected = AppModel.rememberedConnectablePhone(
            for: record,
            in: [matching]
        )

        XCTAssertEqual(selected, matching)
    }

    func testRememberedConnectablePhoneUsesOnlyLiveConnectableWhenSavedRouteChanged() {
        let record = PairedPhoneRecord(
            id: "adb-samsung",
            displayName: "Samsung",
            lastAddress: "192.168.1.44:42111",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let currentRoute = DiscoveredPhone(
            id: "adb-current-session",
            address: "192.168.68.54:46507",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )

        let selected = AppModel.rememberedConnectablePhone(
            for: record,
            in: [currentRoute]
        )

        XCTAssertEqual(selected, currentRoute)
    }

    func testWiFiIPAddressParsingPrefersWLANSourceAddress() {
        let output = """
        default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.44
        192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.44
        """

        XCTAssertEqual(AppModel.wifiIPAddress(in: output), "192.168.1.44")
    }

    func testWiFiIPAddressParsingIgnoresNonWiFiRoutes() {
        let output = "10.0.2.0/24 dev rmnet_data0 proto kernel scope link src 10.0.2.15"

        XCTAssertNil(AppModel.wifiIPAddress(in: output))
    }

    func testWirelessPhoneMatchingUSBRoutePrefersSameWiFiHost() {
        let routeOutput = "default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.44"
        let other = DiscoveredPhone(
            id: "adb-other",
            address: "192.168.1.22:39111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )
        let matching = DiscoveredPhone(
            id: "adb-matching",
            address: "192.168.1.44:42111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 200)
        )

        let selected = AppModel.wirelessPhoneMatchingUSBRoute(
            routeOutput,
            phones: [other, matching]
        )

        XCTAssertEqual(selected, matching)
    }

    func testWirelessPhoneMatchingUSBRouteIgnoresPairingOnlyServices() {
        let routeOutput = "default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.44"
        let pairingOnly = DiscoveredPhone(
            id: "adb-pairing",
            address: "192.168.1.44:39111",
            kind: .pairable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )

        let selected = AppModel.wirelessPhoneMatchingUSBRoute(
            routeOutput,
            phones: [pairingOnly]
        )

        XCTAssertNil(selected)
    }

    func testWirelessDebuggingAddressCombinesUSBWiFiIPAndTLSPort() {
        let routeOutput = "default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.44"

        XCTAssertEqual(
            AppModel.wirelessDebuggingAddress(routeOutput: routeOutput, tlsPortOutput: "42111\n"),
            "192.168.1.44:42111"
        )
    }

    func testWirelessDebuggingAddressIgnoresInvalidTLSPort() {
        let routeOutput = "default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.44"

        XCTAssertNil(
            AppModel.wirelessDebuggingAddress(routeOutput: routeOutput, tlsPortOutput: "-1\n")
        )
    }

    func testWirelessDebuggingAddressFallsBackToLegacyTCPPort() {
        let routeOutput = "default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.44"

        XCTAssertEqual(
            AppModel.wirelessDebuggingAddress(
                routeOutput: routeOutput,
                tlsPortOutput: "\n",
                tcpPortOutput: "5555\n"
            ),
            "192.168.1.44:5555"
        )
    }

    func testLegacyTCPIPDebuggingAddressUsesUSBWiFiIPAndDefaultPort() {
        let routeOutput = "default via 192.168.1.1 dev wlan0 proto dhcp src 192.168.1.44"

        XCTAssertEqual(
            AppModel.legacyTCPIPDebuggingAddress(routeOutput: routeOutput),
            "192.168.1.44:5555"
        )
    }

    func testLegacyTCPIPDebuggingAddressRequiresWiFiRoute() {
        let routeOutput = "10.0.2.0/24 dev rmnet_data0 proto kernel scope link src 10.0.2.15"

        XCTAssertNil(AppModel.legacyTCPIPDebuggingAddress(routeOutput: routeOutput))
    }

    func testReconnectCandidatesAppendStableLegacyPort() {
        XCTAssertEqual(
            AppModel.reconnectCandidateAddresses(for: "192.168.1.44:42111"),
            ["192.168.1.44:42111", "192.168.1.44:5555"]
        )
    }

    func testReconnectCandidatesDoNotDuplicateLegacyPort() {
        XCTAssertEqual(
            AppModel.reconnectCandidateAddresses(for: "192.168.1.44:5555"),
            ["192.168.1.44:5555"]
        )
    }

    func testADBTCPIPResultParsing() {
        XCTAssertTrue(AppModel.adbTCPIPSucceeded("restarting in TCP mode port: 5555"))
        XCTAssertTrue(AppModel.adbTCPIPSucceeded("already in TCP mode"))
        XCTAssertFalse(AppModel.adbTCPIPSucceeded("error: device unauthorized"))
    }

    func testWaitForADBConnectRetriesUntilADBAcceptsWirelessTarget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMirrorMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_LOG")
            unsetenv("ADB_FAKE_COUNT")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("adb.log")
        let count = directory.appendingPathComponent("adb.count")
        let script = """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          current=$(cat "$ADB_FAKE_COUNT" 2>/dev/null || echo 0)
          current=$((current + 1))
          echo "$current" > "$ADB_FAKE_COUNT"
          if [ "$current" -lt 3 ]; then
            echo "failed to connect to '$2': Connection refused"
          else
            echo "connected to $2"
          fi
          exit 0
        fi
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)
        setenv("ADB_FAKE_LOG", log.path, 1)
        setenv("ADB_FAKE_COUNT", count.path, 1)

        let connected = await AppModel.waitForADBConnect(
            adb: ADBController(),
            address: "192.168.68.57:5555",
            attempts: 4,
            delayNanoseconds: 1
        )

        XCTAssertTrue(connected)
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(calls, [
            "connect 192.168.68.57:5555",
            "connect 192.168.68.57:5555",
            "connect 192.168.68.57:5555"
        ])
    }

    func testWaitForADBWirelessTargetReadyWaitsForShellCommand() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMirrorMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_LOG")
            unsetenv("ADB_FAKE_SHELL_COUNT")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("adb.log")
        let shellCount = directory.appendingPathComponent("adb-shell.count")
        let script = """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          current=$(cat "$ADB_FAKE_SHELL_COUNT" 2>/dev/null || echo 0)
          current=$((current + 1))
          echo "$current" > "$ADB_FAKE_SHELL_COUNT"
          if [ "$current" -lt 3 ]; then
            echo "error: protocol fault (couldn't read status): Undefined error: 0"
          else
            echo "wifi-adb-ok"
          fi
          exit 0
        fi
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)
        setenv("ADB_FAKE_LOG", log.path, 1)
        setenv("ADB_FAKE_SHELL_COUNT", shellCount.path, 1)

        let ready = await AppModel.waitForADBWirelessTargetReady(
            adb: ADBController(),
            address: "192.168.68.57:5555",
            attempts: 4,
            delayNanoseconds: 1
        )

        XCTAssertTrue(ready)
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(calls, [
            "connect 192.168.68.57:5555",
            "-s 192.168.68.57:5555 shell echo wifi-adb-ok",
            "connect 192.168.68.57:5555",
            "-s 192.168.68.57:5555 shell echo wifi-adb-ok",
            "connect 192.168.68.57:5555",
            "-s 192.168.68.57:5555 shell echo wifi-adb-ok"
        ])
    }

    func testWaitForADBWirelessTargetReadyPrimesRouteBeforeEachConnectAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMirrorMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_LOG")
            unsetenv("ADB_FAKE_COUNT")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("adb.log")
        let count = directory.appendingPathComponent("adb.count")
        let script = """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          current=$(cat "$ADB_FAKE_COUNT" 2>/dev/null || echo 0)
          current=$((current + 1))
          echo "$current" > "$ADB_FAKE_COUNT"
          if [ "$current" -lt 3 ]; then
            echo "failed to connect to '$2': No route to host"
          else
            echo "connected to $2"
          fi
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          echo "wifi-adb-ok"
          exit 0
        fi
        exit 0
        """
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)
        setenv("ADB_FAKE_LOG", log.path, 1)
        setenv("ADB_FAKE_COUNT", count.path, 1)

        var primeCount = 0
        let ready = await AppModel.waitForADBWirelessTargetReady(
            adb: ADBController(),
            address: "192.168.68.57:5555",
            attempts: 4,
            delayNanoseconds: 1,
            primeRoute: {
                primeCount += 1
            }
        )

        XCTAssertTrue(ready)
        XCTAssertEqual(primeCount, 3)
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(calls, [
            "connect 192.168.68.57:5555",
            "connect 192.168.68.57:5555",
            "connect 192.168.68.57:5555",
            "-s 192.168.68.57:5555 shell echo wifi-adb-ok"
        ])
    }

    func testUSBHandoffCandidateReturnsNewAuthorizedUSBDevice() {
        let output = """
        List of devices attached
        R5CT123ABC device usb:336592896X product:raven model:Pixel_6_Pro device:raven transport_id:1
        """

        let candidate = AppModel.usbHandoffCandidate(
            in: output,
            lastAttemptedSerial: nil
        )

        XCTAssertEqual(candidate?.serial, "R5CT123ABC")
    }

    func testUSBHandoffCandidateIgnoresAlreadyAttemptedSerial() {
        let output = """
        List of devices attached
        R5CT123ABC device usb:336592896X product:raven model:Pixel_6_Pro device:raven transport_id:1
        """

        let candidate = AppModel.usbHandoffCandidate(
            in: output,
            lastAttemptedSerial: "R5CT123ABC"
        )

        XCTAssertNil(candidate)
    }
}

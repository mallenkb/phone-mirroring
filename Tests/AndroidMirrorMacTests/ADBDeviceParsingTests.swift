import XCTest
@testable import AndroidMirrorMac

final class ADBDeviceParsingTests: XCTestCase {
    func testAuthorizedADBDevicesIncludesUSBDeviceDetails() {
        let output = """
        List of devices attached
        TESTDEVICE001 device usb:100000001X product:raven model:Pixel_6_Pro device:raven transport_id:1
        192.0.2.22:5555 device product:oriole model:Pixel_6 device:oriole transport_id:2
        """

        let devices = AppModel.authorizedADBDevices(in: output)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].serial, "TESTDEVICE001")
        XCTAssertEqual(devices[0].model, "Pixel 6 Pro")
        XCTAssertEqual(devices[0].product, "raven")
        XCTAssertTrue(devices[0].isUSB)
        XCTAssertFalse(devices[1].isUSB)
    }

    func testAuthorizedADBDevicesExcludesUnauthorizedAndOfflineDevices() {
        let output = """
        List of devices attached
        TESTDEVICE001 unauthorized usb:100000001X transport_id:1
        TESTDEVICE002 offline usb:100000002X transport_id:2
        TESTDEVICE003 device usb:100000003X product:cheetah model:Pixel_7_Pro device:cheetah transport_id:3
        """

        let devices = AppModel.authorizedADBDevices(in: output)

        XCTAssertEqual(devices.map(\.serial), ["TESTDEVICE003"])
    }

    func testAuthorizedADBDevicesIgnoresDaemonStartupNoiseAndHeader() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        192.0.2.54:5555 device product:g0sxxx model:SM_S906B device:g0s transport_id:1
        """

        let devices = AppModel.authorizedADBDevices(in: output)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].serial, "192.0.2.54:5555")
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
        XCTAssertTrue(AppModel.adbConnectSucceeded("connected to 192.0.2.57:5555"))
        XCTAssertTrue(AppModel.adbConnectSucceeded("already connected to 192.0.2.57:5555"))
        XCTAssertFalse(AppModel.adbConnectSucceeded("failed to connect to '192.0.2.57:5555': No route to host"))
    }

    func testRecordsByMostRecentIncludesUSBAndWireless() {
        let olderWireless = PairedPhoneRecord(
            id: "wifi-phone",
            displayName: "Wi-Fi Pixel",
            lastAddress: "192.0.2.22:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let newerUSB = PairedPhoneRecord(
            id: "TESTDEVICE001",
            displayName: "USB Pixel",
            lastAddress: "TESTDEVICE001",
            firstPaired: Date(timeIntervalSince1970: 300),
            lastConnected: Date(timeIntervalSince1970: 900)
        )

        let selected = AppModel.recordsByMostRecent([olderWireless, newerUSB])

        XCTAssertEqual(selected.map(\.id), ["TESTDEVICE001", "wifi-phone"])
        XCTAssertFalse(AppModel.isWirelessRecord(newerUSB))
        XCTAssertTrue(AppModel.isWirelessRecord(olderWireless))
    }

    func testRememberedAuthorizedDeviceMatchesSerialOrAddress() {
        let record = PairedPhoneRecord(
            id: "TESTDEVICE001",
            displayName: "Pixel",
            lastAddress: "TESTDEVICE001",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let device = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        XCTAssertEqual(
            AppModel.rememberedAuthorizedDevice(for: record, in: [device]),
            device
        )
    }

    func testUSBMirroringPreferenceKeepsAuthorizedUSBDeviceOnCable() {
        let usbDevice = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        XCTAssertFalse(AppModel.shouldAttemptWirelessHandoff(from: usbDevice, preferUSBMirroring: true))
        XCTAssertTrue(AppModel.shouldAttemptWirelessHandoff(from: usbDevice, preferUSBMirroring: false))
    }

    func testRememberedAuthorizedDeviceFallsBackToSpecificModelName() {
        let record = PairedPhoneRecord(
            id: "adb-old-session",
            displayName: "SM S906B",
            lastAddress: "192.0.2.51:33883",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let device = AuthorizedADBDevice(
            serial: "192.0.2.57:39757",
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
            lastAddress: "192.0.2.51:33883",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let device = AuthorizedADBDevice(
            serial: "192.0.2.57:39757",
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
            lastAddress: "192.0.2.44:42111",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let matching = DiscoveredPhone(
            id: "adb-samsung",
            address: "192.0.2.44:39001",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )
        let sameHostDifferentID = DiscoveredPhone(
            id: "adb-other",
            address: "192.0.2.44:42111",
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
            lastAddress: "192.0.2.44:42111",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let matching = DiscoveredPhone(
            id: "adb-new-id",
            address: "192.0.2.44:39001",
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
            lastAddress: "192.0.2.44:42111",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let currentRoute = DiscoveredPhone(
            id: "adb-current-session",
            address: "192.0.2.54:46507",
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
        default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44
        192.0.2.0/24 dev wlan0 proto kernel scope link src 192.0.2.44
        """

        XCTAssertEqual(AppModel.wifiIPAddress(in: output), "192.0.2.44")
    }

    func testWiFiIPAddressParsingIgnoresNonWiFiRoutes() {
        let output = "198.51.100.0/24 dev rmnet_data0 proto kernel scope link src 198.51.100.15"

        XCTAssertNil(AppModel.wifiIPAddress(in: output))
    }

    func testWirelessPhoneMatchingUSBRoutePrefersSameWiFiHost() {
        let routeOutput = "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
        let other = DiscoveredPhone(
            id: "adb-other",
            address: "192.0.2.22:39111",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )
        let matching = DiscoveredPhone(
            id: "adb-matching",
            address: "192.0.2.44:42111",
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
        let routeOutput = "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
        let pairingOnly = DiscoveredPhone(
            id: "adb-pairing",
            address: "192.0.2.44:39111",
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
        let routeOutput = "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"

        XCTAssertEqual(
            AppModel.wirelessDebuggingAddress(routeOutput: routeOutput, tlsPortOutput: "42111\n"),
            "192.0.2.44:42111"
        )
    }

    func testWirelessDebuggingAddressIgnoresInvalidTLSPort() {
        let routeOutput = "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"

        XCTAssertNil(
            AppModel.wirelessDebuggingAddress(routeOutput: routeOutput, tlsPortOutput: "-1\n")
        )
    }

    func testWirelessDebuggingAddressFallsBackToLegacyTCPPort() {
        let routeOutput = "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"

        XCTAssertEqual(
            AppModel.wirelessDebuggingAddress(
                routeOutput: routeOutput,
                tlsPortOutput: "\n",
                tcpPortOutput: "5555\n"
            ),
            "192.0.2.44:5555"
        )
    }

    func testLegacyTCPIPDebuggingAddressUsesUSBWiFiIPAndDefaultPort() {
        let routeOutput = "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"

        XCTAssertEqual(
            AppModel.legacyTCPIPDebuggingAddress(routeOutput: routeOutput),
            "192.0.2.44:5555"
        )
    }

    func testLegacyTCPIPDebuggingAddressRequiresWiFiRoute() {
        let routeOutput = "198.51.100.0/24 dev rmnet_data0 proto kernel scope link src 198.51.100.15"

        XCTAssertNil(AppModel.legacyTCPIPDebuggingAddress(routeOutput: routeOutput))
    }

    func testReconnectCandidatesAppendStableLegacyPort() {
        XCTAssertEqual(
            AppModel.reconnectCandidateAddresses(for: "192.0.2.44:42111"),
            ["192.0.2.44:42111", "192.0.2.44:5555"]
        )
    }

    func testReconnectCandidatesDoNotDuplicateLegacyPort() {
        XCTAssertEqual(
            AppModel.reconnectCandidateAddresses(for: "192.0.2.44:5555"),
            ["192.0.2.44:5555"]
        )
    }

    func testPromoteToLegacyTCPIPSwitchesWirelessDeviceToPort5555() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMirrorMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_LOG")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("adb.log")
        let script = """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ]; then
          echo "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "tcpip" ]; then
          echo "restarting in TCP mode port: 5555"
          exit 0
        fi
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
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

        let promoted = await AppModel.promoteToLegacyTCPIP(
            adb: ADBController(),
            sourceSerial: "192.0.2.44:42111"
        )

        XCTAssertEqual(promoted, "192.0.2.44:5555")
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(calls.contains("-s 192.0.2.44:42111 tcpip 5555"))
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
    }

    func testPromoteToLegacyTCPIPReturnsNilWhenDeviceRefusesTCPIP() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMirrorMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_LOG")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("adb.log")
        let script = """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ]; then
          echo "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "tcpip" ]; then
          echo "error: closed"
          exit 1
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

        let promoted = await AppModel.promoteToLegacyTCPIP(
            adb: ADBController(),
            sourceSerial: "192.0.2.44:42111"
        )

        XCTAssertNil(promoted)
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
            address: "192.0.2.57:5555",
            attempts: 4,
            delayNanoseconds: 1
        )

        XCTAssertTrue(connected)
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(calls, [
            "connect 192.0.2.57:5555",
            "connect 192.0.2.57:5555",
            "connect 192.0.2.57:5555"
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
            address: "192.0.2.57:5555",
            attempts: 4,
            delayNanoseconds: 1
        )

        XCTAssertTrue(ready)
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(calls, [
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok",
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok",
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok"
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
            address: "192.0.2.57:5555",
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
            "connect 192.0.2.57:5555",
            "connect 192.0.2.57:5555",
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok"
        ])
    }

    func testUSBHandoffCandidateReturnsNewAuthorizedUSBDevice() {
        let output = """
        List of devices attached
        TESTDEVICE001 device usb:100000001X product:raven model:Pixel_6_Pro device:raven transport_id:1
        """

        let candidate = AppModel.usbHandoffCandidate(
            in: output,
            lastAttemptedSerial: nil
        )

        XCTAssertEqual(candidate?.serial, "TESTDEVICE001")
    }

    func testUSBHandoffCandidateIgnoresAlreadyAttemptedSerial() {
        let output = """
        List of devices attached
        TESTDEVICE001 device usb:100000001X product:raven model:Pixel_6_Pro device:raven transport_id:1
        """

        let candidate = AppModel.usbHandoffCandidate(
            in: output,
            lastAttemptedSerial: "TESTDEVICE001"
        )

        XCTAssertNil(candidate)
    }

    // MARK: - Remembered wireless reconnect readiness

    func testConnectToRememberedWirelessRejectsConnectWhenShellReadinessFails() async throws {
        // adb "connects" to every candidate but never accepts a shell command, so
        // no candidate is usable — the readiness probe must veto the bare connect.
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          echo "error: protocol fault (couldn't read status): Undefined error: 0"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let connected = await AppModel.connectToRememberedWireless(
            adb: ADBController(),
            savedAddress: "192.0.2.44:42111"
        )

        XCTAssertNil(connected)
        // Both the saved port and the stable :5555 fallback should be attempted.
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("connect 192.0.2.44:42111"))
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
    }

    func testConnectToRememberedWirelessAcceptsFirstCandidateThatIsShellReady() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          echo "wifi-adb-ok"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let connected = await AppModel.connectToRememberedWireless(
            adb: ADBController(),
            savedAddress: "192.0.2.44:42111"
        )

        XCTAssertEqual(connected, "192.0.2.44:42111")
        // The saved port worked, so the :5555 fallback is never tried.
        XCTAssertFalse(loggedCalls(fake.log).contains("connect 192.0.2.44:5555"))
    }

    func testConnectToRememberedWirelessFallsBackToLegacyPortWhenSavedPortNotReady() async throws {
        // The saved TLS port connects but won't run a shell (toggle since turned
        // off); the stable :5555 listener is shell-ready and wins.
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          case "$2" in
            *:5555) echo "wifi-adb-ok" ;;
            *) echo "error: closed" ;;
          esac
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let connected = await AppModel.connectToRememberedWireless(
            adb: ADBController(),
            savedAddress: "192.0.2.44:42111"
        )

        XCTAssertEqual(connected, "192.0.2.44:5555")
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("connect 192.0.2.44:42111"))
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
    }

    func testConnectToUSBDeviceOverCurrentWiFiUsesExistingLegacyListener() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ]; then
          echo "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
          exit 0
        fi
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          echo "wifi-adb-ok"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ping" ]; then
          echo "1 packets transmitted, 1 received"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let connected = await AppModel.connectToUSBDeviceOverCurrentWiFi(
            adb: ADBController(),
            usbDevice: AuthorizedADBDevice(
                serial: "TESTDEVICE001",
                product: "raven",
                model: "Pixel 6 Pro",
                isUSB: true
            )
        )

        XCTAssertEqual(connected, "192.0.2.44:5555")
        XCTAssertFalse(loggedCalls(fake.log).contains("-s TESTDEVICE001 tcpip 5555"))
    }

    func testConnectToUSBDeviceOverCurrentWiFiStartsTCPIPWhenNeeded() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ]; then
          echo "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
          exit 0
        fi
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          if grep -q tcpip "$ADB_FAKE_LOG"; then
            echo "wifi-adb-ok"
          else
            echo "error: closed"
          fi
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "tcpip" ]; then
          echo "restarting in TCP mode port: 5555"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ping" ]; then
          echo "1 packets transmitted, 1 received"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let connected = await AppModel.connectToUSBDeviceOverCurrentWiFi(
            adb: ADBController(),
            usbDevice: AuthorizedADBDevice(
                serial: "TESTDEVICE001",
                product: "raven",
                model: "Pixel 6 Pro",
                isUSB: true
            )
        )

        XCTAssertEqual(connected, "192.0.2.44:5555")
        XCTAssertTrue(loggedCalls(fake.log).contains("-s TESTDEVICE001 tcpip 5555"))
    }

    func testShouldPromoteToLegacyTCPIPSkipsAddressesAlreadyOnPort5555() {
        XCTAssertFalse(AppModel.shouldPromoteToLegacyTCPIP(connectedAddress: "192.0.2.44:5555"))
        XCTAssertTrue(AppModel.shouldPromoteToLegacyTCPIP(connectedAddress: "192.0.2.44:42111"))
    }

    // MARK: - Fake adb helpers

    /// Writes an executable fake `adb` to a throwaway directory, points the
    /// tooling env vars at it, and returns the log file each invocation appends
    /// its arguments to plus a cleanup closure the caller defers.
    private func installFakeADB(script: String) throws -> (log: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMirrorMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fakeADB = directory.appendingPathComponent("adb")
        let log = directory.appendingPathComponent("adb.log")
        try script.write(to: fakeADB, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeADB.path
        )
        setenv("ANDROID_MIRROR_ADB_PATH", fakeADB.path, 1)
        setenv("ADB_FAKE_LOG", log.path, 1)
        return (log, {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_LOG")
        })
    }

    private func loggedCalls(_ log: URL) -> [String] {
        (try? String(contentsOf: log, encoding: .utf8))?
            .split(whereSeparator: \.isNewline)
            .map(String.init) ?? []
    }
}

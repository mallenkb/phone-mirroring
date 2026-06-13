import XCTest
@testable import PhoneRelay

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

    @MainActor
    func testMirrorFailureMessageTreatsADBPushEOFAsDeviceOffline() {
        let error = MirrorSession.SessionError.start("""
        adb push failed: /Applications/PhoneRelay.app/Contents/Resources/scrcpy-server: 1 file pushed, 0 skipped.
        adb: error: failed to read copy response: EOF
        """)

        XCTAssertEqual(
            AppModel.mirrorFailureMessage(for: error),
            "The phone went offline. Reconnect it (USB or Wi-Fi) and try again."
        )
    }

    @MainActor
    func testMirrorFailureMessageKeepsMissingServerArtifactAction() {
        XCTAssertEqual(
            AppModel.mirrorFailureMessage(for: ScrcpyServerHost.HostError.missingServerArtifact),
            "The mirroring engine file is missing from the app. Reinstall PhoneRelay."
        )
    }

    func testTransientMirrorLaunchFailuresKeepRetryingWithoutBadge() {
        XCTAssertTrue(AppModel.shouldKeepRetryingMirrorLaunchFailure("The phone went offline. Reconnect it (USB or Wi-Fi) and try again."))
        XCTAssertTrue(AppModel.shouldKeepRetryingMirrorLaunchFailure("Could not start mirror: adb reverse failed: adb: error: closed"))
        XCTAssertTrue(AppModel.shouldKeepRetryingMirrorLaunchFailure("failed to connect to '192.168.68.57:5555': Connection refused"))
        XCTAssertTrue(AppModel.shouldKeepRetryingMirrorLaunchFailure("The phone didn’t respond in time. Check the cable or Wi-Fi connection and try again."))
    }

    func testActionableMirrorLaunchFailuresStillSurface() {
        XCTAssertFalse(AppModel.shouldKeepRetryingMirrorLaunchFailure("This Mac isn't authorized on the phone yet. Unlock the phone and tap Allow."))
        XCTAssertFalse(AppModel.shouldKeepRetryingMirrorLaunchFailure("The mirroring engine file is missing from the app. Reinstall PhoneRelay."))
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

    // When the same phone is live on both transports, auto-connect must take
    // the wireless one — it mirrors immediately, no tcpip handoff round-trip.
    func testRememberedAuthorizedDevicePrefersWirelessTransportOverUSB() {
        let record = PairedPhoneRecord(
            id: "TESTDEVICE001",
            displayName: "Pixel",
            lastAddress: "192.0.2.51:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let usb = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )
        let wireless = AuthorizedADBDevice(
            serial: "192.0.2.51:5555",
            product: "raven",
            model: "Pixel",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.rememberedAuthorizedDevice(for: record, in: [usb, wireless]),
            wireless
        )
        XCTAssertEqual(
            AppModel.rememberedAuthorizedDevice(for: record, in: [usb]),
            usb
        )
    }

    func testRememberedAuthorizedDevicePrefersWirelessModelMatchOverUSB() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "Android-3.local:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let usb = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: true
        )
        let wireless = AuthorizedADBDevice(
            serial: "192.168.68.57:5555",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.rememberedAuthorizedDevice(for: record, in: [usb, wireless]),
            wireless
        )
    }

    func testOutputIndicatesLocalNetworkBlocked() {
        XCTAssertTrue(
            AppModel.outputIndicatesLocalNetworkBlocked(
                "failed to connect to '192.0.2.50:5555': No route to host"
            )
        )
        XCTAssertFalse(
            AppModel.outputIndicatesLocalNetworkBlocked(
                "failed to connect to '192.0.2.50:5555': Connection refused"
            )
        )
        XCTAssertFalse(AppModel.outputIndicatesLocalNetworkBlocked("connected to 192.0.2.50:5555"))
    }

    func testLocalNetworkPreflightAddressParsing() {
        XCTAssertEqual(
            AppModel.localNetworkEndpointParts(from: "192.0.2.57:5555"),
            AppModel.LocalNetworkEndpointParts(host: "192.0.2.57", port: 5555)
        )
        XCTAssertEqual(
            AppModel.localNetworkEndpointParts(from: "pixel.local:42111"),
            AppModel.LocalNetworkEndpointParts(host: "pixel.local", port: 42111)
        )
        XCTAssertNil(AppModel.localNetworkEndpointParts(from: "TESTDEVICE001"))
        XCTAssertNil(AppModel.localNetworkEndpointParts(from: "192.0.2.57:not-a-port"))
        XCTAssertNil(AppModel.localNetworkEndpointParts(from: "192.0.2.57:0"))
    }

    func testWaitForWirelessTargetReadinessRunsLocalNetworkPreflightBeforeADBConnect() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          echo "wifi-adb-ok"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let recorder = LocalNetworkPreflightRecorder()

        let readiness = await AppModel.waitForADBWirelessTargetReadiness(
            adb: ADBController(),
            address: "192.0.2.57:5555",
            attempts: 2,
            delayNanoseconds: 1,
            preflightLocalNetworkAccess: { address in
                await recorder.record(address)
            }
        )

        XCTAssertTrue(readiness.isReady)
        XCTAssertFalse(readiness.sawNoRouteToHost)
        let preflightedAddresses = await recorder.snapshot()
        XCTAssertEqual(preflightedAddresses, ["192.0.2.57:5555"])
    }

    func testWaitForWirelessTargetReadinessStopsImmediatelyWhenCancelled() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          sleep 2
          echo "connected to $2"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let task = Task {
            await AppModel.waitForADBWirelessTargetReadiness(
                adb: ADBController(),
                address: "Android.local:5555",
                attempts: 3,
                delayNanoseconds: 1
            )
        }
        task.cancel()

        let readiness = await task.value

        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.connectAttempts, 0)
        XCTAssertEqual(loggedCalls(fake.log), [])
    }

    // "No route to host" on every attempt is how a denied macOS Local Network
    // permission presents; the readiness result must carry that signal up so
    // the app can tell the user instead of failing silently forever.
    func testWaitForWirelessTargetReadinessFlagsNoRouteToHost() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        if [ "$1" = "connect" ]; then
          echo "failed to connect to '$2': No route to host"
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

        let readiness = await AppModel.waitForADBWirelessTargetReadiness(
            adb: ADBController(),
            address: "192.0.2.57:5555",
            attempts: 2,
            delayNanoseconds: 1
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertTrue(readiness.sawNoRouteToHost)
    }

    func testWaitForWirelessTargetReadinessDoesNotFlagOrdinaryFailures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let script = """
        #!/bin/sh
        if [ "$1" = "connect" ]; then
          echo "failed to connect to '$2': Connection refused"
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

        let readiness = await AppModel.waitForADBWirelessTargetReadiness(
            adb: ADBController(),
            address: "192.0.2.57:5555",
            attempts: 2,
            delayNanoseconds: 1
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertFalse(readiness.sawNoRouteToHost)
    }

    func testWaitForWirelessTargetReadinessDoesNotFlagMixedNoRouteFailures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            unsetenv("ANDROID_MIRROR_ADB_PATH")
            unsetenv("ADB_FAKE_COUNT")
        }

        let fakeADB = directory.appendingPathComponent("adb")
        let count = directory.appendingPathComponent("adb.count")
        let script = """
        #!/bin/sh
        if [ "$1" = "connect" ]; then
          current=$(cat "$ADB_FAKE_COUNT" 2>/dev/null || echo 0)
          current=$((current + 1))
          echo "$current" > "$ADB_FAKE_COUNT"
          if [ "$current" -eq 1 ]; then
            echo "failed to connect to '$2': No route to host"
          else
            echo "failed to connect to '$2': Connection refused"
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
        setenv("ADB_FAKE_COUNT", count.path, 1)

        let readiness = await AppModel.waitForADBWirelessTargetReadiness(
            adb: ADBController(),
            address: "192.0.2.57:5555",
            attempts: 3,
            delayNanoseconds: 1
        )

        XCTAssertFalse(readiness.isReady)
        XCTAssertFalse(readiness.sawNoRouteToHost)
        XCTAssertEqual(readiness.connectAttempts, 3)
        XCTAssertEqual(readiness.noRouteToHostFailures, 1)
    }

    // A transport that is merely settling (post-connect handshake, trust
    // prompt) must not be disconnected between readiness attempts — that
    // restarts the very handshake being waited out.
    func testShouldDropStaleWirelessTransportLeavesSettlingTransportsAlone() {
        XCTAssertFalse(
            AppModel.shouldDropStaleWirelessTransport(
                shellOutput: "adb: device offline"
            )
        )
        XCTAssertFalse(
            AppModel.shouldDropStaleWirelessTransport(
                shellOutput: "error: device unauthorized.\nThis adb server's $ADB_VENDOR_KEYS is not set"
            )
        )
        XCTAssertTrue(
            AppModel.shouldDropStaleWirelessTransport(
                shellOutput: "error: closed"
            )
        )
        XCTAssertTrue(AppModel.shouldDropStaleWirelessTransport(shellOutput: ""))
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

    func testLiveSelectedOrRememberedDeviceFallsBackAcrossTransports() {
        let wirelessRecord = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "Android.local:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let usbDevice = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: true
        )

        let selected = AppModel.liveSelectedOrRememberedDevice(
            selectedSerial: "Android.local:5555",
            pairedPhones: [wirelessRecord],
            authorizedDevices: [usbDevice]
        )

        XCTAssertEqual(selected, usbDevice)
    }

    func testLiveSelectedOrRememberedDevicePrefersExactSelectedSerial() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "Android.local:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let usbDevice = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: true
        )
        let wirelessDevice = AuthorizedADBDevice(
            serial: "Android.local:5555",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: false
        )

        let selected = AppModel.liveSelectedOrRememberedDevice(
            selectedSerial: "Android.local:5555",
            pairedPhones: [record],
            authorizedDevices: [usbDevice, wirelessDevice]
        )

        XCTAssertEqual(selected, wirelessDevice)
    }

    func testLiveSelectedOrRememberedDevicePrefersRememberedWirelessOverSelectedUSB() {
        let record = PairedPhoneRecord(
            id: "RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "192.168.68.50:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let usbDevice = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: true
        )
        let wirelessDevice = AuthorizedADBDevice(
            serial: "192.168.68.50:5555",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: false
        )

        let selected = AppModel.liveSelectedOrRememberedDevice(
            selectedSerial: "RFCT10ZLTAJ",
            pairedPhones: [record],
            authorizedDevices: [usbDevice, wirelessDevice]
        )

        XCTAssertEqual(selected, wirelessDevice)
    }

    func testLiveSelectedUSBPrefersAuthorizedWirelessTwinWithoutSavedRecord() {
        let usbDevice = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: true
        )
        let wirelessDevice = AuthorizedADBDevice(
            serial: "192.168.68.57:5555",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: false
        )

        let selected = AppModel.liveSelectedOrRememberedDevice(
            selectedSerial: "RFCT10ZLTAJ",
            pairedPhones: [],
            authorizedDevices: [usbDevice, wirelessDevice]
        )

        XCTAssertEqual(selected, wirelessDevice)
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
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
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
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
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
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
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
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
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
            "disconnect 192.0.2.57:5555",
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok",
            "disconnect 192.0.2.57:5555",
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok"
        ])
    }

    func testWaitForADBWirelessTargetReadyPrimesRouteBeforeEachConnectAttempt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
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

    func testWaitForADBWirelessTargetReadyDisconnectsStaleTransportBeforeRetrying() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          echo "already connected to $2"
          exit 0
        fi
        if [ "$1" = "disconnect" ]; then
          echo "disconnected $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          current=$(cat "$ADB_FAKE_SHELL_COUNT" 2>/dev/null || echo 0)
          current=$((current + 1))
          echo "$current" > "$ADB_FAKE_SHELL_COUNT"
          if [ "$current" -lt 2 ]; then
            echo "error: closed"
          else
            echo "wifi-adb-ok"
          fi
          exit 0
        fi
        exit 0
        """)
        defer {
            fake.cleanup()
            unsetenv("ADB_FAKE_SHELL_COUNT")
        }
        let shellCount = fake.log.deletingLastPathComponent().appendingPathComponent("adb-shell.count")
        setenv("ADB_FAKE_SHELL_COUNT", shellCount.path, 1)

        let ready = await AppModel.waitForADBWirelessTargetReady(
            adb: ADBController(),
            address: "192.0.2.57:5555",
            attempts: 2,
            delayNanoseconds: 1
        )

        XCTAssertTrue(ready)
        XCTAssertEqual(loggedCalls(fake.log), [
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok",
            "disconnect 192.0.2.57:5555",
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok"
        ])
    }

    func testWiFiHandoffReadinessStopsAfterThreeSecondBudget() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          echo "failed to connect to '$2': No route to host"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let startedAt = Date()
        let readiness = await AppModel.waitForADBWirelessTargetReadiness(
            adb: ADBController(),
            address: "192.0.2.57:5555",
            attempts: 8,
            delayNanoseconds: 500_000_000,
            maximumDuration: 3
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let connectCalls = loggedCalls(fake.log).filter { $0 == "connect 192.0.2.57:5555" }

        XCTAssertFalse(readiness.isReady)
        XCTAssertLessThan(elapsed, 3.4)
        XCTAssertLessThan(connectCalls.count, 8)
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

    func testFreshUSBHandoffSuppressesPresenceAutoConnectForSameWatcherPoll() {
        let usbDevice = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        XCTAssertTrue(
            AppModel.shouldPrioritizeUSBHandoff(
                authorizedDevices: [usbDevice],
                lastAttemptedSerial: nil,
                preferUSBMirroring: false,
                isMirroring: false,
                isPairing: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldRunPresenceAutoConnect(
                authorizedDevices: [usbDevice],
                lastAttemptedSerial: nil,
                preferUSBMirroring: false,
                isMirroring: false,
                isPairing: false
            )
        )
    }

    func testAuthorizedUSBStartsImmediatelyEvenWhenWirelessIsAuthorized() {
        let usbDevice = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: true
        )
        let wirelessDevice = AuthorizedADBDevice(
            serial: "192.168.68.57:5555",
            product: "g0sxxx",
            model: "SM-S906B",
            isUSB: false
        )

        XCTAssertTrue(
            AppModel.shouldPrioritizeUSBHandoff(
                authorizedDevices: [usbDevice, wirelessDevice],
                lastAttemptedSerial: nil,
                preferUSBMirroring: false,
                isMirroring: false,
                isPairing: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldRunPresenceAutoConnect(
                authorizedDevices: [usbDevice, wirelessDevice],
                lastAttemptedSerial: nil,
                preferUSBMirroring: false,
                isMirroring: false,
                isPairing: false
            )
        )
    }

    func testFreshAuthorizedUSBAutoStartsDuringExplicitSetup() {
        XCTAssertTrue(
            AppModel.shouldAutoStartAuthorizedUSB(
                hasSavedDevices: false,
                explicitDeviceSetupRequired: true
            )
        )
        XCTAssertTrue(
            AppModel.shouldAutoStartAuthorizedUSB(
                hasSavedDevices: false,
                explicitDeviceSetupRequired: false
            )
        )
    }

    func testAlreadyAttemptedUSBDoesNotFallBackToPresenceAutoConnect() {
        let usbDevice = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        XCTAssertFalse(
            AppModel.shouldPrioritizeUSBHandoff(
                authorizedDevices: [usbDevice],
                lastAttemptedSerial: "TESTDEVICE001",
                preferUSBMirroring: false,
                isMirroring: false,
                isPairing: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldRunPresenceAutoConnect(
                authorizedDevices: [usbDevice],
                lastAttemptedSerial: "TESTDEVICE001",
                preferUSBMirroring: false,
                isMirroring: false,
                isPairing: false
            )
        )
    }

    func testUSBPresenceInterruptsStuckReconnectOverlay() {
        let usbDevice = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        XCTAssertTrue(
            AppModel.shouldUSBInterruptReconnect(
                authorizedDevices: [usbDevice],
                isRecoveringConnection: true,
                isAwaitingReconnect: false,
                hasReconnectTask: false,
                hasWirelessStartTask: false
            )
        )
        XCTAssertTrue(
            AppModel.shouldUSBInterruptReconnect(
                authorizedDevices: [usbDevice],
                isRecoveringConnection: false,
                isAwaitingReconnect: false,
                hasReconnectTask: true,
                hasWirelessStartTask: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldUSBInterruptReconnect(
                authorizedDevices: [],
                isRecoveringConnection: true,
                isAwaitingReconnect: true,
                hasReconnectTask: true,
                hasWirelessStartTask: true
            )
        )
    }

    func testBackgroundServicesStartUnlessRunningUnderXCTestEnvironment() {
        XCTAssertTrue(
            AppModel.shouldStartBackgroundServices(
                environment: [:],
                executablePath: "/Applications/PhoneRelay.app/Contents/MacOS/PhoneRelay"
            )
        )
        XCTAssertTrue(
            AppModel.shouldStartBackgroundServices(
                environment: ["SIMULATOR_DEVICE_NAME": "Mac"],
                executablePath: "/Applications/PhoneRelay.app/Contents/MacOS/PhoneRelay"
            )
        )
        XCTAssertFalse(
            AppModel.shouldStartBackgroundServices(
                environment: [:],
                executablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"
            )
        )
        XCTAssertFalse(
            AppModel.shouldStartBackgroundServices(
                environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
                executablePath: "/Applications/PhoneRelay.app/Contents/MacOS/PhoneRelay"
            )
        )
        XCTAssertFalse(
            AppModel.shouldStartBackgroundServices(
                environment: ["XCTestBundlePath": "/tmp/PhoneRelayTests.xctest"],
                executablePath: "/Applications/PhoneRelay.app/Contents/MacOS/PhoneRelay"
            )
        )
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

    func testUSBWiFiHandoffDoesNotBlockUSBFallbackPastThreeSeconds() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ]; then
          echo "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ping" ]; then
          echo "1 packets transmitted, 1 received"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "tcpip" ]; then
          echo "restarting in TCP mode port: 5555"
          exit 0
        fi
        if [ "$1" = "connect" ]; then
          sleep 1
          echo "failed to connect to '$2': No route to host"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let startedAt = Date()
        let connected = await AppModel.connectToUSBDeviceOverCurrentWiFi(
            adb: ADBController(),
            usbDevice: AuthorizedADBDevice(
                serial: "TESTDEVICE001",
                product: "raven",
                model: "Pixel 6 Pro",
                isUSB: true
            ),
            readinessAttempts: 8,
            maximumDuration: 3
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let connectCalls = loggedCalls(fake.log).filter { $0 == "connect 192.0.2.44:5555" }

        XCTAssertNil(connected)
        XCTAssertLessThan(elapsed, 3.6)
        XCTAssertLessThan(connectCalls.count, 8)
    }

    @MainActor
    func testManualUSBConnectStartsMirrorBeforeWiFiHandoffCompletes() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "devices" ]; then
          echo "List of devices attached"
          echo "TESTDEVICE001 device usb:100000001X product:raven model:Pixel_6_Pro device:raven transport_id:1"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ]; then
          echo "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ping" ]; then
          echo "1 packets transmitted, 1 received"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "tcpip" ]; then
          echo "restarting in TCP mode port: 5555"
          exit 0
        fi
        if [ "$1" = "connect" ]; then
          sleep 1
          echo "failed to connect to '$2': No route to host"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "input" ]; then
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "pkill" ]; then
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          case "$4" in
            CLASSPATH=*) sleep 5; exit 0 ;;
          esac
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.connectViaUSB()
        let startedAt = Date()
        while !model.hasActiveMirrorSession, Date().timeIntervalSince(startedAt) < 1.5 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(model.hasActiveMirrorSession)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1.5)
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    func testManualUSBConnectClearsPairingWhenDeviceScanStalls() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "devices" ]; then
          sleep 5
          echo "List of devices attached"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        defer { model.shutdown() }

        model.connectViaUSB()
        let startedAt = Date()
        while model.isPairing, Date().timeIntervalSince(startedAt) < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(model.isPairing)
        XCTAssertFalse(model.hasActiveMirrorSession)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
    }

    @MainActor
    func testManualUSBConnectPreparesStableWiFiHandoffInBackground() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "devices" ]; then
          echo "List of devices attached"
          echo "TESTDEVICE001 device usb:100000001X product:raven model:Pixel_6_Pro device:raven transport_id:1"
          exit 0
        fi
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
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "input" ]; then
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "pkill" ]; then
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          case "$4" in
            CLASSPATH=*) sleep 5; exit 0 ;;
          esac
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        model.connectViaUSB()
        let startedAt = Date()
        while (!model.hasActiveMirrorSession
            || !model.pairedPhones.contains(where: { $0.lastAddress == "192.0.2.44:5555" })),
              Date().timeIntervalSince(startedAt) < 2.5 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(model.hasActiveMirrorSession)
        XCTAssertEqual(model.selectedDevice.adbSerial, "TESTDEVICE001")
        XCTAssertTrue(model.pairedPhones.contains(where: { $0.lastAddress == "192.0.2.44:5555" }))
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    func testShouldPromoteToLegacyTCPIPSkipsAddressesAlreadyOnPort5555() {
        XCTAssertFalse(AppModel.shouldPromoteToLegacyTCPIP(connectedAddress: "192.0.2.44:5555"))
        XCTAssertTrue(AppModel.shouldPromoteToLegacyTCPIP(connectedAddress: "192.0.2.44:42111"))
    }

    func testEnsureADBServerStartedDoesNotKillExistingTransports() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        exit 0
        """)
        defer { fake.cleanup() }

        await ADBController().ensureServerStarted()

        XCTAssertEqual(loggedCalls(fake.log), ["start-server"])
    }

    // MARK: - Fake adb helpers

    /// Writes an executable fake `adb` to a throwaway directory, points the
    /// tooling env vars at it, and returns the log file each invocation appends
    /// its arguments to plus a cleanup closure the caller defers.
    private func installFakeADB(script: String) throws -> (log: URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayTests-\(UUID().uuidString)")
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

private actor LocalNetworkPreflightRecorder {
    private var addresses: [String] = []

    func record(_ address: String) {
        addresses.append(address)
    }

    func snapshot() -> [String] {
        addresses
    }
}

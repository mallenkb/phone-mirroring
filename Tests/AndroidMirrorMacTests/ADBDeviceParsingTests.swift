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

    func testADBTCPIPResultParsing() {
        XCTAssertTrue(AppModel.adbTCPIPSucceeded("restarting in TCP mode port: 5555"))
        XCTAssertTrue(AppModel.adbTCPIPSucceeded("restarting in TCP mode port: 42111"))
        XCTAssertFalse(AppModel.adbTCPIPSucceeded("error: no devices/emulators found"))
    }

    func testMostRecentWirelessRecordPrefersLastConnectedPhone() {
        let older = PairedPhoneRecord(
            id: "old-phone",
            displayName: "Old Pixel",
            lastAddress: "192.168.1.22:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let newerUSBOnly = PairedPhoneRecord(
            id: "usb-phone",
            displayName: "USB Pixel",
            lastAddress: "R5CT123ABC",
            firstPaired: Date(timeIntervalSince1970: 300),
            lastConnected: Date(timeIntervalSince1970: 900)
        )
        let newerWireless = PairedPhoneRecord(
            id: "new-phone",
            displayName: "New Pixel",
            lastAddress: "192.168.1.44:5555",
            firstPaired: Date(timeIntervalSince1970: 400),
            lastConnected: Date(timeIntervalSince1970: 800)
        )

        let selected = AppModel.mostRecentWirelessRecord(in: [older, newerUSBOnly, newerWireless])

        XCTAssertEqual(selected?.id, "new-phone")
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

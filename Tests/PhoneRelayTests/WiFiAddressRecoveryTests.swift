import XCTest
@testable import PhoneRelay

final class WiFiAddressRecoveryTests: XCTestCase {

    // MARK: - MAC normalization

    func testNormalizedMACUppercasesAndColonizes() {
        XCTAssertEqual(PairedPhoneRecord.normalizedMACAddress("AA:BB:CC:DD:EE:FF"), "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(PairedPhoneRecord.normalizedMACAddress("aa-bb-cc-dd-ee-ff"), "aa:bb:cc:dd:ee:ff")
    }

    func testNormalizedMACPadsLeadingZeroOctets() {
        // BSD `arp` strips leading zeros; we must pad so it matches sysfs form.
        XCTAssertEqual(PairedPhoneRecord.normalizedMACAddress("8:0:27:1a:2b:3c"), "08:00:27:1a:2b:3c")
    }

    func testNormalizedMACRejectsUnusableInput() {
        XCTAssertNil(PairedPhoneRecord.normalizedMACAddress(nil))
        XCTAssertNil(PairedPhoneRecord.normalizedMACAddress("(incomplete)"))
        XCTAssertNil(PairedPhoneRecord.normalizedMACAddress("00:00:00:00:00:00"))
        XCTAssertNil(PairedPhoneRecord.normalizedMACAddress("gg:hh:ii:jj:kk:ll"))
        XCTAssertNil(PairedPhoneRecord.normalizedMACAddress("aa:bb:cc:dd:ee"))
    }

    // MARK: - ip route / ip addr parsing

    func testWifiInterfaceNameFromRoute() {
        let route = """
        192.168.1.0/24 dev wlan0 proto kernel scope link src 192.168.1.50
        default via 192.168.1.1 dev wlan0
        """
        XCTAssertEqual(AppModel.wifiInterfaceName(in: route), "wlan0")
    }

    func testWifiInterfaceNameNilWithoutWlan() {
        let route = "default via 10.0.0.1 dev rmnet0"
        XCTAssertNil(AppModel.wifiInterfaceName(in: route))
    }

    func testMacAddressFromLinkOutput() {
        let output = """
        24: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP
            link/ether 08:00:27:1a:2b:3c brd ff:ff:ff:ff:ff:ff
            inet 192.168.1.50/24 brd 192.168.1.255 scope global wlan0
        """
        XCTAssertEqual(AppModel.macAddress(inLinkOutput: output), "08:00:27:1a:2b:3c")
    }

    // MARK: - ARP parsing

    func testParseARPTableSkipsIncomplete() {
        let output = """
        ? (192.168.1.1) at 0:11:22:33:44:55 on en0 ifscope [ethernet]
        ? (192.168.1.73) at 8c:85:90:a:b:3c on en0 ifscope [ethernet]
        ? (192.168.1.99) at (incomplete) on en0 ifscope [ethernet]
        """
        let map = WiFiAddressRecovery.parseARPTable(output)
        XCTAssertEqual(map["192.168.1.1"], "00:11:22:33:44:55")
        XCTAssertEqual(map["192.168.1.73"], "8c:85:90:0a:0b:3c")
        XCTAssertNil(map["192.168.1.99"])
    }

    // MARK: - Subnet math

    func testSubnetPrefixFromIPv4() {
        XCTAssertEqual(WiFiAddressRecovery.subnetPrefix(forIPv4: "192.168.1.42"), "192.168.1.")
        XCTAssertNil(WiFiAddressRecovery.subnetPrefix(forIPv4: "not-an-ip"))
    }

    func testSubnetHostsCoversUsableRange() {
        let hosts = WiFiAddressRecovery.subnetHosts(prefix: "192.168.1.")
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
    }

    func testSubnetPrefixesExpandInterfaceNetmask() {
        let prefixes = WiFiAddressRecovery.subnetPrefixes(
            forIPv4: "192.168.68.54",
            netmask: "255.255.252.0"
        )
        XCTAssertEqual(prefixes, ["192.168.68.", "192.168.69.", "192.168.70.", "192.168.71."])
    }

    func testSubnetPrefixesForPlain24() {
        let prefixes = WiFiAddressRecovery.subnetPrefixes(
            forIPv4: "10.0.3.42",
            netmask: "255.255.255.0"
        )
        XCTAssertEqual(prefixes, ["10.0.3."])
    }

    func testSubnetPrefixesPrioritizeLastKnownThenDedupe() {
        let prefixes = WiFiAddressRecovery.subnetPrefixes(
            lastKnownIP: "192.168.1.50:5555",
            localSubnets: ["10.0.0.", "192.168.1."]
        )
        XCTAssertEqual(prefixes, ["192.168.1.", "10.0.0."])
    }

    func testIPv4HostStripsPort() {
        XCTAssertEqual(WiFiAddressRecovery.ipv4Host(in: "192.168.1.50:5555"), "192.168.1.50")
        XCTAssertEqual(WiFiAddressRecovery.ipv4Host(in: "192.168.1.50"), "192.168.1.50")
        XCTAssertNil(WiFiAddressRecovery.ipv4Host(in: "adb-ABCDEF-x._adb-tls-connect"))
    }

    // MARK: - MAC matching

    func testMatchIPPrefersOpenHostOnMACCollision() {
        let arp = ["192.168.1.10": "aa:bb:cc:dd:ee:ff", "192.168.1.20": "aa:bb:cc:dd:ee:ff"]
        let match = WiFiAddressRecovery.matchIP(
            forMAC: "AA:BB:CC:DD:EE:FF",
            in: arp,
            preferring: ["192.168.1.20"]
        )
        XCTAssertEqual(match, "192.168.1.20")
    }

    func testMatchIPNilWhenNoMACMatch() {
        let arp = ["192.168.1.10": "11:22:33:44:55:66"]
        XCTAssertNil(WiFiAddressRecovery.matchIP(forMAC: "aa:bb:cc:dd:ee:ff", in: arp, preferring: []))
        XCTAssertNil(WiFiAddressRecovery.matchIP(forMAC: nil, in: arp, preferring: []))
    }

    // MARK: - recover() driver (MAC path is adb-free)

    func testRecoverResolvesViaMACMatch() async {
        let resolved = await WiFiAddressRecovery.recover(
            adb: ADBController(),
            target: .init(
                macAddress: "AA:BB:CC:DD:EE:FF",
                usbSerial: nil,
                displayName: "Pixel 8",
                lastKnownIP: "192.168.1.50:5555"
            ),
            sweep: { _ in [] },
            readARP: { ["192.168.1.73": "aa:bb:cc:dd:ee:ff"] },
            localSubnets: { ["192.168.1."] }
        )
        XCTAssertEqual(resolved, "192.168.1.73:5555")
    }

    func testRecoverReturnsNilWhenNothingMatches() async {
        let resolved = await WiFiAddressRecovery.recover(
            adb: ADBController(),
            target: .init(
                macAddress: "AA:BB:CC:DD:EE:FF",
                usbSerial: nil,
                displayName: "Pixel 8",
                lastKnownIP: "192.168.1.50:5555"
            ),
            sweep: { _ in [] },
            readARP: { ["192.168.1.73": "11:22:33:44:55:66"] },
            localSubnets: { ["192.168.1."] }
        )
        XCTAssertNil(resolved)
    }

    func testRecoverNoSubnetReturnsNil() async {
        let resolved = await WiFiAddressRecovery.recover(
            adb: ADBController(),
            target: .init(macAddress: "aa:bb:cc:dd:ee:ff", usbSerial: nil, displayName: "X", lastKnownIP: nil),
            sweep: { _ in [] },
            readARP: { [:] },
            localSubnets: { [] }
        )
        XCTAssertNil(resolved)
    }
}

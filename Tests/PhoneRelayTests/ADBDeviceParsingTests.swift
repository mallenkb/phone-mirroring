import XCTest
@testable import PhoneRelay

final class ADBDeviceParsingTests: XCTestCase {
    private let explicitDeviceSetupRequiredDefaultsKey = "MirrorBehavior.explicitDeviceSetupRequired"

    private func withoutExplicitDeviceSetupRequired(_ body: () async throws -> Void) async rethrows {
        let defaults = [UserDefaults.standard]
            + PairedPhoneStore.compatibilitySuites.compactMap { UserDefaults(suiteName: $0) }
        let previousValues = defaults.map { $0.object(forKey: explicitDeviceSetupRequiredDefaultsKey) }
        defer {
            for (defaults, previousValue) in zip(defaults, previousValues) {
                if let previousValue {
                    defaults.set(previousValue, forKey: explicitDeviceSetupRequiredDefaultsKey)
                } else {
                    defaults.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey)
                }
            }
        }
        defaults.forEach { $0.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey) }
        try await body()
    }

    @MainActor
    func testNoSavedDeviceStartsWithUSBSetup() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])

        XCTAssertFalse(model.connectionWindowPrefersWirelessDetails)
        XCTAssertTrue(model.isFirstTimeUSBSetup)
    }

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

    func testConnectionHealthRecommendsUSBAuthorizationBeforeWiFiFixes() {
        let snapshot = AppModel.connectionHealthSnapshot(
            selectedSerial: nil,
            selectedNetwork: "Local WLAN",
            isSelectedDeviceOnline: false,
            isActivelyConnecting: false,
            hasUnauthorizedUSBDevice: true,
            authorizedDevices: [],
            discoveredPhones: [],
            localNetworkPermissionGranted: false,
            adbStatusText: "Waiting for authorization",
            reconnectAttemptCount: 0,
            activeErrorMessage: nil
        )

        XCTAssertEqual(snapshot.usbAuthorization.value, "Action needed")
        XCTAssertEqual(snapshot.recommendedFix, "Unlock the phone and tap Allow on the USB debugging prompt.")
    }

    func testConnectionHealthShowsOnlineWirelessTransport() {
        let wireless = AuthorizedADBDevice(
            serial: "192.0.2.22:5555",
            product: "oriole",
            model: "Pixel 6",
            isUSB: false
        )

        let snapshot = AppModel.connectionHealthSnapshot(
            selectedSerial: wireless.serial,
            selectedNetwork: "Wireless debugging",
            isSelectedDeviceOnline: true,
            isActivelyConnecting: false,
            hasUnauthorizedUSBDevice: false,
            authorizedDevices: [wireless],
            discoveredPhones: [],
            localNetworkPermissionGranted: true,
            adbStatusText: "Running",
            reconnectAttemptCount: 2,
            activeErrorMessage: nil
        )

        XCTAssertEqual(snapshot.wifiReachability.value, "Reachable")
        XCTAssertEqual(snapshot.selectedTransport.value, "Wi-Fi")
        XCTAssertEqual(snapshot.reconnectAttempts.value, "2")
        XCTAssertEqual(snapshot.recommendedFix, "No action needed. The selected device is reachable.")
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
            "The mirroring engine file is missing from the app. Reinstall Phone Relay."
        )
    }

    func testTransientMirrorLaunchFailuresKeepRetryingWithoutBadge() {
        XCTAssertTrue(AppModel.shouldKeepRetryingMirrorLaunchFailure("The phone went offline. Reconnect it (USB or Wi-Fi) and try again."))
        XCTAssertTrue(AppModel.shouldKeepRetryingMirrorLaunchFailure("Could not start mirror: adb reverse failed: adb: error: closed"))
        XCTAssertTrue(AppModel.shouldKeepRetryingMirrorLaunchFailure("failed to connect to '192.168.68.57:5555': Connection refused"))
        XCTAssertTrue(AppModel.shouldKeepRetryingMirrorLaunchFailure("The phone didn’t respond in time. Check the cable or Wi-Fi connection and try again."))
    }

    func testUSBNotFoundLaunchFailureRecoversThroughRememberedWirelessRoute() {
        let record = PairedPhoneRecord(
            id: "RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "192.168.68.57:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )

        let route = AppModel.rememberedWirelessRouteForUSBLaunchFailure(
            message: "adb: device 'RFCT10ZLTAJ' not found",
            failedSerial: "RFCT10ZLTAJ",
            pairedPhones: [record]
        )

        XCTAssertEqual(route, record)
    }

    func testMissingMirrorTransportUsesRememberedWirelessRouteDirectly() {
        let wirelessRecord = PairedPhoneRecord(
            id: "RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "192.168.68.57:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 300)
        )
        let selectedUSBDevice = MirrorDevice(
            id: "RFCT10ZLTAJ",
            name: "SM-S906B",
            model: "SM-S906B",
            battery: 80,
            isCharging: true,
            network: "USB debugging",
            lastSeen: Date(timeIntervalSince1970: 400),
            states: [.mirroringReady, .companionConnected],
            adbSerial: "RFCT10ZLTAJ"
        )

        let route = AppModel.rememberedWirelessRouteForMissingMirrorTransport(
            selectedDevice: selectedUSBDevice,
            pairedPhones: [wirelessRecord]
        )

        XCTAssertEqual(route, wirelessRecord)
    }

    func testUSBLaunchFailureRecoveryRequiresMissingUSBAndWirelessRoute() {
        let record = PairedPhoneRecord(
            id: "RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "192.168.68.57:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let usbOnlyRecord = PairedPhoneRecord(
            id: "RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "RFCT10ZLTAJ",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 300)
        )

        XCTAssertNil(
            AppModel.rememberedWirelessRouteForUSBLaunchFailure(
                message: "adb: device 'RFCT10ZLTAJ' not found",
                failedSerial: "192.168.68.57:5555",
                pairedPhones: [record]
            )
        )
        XCTAssertNil(
            AppModel.rememberedWirelessRouteForUSBLaunchFailure(
                message: "adb: device 'RFCT10ZLTAJ' offline",
                failedSerial: "RFCT10ZLTAJ",
                pairedPhones: [record]
            )
        )
        XCTAssertNil(
            AppModel.rememberedWirelessRouteForUSBLaunchFailure(
                message: "adb: device 'RFCT10ZLTAJ' not found",
                failedSerial: "RFCT10ZLTAJ",
                pairedPhones: [usbOnlyRecord]
            )
        )
    }

    func testActionableMirrorLaunchFailuresStillSurface() {
        XCTAssertFalse(AppModel.shouldKeepRetryingMirrorLaunchFailure("This Mac isn't authorized on the phone yet. Unlock the phone and tap Allow."))
        XCTAssertFalse(AppModel.shouldKeepRetryingMirrorLaunchFailure("The mirroring engine file is missing from the app. Reinstall Phone Relay."))
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

    func testPassiveUSBHandoffIsAllowedForSavedAndUnsavedDevices() {
        let usbDevice = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        XCTAssertFalse(AppModel.shouldAttemptWirelessHandoff(from: usbDevice, preferUSBMirroring: true))
        XCTAssertTrue(
            AppModel.shouldAttemptWirelessHandoff(
                from: usbDevice,
                preferUSBMirroring: false,
                hasSavedDevices: true
            )
        )
        XCTAssertTrue(
            AppModel.shouldAttemptWirelessHandoff(
                from: usbDevice,
                preferUSBMirroring: false,
                hasSavedDevices: false
            )
        )
    }

    func testPassiveUSBWiFiHandoffDoesNotDependOnAdvancedToggle() {
        let usbDevice = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        XCTAssertTrue(
            AppModel.shouldAttemptWirelessHandoff(
                from: usbDevice,
                preferUSBMirroring: false,
                backgroundWiFiHandoffEnabled: true
            )
        )
        XCTAssertTrue(
            AppModel.shouldAttemptWirelessHandoff(
                from: usbDevice,
                preferUSBMirroring: false,
                backgroundWiFiHandoffEnabled: false
            )
        )
    }

    func testManualUSBConnectPinsUSBWithoutChangingAutoPreference() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/AppModel.swift", encoding: .utf8)
        guard let functionRange = source.range(of: "func connectViaUSB()"),
              let nextFunctionRange = source.range(
                of: "private func prefillWirelessIPFromUSBDevice",
                range: functionRange.upperBound..<source.endIndex
              )
        else {
            XCTFail("connectViaUSB() source not found")
            return
        }

        let body = String(source[functionRange.lowerBound..<nextFunctionRange.lowerBound])
        XCTAssertTrue(body.contains("pinManualUSBTransport(serial: readyUSBDevice.serial)"))
        XCTAssertTrue(body.contains("prepareWirelessHandoff: false"))
        XCTAssertTrue(body.contains("pinManualUSBTransport(serial: liveUSBDevice.serial)"))
        XCTAssertFalse(body.contains("shouldAttemptWirelessHandoff("))
        XCTAssertFalse(body.contains("preferUSBMirroring"))
    }

    func testADBShellReadinessFailureRecognizesStaleUSBTransport() {
        XCTAssertTrue(AppModel.adbShellReadinessFailed("adb: device 'RFCT10ZLTAJ' not found"))
        XCTAssertTrue(AppModel.adbShellReadinessFailed("error: device offline"))
        XCTAssertTrue(AppModel.adbShellReadinessFailed("error: closed"))
        XCTAssertFalse(AppModel.adbShellReadinessFailed("phone-relay-usb-ok"))
    }

    func testSavedDeviceAutomaticConnectPrioritizesLiveRoutesBeforeSavedRecovery() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/AppModel.swift", encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func connect(record: PairedPhoneRecord, transport: SavedConnectionTransport = .automatic)"))
        let end = try XCTUnwrap(source.range(of: "private func connectViaSavedUSB(record:", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        let liveWiFi = try XCTUnwrap(body.range(of: "Self.liveWirelessAuthorizedDevice("))
        let liveUSB = try XCTUnwrap(body.range(of: "liveUSBDevice(for: record) != nil"))
        let discoveredWiFi = try XCTUnwrap(body.range(of: "Self.rememberedConnectablePhone(for: record, in: discoveredPhones)"))
        let savedWiFi = try XCTUnwrap(body.range(of: "reconnectOverWiFi(preferredRecord: record, restrictToPreferredRecord: true)"))
        let savedUSB = try XCTUnwrap(body.range(of: "startMirroring(manual: true)", range: savedWiFi.upperBound..<body.endIndex))

        XCTAssertLessThan(liveWiFi.lowerBound, liveUSB.lowerBound)
        XCTAssertLessThan(liveUSB.lowerBound, discoveredWiFi.lowerBound)
        XCTAssertLessThan(discoveredWiFi.lowerBound, savedWiFi.lowerBound)
        XCTAssertLessThan(savedWiFi.lowerBound, savedUSB.lowerBound)
    }

    func testSettingsViewExposesBackgroundWiFiHandoffToggle() throws {
        let source = try String(contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift", encoding: .utf8)

        XCTAssertTrue(source.contains("$model.backgroundWiFiHandoffEnabled"))
        XCTAssertTrue(source.contains("Advanced USB-to-Wi-Fi handoff"))
        XCTAssertTrue(source.contains("Leave this off unless you want USB mirroring to prepare a separate legacy ADB Wi-Fi route."))
    }

    func testConnectionHealthShowsWiFiHandoffStatus() {
        let usbDevice = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )

        let preparing = AppModel.connectionHealthSnapshot(
            selectedSerial: usbDevice.serial,
            selectedNetwork: "USB debugging",
            isSelectedDeviceOnline: true,
            isActivelyConnecting: true,
            hasUnauthorizedUSBDevice: false,
            authorizedDevices: [usbDevice],
            discoveredPhones: [],
            localNetworkPermissionGranted: true,
            adbStatusText: "Running",
            reconnectAttemptCount: 0,
            activeErrorMessage: nil,
            backgroundWiFiHandoffEnabled: true,
            isPreparingWiFiHandoff: true
        )

        XCTAssertEqual(preparing.wifiHandoff.value, "Preparing")

        let disabled = AppModel.connectionHealthSnapshot(
            selectedSerial: usbDevice.serial,
            selectedNetwork: "USB debugging",
            isSelectedDeviceOnline: true,
            isActivelyConnecting: false,
            hasUnauthorizedUSBDevice: false,
            authorizedDevices: [usbDevice],
            discoveredPhones: [],
            localNetworkPermissionGranted: true,
            adbStatusText: "Running",
            reconnectAttemptCount: 0,
            activeErrorMessage: nil,
            backgroundWiFiHandoffEnabled: false,
            isPreparingWiFiHandoff: false
        )

        XCTAssertEqual(disabled.wifiHandoff.value, "Off")
    }

    func testManualADBTargetNormalizationAcceptsIPOnlyAndAddsLegacyPort() {
        XCTAssertEqual(
            AppModel.normalizedManualADBTarget("192.0.2.44"),
            "192.0.2.44:5555"
        )
    }

    func testManualADBTargetNormalizationRejectsExplicitPort() {
        XCTAssertNil(AppModel.normalizedManualADBTarget("192.0.2.44:43123"))
    }

    func testManualADBTargetCandidatesUseOnlyLegacyPort() {
        let discovered = [
            DiscoveredPhone(
                id: "adb-pixel",
                address: "192.0.2.44:43123",
                kind: .wirelessDebugging,
                lastSeen: Date(timeIntervalSince1970: 100)
            ),
            DiscoveredPhone(
                id: "adb-other",
                address: "192.0.2.45:5555",
                kind: .legacyTCPIP,
                lastSeen: Date(timeIntervalSince1970: 100)
            )
        ]
        let saved = PairedPhoneRecord(
            id: "saved-pixel",
            displayName: "Pixel",
            lastAddress: "192.0.2.44:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            AppModel.manualADBTargetCandidateAddresses(
                normalizedAddress: "192.0.2.44:5555",
                discoveredPhones: discovered,
                pairedPhones: [saved]
            ),
            ["192.0.2.44:5555"]
        )
    }

    func testManualADBTargetCandidatesIgnoreDiscoveredWirelessDebuggingPorts() {
        let discovered = [
            DiscoveredPhone(
                id: "adb-pixel",
                address: "192.0.2.44:43123",
                kind: .wirelessDebugging,
                lastSeen: Date(timeIntervalSince1970: 100)
            )
        ]

        XCTAssertEqual(
            AppModel.manualADBTargetCandidateAddresses(
                normalizedAddress: "192.0.2.44:5555",
                discoveredPhones: discovered,
                pairedPhones: []
            ),
            ["192.0.2.44:5555"]
        )
    }

    func testManualADBTargetPortScanCandidatesAppendDiscoveredPorts() {
        XCTAssertEqual(
            AppModel.manualADBTargetPortScanCandidateAddresses(
                host: "192.0.2.44",
                ports: [39555, 43123],
                existingCandidates: ["192.0.2.44:5555"]
            ),
            ["192.0.2.44:5555", "192.0.2.44:39555", "192.0.2.44:43123"]
        )
    }

    func testManualADBTargetNormalizationRejectsInvalidTargets() {
        XCTAssertNil(AppModel.normalizedManualADBTarget(""))
        XCTAssertNil(AppModel.normalizedManualADBTarget("not a host"))
        XCTAssertNil(AppModel.normalizedManualADBTarget("phone.local"))
        XCTAssertNil(AppModel.normalizedManualADBTarget("192.0.2"))
        XCTAssertNil(AppModel.normalizedManualADBTarget("192.0.2."))
        XCTAssertNil(AppModel.normalizedManualADBTarget("192.0.2.abc"))
        XCTAssertNil(AppModel.normalizedManualADBTarget("192.0.2.256"))
        XCTAssertNil(AppModel.normalizedManualADBTarget("192.0.2.44:ssh"))
        XCTAssertNil(AppModel.normalizedManualADBTarget("192.0.2.44:0"))
        XCTAssertNil(AppModel.normalizedManualADBTarget("192.0.2.44:70000"))
    }

    @MainActor
    func testManualADBTargetFallsBackFromStaleRandomPortToLegacyHandoffPort() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          if [ "$2" = "192.0.2.44:5555" ]; then
            echo "connected to $2"
          else
            echo "failed to connect to '$2': No route to host"
          fi
          exit 0
        fi
        if [ "$1" = "devices" ]; then
          echo "List of devices attached"
          echo "192.0.2.44:5555 device product:raven model:Pixel_6_Pro device:raven transport_id:1"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          if [ "$2" = "192.0.2.44:5555" ]; then
            echo "wifi-adb-ok"
          else
            echo "error: closed"
          fi
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
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.manualADBTarget = "192.0.2.44"
        model.connectManualADBTarget()

        let startedAt = Date()
        while model.selectedDevice.adbSerial != "192.0.2.44:5555",
              Date().timeIntervalSince(startedAt) < 5 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(model.activeError)
        XCTAssertEqual(model.selectedDevice.adbSerial, "192.0.2.44:5555")
        XCTAssertEqual(model.manualADBTarget, "192.0.2.44")
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    func testManualADBTargetIgnoresDiscoveredSameHostWirelessDebuggingPort() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "mdns" ] && [ "$2" = "services" ]; then
          echo "List of discovered mdns services"
          exit 0
        fi
        if [ "$1" = "connect" ]; then
          if [ "$2" = "192.0.2.44:43123" ]; then
            echo "connected to $2"
          else
            echo "failed to connect to '$2': Connection refused"
          fi
          exit 0
        fi
        if [ "$1" = "devices" ]; then
          echo "List of devices attached"
          echo "192.0.2.44:43123 device product:raven model:Pixel_6_Pro device:raven transport_id:1"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          if [ "$2" = "192.0.2.44:43123" ]; then
            echo "wifi-adb-ok"
          else
            echo "error: closed"
          fi
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.setDiscoveredPhonesForTesting([
            DiscoveredPhone(
                id: "adb-pixel",
                address: "192.0.2.44:43123",
                kind: .wirelessDebugging,
                lastSeen: Date(timeIntervalSince1970: 100)
            )
        ])
        model.manualADBTarget = "192.0.2.44"
        model.connectManualADBTarget()

        let startedAt = Date()
        while model.activeError == nil,
              Date().timeIntervalSince(startedAt) < 10 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.activeError?.title, "Connect USB to refresh Wi-Fi")
        XCTAssertNil(model.selectedDevice.adbSerial)
        let calls = loggedCalls(fake.log)
        XCTAssertFalse(calls.contains("connect 192.0.2.44:43123"))
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
    }

    @MainActor
    func testManualADBTargetRejectsExplicitWirelessDebuggingPort() async throws {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.manualADBTarget = "192.0.2.44:39555"
        model.connectManualADBTarget()

        XCTAssertEqual(model.activeError?.title, "Invalid IP address")
        XCTAssertNil(model.selectedDevice.adbSerial)
    }

    @MainActor
    func testManualADBTargetDoesNotDiscoverWirelessDebuggingPortFromBareIP() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "mdns" ] && [ "$2" = "services" ]; then
          echo "List of discovered mdns services"
          exit 0
        fi
        if [ "$1" = "connect" ]; then
          if [ "$2" = "192.0.2.44:39555" ]; then
            echo "connected to $2"
          else
            echo "failed to connect to '$2': Connection refused"
          fi
          exit 0
        fi
        if [ "$1" = "devices" ]; then
          echo "List of devices attached"
          echo "192.0.2.44:39555 device product:raven model:Pixel_6_Pro device:raven transport_id:1"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          if [ "$2" = "192.0.2.44:39555" ]; then
            echo "wifi-adb-ok"
          else
            echo "error: closed"
          fi
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let originalProbe = AppModel.adbTCPPortProbe
        AppModel.adbTCPPortProbe = { _ in true }
        defer {
            AppModel.adbTCPPortProbe = originalProbe
        }
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.manualADBTarget = "192.0.2.44"
        model.connectManualADBTarget()

        let startedAt = Date()
        while model.activeError == nil, Date().timeIntervalSince(startedAt) < 10 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.activeError?.title, "Connect USB to refresh Wi-Fi")
        let calls = loggedCalls(fake.log)
        XCTAssertNil(model.selectedDevice.adbSerial)
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
        XCTAssertFalse(calls.contains("connect 192.0.2.44:39555"))
    }

    @MainActor
    func testManualADBTargetDoesNotUseMDNSWirelessDebuggingPort() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "mdns" ] && [ "$2" = "services" ]; then
          echo "adb-pixel	_adb-tls-connect._tcp.	192.0.2.44:43123"
          exit 0
        fi
        if [ "$1" = "connect" ]; then
          if [ "$2" = "192.0.2.44:43123" ]; then
            echo "connected to $2"
          else
            echo "failed to connect to '$2': Connection refused"
          fi
          exit 0
        fi
        if [ "$1" = "devices" ]; then
          echo "List of devices attached"
          echo "192.0.2.44:43123 device product:raven model:Pixel_6_Pro device:raven transport_id:1"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          if [ "$2" = "192.0.2.44:43123" ]; then
            echo "wifi-adb-ok"
          else
            echo "error: closed"
          fi
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.manualADBTarget = "192.0.2.44"
        model.connectManualADBTarget()

        let startedAt = Date()
        while model.activeError == nil, Date().timeIntervalSince(startedAt) < 10 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.activeError?.title, "Connect USB to refresh Wi-Fi")
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("mdns services"))
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
        XCTAssertFalse(calls.contains("connect 192.0.2.44:43123"))
    }

    @MainActor
    func testManualADBTargetUsesSavedPhoneNameWhenAddressMatchesRecord() async throws {
        try await withoutExplicitDeviceSetupRequired {
            let fake = try installFakeADB(script: """
            #!/bin/sh
            echo "$@" >> "$ADB_FAKE_LOG"
            if [ "$1" = "connect" ]; then
              echo "failed to connect to '$2': Connection refused"
              exit 0
            fi
            exit 0
            """)
            defer { fake.cleanup() }

            let huawei = PairedPhoneRecord(
                id: "adb-huawei",
                displayName: "VOG L09",
                lastAddress: "192.0.2.61:5555",
                usbSerial: "6KK0220520000403",
                wifiAddress: "192.0.2.61:5555",
                firstPaired: Date(timeIntervalSince1970: 200),
                lastConnected: Date(timeIntervalSince1970: 300)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [huawei])
            model.manualADBTarget = "192.0.2.61"
            let originalScanner = AppModel.manualADBPortScanner
            AppModel.manualADBPortScanner = { _ in [] }
            defer { AppModel.manualADBPortScanner = originalScanner }

            model.connectManualADBTarget()

            XCTAssertEqual(model.selectedDevice.name, "VOG L09")
            XCTAssertEqual(model.connectionDeviceLabel, "VOG L09")

            let startedAt = Date()
            while model.activeError == nil, Date().timeIntervalSince(startedAt) < 10 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            XCTAssertEqual(model.activeError?.title, "Connect USB to refresh Wi-Fi")
            XCTAssertTrue(model.activeError?.message.contains("VOG L09") == true)
            XCTAssertFalse(model.connectionDeviceLabel.contains("Android Device"))
        }
    }

    @MainActor
    func testManualADBTargetRestartsADBServerAfterNoRouteFailures() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          count=$(grep -c '^connect 192.0.2.44:5555$' "$ADB_FAKE_LOG")
          if [ "$count" -le 3 ]; then
            echo "failed to connect to '$2': No route to host"
          else
            echo "connected to $2"
          fi
          exit 0
        fi
        if [ "$1" = "kill-server" ] || [ "$1" = "start-server" ]; then
          exit 0
        fi
        if [ "$1" = "devices" ]; then
          echo "List of devices attached"
          echo "192.0.2.44:5555 device product:raven model:Pixel_6_Pro device:raven transport_id:1"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          echo "wifi-adb-ok"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }
        let originalScanner = AppModel.manualADBPortScanner
        AppModel.manualADBPortScanner = { _ in [] }
        defer { AppModel.manualADBPortScanner = originalScanner }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.manualADBTarget = "192.0.2.44"
        model.connectManualADBTarget()

        let startedAt = Date()
        while model.selectedDevice.adbSerial != "192.0.2.44:5555",
              Date().timeIntervalSince(startedAt) < 12 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(model.activeError)
        XCTAssertEqual(model.selectedDevice.adbSerial, "192.0.2.44:5555")
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("kill-server"))
        XCTAssertGreaterThanOrEqual(calls.filter { $0 == "start-server" }.count, 2)
        XCTAssertEqual(calls.filter { $0 == "connect 192.0.2.44:5555" }.count, 4)
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    func testManualADBTargetShowsLocalNetworkErrorWhenRestartRetryStillHasNoRoute() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          echo "failed to connect to '$2': No route to host"
          exit 0
        fi
        if [ "$1" = "kill-server" ] || [ "$1" = "start-server" ]; then
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }
        let originalScanner = AppModel.manualADBPortScanner
        AppModel.manualADBPortScanner = { _ in [] }
        defer { AppModel.manualADBPortScanner = originalScanner }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.manualADBTarget = "192.0.2.44"
        model.connectManualADBTarget()

        let startedAt = Date()
        while model.activeError == nil, Date().timeIntervalSince(startedAt) < 14 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.activeError?.title, "Local Network may be blocked")
        XCTAssertTrue(model.activeError?.message.contains("System Settings > Privacy & Security > Local Network") == true)
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("kill-server"))
        XCTAssertGreaterThanOrEqual(calls.filter { $0 == "connect 192.0.2.44:5555" }.count, 4)
    }

    func testScrcpyStyleConnectionPlanPrefersUSBOrTCPIPDeterministically() {
        let usbDevice = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel",
            isUSB: true
        )
        let wirelessDevice = AuthorizedADBDevice(
            serial: "192.0.2.44:5555",
            product: "raven",
            model: "Pixel",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.scrcpyStyleConnectionPlan(
                authorizedDevices: [usbDevice, wirelessDevice],
                preferUSBMirroring: true,
                manualTarget: nil
            ),
            .usb(serial: "TESTDEVICE001")
        )
        XCTAssertEqual(
            AppModel.scrcpyStyleConnectionPlan(
                authorizedDevices: [usbDevice],
                preferUSBMirroring: false,
                manualTarget: nil
            ),
            .usbPromoteToTCPIP(serial: "TESTDEVICE001")
        )
        XCTAssertEqual(
            AppModel.scrcpyStyleConnectionPlan(
                authorizedDevices: [usbDevice],
                preferUSBMirroring: true,
                manualTarget: "192.0.2.44"
            ),
            .manualTCPIP(address: "192.0.2.44:5555")
        )
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

    func testScrcpyStyleAutoConnectUsesLiveADBTransportBeforeDiscovery() {
        let record = PairedPhoneRecord(
            id: "adb-stale-mdns-record",
            displayName: "Pixel 8",
            lastAddress: "192.0.2.44:41235",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let liveWireless = AuthorizedADBDevice(
            serial: "192.0.2.44:5555",
            product: "shiba",
            model: "Pixel 8",
            isUSB: false
        )
        let liveUSB = AuthorizedADBDevice(
            serial: "USB123",
            product: "shiba",
            model: "Pixel 8",
            isUSB: true
        )

        let selected = AppModel.scrcpyStyleAutoConnectDevice(
            authorizedDevices: [liveUSB, liveWireless],
            pairedPhones: [record],
            preferUSBMirroring: false
        )

        XCTAssertEqual(selected, liveWireless)
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

    func testUSBOnlyRecordDoesNotClaimUnrelatedSingleConnectablePhone() {
        let record = PairedPhoneRecord(
            id: "TESTDEVICE001",
            displayName: "Pixel 6 Pro",
            lastAddress: "TESTDEVICE001",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let unrelated = DiscoveredPhone(
            id: "adb-unrelated",
            address: "192.0.2.54:46507",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )

        let selected = AppModel.rememberedConnectablePhone(
            for: record,
            in: [unrelated]
        )

        XCTAssertNil(selected)
    }

    func testUSBRecordCanUseExactDiscoveredWiFiServiceID() {
        let record = PairedPhoneRecord(
            id: "adb-TESTDEVICE001",
            displayName: "Pixel 6 Pro",
            lastAddress: "TESTDEVICE001",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let matching = DiscoveredPhone(
            id: "adb-TESTDEVICE001",
            address: "192.0.2.54:46507",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )

        let selected = AppModel.rememberedConnectablePhone(
            for: record,
            in: [matching]
        )

        XCTAssertEqual(selected, matching)
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

    func testWirelessPhoneMatchingUSBRouteRequiresNumericUSBWiFiAddress() {
        let routeOutput = "198.51.100.0/24 dev rmnet_data0 proto kernel scope link src 198.51.100.15"
        let mdnsOnly = DiscoveredPhone(
            id: "adb-RFCT10ZLTAJ",
            address: "Android.local:5555",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(
            AppModel.wirelessPhoneMatchingUSBRoute(
                routeOutput,
                phones: [mdnsOnly]
            )
        )
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

        XCTAssertEqual(promoted, .promoted("192.0.2.44:5555"))
        let calls = try String(contentsOf: log, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertTrue(calls.contains("-s 192.0.2.44:42111 tcpip 5555"))
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
    }

    func testPromoteToLegacyTCPIPKeepsOriginalWhenDeviceRefusesTCPIP() async throws {
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

        // A refused `tcpip` never restarts adbd, so the caller's original
        // transport stays valid — not a transport loss.
        XCTAssertEqual(promoted, .unavailable)
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

    func testWaitForADBWirelessTargetReadyWaitsForTCPPortBeforeADBConnect() async throws {
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

        let probe = TCPProbeRecorder(openOnAttempt: 3)
        let ready = await AppModel.waitForADBWirelessTargetReady(
            adb: ADBController(),
            address: "192.0.2.57:5555",
            attempts: 4,
            delayNanoseconds: 1,
            tcpPortProbe: { address in
                await probe.record(address)
            }
        )

        XCTAssertTrue(ready)
        let probedAddresses = await probe.snapshot()
        XCTAssertEqual(probedAddresses, [
            "192.0.2.57:5555",
            "192.0.2.57:5555",
            "192.0.2.57:5555"
        ])
        XCTAssertEqual(loggedCalls(fake.log), [
            "connect 192.0.2.57:5555",
            "-s 192.0.2.57:5555 shell echo wifi-adb-ok"
        ])
    }

    func testADBPortProbeOnlyRunsForLocalNetworkAddresses() {
        XCTAssertTrue(AppModel.shouldProbeADBPort(host: "192.168.68.61"))
        XCTAssertTrue(AppModel.shouldProbeADBPort(host: "10.0.0.12"))
        XCTAssertTrue(AppModel.shouldProbeADBPort(host: "172.20.0.8"))
        XCTAssertTrue(AppModel.shouldProbeADBPort(host: "Android-3.local"))

        XCTAssertFalse(AppModel.shouldProbeADBPort(host: "192.0.2.57"))
        XCTAssertFalse(AppModel.shouldProbeADBPort(host: "example.com"))
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

    // MARK: - Manual-disconnect re-discovery

    private static let resumeUSB = AuthorizedADBDevice(
        serial: "RFCT10ZLTAJ", product: "g0sxxx", model: "SM-S906B", isUSB: true
    )
    private static let resumeWiFi = AuthorizedADBDevice(
        serial: "192.168.68.67:5555", product: "g0sxxx", model: "SM-S906B", isUSB: false
    )

    func testManualDisconnectStaysPausedWhenBothTransportsStayConnected() {
        // Both transports were online at disconnect and remain online — the user
        // walked away from them, so nothing should reconnect (no fall-over).
        XCTAssertNil(
            AppModel.manualDisconnectResumeDevice(
                authorizedDevices: [Self.resumeUSB, Self.resumeWiFi],
                knownSerials: [Self.resumeUSB.serial, Self.resumeWiFi.serial]
            )
        )
    }

    func testManualDisconnectResumesOnRepluggedCable() {
        // Only Wi-Fi was online at disconnect; plugging the cable back in is a
        // fresh re-discovery and should reconnect over USB.
        let resume = AppModel.manualDisconnectResumeDevice(
            authorizedDevices: [Self.resumeUSB, Self.resumeWiFi],
            knownSerials: [Self.resumeWiFi.serial]
        )
        XCTAssertEqual(resume, Self.resumeUSB)
    }

    func testManualDisconnectResumesOnReturnedWiFi() {
        // Wi-Fi dropped during the pause (so it left the known set) and came
        // back — reconnect on that very channel, not the still-present cable.
        let resume = AppModel.manualDisconnectResumeDevice(
            authorizedDevices: [Self.resumeUSB, Self.resumeWiFi],
            knownSerials: [Self.resumeUSB.serial]
        )
        XCTAssertEqual(resume, Self.resumeWiFi)
    }

    func testManualDisconnectPrefersRepluggedCableWhenBothReturn() {
        // Phone went fully offline then came back on both transports at once —
        // prefer the cable for a deterministic, fast reconnect.
        let resume = AppModel.manualDisconnectResumeDevice(
            authorizedDevices: [Self.resumeWiFi, Self.resumeUSB],
            knownSerials: []
        )
        XCTAssertEqual(resume, Self.resumeUSB)
    }

    func testManualDisconnectNoResumeWhenNothingOnline() {
        XCTAssertNil(
            AppModel.manualDisconnectResumeDevice(
                authorizedDevices: [],
                knownSerials: [Self.resumeUSB.serial, Self.resumeWiFi.serial]
            )
        )
    }

    func testManualDisconnectResumesWhenWiFiReturnsOnNewIP() {
        // A DHCP change gives Wi-Fi a different serial than the one online at
        // disconnect, so it reads as a fresh transport and reconnects.
        let newIP = AuthorizedADBDevice(
            serial: "192.168.68.99:5555", product: "g0sxxx", model: "SM-S906B", isUSB: false
        )
        let resume = AppModel.manualDisconnectResumeDevice(
            authorizedDevices: [newIP],
            knownSerials: [Self.resumeWiFi.serial]
        )
        XCTAssertEqual(resume, newIP)
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

    func testAuthorizedWirelessWinsWhenUSBIsAlsoAvailable() {
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

        XCTAssertFalse(
            AppModel.shouldPrioritizeUSBHandoff(
                authorizedDevices: [usbDevice, wirelessDevice],
                lastAttemptedSerial: nil,
                preferUSBMirroring: false,
                isMirroring: false,
                isPairing: false
            )
        )
        XCTAssertTrue(
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
        XCTAssertFalse(
            AppModel.shouldUSBInterruptReconnect(
                authorizedDevices: [usbDevice],
                isRecoveringConnection: true,
                isAwaitingReconnect: true,
                hasReconnectTask: false,
                hasWirelessStartTask: false,
                hasUSBWiFiTakeoverTask: true
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

    @MainActor
    func testManualSavedWiFiConnectDoesNotFallbackToAnotherSavedPhone() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "connect" ]; then
          case "$2" in
            192.0.2.61:5555)
              echo "failed to connect to '$2': Connection refused"
              ;;
            Android-3.local:5555)
              echo "connected to $2"
              ;;
            *)
              echo "failed to connect to '$2': No route to host"
              ;;
          esac
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          if [ "$2" = "Android-3.local:5555" ]; then
            echo "wifi-adb-ok"
          else
            echo "error: closed"
          fi
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let originalProbe = AppModel.adbTCPPortProbe
        AppModel.adbTCPPortProbe = { _ in true }
        defer { AppModel.adbTCPPortProbe = originalProbe }

        let samsung = PairedPhoneRecord(
            id: "adb-samsung",
            displayName: "SM S906B",
            lastAddress: "Android-3.local:5555",
            usbSerial: nil,
            wifiAddress: "Android-3.local:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 400)
        )
        let huawei = PairedPhoneRecord(
            id: "adb-huawei",
            displayName: "VOG L09",
            lastAddress: "192.0.2.61:5555",
            usbSerial: "6KK0220520000403",
            wifiAddress: "192.0.2.61:5555",
            firstPaired: Date(timeIntervalSince1970: 200),
            lastConnected: Date(timeIntervalSince1970: 300)
        )

        let model = AppModel(startBackgroundServices: false, pairedPhones: [samsung, huawei])
        model.connect(record: huawei, transport: AppModel.SavedConnectionTransport.wifi)

        let startedAt = Date()
        while !loggedCalls(fake.log).contains("connect 192.0.2.61:5555"),
              Date().timeIntervalSince(startedAt) < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("connect 192.0.2.61:5555"))
        XCTAssertFalse(calls.contains("connect Android-3.local:5555"))
        XCTAssertNotEqual(model.selectedDevice.adbSerial, "Android-3.local:5555")
        model.stopMirroring()
    }

    func testConnectToRememberedWirelessReadinessFlagsNoRouteToHostAcrossCandidates() async throws {
        // Every connect — saved port and the :5555 fallback — fails with "No
        // route to host", the macOS Local Network denial signature. The result
        // must report it so the saved-route reconnect prompts for permission
        // instead of silently treating the phone as offline.
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

        let result = await AppModel.connectToRememberedWirelessReadiness(
            adb: ADBController(),
            savedAddress: "192.0.2.44:42111"
        )

        XCTAssertNil(result.connectedAddress)
        XCTAssertTrue(result.sawNoRouteToHost)
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("connect 192.0.2.44:42111"))
        XCTAssertTrue(calls.contains("connect 192.0.2.44:5555"))
    }

    func testConnectToRememberedWirelessReadinessDoesNotFlagWhenReady() async throws {
        // A reachable saved route must never be mistaken for a Local Network block.
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

        let result = await AppModel.connectToRememberedWirelessReadiness(
            adb: ADBController(),
            savedAddress: "192.0.2.44:42111"
        )

        XCTAssertEqual(result.connectedAddress, "192.0.2.44:42111")
        XCTAssertFalse(result.sawNoRouteToHost)
    }

    func testWirelessReadinessRestartsADBWhenTCPIsReachableButConnectReportsNoRoute() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        STATE="$ADB_FAKE_LOG.state"
        if [ "$1" = "connect" ]; then
          if [ -f "$STATE" ]; then
            echo "connected to $2"
          else
            echo "failed to connect to '$2': No route to host"
          fi
          exit 0
        fi
        if [ "$1" = "kill-server" ]; then
          echo "killed"
          exit 0
        fi
        if [ "$1" = "start-server" ]; then
          touch "$STATE"
          echo "started"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          echo "wifi-adb-ok"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let readiness = await AppModel.waitForADBWirelessTargetReadiness(
            adb: ADBController(),
            address: "192.0.2.57:5555",
            attempts: 3,
            delayNanoseconds: 1,
            tcpPortProbe: { _ in true }
        )

        XCTAssertTrue(readiness.isReady)
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("connect 192.0.2.57:5555"))
        XCTAssertTrue(calls.contains("kill-server"))
        XCTAssertTrue(calls.contains("start-server"))
        XCTAssertEqual(calls.filter { $0 == "connect 192.0.2.57:5555" }.count, 2)
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

        XCTAssertNil(connected)
        XCTAssertLessThan(elapsed, 3.6)
    }

    @MainActor
    func testManualUSBConnectFallsBackToUSBWhenWiFiIsNotReadyQuickly() async throws {
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
        model.backgroundWiFiHandoffEnabled = true

        model.connectViaUSB()
        let startedAt = Date()
        while (!model.hasActiveMirrorSession || model.pairedPhones.first?.wifiAddress != "192.0.2.44:5555"),
              Date().timeIntervalSince(startedAt) < 10 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(model.hasActiveMirrorSession)
        XCTAssertEqual(model.selectedDevice.adbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.pairedPhones.first?.usbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.pairedPhones.first?.wifiAddress, "192.0.2.44:5555")
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3.5)
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    func testManualUSBConnectPrefillsWirelessIPFromDeviceWiFiRoute() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "devices" ]; then
          echo "List of devices attached"
          echo "TESTDEVICE001 device usb:100000001X product:g0sxxx model:SM_S906B device:g0s transport_id:1"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ]; then
          echo "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
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
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.backgroundWiFiHandoffEnabled = false

        model.connectViaUSB()
        let startedAt = Date()
        while model.manualADBTarget != "192.0.2.44",
              Date().timeIntervalSince(startedAt) < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.manualADBTarget, "192.0.2.44")
        XCTAssertEqual(model.selectedDevice.adbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.pairedPhones.first?.usbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.pairedPhones.first?.wifiAddress, "192.0.2.44:5555")
        XCTAssertFalse(loggedCalls(fake.log).contains("-s TESTDEVICE001 tcpip 5555"))
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    func testUSBPresencePrefillsAndStoresWirelessRouteBeforeUserChoosesTransport() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ]; then
          echo "default via 192.0.2.1 dev wlan0 proto dhcp src 192.0.2.44"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(
            startBackgroundServices: false,
            pairedPhones: [
                PairedPhoneRecord(
                    id: "TESTDEVICE001",
                    displayName: "SM S906B",
                    lastAddress: "TESTDEVICE001",
                    usbSerial: "TESTDEVICE001",
                    firstPaired: .now,
                    lastConnected: .now
                )
            ]
        )
        defer { model.shutdown() }

        model.applyDevicePresence("""
        List of devices attached
        TESTDEVICE001 device usb:100000001X product:g0sxxx model:SM_S906B device:g0s transport_id:1
        """)

        let startedAt = Date()
        while model.pairedPhones.first?.wifiAddress != "192.0.2.44:5555",
              Date().timeIntervalSince(startedAt) < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.manualADBTarget, "192.0.2.44")
        XCTAssertEqual(model.pairedPhones.first?.usbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.pairedPhones.first?.wifiAddress, "192.0.2.44:5555")
        XCTAssertEqual(model.pairedPhones.first?.lastAddress, "192.0.2.44:5555")
        XCTAssertFalse(loggedCalls(fake.log).contains("tcpip 5555"))
        XCTAssertFalse(model.hasActiveMirrorSession)
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
    func testManualUSBConnectPreparesVerifiedWiFiWhileKeepingUSBMirrorActive() async throws {
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
        model.backgroundWiFiHandoffEnabled = true

        model.connectViaUSB()
        let startedAt = Date()
        while (!model.hasActiveMirrorSession
            || !model.pairedPhones.contains(where: { $0.lastAddress == "192.0.2.44:5555" })),
              Date().timeIntervalSince(startedAt) < 6 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(model.hasActiveMirrorSession)
        XCTAssertEqual(model.selectedDevice.adbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.selectedDevice.network, "USB debugging")
        XCTAssertTrue(model.pairedPhones.contains(where: { $0.lastAddress == "192.0.2.44:5555" }))
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    func testManualUSBConnectStartsUSBImmediatelyWithoutPreparingWiFiHandoff() async throws {
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
            CLASSPATH=*) sleep 20; exit 0 ;;
          esac
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.backgroundWiFiHandoffEnabled = true

        model.connectViaUSB()
        let startedAt = Date()
        while !model.hasActiveMirrorSession, Date().timeIntervalSince(startedAt) < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(model.hasActiveMirrorSession)
        XCTAssertEqual(model.selectedDevice.adbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.selectedDevice.network, "USB debugging")
        XCTAssertEqual(model.pairedPhones.first?.resolvedWiFiAddress, "192.0.2.44:5555")
        let calls = loggedCalls(fake.log)
        XCTAssertFalse(calls.contains("-s TESTDEVICE001 tcpip 5555"))
        XCTAssertFalse(calls.contains("connect 192.0.2.44:5555"))
        XCTAssertFalse(calls.contains { $0.contains("-s 192.0.2.44:5555 shell CLASSPATH=") })
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    func testManualUSBMirrorExitDoesNotTakeOverWiFiHandoffSilently() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        CONNECT_COUNT_FILE="$ADB_FAKE_LOG.connect-count"
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
          count=0
          if [ -f "$CONNECT_COUNT_FILE" ]; then
            count="$(cat "$CONNECT_COUNT_FILE")"
          fi
          count=$((count + 1))
          echo "$count" > "$CONNECT_COUNT_FILE"
          if [ "$count" -le 8 ]; then
            echo "failed to connect to '$2': No route to host"
          else
            echo "connected to $2"
          fi
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
            CLASSPATH=*)
              if [ "$2" = "TESTDEVICE001" ]; then
                sleep 1
              else
                sleep 20
              fi
              exit 0
              ;;
          esac
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.backgroundWiFiHandoffEnabled = true

        model.connectViaUSB()
        let startedAt = Date()
        while !model.hasActiveMirrorSession,
              Date().timeIntervalSince(startedAt) < 3 {
            XCTAssertNil(model.activeError)
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertNil(model.activeError)
        XCTAssertTrue(model.hasActiveMirrorSession)
        XCTAssertEqual(model.selectedDevice.adbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.selectedDevice.network, "USB debugging")
        let calls = loggedCalls(fake.log)
        XCTAssertFalse(calls.contains("-s TESTDEVICE001 tcpip 5555"))
        XCTAssertFalse(calls.contains { $0.contains("-s 192.0.2.44:5555 shell CLASSPATH=") })
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// A phone already listening on 5555 must hand over to Wi-Fi *without*
    /// running `adb tcpip` (which restarts adbd and drops the live USB mirror).
    @MainActor
    func testManualUSBConnectDoesNotSwitchToWiFiWhenPortAlreadyOpen() async throws {
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
        if [ "$1" = "connect" ]; then
          echo "connected to $2"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "echo" ]; then
          echo "wifi-adb-ok"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          case "$4" in
            CLASSPATH=*) sleep 20; exit 0 ;;
          esac
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        // Port 5555 already accepts connections, so no `adb tcpip` is needed.
        AppModel.adbTCPPortProbe = { _ in true }
        defer { AppModel.adbTCPPortProbe = { await AppModel.adbTCPPortAcceptsConnection($0) } }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.backgroundWiFiHandoffEnabled = true

        model.connectViaUSB()
        let startedAt = Date()
        while !model.hasActiveMirrorSession,
              Date().timeIntervalSince(startedAt) < 3 {
            XCTAssertNil(model.activeError)
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertNil(model.activeError)
        XCTAssertTrue(model.hasActiveMirrorSession)
        XCTAssertEqual(model.selectedDevice.adbSerial, "TESTDEVICE001")
        XCTAssertEqual(model.selectedDevice.network, "USB debugging")
        let calls = loggedCalls(fake.log)
        XCTAssertFalse(calls.contains { $0.contains("tcpip 5555") })
        XCTAssertFalse(calls.contains { $0.contains("-s 192.0.2.44:5555 shell CLASSPATH=") })
        XCTAssertEqual(model.pairedPhones.first?.resolvedWiFiAddress, "192.0.2.44:5555")
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    /// On a phone that blocks adb-over-Wi-Fi (`tcpip` "succeeds" but 5555 never
    /// opens), the handoff must restart adbd at most once per session and then
    /// stop, so cable reconnects don't keep killing the USB mirror. It must
    /// still persist the freshly-learned Wi-Fi IP each time.
    @MainActor
    func testRepeatedHandoffStopsRestartingADBDAfterWiFiFailure() async throws {
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
          echo "failed to connect to '$2': No route to host"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        // Wireless adb is blocked: 5555 never accepts connections.
        AppModel.adbTCPPortProbe = { _ in false }
        defer { AppModel.adbTCPPortProbe = { await AppModel.adbTCPPortAcceptsConnection($0) } }

        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.backgroundWiFiHandoffEnabled = true
        let usb = AuthorizedADBDevice(
            serial: "TESTDEVICE001",
            product: "raven",
            model: "Pixel_6_Pro",
            isUSB: true
        )

        _ = await model.prepareWirelessHandoffForTesting(usb)
        let tcpipAfterFirst = loggedCalls(fake.log)
            .filter { $0 == "-s TESTDEVICE001 tcpip 5555" }.count
        XCTAssertEqual(tcpipAfterFirst, 1)
        XCTAssertTrue(model.legacyHandoffFailedSerialsForTesting.contains("TESTDEVICE001"))
        // The current Wi-Fi IP is saved even though the handoff didn't complete.
        XCTAssertTrue(model.pairedPhones.contains { $0.lastAddress == "192.0.2.44:5555" })

        _ = await model.prepareWirelessHandoffForTesting(usb)
        let tcpipAfterSecond = loggedCalls(fake.log)
            .filter { $0 == "-s TESTDEVICE001 tcpip 5555" }.count
        XCTAssertEqual(tcpipAfterSecond, 1)
    }

    func testOrderedByReachabilityDialsLiveCandidateFirstButKeepsPreferenceOrder() {
        let candidates = ["192.0.2.44:40123", "192.0.2.44:5555"]
        // Only the legacy listener answers → it must be dialed first.
        XCTAssertEqual(
            AppModel.orderedByReachability(candidates, reachable: ["192.0.2.44:5555"]),
            ["192.0.2.44:5555", "192.0.2.44:40123"]
        )
        // No signal (nothing / everything reachable) → preference order untouched.
        XCTAssertEqual(AppModel.orderedByReachability(candidates, reachable: []), candidates)
        XCTAssertEqual(AppModel.orderedByReachability(candidates, reachable: Set(candidates)), candidates)
    }

    func testSystemEventReconnectNudgeDecision() {
        let now = Date()
        XCTAssertTrue(AppModel.shouldNudgeReconnectForSystemEvent(
            lastNudgeAt: nil, now: now,
            isMirroring: false, isSuppressedForManualDisconnect: false, hasSavedWirelessRoute: true
        ))
        // Bursty callbacks are debounced, then allowed again.
        XCTAssertFalse(AppModel.shouldNudgeReconnectForSystemEvent(
            lastNudgeAt: now.addingTimeInterval(-1), now: now,
            isMirroring: false, isSuppressedForManualDisconnect: false, hasSavedWirelessRoute: true
        ))
        XCTAssertTrue(AppModel.shouldNudgeReconnectForSystemEvent(
            lastNudgeAt: now.addingTimeInterval(-10), now: now,
            isMirroring: false, isSuppressedForManualDisconnect: false, hasSavedWirelessRoute: true
        ))
        // Manual Disconnect stays sticky across wake/path events; a live
        // mirror needs no nudge; no saved wireless route → nothing to dial.
        XCTAssertFalse(AppModel.shouldNudgeReconnectForSystemEvent(
            lastNudgeAt: nil, now: now,
            isMirroring: false, isSuppressedForManualDisconnect: true, hasSavedWirelessRoute: true
        ))
        XCTAssertFalse(AppModel.shouldNudgeReconnectForSystemEvent(
            lastNudgeAt: nil, now: now,
            isMirroring: true, isSuppressedForManualDisconnect: false, hasSavedWirelessRoute: true
        ))
        XCTAssertFalse(AppModel.shouldNudgeReconnectForSystemEvent(
            lastNudgeAt: nil, now: now,
            isMirroring: false, isSuppressedForManualDisconnect: false, hasSavedWirelessRoute: false
        ))
    }

    func testReconnectWorthyPathTransitionFiresOnlyOnRestore() {
        XCTAssertTrue(AppModel.isReconnectWorthyPathTransition(previousSatisfied: false, nowSatisfied: true))
        // The monitor's initial callback right after start() must not dial —
        // launch reconnect is attemptAutoReconnect's job.
        XCTAssertFalse(AppModel.isReconnectWorthyPathTransition(previousSatisfied: nil, nowSatisfied: true))
        XCTAssertFalse(AppModel.isReconnectWorthyPathTransition(previousSatisfied: true, nowSatisfied: true))
        XCTAssertFalse(AppModel.isReconnectWorthyPathTransition(previousSatisfied: true, nowSatisfied: false))
    }

    func testShouldPromoteToLegacyTCPIPSkipsAddressesAlreadyOnPort5555() {
        XCTAssertFalse(AppModel.shouldPromoteToLegacyTCPIP(connectedAddress: "192.0.2.44:5555"))
        XCTAssertTrue(AppModel.shouldPromoteToLegacyTCPIP(connectedAddress: "192.0.2.44:42111"))
    }

    func testNormalizedManualPairingAddressRequiresExplicitPort() {
        XCTAssertEqual(AppModel.normalizedManualPairingAddress("192.168.1.23:37123"), "192.168.1.23:37123")
        XCTAssertEqual(AppModel.normalizedManualPairingAddress("  192.168.1.23:37123 "), "192.168.1.23:37123")
        // No bare-IP default: pairing needs the specific pairing port.
        XCTAssertNil(AppModel.normalizedManualPairingAddress("192.168.1.23"))
        XCTAssertNil(AppModel.normalizedManualPairingAddress("192.168.1.23:0"))
        XCTAssertNil(AppModel.normalizedManualPairingAddress("192.168.1.23:99999"))
        XCTAssertNil(AppModel.normalizedManualPairingAddress("not-an-ip:37123"))
        XCTAssertNil(AppModel.normalizedManualPairingAddress(""))
    }

    func testNormalizedWirelessPairingCodeRequiresSixDigits() {
        XCTAssertEqual(AppModel.normalizedWirelessPairingCode("123456"), "123456")
        XCTAssertEqual(AppModel.normalizedWirelessPairingCode(" 654321 "), "654321")
        XCTAssertNil(AppModel.normalizedWirelessPairingCode("12345"))
        XCTAssertNil(AppModel.normalizedWirelessPairingCode("1234567"))
        XCTAssertNil(AppModel.normalizedWirelessPairingCode("12a456"))
        XCTAssertNil(AppModel.normalizedWirelessPairingCode(""))
    }

    /// End-to-end manual Wireless-debugging pairing: `adb pair ip:pairport code`
    /// succeeds, the connect service is discovered over mDNS on the same host,
    /// the app connects to that (different) port and mirrors.
    @MainActor
    func testManualWirelessPairingPairsThenConnectsAndMirrors() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "pair" ]; then
          if [ "$2" = "192.168.68.67:37123" ] && [ "$3" = "123456" ]; then
            echo "Successfully paired to 192.168.68.67:43123 [guid=adb-pixel]"
          else
            echo "Failed: wrong code"
          fi
          exit 0
        fi
        if [ "$1" = "mdns" ] && [ "$2" = "services" ]; then
          echo "List of discovered mdns services"
          echo "adb-pixel	_adb-tls-connect._tcp.	192.168.68.67:43123"
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
        if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "ip" ] && [ "$5" = "route" ]; then
          echo "192.168.68.0/24 dev wlan0 proto kernel scope link src 192.168.68.67"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "tcpip" ] && [ "$4" = "5555" ]; then
          echo "restarting in TCP mode port: 5555"
          exit 0
        fi
        if [ "$1" = "-s" ] && [ "$3" = "shell" ]; then
          case "$4" in
            CLASSPATH=*) sleep 20; exit 0 ;;
          esac
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let isolated = isolatedPairedPhoneStore()
        defer { isolated.cleanup() }
        let model = AppModel(startBackgroundServices: false, pairedPhones: [], store: isolated.store)

        model.manualADBTarget = "192.168.68.67:37123"
        model.manualWirelessPairingCode = "123456"
        XCTAssertTrue(model.canPairManualWirelessTarget)

        model.pairManualWirelessTarget()
        let startedAt = Date()
        while (model.selectedDevice.adbSerial == nil
            || !model.hasActiveMirrorSession),
              Date().timeIntervalSince(startedAt) < 12 {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        XCTAssertNil(model.activeError)
        XCTAssertTrue(model.hasActiveMirrorSession)
        XCTAssertTrue(AppModel.isWirelessADBTarget(model.selectedDevice.adbSerial ?? ""))
        XCTAssertEqual(model.selectedDevice.network, "Wi-Fi")
        XCTAssertEqual(model.manualWirelessPairingCode, "")
        XCTAssertTrue(model.pairedPhones.contains { $0.lastAddress == "192.168.68.67:5555" })
        let calls = loggedCalls(fake.log)
        XCTAssertTrue(calls.contains("pair 192.168.68.67:37123 123456"))
        model.stopMirroring()
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    @MainActor
    func testManualWirelessPairingSurfacesErrorOnBadCode() async throws {
        let fake = try installFakeADB(script: """
        #!/bin/sh
        echo "$@" >> "$ADB_FAKE_LOG"
        if [ "$1" = "pair" ]; then
          echo "Failed: pairing code is incorrect"
          exit 0
        fi
        exit 0
        """)
        defer { fake.cleanup() }

        let isolated = isolatedPairedPhoneStore()
        defer { isolated.cleanup() }
        let model = AppModel(startBackgroundServices: false, pairedPhones: [], store: isolated.store)

        model.manualADBTarget = "192.168.68.67:37123"
        model.manualWirelessPairingCode = "000000"
        model.pairManualWirelessTarget()

        let startedAt = Date()
        while model.activeError == nil, Date().timeIntervalSince(startedAt) < 5 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(model.activeError?.title, "Pairing failed")
        XCTAssertFalse(model.isManualWirelessPairing)
        XCTAssertFalse(model.hasActiveMirrorSession)
    }

    @MainActor
    func testSavedDeviceConnectUsesDiscoveredWiFiHandoffAddress() async throws {
        try await withoutExplicitDeviceSetupRequired {
            let fake = try installFakeADB(script: """
            #!/bin/sh
            echo "$@" >> "$ADB_FAKE_LOG"
            if [ "$1" = "start-server" ]; then
              exit 0
            fi
            if [ "$1" = "connect" ]; then
              echo "connected to $2"
              exit 0
            fi
            if [ "$1" = "devices" ]; then
              echo "List of devices attached"
              echo "192.168.68.57:5555 device product:g0sxxx model:SM_S906B device:g0s transport_id:39"
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
              exit 0
            fi
            exit 0
            """)
            defer { fake.cleanup() }

            let record = PairedPhoneRecord(
                id: "adb-RFCT10ZLTAJ",
                displayName: "SM S906B",
                lastAddress: "RFCT10ZLTAJ",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 200)
            )
            let phone = DiscoveredPhone(
                id: "adb-RFCT10ZLTAJ",
                address: "192.168.68.57:5555",
                kind: .connectable,
                lastSeen: Date(timeIntervalSince1970: 300)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [record])
            model.setDiscoveredPhonesForTesting([phone])
            let originalProbe = AppModel.adbTCPPortProbe
            AppModel.adbTCPPortProbe = { _ in true }
            defer {
                AppModel.adbTCPPortProbe = originalProbe
            }

            model.connect(record: record)
            let startedAt = Date()
            while model.selectedDevice.adbSerial != "192.168.68.57:5555",
                  Date().timeIntervalSince(startedAt) < 4 {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            let calls = loggedCalls(fake.log)
            XCTAssertTrue(calls.contains("connect 192.168.68.57:5555"))
            XCTAssertFalse(calls.contains("connect RFCT10ZLTAJ"))
            XCTAssertEqual(model.selectedDevice.adbSerial, "192.168.68.57:5555")
            XCTAssertEqual(model.pairedPhones.first?.lastAddress, "192.168.68.57:5555")
            model.stopMirroring()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
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
    /// A PairedPhoneStore backed by a unique, volatile UserDefaults suite so a
    /// test that persists a phone never touches the developer's real prefs (or
    /// the shared xctest-tool domain). `cleanup()` removes the suite.
    private func isolatedPairedPhoneStore() -> (store: PairedPhoneStore, cleanup: () -> Void) {
        let suiteName = "PhoneRelayTests.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = PairedPhoneStore(primaryDefaults: defaults, suiteNames: [])
        return (store, {
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

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

private actor TCPProbeRecorder {
    private let openOnAttempt: Int
    private var addresses: [String] = []

    init(openOnAttempt: Int) {
        self.openOnAttempt = openOnAttempt
    }

    func record(_ address: String) -> Bool {
        addresses.append(address)
        return addresses.count >= openOnAttempt
    }

    func snapshot() -> [String] {
        addresses
    }
}

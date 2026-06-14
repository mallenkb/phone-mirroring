import XCTest
@testable import PhoneRelay

final class MirrorReconnectBackoffTests: XCTestCase {
    private let explicitDeviceSetupRequiredDefaultsKey = "MirrorBehavior.explicitDeviceSetupRequired"

    private func withoutExplicitDeviceSetupRequired(_ body: () -> Void) {
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
        body()
    }

    @MainActor
    func testClearAllDevicesResetsSelectedDeviceAndRequiresExplicitSetup() {
        let defaults = UserDefaults.standard
        let previousExplicitSetup = defaults.object(forKey: explicitDeviceSetupRequiredDefaultsKey)
        defer {
            if let previousExplicitSetup {
                defaults.set(previousExplicitSetup, forKey: explicitDeviceSetupRequiredDefaultsKey)
            } else {
                defaults.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey)
            }
        }
        defaults.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey)

        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM-S906B",
            lastAddress: "192.168.68.50:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let model = AppModel(startBackgroundServices: false, pairedPhones: [record])

        model.forgetAllPairedPhones()

        XCTAssertTrue(model.pairedPhones.isEmpty)
        XCTAssertTrue(model.discoveredPhones.isEmpty)
        XCTAssertEqual(model.selectedDevice, .demo)
        XCTAssertFalse(model.isSelectedDeviceOnline)
        XCTAssertFalse(model.isAutoConnecting)
        XCTAssertFalse(model.isPairing)
        XCTAssertTrue(defaults.bool(forKey: explicitDeviceSetupRequiredDefaultsKey))
    }

    func testClearedDeviceStateBlocksLaunchRecoveryReconnect() {
        XCTAssertFalse(
            AppModel.shouldAttemptRecoveredWiFiReconnect(
                hasSavedDevices: false,
                explicitDeviceSetupRequired: true
            )
        )
        XCTAssertTrue(
            AppModel.shouldAttemptRecoveredWiFiReconnect(
                hasSavedDevices: false,
                explicitDeviceSetupRequired: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldAttemptRecoveredWiFiReconnect(
                hasSavedDevices: true,
                explicitDeviceSetupRequired: false
            )
        )
    }

    @MainActor
    func testClearedDeviceStateAdoptsAuthorizedUSBPresenceImmediately() {
        let defaults = UserDefaults.standard
        let previousExplicitSetup = defaults.object(forKey: explicitDeviceSetupRequiredDefaultsKey)
        defer {
            if let previousExplicitSetup {
                defaults.set(previousExplicitSetup, forKey: explicitDeviceSetupRequiredDefaultsKey)
            } else {
                defaults.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey)
            }
        }
        defaults.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey)

        let model = AppModel(startBackgroundServices: false)
        model.forgetAllPairedPhones()

        model.applyDevicePresence("""
        List of devices attached
        RFCT10ZLTAJ device usb:336592896X product:g0qxxx model:SM_S906B device:g0q transport_id:4
        """)

        XCTAssertEqual(model.selectedDevice.adbSerial, "RFCT10ZLTAJ")
        XCTAssertEqual(model.selectedDevice.network, "USB debugging")
        XCTAssertTrue(model.isSelectedDeviceOnline)
        XCTAssertEqual(model.connectionStatusText, "Online")
    }

    @MainActor
    func testUnsavedAuthorizedUSBPresenceCreatesOnlineDevicePill() {
        let defaults = UserDefaults.standard
        let previousExplicitSetup = defaults.object(forKey: explicitDeviceSetupRequiredDefaultsKey)
        defer {
            if let previousExplicitSetup {
                defaults.set(previousExplicitSetup, forKey: explicitDeviceSetupRequiredDefaultsKey)
            } else {
                defaults.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey)
            }
        }
        defaults.removeObject(forKey: explicitDeviceSetupRequiredDefaultsKey)

        let model = AppModel(startBackgroundServices: false)

        model.applyDevicePresence("""
        List of devices attached
        RFCT10ZLTAJ device usb:336592896X product:g0qxxx model:SM_S906B device:g0q transport_id:4
        """)

        XCTAssertTrue(model.pairedPhones.isEmpty)
        XCTAssertEqual(model.selectedDevice.adbSerial, "RFCT10ZLTAJ")
        XCTAssertEqual(model.selectedDevice.network, "USB debugging")
        XCTAssertTrue(model.isSelectedDeviceOnline)
        XCTAssertEqual(model.connectionStatusText, "Online")
    }

    func testClearAllDisconnectTargetsIncludeOnlyWirelessADBTransports() {
        let records = [
            PairedPhoneRecord(
                id: "usb-record",
                displayName: "USB Phone",
                lastAddress: "RFCT10ZLTAJ",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 100)
            ),
            PairedPhoneRecord(
                id: "wifi-record",
                displayName: "Wi-Fi Phone",
                lastAddress: "192.168.68.50:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 200)
            )
        ]

        XCTAssertEqual(
            AppModel.wirelessTargetsToDisconnect(
                selectedSerial: "adb-RFCT10ZLTAJ._adb-tls-connect._tcp",
                selectedID: "RFCT10ZLTAJ",
                records: records
            ),
            [
                "adb-RFCT10ZLTAJ._adb-tls-connect._tcp",
                "192.168.68.50:5555"
            ]
        )
    }

    func testFirstQuickFailureDoesNotBackOff() {
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 0), 0)
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 1), 0)
    }

    func testRepeatedQuickFailuresGrowTheBackoff() {
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 2), 10)
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 3), 20)
    }

    func testBackoffIsCappedSoItStillSelfHeals() {
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 4), 30)
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 50), 30)
    }

    func testDisconnectRecoveryReturnsToOnboardingPromptly() {
        XCTAssertEqual(AppModel.disconnectRecoveryGracePeriod, 5)
    }

    func testManualReconnectWindowFailsFast() {
        XCTAssertEqual(AppModel.manualReconnectWindow, 10)
    }

    @MainActor
    func testManualDisconnectSuspendsAutoConnectForSelectedPhone() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "adb-RFCT10ZLTAJ",
                displayName: "SM S906B",
                lastAddress: "192.168.68.57:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 200)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [record])
            model.selectedDevice = MirrorDevice(
                id: record.id,
                name: record.displayName,
                model: "SM S906B",
                battery: 50,
                isCharging: false,
                network: "Wireless debugging",
                lastSeen: record.lastConnected,
                states: [.mirroringReady, .companionConnected],
                adbSerial: record.lastAddress
            )

            model.stopMirroring()

            XCTAssertEqual(model.pairedPhones.first?.autoConnectSuspended, true)
        }
    }

    @MainActor
    func testManualConnectResumesAutoConnectForSelectedPhone() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "RFCT10ZLTAJ",
                displayName: "SM S906B",
                lastAddress: "RFCT10ZLTAJ",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 200),
                autoConnectSuspended: true
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [record])

            model.connect(record: record)

            XCTAssertEqual(model.pairedPhones.first?.autoConnectSuspended, false)
        }
    }

    func testSavedDeviceShowsConnectingDuringReconnectAttempt() {
        XCTAssertEqual(
            AppModel.devicePillStatusText(
                isOnline: false,
                hasSavedDevice: true,
                isActivelyConnecting: true
            ),
            "Connecting"
        )
    }

    func testUnsavedActivePairingShowsConnecting() {
        XCTAssertEqual(
            AppModel.devicePillStatusText(
                isOnline: false,
                hasSavedDevice: false,
                isActivelyConnecting: true
            ),
            "Connecting"
        )
    }

    func testReachableDeviceStillShowsConnectingWhileMirrorLaunches() {
        XCTAssertEqual(
            AppModel.devicePillStatusText(
                isOnline: true,
                hasSavedDevice: true,
                isActivelyConnecting: true
            ),
            "Connecting"
        )
    }

    func testReachableIdleDeviceShowsOnline() {
        XCTAssertEqual(
            AppModel.devicePillStatusText(
                isOnline: true,
                hasSavedDevice: true,
                isActivelyConnecting: false
            ),
            "Online"
        )
    }

    func testConnectionDeviceLabelKeepsKnownModelName() {
        XCTAssertEqual(
            AppModel.connectionDeviceLabel(
                name: "SM-S906B",
                id: "adb-RFCT10ZLTAJ",
                serial: "Android.local:5555",
                network: "Wireless debugging"
            ),
            "SM-S906B"
        )
    }

    func testConnectionDeviceLabelUsesAndroidDeviceInsteadOfWirelessHost() {
        XCTAssertEqual(
            AppModel.connectionDeviceLabel(
                name: "Android device",
                id: "adb-RFCT10ZLTAJ",
                serial: "192.168.68.50:5555",
                network: "Wireless debugging"
            ),
            "Android Device"
        )
    }

    func testConnectionDeviceLabelUsesAndroidDeviceInsteadOfUSBSerial() {
        XCTAssertEqual(
            AppModel.connectionDeviceLabel(
                name: "Android device",
                id: "RFCT10ZLTAJ",
                serial: "RFCT10ZLTAJ",
                network: "USB debugging"
            ),
            "Android Device"
        )
    }

    func testConnectionDeviceLabelKeepsUserNamedDevice() {
        XCTAssertEqual(
            AppModel.connectionDeviceLabel(
                name: "Work phone",
                id: "adb-RFCT10ZLTAJ",
                serial: "192.168.68.50:5555",
                network: "Wireless debugging"
            ),
            "Work phone"
        )
    }

    func testMirrorWindowTitleKeepsKnownPixelModelName() {
        XCTAssertEqual(
            AppModel.mirrorWindowDeviceTitle(name: "Pixel 6 Pro"),
            "Pixel 6 Pro"
        )
    }

    func testMirrorWindowTitleKeepsUserNamedDevice() {
        XCTAssertEqual(
            AppModel.mirrorWindowDeviceTitle(name: "Work phone"),
            "Work phone"
        )
    }

    func testMirrorLoadingTitleUsesFriendlyGenericPhoneName() {
        XCTAssertEqual(AppModel.mirrorLoadingStatusText(name: "Android device"), "Connecting to your")
        XCTAssertEqual(AppModel.mirrorLoadingDeviceTitle(name: "Android device"), "Android phone")
        XCTAssertEqual(AppModel.mirrorLoadingDeviceTitle(name: "unknown"), "Android phone")
    }

    func testMirrorLoadingTitleKeepsResolvedDeviceName() {
        XCTAssertEqual(AppModel.mirrorLoadingStatusText(name: "SM-S906B"), "Connecting to your")
        XCTAssertEqual(AppModel.mirrorLoadingDeviceTitle(name: "SM-S906B"), "SM-S906B")
        XCTAssertEqual(AppModel.mirrorLoadingDeviceTitle(name: "Work phone"), "Work phone")
    }

    // MARK: - Unified auto-connecting indicator

    func testSavedPhonePresentWithoutReconnectWorkStaysOffline() {
        XCTAssertTrue(
            !AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: false,
                isMirroring: false,
                hasActiveReconnectWork: false
            )
        )
    }

    func testSavedReconnectWorkShowsConnecting() {
        XCTAssertTrue(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: false,
                isMirroring: false,
                hasActiveReconnectWork: true
            )
        )
    }

    func testNoLiveTargetDoesNotShowConnecting() {
        XCTAssertFalse(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: false,
                isMirroring: false,
                hasActiveReconnectWork: false
            )
        )
    }

    func testOnlineDeviceStillShowsConnectingWhileConnectWorkIsActive() {
        XCTAssertTrue(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: true,
                isMirroring: false,
                hasActiveReconnectWork: true
            )
        )
    }

    func testOnlineDeviceIsNotAutoConnectingWhenIdle() {
        XCTAssertFalse(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: true,
                isMirroring: false,
                hasActiveReconnectWork: false
            )
        )
    }

    func testMirroringIsNotAutoConnecting() {
        XCTAssertFalse(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: false,
                isMirroring: true,
                hasActiveReconnectWork: true
            )
        )
    }

    func testBackgroundAutoConnectDoesNotDisableManualUSBButton() {
        XCTAssertFalse(
            AppModel.shouldDisableManualUSBConnectButton(
                isPairing: false,
                isScanning: false,
                isRecoveringConnection: false,
                isAwaitingReconnect: false,
                isMirroring: false,
                isAutoConnecting: true
            )
        )
    }

    func testActivePairingDisablesManualUSBButton() {
        XCTAssertTrue(
            AppModel.shouldDisableManualUSBConnectButton(
                isPairing: true,
                isScanning: false,
                isRecoveringConnection: false,
                isAwaitingReconnect: false,
                isMirroring: false,
                isAutoConnecting: false
            )
        )
    }

    func testRecentAutoConnectFailureIsCoolingDown() {
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            AppModel.isAutoConnectFailureCoolingDown(
                failedAt: Date(timeIntervalSince1970: 95),
                now: now,
                cooldown: 10
            )
        )
        XCTAssertFalse(
            AppModel.isAutoConnectFailureCoolingDown(
                failedAt: Date(timeIntervalSince1970: 80),
                now: now,
                cooldown: 10
            )
        )
    }

    func testMirrorSettingsRestartIsSkippedWhileMirrorLaunches() {
        XCTAssertFalse(
            AppModel.shouldScheduleMirrorSettingsRestart(
                isMirroring: true,
                isPairing: false,
                isLaunching: true
            )
        )
    }

    func testMirrorSettingsRestartOnlyRunsForStableActiveMirror() {
        XCTAssertTrue(
            AppModel.shouldScheduleMirrorSettingsRestart(
                isMirroring: true,
                isPairing: false,
                isLaunching: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleMirrorSettingsRestart(
                isMirroring: false,
                isPairing: false,
                isLaunching: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldScheduleMirrorSettingsRestart(
                isMirroring: true,
                isPairing: true,
                isLaunching: false
            )
        )
    }

    func testNoSavedDeviceIsNotAutoConnecting() {
        XCTAssertFalse(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: false,
                isOnline: false,
                isMirroring: false,
                hasActiveReconnectWork: true
            )
        )
    }

    func testMirroredWirelessDeviceMissingFromADBStartsRecovery() {
        XCTAssertTrue(
            AppModel.shouldRecoverMissingMirrorTransport(
                isMirroring: true,
                selectedSerial: "192.168.68.50:5555",
                pairedPhones: [],
                authorizedDevices: []
            )
        )
    }

    func testLiveMirroredWirelessDeviceDoesNotStartRecovery() {
        let device = AuthorizedADBDevice(
            serial: "192.168.68.50:5555",
            product: "g0sxxx",
            model: "SM S906B",
            isUSB: false
        )

        XCTAssertFalse(
            AppModel.shouldRecoverMissingMirrorTransport(
                isMirroring: true,
                selectedSerial: "192.168.68.50:5555",
                pairedPhones: [],
                authorizedDevices: [device]
            )
        )
    }

    func testOnlineIdleSelectedDeviceAutoStartsMirror() {
        XCTAssertTrue(
            AppModel.shouldAutoStartOnlineSelectedDevice(
                isOnline: true,
                isMirroring: false,
                isPairing: false,
                explicitDeviceSetupRequired: false,
                hasMirrorLaunchTask: false,
                hasWirelessStartTask: false,
                hasReconnectTask: false,
                hasUSBConnectTask: false,
                isAwaitingReconnect: false,
                selectedSerial: "192.168.68.50:5555"
            )
        )
    }

    func testOnlineIdleSelectedDeviceDoesNotAutoStartDuringExplicitSetup() {
        XCTAssertFalse(
            AppModel.shouldAutoStartOnlineSelectedDevice(
                isOnline: true,
                isMirroring: false,
                isPairing: false,
                explicitDeviceSetupRequired: true,
                hasMirrorLaunchTask: false,
                hasWirelessStartTask: false,
                hasReconnectTask: false,
                hasUSBConnectTask: false,
                isAwaitingReconnect: false,
                selectedSerial: "192.168.68.50:5555"
            )
        )
    }

    func testOnlineSelectedDeviceDoesNotAutoStartWhileReconnectOwnsTransition() {
        XCTAssertFalse(
            AppModel.shouldAutoStartOnlineSelectedDevice(
                isOnline: true,
                isMirroring: false,
                isPairing: false,
                explicitDeviceSetupRequired: false,
                hasMirrorLaunchTask: false,
                hasWirelessStartTask: true,
                hasReconnectTask: false,
                hasUSBConnectTask: false,
                isAwaitingReconnect: false,
                selectedSerial: "192.168.68.50:5555"
            )
        )
        XCTAssertFalse(
            AppModel.shouldAutoStartOnlineSelectedDevice(
                isOnline: true,
                isMirroring: false,
                isPairing: false,
                explicitDeviceSetupRequired: false,
                hasMirrorLaunchTask: false,
                hasWirelessStartTask: false,
                hasReconnectTask: false,
                hasUSBConnectTask: false,
                isAwaitingReconnect: true,
                selectedSerial: "192.168.68.50:5555"
            )
        )
    }

    func testLiveRememberedMDNSTargetBypassesPresenceThrottle() {
        let now = Date(timeIntervalSince1970: 200)

        XCTAssertFalse(
            AppModel.shouldDelayRememberedAutoConnect(
                lastAttemptAt: Date(timeIntervalSince1970: 199),
                now: now,
                throttle: 3,
                hasLiveRememberedPhone: true
            )
        )
    }

    func testPresenceThrottleStillDelaysWhenOnlyStaleSavedAddressIsAvailable() {
        let now = Date(timeIntervalSince1970: 200)

        XCTAssertTrue(
            AppModel.shouldDelayRememberedAutoConnect(
                lastAttemptAt: Date(timeIntervalSince1970: 199),
                now: now,
                throttle: 3,
                hasLiveRememberedPhone: false
            )
        )
    }

    func testOnlineUSBDeviceCanRetryHandoffWhenItIsIdle() {
        XCTAssertTrue(
            AppModel.shouldAutoStartOnlineSelectedDevice(
                isOnline: true,
                isMirroring: false,
                isPairing: false,
                explicitDeviceSetupRequired: false,
                hasMirrorLaunchTask: false,
                hasWirelessStartTask: false,
                hasReconnectTask: false,
                hasUSBConnectTask: false,
                isAwaitingReconnect: false,
                selectedSerial: "RFCT10ZLTAJ"
            )
        )
    }

    func testLiveSelectedDevicePrefersRememberedWirelessTransportOverStaleUSBSerial() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "192.168.68.52:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let usb = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "",
            model: "SM S906B",
            isUSB: true
        )
        let wireless = AuthorizedADBDevice(
            serial: "192.168.68.52:5555",
            product: "g0qxxx",
            model: "SM S906B",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.liveSelectedOrRememberedDevice(
                selectedSerial: "RFCT10ZLTAJ",
                pairedPhones: [record],
                authorizedDevices: [usb, wireless]
            ),
            wireless
        )
    }

    func testLiveSelectedDeviceDoesNotUseSubstringMatchedRecordFromDifferentPhone() {
        let unrelatedRecord = PairedPhoneRecord(
            id: "adb-XRFCT10ZLTAJY",
            displayName: "Other Phone",
            lastAddress: "192.168.68.53:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let selectedUSB = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0qxxx",
            model: "SM S906B",
            isUSB: true
        )
        let unrelatedWireless = AuthorizedADBDevice(
            serial: "192.168.68.53:5555",
            product: "oriole",
            model: "Other Phone",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.liveSelectedOrRememberedDevice(
                selectedSerial: "RFCT10ZLTAJ",
                pairedPhones: [unrelatedRecord],
                authorizedDevices: [selectedUSB, unrelatedWireless]
            ),
            selectedUSB
        )
    }

    func testAwaitingReconnectShowsReconnectSurface() {
        XCTAssertTrue(
            AppModel.shouldShowReconnectSurface(
                isRecoveringConnection: false,
                isAwaitingReconnect: true
            )
        )
    }

    func testMirrorLaunchKeepsConnectionWindowVisibleUntilReadyToDisplay() {
        XCTAssertTrue(
            AppModel.shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
                isRecoveringConnection: true,
                isAwaitingReconnect: false
            )
        )
        XCTAssertTrue(
            AppModel.shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
                isRecoveringConnection: false,
                isAwaitingReconnect: true
            )
        )
        XCTAssertTrue(
            AppModel.shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
                isRecoveringConnection: false,
                isAwaitingReconnect: false
            )
        )
    }

    func testSingleConnectablePhoneCanRecoverMissingPairingRecord() {
        let phone = DiscoveredPhone(
            id: "adb-RFCT10ZLTAJ",
            address: "192.168.68.50:5555",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            AppModel.singleConnectableRecoveryCandidate(in: [phone]),
            phone
        )
    }

    func testRecoveryDoesNotGuessBetweenMultipleConnectablePhones() {
        let phones = [
            DiscoveredPhone(
                id: "adb-one",
                address: "192.168.68.50:5555",
                kind: .connectable,
                lastSeen: Date(timeIntervalSince1970: 100)
            ),
            DiscoveredPhone(
                id: "adb-two",
                address: "192.168.68.51:5555",
                kind: .connectable,
                lastSeen: Date(timeIntervalSince1970: 100)
            )
        ]

        XCTAssertNil(AppModel.singleConnectableRecoveryCandidate(in: phones))
    }

    func testPairingOnlyMDNSServiceDoesNotRecoverMissingPairingRecord() {
        let phone = DiscoveredPhone(
            id: "adb-RFCT10ZLTAJ",
            address: "192.168.68.50:37123",
            kind: .pairable,
            lastSeen: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(AppModel.singleConnectableRecoveryCandidate(in: [phone]))
    }

    func testUnauthorizedUSBDeviceIsDetected() {
        let output = """
        List of devices attached
        RFCT10ZLTAJ            unauthorized usb:1-1 transport_id:1
        """

        XCTAssertTrue(AppModel.hasUnauthorizedUSBDevice(in: output))
    }

    func testWirelessUnauthorizedOutputDoesNotCountAsUSBPrompt() {
        let output = """
        List of devices attached
        192.168.68.50:5555     unauthorized product:foo model:Pixel transport_id:2
        """

        XCTAssertFalse(AppModel.hasUnauthorizedUSBDevice(in: output))
    }

    func testLaunchReconnectWindowMatchesThreeToFiveSecondTarget() {
        XCTAssertGreaterThanOrEqual(AppModel.launchReconnectWindow, 3)
        XCTAssertLessThanOrEqual(AppModel.launchReconnectWindow, 5)
    }
}

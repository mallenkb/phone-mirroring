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
        XCTAssertFalse(
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

    func testRememberedWirelessAutoConnectRecordUsesSavedWiFiRouteWhenNotCoolingDown() {
        let usb = PairedPhoneRecord(
            id: "RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "RFCT10ZLTAJ",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let wifi = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "192.168.68.57:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(
            AppModel.rememberedWirelessAutoConnectRecord(
                in: [usb, wifi],
                failedTargets: [:],
                now: Date(timeIntervalSince1970: 400)
            ),
            wifi
        )
    }

    func testRememberedWirelessAutoConnectRecordSkipsCoolingDownSavedRoute() {
        let first = PairedPhoneRecord(
            id: "first",
            displayName: "First",
            lastAddress: "192.168.68.57:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 300)
        )
        let second = PairedPhoneRecord(
            id: "second",
            displayName: "Second",
            lastAddress: "192.168.68.58:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            AppModel.rememberedWirelessAutoConnectRecord(
                in: [first, second],
                failedTargets: ["192.168.68.57:5555": Date(timeIntervalSince1970: 395)],
                now: Date(timeIntervalSince1970: 400),
                cooldown: 20
            ),
            second
        )
    }

    func testBackgroundAutoConnectVerifiesSavedWiFiRoutesWithoutMDNS() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppModel.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("rememberedWirelessAutoConnectRecord"))
        XCTAssertTrue(source.contains("connectAndMirror(record: record)"))
        XCTAssertTrue(source.contains("connectToRememberedWireless("))
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

            XCTAssertTrue(model.isAutoConnectPausedForSession(record: record))
            XCTAssertEqual(model.pairedPhones.first?.autoConnectSuspended, false)
        }
    }

    @MainActor
    func testManualDisconnectPausesDiscoveryUntilManualConnect() {
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

            XCTAssertTrue(model.isConnectionDiscoveryPausedForManualDisconnect)

            model.connect(record: record)

            XCTAssertFalse(model.isConnectionDiscoveryPausedForManualDisconnect)
        }
    }

    @MainActor
    func testSettingsDisconnectKeepsAutoConnectPausedWhileShowingMainConnectionScreen() {
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

            model.disconnectFromSettings()

            XCTAssertTrue(model.isConnectionDiscoveryPausedForManualDisconnect)
            XCTAssertTrue(model.isAutoConnectPausedForSession(record: record))
            XCTAssertEqual(model.pairedPhones.first?.autoConnectSuspended, false)
            XCTAssertFalse(model.connectionWindowPrefersWirelessDetails)

            model.ensureQRCodePairingSession()

            XCTAssertTrue(model.isConnectionDiscoveryPausedForManualDisconnect)
            XCTAssertTrue(model.isAutoConnectPausedForSession(record: record))
        }
    }

    func testManualDisconnectKeepsPresenceWatcherForStatusOnly() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/AppModel.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("guard backgroundServicesEnabled else { return }"))
        XCTAssertFalse(source.contains("guard backgroundServicesEnabled, !isConnectionDiscoveryPausedForManualDisconnect else { return }"))
        XCTAssertTrue(source.contains("if self.isConnectionDiscoveryPausedForManualDisconnect"))
        XCTAssertTrue(source.contains("self.applyDevicePresence(output)"))
        XCTAssertTrue(source.contains("self.isAutoConnecting = false"))
    }

    @MainActor
    func testManualConnectResumesAutoConnectForSelectedPhone() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "RFCT10ZLTAJ",
                displayName: "SM S906B",
                lastAddress: "RFCT10ZLTAJ",
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
                network: "USB",
                lastSeen: record.lastConnected,
                states: [.mirroringReady, .companionConnected],
                adbSerial: record.lastAddress
            )

            model.stopMirroring()

            XCTAssertTrue(model.isAutoConnectPausedForSession(record: record))

            model.connect(record: record)

            XCTAssertFalse(model.isAutoConnectPausedForSession(record: record))
            XCTAssertEqual(model.pairedPhones.first?.autoConnectSuspended, false)
        }
    }

    @MainActor
    func testManualDisconnectAutoConnectPauseDoesNotSurviveNewAppSession() {
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

            XCTAssertTrue(model.isAutoConnectPausedForSession(record: record))
            XCTAssertEqual(model.pairedPhones.first?.autoConnectSuspended, false)

            let relaunchedModel = AppModel(startBackgroundServices: false, pairedPhones: model.pairedPhones)

            XCTAssertFalse(relaunchedModel.isAutoConnectPausedForSession(record: record))
            XCTAssertEqual(relaunchedModel.pairedPhones.first?.autoConnectSuspended, false)
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

    @MainActor
    func testConnectionChooserCanShowUSBAndWirelessAvailableTogether() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.applyDevicePresence("""
        List of devices attached
        RFCT10ZLTAJ            device usb:1-1 product:g0sxxx model:SM_S906B device:g0s transport_id:1
        """)
        model.setDiscoveredPhonesForTesting([
            DiscoveredPhone(
                id: "adb-RFCT10ZLTAJ",
                address: "192.168.68.54:5555",
                kind: .connectable,
                lastSeen: Date(timeIntervalSince1970: 100)
            )
        ])

        XCTAssertTrue(model.isUSBConnectionAvailable)
        XCTAssertTrue(model.isWirelessConnectionAvailable)
    }

    @MainActor
    func testConnectionChooserClearsUSBWithoutClearingOnlineWireless() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.applyDevicePresence("""
        List of devices attached
        RFCT10ZLTAJ            device usb:1-1 product:g0sxxx model:SM_S906B device:g0s transport_id:1
        192.168.68.54:5555     device product:g0sxxx model:SM_S906B device:g0s transport_id:2
        """)

        XCTAssertTrue(model.isUSBConnectionAvailable)
        XCTAssertTrue(model.isWirelessConnectionAvailable)

        model.applyDevicePresence("""
        List of devices attached
        192.168.68.54:5555     device product:g0sxxx model:SM_S906B device:g0s transport_id:2
        """)

        XCTAssertFalse(model.isUSBConnectionAvailable)
        XCTAssertTrue(model.isWirelessConnectionAvailable)
    }

    @MainActor
    func testConnectionChooserAddsUSBWithoutClearingOnlineWireless() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.applyDevicePresence("""
        List of devices attached
        192.168.68.54:5555     device product:g0sxxx model:SM_S906B device:g0s transport_id:2
        """)

        XCTAssertFalse(model.isUSBConnectionAvailable)
        XCTAssertTrue(model.isWirelessConnectionAvailable)

        model.applyDevicePresence("""
        List of devices attached
        RFCT10ZLTAJ            device usb:1-1 product:g0sxxx model:SM_S906B device:g0s transport_id:1
        192.168.68.54:5555     device product:g0sxxx model:SM_S906B device:g0s transport_id:2
        """)

        XCTAssertTrue(model.isUSBConnectionAvailable)
        XCTAssertTrue(model.isWirelessConnectionAvailable)
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

    func testConnectionWindowTitleDoesNotPretendGenericOfflineDeviceIsConnected() {
        XCTAssertEqual(
            AppModel.connectionWindowTitle(
                name: "Android device",
                isOnline: false,
                isMirroring: false
            ),
            "Phone Relay"
        )
    }

    func testConnectionWindowTitleUsesDeviceNameWhenOnline() {
        XCTAssertEqual(
            AppModel.connectionWindowTitle(
                name: "Pixel 6 Pro",
                isOnline: true,
                isMirroring: false
            ),
            "Pixel 6 Pro"
        )
    }

    func testMirrorLoadingTitleUsesFriendlyGenericPhoneName() {
        XCTAssertEqual(AppModel.mirrorLoadingStatusText(name: "Android device"), "Connecting to")
        XCTAssertEqual(AppModel.mirrorLoadingDeviceTitle(name: "Android device"), "Android phone")
        XCTAssertEqual(AppModel.mirrorLoadingDeviceTitle(name: "unknown"), "Android phone")
    }

    func testMirrorLoadingTitleKeepsResolvedDeviceName() {
        XCTAssertEqual(AppModel.mirrorLoadingStatusText(name: "SM-S906B"), "Connecting to")
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

    @MainActor
    func testActivePairingDoesNotReplaceConnectionSetupWithLoadingSurface() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        defer { model.shutdown() }

        model.isPairing = true

        XCTAssertTrue(model.isActivelyConnecting)
        XCTAssertFalse(model.shouldShowConnectionLoadingSurface)
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

    func testRememberedConnectablePhoneMarksSavedDeviceReachable() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "192.168.68.57:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let phone = DiscoveredPhone(
            id: "adb-RFCT10ZLTAJ",
            address: "192.168.68.57:5555",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 210)
        )

        XCTAssertTrue(
            AppModel.hasRememberedConnectablePhone(
                records: [record],
                in: [phone]
            )
        )
    }

    func testRememberedWiFiHandoffRouteCanMakeConnectionPillOnline() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "Android.local:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let phone = DiscoveredPhone(
            id: "adb-RFCT10ZLTAJ",
            address: "Android.local:5555",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 210)
        )

        XCTAssertTrue(
            AppModel.hasRememberedConnectablePhone(
                records: [record],
                in: [phone]
            ),
            "mDNS should still identify a remembered reconnect candidate."
        )
        XCTAssertEqual(
            AppModel.rememberedConnectablePhone(records: [record], in: [phone])?.address,
            "Android.local:5555",
            "The UI should use the live Wi-Fi handoff route when it is available."
        )
        XCTAssertEqual(
            AppModel.resolveConnectionPillState(
                hasError: false,
                needsUserAction: false,
                isOnline: AppModel.hasRememberedConnectablePhone(records: [record], in: [phone]),
                hasSavedDevice: true,
                isActivelyConnecting: false,
                isReconnecting: false
            ),
            .online,
            "The connection pill should show Online when a remembered USB-to-Wi-Fi handoff route is discoverable."
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

    func testFirstLaunchRecoveryUsesConnectingCopyUntilFirstSuccessfulMirror() {
        XCTAssertEqual(
            AppModel.connectionLoadingStatusText(
                hasCompletedSuccessfulMirrorConnection: false,
                isRecoveringConnection: true,
                isAwaitingReconnect: true,
                isLaunchReconnect: false,
                transport: nil
            ),
            "Connecting to"
        )

        XCTAssertEqual(
            AppModel.connectionLoadingStatusText(
                hasCompletedSuccessfulMirrorConnection: true,
                isRecoveringConnection: true,
                isAwaitingReconnect: false,
                isLaunchReconnect: false,
                transport: nil
            ),
            "Reconnecting to"
        )
    }

    func testFreshLaunchReconnectUsesGenericConnectingCopy() {
        XCTAssertEqual(
            AppModel.connectionLoadingStatusText(
                hasCompletedSuccessfulMirrorConnection: false,
                isRecoveringConnection: false,
                isAwaitingReconnect: false,
                isLaunchReconnect: true,
                transport: nil
            ),
            "Connecting..."
        )
    }

    func testWiFiHandoffUsesDeviceNameConnectionCopy() {
        XCTAssertEqual(
            AppModel.connectionLoadingStatusText(
                hasCompletedSuccessfulMirrorConnection: false,
                isRecoveringConnection: false,
                isAwaitingReconnect: false,
                isLaunchReconnect: false,
                transport: .wifi
            ),
            "Connecting to"
        )
    }

    func testUSBConnectionUsesGenericConnectionCopy() {
        XCTAssertEqual(
            AppModel.connectionLoadingStatusText(
                hasCompletedSuccessfulMirrorConnection: false,
                isRecoveringConnection: false,
                isAwaitingReconnect: false,
                isLaunchReconnect: false,
                transport: .usb
            ),
            "Connecting to"
        )

        XCTAssertEqual(
            AppModel.connectionLoadingStatusText(
                hasCompletedSuccessfulMirrorConnection: true,
                isRecoveringConnection: true,
                isAwaitingReconnect: false,
                isLaunchReconnect: false,
                transport: .usb
            ),
            "Reconnecting to"
        )
    }

    func testWiFiReconnectUsesDeviceNameReconnectCopy() {
        XCTAssertEqual(
            AppModel.connectionLoadingStatusText(
                hasCompletedSuccessfulMirrorConnection: true,
                isRecoveringConnection: true,
                isAwaitingReconnect: true,
                isLaunchReconnect: false,
                transport: .wifi
            ),
            "Reconnecting to"
        )
    }

    func testDeviceWatcherPollsAggressivelyWhileFindingSavedDevice() {
        XCTAssertEqual(
            AppModel.deviceWatcherPollInterval(
                isPairing: false,
                isMirroring: false,
                hasAuthorizedDevices: false,
                hasSavedDevices: true,
                isActivelyConnecting: true
            ),
            500_000_000
        )

        XCTAssertEqual(
            AppModel.deviceWatcherPollInterval(
                isPairing: false,
                isMirroring: false,
                hasAuthorizedDevices: true,
                hasSavedDevices: true,
                isActivelyConnecting: true
            ),
            500_000_000
        )

        XCTAssertEqual(
            AppModel.deviceWatcherPollInterval(
                isPairing: false,
                isMirroring: false,
                hasAuthorizedDevices: true,
                hasSavedDevices: true,
                isActivelyConnecting: false
            ),
            250_000_000
        )

        XCTAssertEqual(
            AppModel.deviceWatcherPollInterval(
                isPairing: false,
                isMirroring: true,
                hasAuthorizedDevices: true,
                hasSavedDevices: true,
                isActivelyConnecting: false
            ),
            2_000_000_000
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

    func testLaunchReconnectWindowIsCappedAtThreeSeconds() {
        XCTAssertEqual(AppModel.launchReconnectWindow, 3)
    }

    func testQuickFailureIsNotAStableConnection() {
        // A load-then-bail (e.g. the S906B crash) lives well under the threshold,
        // so it must not count as a completed connection — later attempts keep
        // reading "Connecting", never "Reconnecting".
        XCTAssertFalse(AppModel.isStableMirrorSession(lived: 0.5))
        XCTAssertFalse(AppModel.isStableMirrorSession(lived: 11.9))
    }

    func testSessionPastThresholdCountsAsStableConnection() {
        XCTAssertTrue(AppModel.isStableMirrorSession(lived: AppModel.quickMirrorFailureThreshold))
        XCTAssertTrue(AppModel.isStableMirrorSession(lived: 60))
    }

    func testConnectionPillStateCoversAllSevenStatuses() {
        func state(error: Bool = false, online: Bool = false, saved: Bool = false,
                   actionNeeded: Bool = false,
                   connecting: Bool = false, reconnecting: Bool = false) -> AppModel.ConnectionPillState {
            AppModel.resolveConnectionPillState(
                hasError: error, needsUserAction: actionNeeded, isOnline: online, hasSavedDevice: saved,
                isActivelyConnecting: connecting, isReconnecting: reconnecting
            )
        }
        XCTAssertEqual(state(), .noPhone)
        XCTAssertEqual(state(saved: true), .offline)
        XCTAssertEqual(state(saved: true, actionNeeded: true), .actionNeeded)
        XCTAssertEqual(state(saved: true, connecting: true), .connecting)
        XCTAssertEqual(state(saved: true, connecting: true, reconnecting: true), .reconnecting)
        XCTAssertEqual(state(online: true, saved: true), .online)
        XCTAssertEqual(state(error: true, saved: true), .failed)
        // User action wins over failures; failures win over online; online wins over connecting.
        XCTAssertEqual(state(error: true, online: true, actionNeeded: true, connecting: true), .actionNeeded)
        XCTAssertEqual(state(error: true, online: true, connecting: true), .failed)
        XCTAssertEqual(state(online: true, connecting: true), .online)

        XCTAssertEqual(AppModel.ConnectionPillState.noPhone.text, "No phone connected")
        XCTAssertEqual(AppModel.ConnectionPillState.actionNeeded.text, "Action needed")
        XCTAssertEqual(AppModel.ConnectionPillState.reconnecting.text, "Reconnecting")
        XCTAssertEqual(AppModel.ConnectionPillState.failed.text, "Connection failed")
    }

    func testConnectionPillTextUsesSpecificActionNeededReason() {
        XCTAssertEqual(
            AppModel.connectionPillText(
                state: .actionNeeded,
                activeErrorTitle: "Local Network may be blocked",
                hasUnauthorizedUSBDevice: false,
                adbStatusText: "Running"
            ),
            "Local Network may be blocked"
        )
        XCTAssertEqual(
            AppModel.connectionPillText(
                state: .actionNeeded,
                activeErrorTitle: nil,
                hasUnauthorizedUSBDevice: true,
                adbStatusText: "Running"
            ),
            "Allow USB debugging"
        )
        XCTAssertEqual(
            AppModel.connectionPillText(
                state: .actionNeeded,
                activeErrorTitle: nil,
                hasUnauthorizedUSBDevice: false,
                adbStatusText: "adb missing"
            ),
            "adb missing"
        )
    }

    func testSavedDeviceWithoutAnyLiveRouteShowsOffline() {
        XCTAssertEqual(
            AppModel.resolveConnectionPillState(
                hasError: false,
                needsUserAction: false,
                isOnline: false,
                hasSavedDevice: true,
                isActivelyConnecting: false,
                isReconnecting: false
            ),
            .offline
        )
    }

    // A phone paired over USB is recognized on its Wi-Fi transport via a
    // normalized model-name match, even though its saved address is the USB serial.
    func testRememberedDeviceMatchesWirelessTransportForUSBPairedRecord() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "RFCT10ZLTAJ",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let wireless = AuthorizedADBDevice(
            serial: "192.168.68.57:5555",
            product: "g0sxxx",
            model: "SM S906B",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.rememberedAuthorizedDevice(for: record, in: [wireless]),
            wireless
        )
    }

    // The core reliability fix: when the phone (paired under its USB serial) is
    // live only on Wi-Fi, the selected serial switches to the Wi-Fi address AND
    // that address is persisted as the record's lastAddress — so reconnect dials
    // Wi-Fi instead of looping on the dead USB serial.
    @MainActor
    func testLiveWiFiTransportReplacesAndPersistsOverStaleUSBSerial() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "adb-RFCT10ZLTAJ",
                displayName: "SM S906B",
                lastAddress: "RFCT10ZLTAJ",
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
                network: "USB debugging",
                lastSeen: record.lastConnected,
                states: [.mirroringReady, .companionConnected],
                adbSerial: "RFCT10ZLTAJ"
            )

            model.applyDevicePresence("""
            List of devices attached
            192.168.68.57:5555     device product:g0sxxx model:SM_S906B device:g0s transport_id:39
            """)

            XCTAssertTrue(model.isSelectedDeviceOnline)
            XCTAssertEqual(model.selectedDevice.adbSerial, "192.168.68.57:5555")
            XCTAssertEqual(model.pairedPhones.first?.lastAddress, "192.168.68.57:5555")
        }
    }
}

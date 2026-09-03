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

    // MARK: - Listener-missing parking (no churn on a proven-dead listener)

    /// A swept-and-silent LAN is proof the listener is gone. Re-selecting the
    /// record every presence poll would restart the whole sweep + dial cycle,
    /// so the verdict parks the record until a cable arm clears it.
    func testRememberedWirelessAutoConnectRecordSkipsListenerMissingRoute() {
        let wifi = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "192.168.68.57:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(
            AppModel.rememberedWirelessAutoConnectRecord(
                in: [wifi],
                failedTargets: [:],
                listenerMissingRecordIDs: [],
                now: Date(timeIntervalSince1970: 400)
            ),
            wifi
        )
        XCTAssertNil(
            AppModel.rememberedWirelessAutoConnectRecord(
                in: [wifi],
                failedTargets: [:],
                listenerMissingRecordIDs: ["adb-RFCT10ZLTAJ"],
                now: Date(timeIntervalSince1970: 400)
            )
        )
    }

    func testProbeSavedWiFiStatusSkipsListenerMissingRoute() {
        XCTAssertTrue(
            AppModel.shouldProbeSavedWiFiStatus(
                hasSavedWiFiRoute: true,
                hasLiveWirelessDevice: false,
                isPairing: false,
                isMirroring: false,
                hasWirelessWorkInFlight: false,
                lastProbeAt: nil
            )
        )
        XCTAssertFalse(
            AppModel.shouldProbeSavedWiFiStatus(
                hasSavedWiFiRoute: true,
                hasLiveWirelessDevice: false,
                isPairing: false,
                isMirroring: false,
                hasWirelessWorkInFlight: false,
                isListenerMissing: true,
                lastProbeAt: nil
            )
        )
    }

    /// The verdict itself is the proof — a second dial adds information about
    /// nothing — so the "plug in once" prompt surfaces on the first failure.
    func testListenerMissingPromptSurfacesOnFirstFailure() {
        XCTAssertTrue(
            AppModel.shouldSurfaceListenerMissingPrompt(
                failure: .wirelessListenerMissing,
                failureCount: 1
            )
        )
        XCTAssertFalse(
            AppModel.shouldSurfaceListenerMissingPrompt(
                failure: .temporarilyUnavailable,
                failureCount: 4
            )
        )
        XCTAssertFalse(
            AppModel.shouldSurfaceListenerMissingPrompt(
                failure: .wirelessListenerMissing,
                failureCount: 0
            )
        )
    }

    /// With every wireless record parked, selection returns nil so the loop
    /// exits to idle instead of churning a dead port every backoff window.
    @MainActor
    func testReconnectLoopParksListenerMissingRecord() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "adb-RFCT10ZLTAJ",
                displayName: "SM S906B",
                lastAddress: "192.168.68.57:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 300)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [record])

            XCTAssertEqual(model.nextAutomaticReconnectRecord(), record)

            model.connectionCoordinator.wirelessListenerMissingRecordIDs
                .insert("adb-RFCT10ZLTAJ")
            XCTAssertNil(model.nextAutomaticReconnectRecord())
        }
    }

    @MainActor
    func testReconnectLoopPrefersHealthyRecordOverParkedOne() {
        withoutExplicitDeviceSetupRequired {
            let parked = PairedPhoneRecord(
                id: "parked",
                displayName: "Parked",
                lastAddress: "192.168.68.57:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 300)
            )
            let healthy = PairedPhoneRecord(
                id: "healthy",
                displayName: "Healthy",
                lastAddress: "192.168.68.58:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 200)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [parked, healthy])
            model.connectionCoordinator.wirelessListenerMissingRecordIDs.insert("parked")

            XCTAssertEqual(model.nextAutomaticReconnectRecord(), healthy)
        }
    }

    /// Fresh evidence (a discovery/network/wake bypass, or a preferred record
    /// from matched discovery) unparks the verdict: the phone's state may
    /// have actually changed, so one verification dial is warranted.
    @MainActor
    func testReconnectLoopHonorsFreshEvidenceOverListenerMissingVerdict() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "adb-RFCT10ZLTAJ",
                displayName: "SM S906B",
                lastAddress: "192.168.68.57:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 300)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [record])
            model.connectionCoordinator.wirelessListenerMissingRecordIDs
                .insert("adb-RFCT10ZLTAJ")

            model.connectionCoordinator.automaticReconnectPreferredRecordID = record.id
            XCTAssertEqual(model.nextAutomaticReconnectRecord(), record)

            model.connectionCoordinator.automaticReconnectPreferredRecordID = nil
            model.connectionCoordinator.automaticReconnectBypassPending = true
            XCTAssertEqual(model.nextAutomaticReconnectRecord(), record)
        }
    }

    func testRememberedWirelessAutoConnectRecordSkipsCoolingDownSavedRoute() {        let first = PairedPhoneRecord(
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
        let source = try SourceTestSupport.appModelImplementation()
        let helpers = try String(
            contentsOfFile: "Sources/PhoneRelay/AppModel+ConnectionHelpers.swift",
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("rememberedWirelessAutoConnectRecord"))
        XCTAssertTrue(source.contains("requestAutomaticReconnect(trigger:"))
        XCTAssertTrue(source.contains("performAutomaticWirelessReconnect(record:"))
        XCTAssertTrue(helpers.contains("connectToRememberedWireless("))
        // Automatic reconnect must never share the wire with a user-initiated
        // connect flow: both the entry point and the loop guard on manual work.
        // The third site is the cable-arrival Wi-Fi arm, which runs `adb tcpip`
        // and so must yield to any connect the user started.
        XCTAssertEqual(
            source.components(
                separatedBy: "!connectionCoordinator.hasManualConnectionWorkInFlight"
            ).count - 1,
            3
        )
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

            XCTAssertTrue(model.isAutoReconnectSuppressedForManualDisconnect)

            model.connect(record: record)

            XCTAssertFalse(model.isAutoReconnectSuppressedForManualDisconnect)
        }
    }

    // Disconnect means "stop mirroring", not "stop discovering": the phone must
    // stay visible/online in the list afterwards (it just won't auto-re-mirror).
    @MainActor
    func testManualDisconnectKeepsDiscoveryVisible() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "adb-RFCT10ZLTAJ",
                displayName: "SM S906B",
                lastAddress: "192.168.68.67:5555",
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
                network: "Wi-Fi",
                lastSeen: record.lastConnected,
                states: [.mirroringReady, .companionConnected],
                adbSerial: record.lastAddress
            )
            model.setDiscoveredPhonesForTesting([
                DiscoveredPhone(
                    id: "adb-RFCT10ZLTAJ",
                    address: "192.168.68.67:5555",
                    kind: .connectable,
                    lastSeen: Date(timeIntervalSince1970: 210)
                )
            ])

            model.stopMirroring()

            // Discovery is NOT torn down — the phone stays in the list…
            XCTAssertFalse(model.discoveredPhones.isEmpty)
            // …but auto-re-mirror is suppressed for it.
            XCTAssertTrue(model.isAutoReconnectSuppressedForManualDisconnect)
            XCTAssertTrue(model.isAutoConnectPausedForSession(record: record))
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

            XCTAssertTrue(model.isAutoReconnectSuppressedForManualDisconnect)
            XCTAssertTrue(model.isAutoConnectPausedForSession(record: record))
            XCTAssertEqual(model.pairedPhones.first?.autoConnectSuspended, false)
            XCTAssertFalse(model.connectionWindowPrefersWirelessDetails)

            model.ensureQRCodePairingSession()

            XCTAssertTrue(model.isAutoReconnectSuppressedForManualDisconnect)
            XCTAssertTrue(model.isAutoConnectPausedForSession(record: record))
        }
    }

    func testManualDisconnectKeepsPresenceWatcherForStatusOnly() throws {
        let source = try SourceTestSupport.appModelImplementation()

        XCTAssertTrue(source.contains("guard backgroundServicesEnabled else { return }"))
        XCTAssertFalse(source.contains("guard backgroundServicesEnabled, !isAutoReconnectSuppressedForManualDisconnect else { return }"))
        XCTAssertTrue(source.contains("if self.isAutoReconnectSuppressedForManualDisconnect"))
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
                address: "192.168.68.54:42111",
                kind: .wirelessDebugging,
                lastSeen: Date(timeIntervalSince1970: 100)
            )
        ])

        XCTAssertTrue(model.isUSBConnectionAvailable)
        XCTAssertTrue(model.isWirelessConnectionAvailable)
        XCTAssertEqual(model.connectionTransportLabel, "USB + Wi-Fi")
    }

    @MainActor
    func testConnectionAvailabilityIsScopedToSelectedPhone() {
        let selectedRecord = PairedPhoneRecord(
            id: "PHONE-A",
            displayName: "Pixel A",
            lastAddress: "PHONE-A",
            usbSerial: "PHONE-A",
            firstPaired: .now,
            lastConnected: .now
        )
        let model = AppModel(startBackgroundServices: false, pairedPhones: [selectedRecord])
        model.selectedDevice = MirrorDevice(
            id: selectedRecord.id,
            name: selectedRecord.displayName,
            model: "Pixel A",
            battery: 80,
            isCharging: false,
            network: "USB",
            lastSeen: .now,
            states: [.companionConnected],
            adbSerial: "PHONE-A"
        )
        model.applyDevicePresence("""
        List of devices attached
        PHONE-A device usb:1-1 product:pixel_a model:Pixel_A device:pixel transport_id:1
        192.0.2.99:5555 device product:pixel_b model:Pixel_B device:pixel transport_id:2
        """)

        XCTAssertTrue(model.isMatchingUSBConnectionAvailable)
        XCTAssertFalse(model.isMatchingLiveWirelessConnectionAvailable)
        XCTAssertEqual(model.connectionTransportLabel, "USB")
    }

    @MainActor
    func testMatchingDiscoveredWiFiIsGreenBeforeConnectionAttempt() {
        let record = PairedPhoneRecord(
            id: "adb-PHONE-A",
            displayName: "Pixel A",
            lastAddress: "192.0.2.44:5555",
            usbSerial: "PHONE-A",
            wifiAddress: "192.0.2.44:5555",
            firstPaired: .now,
            lastConnected: .now
        )
        let model = AppModel(startBackgroundServices: false, pairedPhones: [record])
        model.legacyWirelessCompatibilityEnabled = true
        defer { model.legacyWirelessCompatibilityEnabled = false }
        model.selectedDevice = MirrorDevice(
            id: record.id,
            name: record.displayName,
            model: "Pixel A",
            battery: 80,
            isCharging: false,
            network: "Wi-Fi",
            lastSeen: .now,
            states: [.companionConnected],
            adbSerial: record.resolvedWiFiAddress
        )
        model.setDiscoveredPhonesForTesting([
            DiscoveredPhone(
                id: record.id,
                address: "192.0.2.44:5555",
                kind: .legacyTCPIP,
                lastSeen: .now
            )
        ])

        XCTAssertTrue(model.isMatchingLiveWirelessConnectionAvailable)
        XCTAssertEqual(model.connectionTransportLabel, "Wi-Fi")
        XCTAssertFalse(model.isActivelyConnecting)
    }

    func testLiveConnectionRoutesDoNotTreatSavedWiFiAsLive() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "RFCT10ZLTAJ",
            usbSerial: "RFCT10ZLTAJ",
            wifiAddress: "192.168.68.54:5555",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )

        let staleSavedRoute = AppModel.liveConnectionRoutes(
            for: record,
            authorizedDevices: [],
            discoveredPhones: []
        )
        XCTAssertNil(staleSavedRoute.wifiAddress)
        XCTAssertNil(staleSavedRoute.usbSerial)
        XCTAssertNil(staleSavedRoute.statusLabel)

        let usb = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0sxxx",
            model: "SM S906B",
            isUSB: true
        )
        let wifi = AuthorizedADBDevice(
            serial: "192.168.68.54:5555",
            product: "g0sxxx",
            model: "SM S906B",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.liveConnectionRoutes(
                for: record,
                authorizedDevices: [usb],
                discoveredPhones: []
            ).statusLabel,
            "USB available"
        )
        XCTAssertEqual(
            AppModel.liveConnectionRoutes(
                for: record,
                authorizedDevices: [wifi],
                discoveredPhones: [],
                allowLegacyCompatibility: true
            ).statusLabel,
            "Wi-Fi available"
        )
        XCTAssertEqual(
            AppModel.liveConnectionRoutes(
                for: record,
                authorizedDevices: [usb, wifi],
                discoveredPhones: [],
                allowLegacyCompatibility: true
            ).statusLabel,
            "Wi-Fi and USB available"
        )

        let secureWiFi = AuthorizedADBDevice(
            serial: "192.168.68.54:37183",
            product: "g0sxxx",
            model: "SM S906B",
            isUSB: false
        )
        XCTAssertEqual(
            AppModel.liveConnectionRoutes(
                for: record,
                authorizedDevices: [wifi, secureWiFi],
                discoveredPhones: []
            ).wifiAddress,
            secureWiFi.serial
        )

        let unrelatedDiscovery = DiscoveredPhone(
            id: "adb-OTHER-PHONE",
            address: "192.0.2.99:5555",
            kind: .legacyTCPIP,
            lastSeen: .now
        )
        XCTAssertFalse(
            AppModel.liveConnectionRoutes(
                for: record,
                authorizedDevices: [usb],
                discoveredPhones: [unrelatedDiscovery]
            ).hasWiFi
        )
    }

    @MainActor
    func testFirstRunLegacyWiFiRequiresCompatibilityWithoutSavedUSBSetup() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.legacyWirelessCompatibilityEnabled = false
        model.applyDevicePresence("""
        List of devices attached
        192.168.68.67:5555     device product:g0sxxx model:SM_S906B device:g0s transport_id:1
        """)

        XCTAssertTrue(model.isFirstTimeUSBSetup)
        XCTAssertFalse(model.isUSBConnectionAvailable)
        XCTAssertFalse(model.isLiveWirelessConnectionAvailable)
        XCTAssertNil(model.connectionTransportLabel)

        model.legacyWirelessCompatibilityEnabled = true
        defer { model.legacyWirelessCompatibilityEnabled = false }
        XCTAssertTrue(model.isLiveWirelessConnectionAvailable)
        XCTAssertEqual(model.connectionTransportLabel, "Wi-Fi")
    }

    @MainActor
    func testConnectionChooserClearsUSBWithoutClearingOnlineWireless() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.legacyWirelessCompatibilityEnabled = true
        defer { model.legacyWirelessCompatibilityEnabled = false }
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
        model.legacyWirelessCompatibilityEnabled = true
        defer { model.legacyWirelessCompatibilityEnabled = false }
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

    func testConnectionChoiceTitleUsesConnectedDeviceNameWhenOnline() {
        XCTAssertEqual(
            AppModel.connectionChoiceTitle(
                deviceLabel: "SM S906B",
                state: .online,
                isDeviceConnected: true,
                isFirstTimeUSBSetup: true,
                isWiFiConnectionAvailable: false
            ),
            "SM S906B is connected"
        )
    }

    func testConnectionChoiceTitleDoesNotClaimConnectedFromDiscoveryOnlyState() {
        XCTAssertEqual(
            AppModel.connectionChoiceTitle(
                deviceLabel: "Android Device",
                state: .online,
                isDeviceConnected: false,
                isFirstTimeUSBSetup: true,
                isWiFiConnectionAvailable: false
            ),
            "Set up your Android phone with USB"
        )
    }

    func testConnectionChoiceTitleKeepsSetupCopyWhenNoDeviceIsOnline() {
        XCTAssertEqual(
            AppModel.connectionChoiceTitle(
                deviceLabel: "",
                state: .noPhone,
                isDeviceConnected: false,
                isFirstTimeUSBSetup: true,
                isWiFiConnectionAvailable: false
            ),
            "Set up your Android phone with USB"
        )
    }

    func testConnectionChoiceTitleKeepsConnectCopyForIdleChooser() {
        XCTAssertEqual(
            AppModel.connectionChoiceTitle(
                deviceLabel: "",
                state: .offline,
                isDeviceConnected: false,
                isFirstTimeUSBSetup: false,
                isWiFiConnectionAvailable: true
            ),
            "Connect your Android phone"
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

    // MARK: - Wi-Fi address recovery throttle

    func testWiFiRecoveryFirstAttemptIsNeverThrottled() {
        XCTAssertFalse(
            AppModel.shouldThrottleWiFiRecovery(
                lastAttemptAt: nil,
                now: Date(timeIntervalSince1970: 100),
                cooldown: 60
            )
        )
    }

    func testWiFiRecoveryBackgroundPollIsThrottledWithinCooldown() {
        XCTAssertTrue(
            AppModel.shouldThrottleWiFiRecovery(
                lastAttemptAt: Date(timeIntervalSince1970: 70),
                now: Date(timeIntervalSince1970: 100),
                cooldown: 60
            )
        )
    }

    func testWiFiRecoveryBackgroundPollResumesAfterCooldown() {
        XCTAssertFalse(
            AppModel.shouldThrottleWiFiRecovery(
                lastAttemptAt: Date(timeIntervalSince1970: 30),
                now: Date(timeIntervalSince1970: 100),
                cooldown: 60
            )
        )
    }

    // A deliberate "Reconnect over Wi-Fi" press is one action, not a poll storm,
    // so it must sweep immediately even if a background poll just swept.
    func testUserInitiatedReconnectBypassesWiFiRecoveryCooldown() {
        XCTAssertFalse(
            AppModel.shouldThrottleWiFiRecovery(
                lastAttemptAt: Date(timeIntervalSince1970: 99),
                now: Date(timeIntervalSince1970: 100),
                cooldown: 60,
                ignoreCooldown: true
            )
        )
    }

    // MARK: - USB Wi-Fi address prefill refresh

    func testUSBPrefillAlwaysRunsForNewlyPluggedSerial() {
        XCTAssertTrue(
            AppModel.shouldRefreshUSBWiFiAddressPrefill(
                lastSerial: "OLD-SERIAL",
                currentSerial: "NEW-SERIAL",
                lastPrefillAt: Date(timeIntervalSince1970: 100),
                now: Date(timeIntervalSince1970: 101)
            )
        )
        XCTAssertTrue(
            AppModel.shouldRefreshUSBWiFiAddressPrefill(
                lastSerial: nil,
                currentSerial: "NEW-SERIAL",
                lastPrefillAt: nil,
                now: Date(timeIntervalSince1970: 101)
            )
        )
    }

    // The same cable re-qualifies only once the refresh interval elapses, so a
    // mid-session DHCP change is picked up without hammering `ip route`.
    func testUSBPrefillSameCableWaitsForRefreshInterval() {
        let prefillAt = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(
            AppModel.shouldRefreshUSBWiFiAddressPrefill(
                lastSerial: "SAME-SERIAL",
                currentSerial: "SAME-SERIAL",
                lastPrefillAt: prefillAt,
                now: prefillAt.addingTimeInterval(179),
                refreshInterval: 180
            )
        )
        XCTAssertTrue(
            AppModel.shouldRefreshUSBWiFiAddressPrefill(
                lastSerial: "SAME-SERIAL",
                currentSerial: "SAME-SERIAL",
                lastPrefillAt: prefillAt,
                now: prefillAt.addingTimeInterval(180),
                refreshInterval: 180
            )
        )
    }

    func testForegroundRecoveryCooldownIsShorterThanIdle() {
        XCTAssertLessThan(
            AppModel.wifiAddressRecoveryForegroundCooldown,
            AppModel.wifiAddressRecoveryCooldown
        )
    }

    // 40s after the last sweep: still throttled at the idle (60s) cadence, but a
    // watched connect screen (foreground, 15s) is free to re-sweep.
    func testForegroundCooldownReleasesRecoverySoonerThanIdle() {
        let lastAttempt = Date(timeIntervalSince1970: 60)
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(
            AppModel.shouldThrottleWiFiRecovery(
                lastAttemptAt: lastAttempt,
                now: now,
                cooldown: AppModel.wifiAddressRecoveryCooldown
            )
        )
        XCTAssertFalse(
            AppModel.shouldThrottleWiFiRecovery(
                lastAttemptAt: lastAttempt,
                now: now,
                cooldown: AppModel.wifiAddressRecoveryForegroundCooldown
            )
        )
    }

    // MARK: - Local Network permission error surfacing

    // Reopening with only Wi-Fi (cable unplugged): a repeated "No route to host"
    // must surface as an actionable error, not silently spin (which reads as
    // "it didn't save / won't reconnect").
    func testWiFiOnlyNoRouteSurfacesLocalNetworkError() {
        XCTAssertTrue(
            AppModel.shouldSurfaceLocalNetworkError(
                isUSBConnectionAvailable: false,
                isMirroring: false,
                currentErrorTitle: nil
            )
        )
    }

    // With USB plugged in, mirroring still works — keep it to the log, don't cover
    // the screen.
    func testUSBFallbackSuppressesLocalNetworkError() {
        XCTAssertFalse(
            AppModel.shouldSurfaceLocalNetworkError(
                isUSBConnectionAvailable: true,
                isMirroring: false,
                currentErrorTitle: nil
            )
        )
    }

    func testActiveMirrorDoesNotSurfaceLocalNetworkError() {
        XCTAssertFalse(
            AppModel.shouldSurfaceLocalNetworkError(
                isUSBConnectionAvailable: false,
                isMirroring: true,
                currentErrorTitle: nil
            )
        )
    }

    // Don't re-report the same error every failed poll.
    func testLocalNetworkErrorIsNotReReportedWhileAlreadyShown() {
        XCTAssertFalse(
            AppModel.shouldSurfaceLocalNetworkError(
                isUSBConnectionAvailable: false,
                isMirroring: false,
                currentErrorTitle: AppModel.localNetworkBlockedErrorTitle
            )
        )
    }

    // The Wi-Fi chooser must reconnect ANY saved wireless device — including a
    // reopened tcpip:5555 phone that isn't live/discovered yet — so the tap keys
    // off hasSavedWirelessConnection, not the live-gated hasVisibleSavedWirelessConnection.
    func testWiFiOptionReconnectsAnySavedWirelessDeviceNotJustVisibleOne() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/Views/FigmaMirrorExperienceView.swift",
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("else if model.hasSavedWirelessConnection {"))
        XCTAssertFalse(source.contains("else if model.hasVisibleSavedWirelessConnection {"))
    }

    // MARK: - Connection-health "Next recommended fix"

    func testHealthyConnectionRecommendsNoAction() {
        XCTAssertEqual(
            AppModel.nextRecommendedConnectionFix(
                isSelectedDeviceOnline: true,
                isActivelyConnecting: false,
                hasUnauthorizedUSBDevice: false,
                hasAuthorizedUSB: false,
                hasWiFiReachability: true,
                localNetworkPermissionGranted: true,
                adbStatusText: "Running",
                activeErrorMessage: nil
            ),
            AppModel.noActionNeededRecommendedFix
        )
    }

    // Local Network off with no USB fallback → the actionable Local Network fix
    // (which the connection-health view renders with a one-tap "Open Local Network").
    func testLocalNetworkOffRecommendsLocalNetworkFix() {
        XCTAssertEqual(
            AppModel.nextRecommendedConnectionFix(
                isSelectedDeviceOnline: false,
                isActivelyConnecting: false,
                hasUnauthorizedUSBDevice: false,
                hasAuthorizedUSB: false,
                hasWiFiReachability: true,
                localNetworkPermissionGranted: false,
                adbStatusText: "Running",
                activeErrorMessage: nil
            ),
            AppModel.localNetworkRecommendedFix
        )
    }

    // The whole "Next recommended fix" row is hidden when the connection is healthy.
    func testConnectionHealthHidesFixRowWhenNoActionNeeded() throws {
        let source = try String(
            contentsOfFile: "Sources/PhoneRelay/Views/SettingsView.swift",
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("snapshot.recommendedFix != AppModel.noActionNeededRecommendedFix"))
    }

    // The manual reconnect loop must hunt for a moved DHCP address by MAC (the
    // case mDNS + the saved address both miss), bypassing the per-phone cooldown.
    func testManualReconnectLoopRecoversChangedWiFiAddress() throws {
        let source = try SourceTestSupport.appModelImplementation()

        XCTAssertTrue(source.contains("func reconnectOverWiFi("))
        XCTAssertTrue(source.contains("recoverChangedWiFiAddress("))
        // The only caller that bypasses the cooldown is the manual reconnect loop.
        XCTAssertTrue(source.contains("ignoreCooldown: true"))
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

    // A single missed poll must not tear down a live mirror — `adb devices -l`
    // can momentarily omit a healthy wireless device, and a genuine loss is
    // caught faster by the stream-death detector anyway.
    func testMissingMirrorTransportTeardownIsDebouncedAcrossPolls() {
        XCTAssertGreaterThanOrEqual(AppModel.missingMirrorTransportPollGrace, 2)
    }

    func testConfirmedNetworkLossInvalidatesLiveWirelessConnection() {
        XCTAssertTrue(
            AppModel.shouldInvalidateConnectionForConfirmedPathLoss(
                isPathLossConfirmed: true,
                isSelectedDeviceOnline: true,
                isMirroring: false,
                selectedSerial: "192.168.68.50:5555",
                selectedNetwork: "Wi-Fi"
            )
        )
    }

    func testConfirmedNetworkLossInvalidatesWirelessMirrorEvenBeforePresencePoll() {
        XCTAssertTrue(
            AppModel.shouldInvalidateConnectionForConfirmedPathLoss(
                isPathLossConfirmed: true,
                isSelectedDeviceOnline: false,
                isMirroring: true,
                selectedSerial: "Android.local:5555",
                selectedNetwork: "Wireless debugging"
            )
        )
    }

    func testConfirmedNetworkLossDoesNotInvalidateUSBConnection() {
        XCTAssertFalse(
            AppModel.shouldInvalidateConnectionForConfirmedPathLoss(
                isPathLossConfirmed: true,
                isSelectedDeviceOnline: true,
                isMirroring: true,
                selectedSerial: "RFCT10ZLTAJ",
                selectedNetwork: "USB debugging"
            )
        )
    }

    func testUnconfirmedNetworkLossDoesNotInvalidateWirelessConnection() {
        XCTAssertFalse(
            AppModel.shouldInvalidateConnectionForConfirmedPathLoss(
                isPathLossConfirmed: false,
                isSelectedDeviceOnline: true,
                isMirroring: true,
                selectedSerial: "192.168.68.50:5555",
                selectedNetwork: "Wi-Fi"
            )
        )
    }

    func testConfirmedNetworkLossFiltersStaleWirelessADBRowsButKeepsUSB() {
        let usb = AuthorizedADBDevice(
            serial: "RFCT10ZLTAJ",
            product: "g0sxxx",
            model: "SM S906B",
            isUSB: true
        )
        let wifi = AuthorizedADBDevice(
            serial: "192.168.68.50:5555",
            product: "g0sxxx",
            model: "SM S906B",
            isUSB: false
        )

        XCTAssertEqual(
            AppModel.devicesAvailableForCurrentPath(
                [usb, wifi],
                isPathLossConfirmed: true
            ),
            [usb]
        )
        XCTAssertEqual(
            AppModel.devicesAvailableForCurrentPath(
                [usb, wifi],
                isPathLossConfirmed: false
            ),
            [usb, wifi]
        )
    }

    func testDeviceWatcherDebouncesMissingMirrorTransport() throws {
        let source = try SourceTestSupport.appModelImplementation()
        XCTAssertTrue(source.contains("missingMirrorTransportPollMisses += 1"))
        XCTAssertTrue(source.contains("missingMirrorTransportPollMisses >= Self.missingMirrorTransportPollGrace"))
        // The counter resets when the transport reappears, so only *consecutive*
        // misses tear down.
        XCTAssertTrue(source.contains("self.missingMirrorTransportPollMisses = 0"))
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
                hasLivePhone: false,
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

    func testSavedWiFiStatusProbeRunsWhenWirelessRouteIsMissing() {
        XCTAssertTrue(
            AppModel.shouldProbeSavedWiFiStatus(
                hasSavedWiFiRoute: true,
                hasLiveWirelessDevice: false,
                isPairing: false,
                isMirroring: false,
                hasWirelessWorkInFlight: false,
                lastProbeAt: nil,
                now: Date(timeIntervalSince1970: 200),
                interval: 2
            )
        )
    }

    func testSavedWiFiStatusProbeIsSubtlyPaced() {
        let now = Date(timeIntervalSince1970: 200)

        XCTAssertFalse(
            AppModel.shouldProbeSavedWiFiStatus(
                hasSavedWiFiRoute: true,
                hasLiveWirelessDevice: false,
                isPairing: false,
                isMirroring: false,
                hasWirelessWorkInFlight: false,
                lastProbeAt: Date(timeIntervalSince1970: 199),
                now: now,
                interval: 2
            )
        )
        XCTAssertTrue(
            AppModel.shouldProbeSavedWiFiStatus(
                hasSavedWiFiRoute: true,
                hasLiveWirelessDevice: false,
                isPairing: false,
                isMirroring: false,
                hasWirelessWorkInFlight: false,
                lastProbeAt: Date(timeIntervalSince1970: 198),
                now: now,
                interval: 2
            )
        )
    }

    func testSavedWiFiStatusProbeSkipsWhenAlreadyOnlineOrBusy() {
        let now = Date(timeIntervalSince1970: 200)

        XCTAssertFalse(
            AppModel.shouldProbeSavedWiFiStatus(
                hasSavedWiFiRoute: true,
                hasLiveWirelessDevice: true,
                isPairing: false,
                isMirroring: false,
                hasWirelessWorkInFlight: false,
                lastProbeAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            AppModel.shouldProbeSavedWiFiStatus(
                hasSavedWiFiRoute: true,
                hasLiveWirelessDevice: false,
                isPairing: false,
                isMirroring: false,
                hasWirelessWorkInFlight: true,
                lastProbeAt: nil,
                now: now
            )
        )
        XCTAssertFalse(
            AppModel.shouldProbeSavedWiFiStatus(
                hasSavedWiFiRoute: true,
                hasLiveWirelessDevice: false,
                isPairing: false,
                isMirroring: true,
                hasWirelessWorkInFlight: false,
                lastProbeAt: nil,
                now: now
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

    func testMirrorLaunchHandsLoadingStateOffToMirrorWindow() {
        XCTAssertFalse(
            AppModel.shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
                isRecoveringConnection: true,
                isAwaitingReconnect: false
            )
        )
        XCTAssertFalse(
            AppModel.shouldKeepConnectionWindowVisibleDuringMirrorLaunch(
                isRecoveringConnection: false,
                isAwaitingReconnect: true
            )
        )
        XCTAssertFalse(
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

    func testConnectionPillStateCoversAllEightStatuses() {
        func state(error: Bool = false, online: Bool = false, live: Bool = false, saved: Bool = false,
                   actionNeeded: Bool = false,
                   connecting: Bool = false, reconnecting: Bool = false) -> AppModel.ConnectionPillState {
            AppModel.resolveConnectionPillState(
                hasError: error, needsUserAction: actionNeeded, isOnline: online, hasLivePhone: live, hasSavedDevice: saved,
                isActivelyConnecting: connecting, isReconnecting: reconnecting
            )
        }
        XCTAssertEqual(state(), .noPhone)
        XCTAssertEqual(state(saved: true), .offline)
        XCTAssertEqual(state(live: true), .online)
        XCTAssertEqual(state(saved: true, actionNeeded: true), .actionNeeded)
        XCTAssertEqual(state(saved: true, connecting: true), .connecting)
        XCTAssertEqual(state(saved: true, connecting: true, reconnecting: true), .reconnecting)
        XCTAssertEqual(state(online: true, saved: true), .online)
        XCTAssertEqual(state(error: true, saved: true), .failed)
        // User action wins over failures; an active dial visibly replaces the
        // passive online/available state until the mirror is ready.
        XCTAssertEqual(state(error: true, online: true, actionNeeded: true, connecting: true), .actionNeeded)
        XCTAssertEqual(state(error: true, online: true, connecting: true), .failed)
        XCTAssertEqual(state(online: true, connecting: true), .connecting)

        XCTAssertEqual(AppModel.ConnectionPillState.noPhone.text, "No phone connected")
        XCTAssertEqual(AppModel.ConnectionPillState.actionNeeded.text, "Action needed")
        XCTAssertEqual(AppModel.ConnectionPillState.reconnecting.text, "Reconnecting")
        XCTAssertEqual(AppModel.ConnectionPillState.waitingForPhone.text, "Retrying saved Wi-Fi")
        XCTAssertEqual(AppModel.ConnectionPillState.failed.text, "Connection failed")
    }

    func testAutomaticReconnectTriggersRespectExplicitSetupAndOnboarding() {
        XCTAssertFalse(
            AppModel.automaticReconnectTriggerAllowed(
                explicitDeviceSetupRequired: true,
                isFirstRunOnboardingActive: false,
                isAutoMirrorHeldForOnboarding: false
            )
        )
        XCTAssertFalse(
            AppModel.automaticReconnectTriggerAllowed(
                explicitDeviceSetupRequired: false,
                isFirstRunOnboardingActive: true,
                isAutoMirrorHeldForOnboarding: false
            )
        )
        XCTAssertTrue(
            AppModel.automaticReconnectTriggerAllowed(
                explicitDeviceSetupRequired: false,
                isFirstRunOnboardingActive: false,
                isAutoMirrorHeldForOnboarding: false
            )
        )
    }

    @MainActor
    func testConnectionPillTransitionsToWaitingExactlyAtThirtySecondPlateau() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "phone-a",
                displayName: "Phone A",
                lastAddress: "192.0.2.44:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 200)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [record])

            model.connectionCoordinator.automaticRetryStates[record.id] = .init(
                failureCount: 3,
                nextRetryAt: Date().addingTimeInterval(20),
                lastFailure: .temporarilyUnavailable
            )
            model.connectionCoordinator.automaticReconnectState = .waiting(
                recordID: record.id,
                retryAt: Date().addingTimeInterval(20),
                failure: .temporarilyUnavailable
            )
            XCTAssertFalse(model.isAutomaticReconnectAtPlateau)

            model.connectionCoordinator.automaticRetryStates[record.id]?.failureCount = 4
            XCTAssertTrue(model.isAutomaticReconnectAtPlateau)
            XCTAssertEqual(model.connectionPillState, .waitingForPhone)
            XCTAssertEqual(model.connectionPillText, "Retrying saved Wi-Fi")
        }
    }

    @MainActor
    func testConnectionPillSurfacesProvenPairingRequirementAtPlateau() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "phone-a",
                displayName: "Phone A",
                lastAddress: "192.0.2.44:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 200)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [record])

            // Pairing-required is the one plateau failure the user provably has
            // to fix, so the pill asks for action instead of an open-ended wait.
            model.connectionCoordinator.automaticRetryStates[record.id] = .init(
                failureCount: 4,
                nextRetryAt: Date().addingTimeInterval(30),
                lastFailure: .pairingRequired
            )
            model.connectionCoordinator.automaticReconnectState = .waiting(
                recordID: record.id,
                retryAt: Date().addingTimeInterval(30),
                failure: .pairingRequired
            )

            XCTAssertEqual(model.automaticReconnectPlateauFailure, .pairingRequired)
            XCTAssertEqual(model.connectionPillState, .actionNeeded)
        }
        XCTAssertEqual(
            AppModel.connectionPillText(
                state: .actionNeeded,
                activeErrorTitle: AppModel.wifiPairingRequiredErrorTitle,
                hasUnauthorizedUSBDevice: false,
                adbStatusText: "Running"
            ),
            "Pair phone again"
        )
    }

    @MainActor
    func testConnectionPillSurfacesMissingListenerAsActionNeededAtPlateau() {
        withoutExplicitDeviceSetupRequired {
            let record = PairedPhoneRecord(
                id: "phone-a",
                displayName: "Phone A",
                lastAddress: "192.0.2.44:5555",
                firstPaired: Date(timeIntervalSince1970: 100),
                lastConnected: Date(timeIntervalSince1970: 200)
            )
            let model = AppModel(startBackgroundServices: false, pairedPhones: [record])
            model.connectionCoordinator.automaticRetryStates[record.id] = .init(
                failureCount: 4,
                nextRetryAt: Date().addingTimeInterval(30),
                lastFailure: .wirelessListenerMissing
            )
            model.connectionCoordinator.automaticReconnectState = .waiting(
                recordID: record.id,
                retryAt: Date().addingTimeInterval(30),
                failure: .wirelessListenerMissing
            )
            model.reportError(AppModel.wifiListenerMissingErrorTitle, "Plug in once.")

            XCTAssertEqual(model.connectionPillState, .actionNeeded)
            XCTAssertEqual(model.connectionPillText, "Plug in once")
        }
    }

    func testConnectionPillTextKeepsActionNeededCopySimple() {
        XCTAssertEqual(
            AppModel.connectionPillText(
                state: .actionNeeded,
                activeErrorTitle: "Local Network may be blocked",
                hasUnauthorizedUSBDevice: false,
                adbStatusText: "Running"
            ),
            "Allow Local Network"
        )
        XCTAssertEqual(
            AppModel.connectionPillText(
                state: .actionNeeded,
                activeErrorTitle: AppModel.wifiConnectionNotReadyErrorTitle,
                hasUnauthorizedUSBDevice: false,
                adbStatusText: "Running"
            ),
            "Wi-Fi not ready"
        )
        XCTAssertEqual(
            AppModel.connectionPillText(
                state: .actionNeeded,
                activeErrorTitle: "Pairing failed",
                hasUnauthorizedUSBDevice: false,
                adbStatusText: "Running"
            ),
            "Action needed"
        )
        XCTAssertEqual(
            AppModel.connectionPillText(
                state: .actionNeeded,
                activeErrorTitle: AppModel.usbPhoneNotFoundErrorTitle,
                hasUnauthorizedUSBDevice: false,
                adbStatusText: "Running"
            ),
            "Mac can't see USB"
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
            "ADB unavailable"
        )
    }

    func testSavedDeviceWithoutAnyLiveRouteShowsOffline() {
        XCTAssertEqual(
            AppModel.resolveConnectionPillState(
                hasError: false,
                needsUserAction: false,
                isOnline: false,
                hasLivePhone: false,
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

    func testDiscoveredWiFiRoutePersistsToSelectedUSBPairedRecord() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "RFCT10ZLTAJ",
            usbSerial: "RFCT10ZLTAJ",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let selected = MirrorDevice(
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
        let discovered = DiscoveredPhone(
            id: "adb-wifi-random-service",
            address: "192.168.68.57:5555",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )

        XCTAssertEqual(
            AppModel.recordForDiscoveredWiFiRoute(
                records: [record],
                selectedDevice: selected,
                phone: discovered,
                deviceName: "SM S906B"
            ),
            record
        )
    }

    func testDiscoveredWiFiRouteDoesNotMergeGenericNameWithoutSelectedRecord() {
        let record = PairedPhoneRecord(
            id: "adb-RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "RFCT10ZLTAJ",
            usbSerial: "RFCT10ZLTAJ",
            firstPaired: Date(timeIntervalSince1970: 100),
            lastConnected: Date(timeIntervalSince1970: 200)
        )
        let discovered = DiscoveredPhone(
            id: "adb-wifi-random-service",
            address: "192.168.68.57:5555",
            kind: .connectable,
            lastSeen: Date(timeIntervalSince1970: 300)
        )

        XCTAssertNil(
            AppModel.recordForDiscoveredWiFiRoute(
                records: [record],
                selectedDevice: .demo,
                phone: discovered,
                deviceName: "Android device"
            )
        )
    }

    func testDiscoveredWiFiConnectPersistsWiFiAddressForNextLaunch() throws {
        let source = try SourceTestSupport.appModelImplementation()
        let start = try XCTUnwrap(source.range(of: "func connectAndMirror(phone: DiscoveredPhone)"))
        let end = try XCTUnwrap(source.range(of: "func connectAndMirror(record:", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("recordForDiscoveredWiFiRoute("))
        XCTAssertTrue(body.contains("usbSerial: matchingRecord?.resolvedUSBSerial"))
        XCTAssertTrue(body.contains("wifiAddress: mirrorAddress"))
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

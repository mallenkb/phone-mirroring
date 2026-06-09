import XCTest
@testable import AndroidMirrorMac

final class MirrorReconnectBackoffTests: XCTestCase {
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

    func testConnectionDeviceLabelKeepsSpecificModelName() {
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

    func testConnectionDeviceLabelUsesWirelessHostWhenNameIsGeneric() {
        XCTAssertEqual(
            AppModel.connectionDeviceLabel(
                name: "Android device",
                id: "adb-RFCT10ZLTAJ",
                serial: "192.168.68.50:5555",
                network: "Wireless debugging"
            ),
            "Wi-Fi 192.168.68.50"
        )
    }

    func testConnectionDeviceLabelUsesUSBSerialWhenNameIsGeneric() {
        XCTAssertEqual(
            AppModel.connectionDeviceLabel(
                name: "Android device",
                id: "RFCT10ZLTAJ",
                serial: "RFCT10ZLTAJ",
                network: "USB debugging"
            ),
            "USB RFCT10ZLTAJ"
        )
    }

    // MARK: - Unified auto-connecting indicator

    func testSavedPhonePresentShowsConnecting() {
        // A remembered phone has appeared (USB or wireless) but isn't online yet:
        // the indicator must read "Connecting", never "Offline".
        XCTAssertTrue(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: false,
                isMirroring: false,
                hasLivePresentTarget: true
            )
        )
    }

    func testNoLiveTargetDoesNotShowConnecting() {
        XCTAssertFalse(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: false,
                isMirroring: false,
                hasLivePresentTarget: false
            )
        )
    }

    func testOnlineDeviceIsNotAutoConnecting() {
        XCTAssertFalse(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: true,
                isMirroring: false,
                hasLivePresentTarget: true
            )
        )
    }

    func testMirroringIsNotAutoConnecting() {
        XCTAssertFalse(
            AppModel.shouldShowAutoConnecting(
                hasSavedDevice: true,
                isOnline: false,
                isMirroring: true,
                hasLivePresentTarget: true
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
                hasLivePresentTarget: true
            )
        )
    }

    func testLaunchReconnectWindowMatchesThreeToFiveSecondTarget() {
        XCTAssertGreaterThanOrEqual(AppModel.launchReconnectWindow, 3)
        XCTAssertLessThanOrEqual(AppModel.launchReconnectWindow, 5)
    }
}

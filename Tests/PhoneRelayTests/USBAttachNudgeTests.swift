import XCTest
@testable import PhoneRelay

/// The kernel USB-attach event wakes the device watcher immediately; these
/// pin the debounce so one physical plug-in (which enumerates several USB
/// interfaces in a burst) triggers exactly one early scan.
final class USBAttachNudgeTests: XCTestCase {
    func testFirstAttachAlwaysNudges() {
        XCTAssertTrue(AppModel.shouldNudgeForUSBAttach(lastNudgeAt: nil))
    }

    func testBurstWithinDebounceWindowNudgesOnce() {
        let t0 = Date()
        XCTAssertFalse(
            AppModel.shouldNudgeForUSBAttach(
                lastNudgeAt: t0,
                now: t0.addingTimeInterval(AppModel.usbAttachNudgeDebounce - 0.2)
            )
        )
    }

    func testReplugAfterDebounceWindowNudgesAgain() {
        let t0 = Date()
        XCTAssertTrue(
            AppModel.shouldNudgeForUSBAttach(
                lastNudgeAt: t0,
                now: t0.addingTimeInterval(AppModel.usbAttachNudgeDebounce + 0.2)
            )
        )
    }

    // MARK: - Cable-arrival Wi-Fi arming

    /// A newly-seen cable arms `tcpip 5555` once, on the plug-in edge — so the
    /// watcher's steady-state polling costs nothing while the cable stays in.
    func testArmsOnNewSerialOnly() {
        XCTAssertTrue(
            AppModel.shouldArmWirelessForUSBSerial(
                "USB-1",
                seenSerials: [],
                lastAttemptAt: nil
            )
        )
        XCTAssertFalse(
            AppModel.shouldArmWirelessForUSBSerial(
                "USB-1",
                seenSerials: ["USB-1"],
                lastAttemptAt: nil
            )
        )
    }

    /// `adb tcpip` restarts adbd, so the serial drops and returns — another
    /// plug-in edge. The per-serial interval is what stops that from looping.
    func testDoesNotRearmWithinRetryInterval() {
        let t0 = Date()
        XCTAssertFalse(
            AppModel.shouldArmWirelessForUSBSerial(
                "USB-1",
                seenSerials: [],
                lastAttemptAt: t0,
                now: t0.addingTimeInterval(AppModel.wirelessArmRetryInterval - 1)
            )
        )
        XCTAssertTrue(
            AppModel.shouldArmWirelessForUSBSerial(
                "USB-1",
                seenSerials: [],
                lastAttemptAt: t0,
                now: t0.addingTimeInterval(AppModel.wirelessArmRetryInterval + 1)
            )
        )
    }

    // MARK: - Anti-ping-pong pin vs a failing route

    /// The pin protects a healthy pursued Wi-Fi route from USB presence.
    @MainActor
    func testPinSuppressesUSBWhileHealthyWiFiRouteIsPursued() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.wirelessPinnedUSBSerials = ["RFCT10ZLTAJ"]
        model.isAwaitingReconnect = true

        XCTAssertTrue(model.isUSBSuppressedByWirelessPin("RFCT10ZLTAJ"))
    }

    /// Once the pursued route is provably failing, the pin must yield: the
    /// cable is the only procedure that can restore a dead `:5555` listener,
    /// and the old unconditional suppression starved it for the whole session.
    @MainActor
    func testPinYieldsToUSBWhenRouteIsFailing() {
        let record = PairedPhoneRecord(
            id: "RFCT10ZLTAJ",
            displayName: "SM S906B",
            lastAddress: "192.168.68.57:5555",
            usbSerial: "RFCT10ZLTAJ",
            firstPaired: Date(),
            lastConnected: Date()
        )
        let model = AppModel(startBackgroundServices: false, pairedPhones: [record])
        model.wirelessPinnedUSBSerials = ["RFCT10ZLTAJ"]
        model.connectionCoordinator.automaticRetryStates["RFCT10ZLTAJ"] =
            ConnectionCoordinator.AutomaticRetryState(failureCount: 2)

        XCTAssertFalse(model.isUSBSuppressedByWirelessPin("RFCT10ZLTAJ"))

        // The listener-missing verdict counts as failing too.
        model.connectionCoordinator.automaticRetryStates.removeAll()
        model.connectionCoordinator.wirelessListenerMissingRecordIDs.insert("RFCT10ZLTAJ")
        XCTAssertFalse(model.isUSBSuppressedByWirelessPin("RFCT10ZLTAJ"))
    }
}

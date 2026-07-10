import XCTest
@testable import PhoneRelay

final class AndroidDeviceLockStateTests: XCTestCase {
    func testParsesSamsungLockedStateWithoutConfusingNearbyFields() {
        let output = """
        mKeyguardOccluded=false
        KeyguardServiceDelegate
          showing=true
          showingAndNotOccluded=true
          interactiveState=INTERACTIVE_STATE_SLEEP
          KeyguardStateMonitor
            mIsShowing=true
        """

        XCTAssertEqual(AndroidDeviceLockStateProbe.parse(output), .locked)
    }

    func testParsesSamsungUnlockedState() {
        let output = """
        mKeyguardOccluded=false
        KeyguardServiceDelegate
          showing=false
          showingAndNotOccluded=true
          interactiveState=INTERACTIVE_STATE_AWAKE
          KeyguardStateMonitor
            mIsShowing=false
        """

        XCTAssertEqual(AndroidDeviceLockStateProbe.parse(output), .unlocked)
    }

    func testUnknownOutputDoesNotPretendDeviceIsUnlocked() {
        XCTAssertEqual(AndroidDeviceLockStateProbe.parse("error: device offline"), .unknown)
    }

    func testProbeUsesSameSerialSelectorForUSBAndWirelessTransports() {
        XCTAssertEqual(
            AndroidDeviceLockStateProbe.adbArguments(serial: "RFCT10ZLTAJ"),
            ["-s", "RFCT10ZLTAJ", "shell", "dumpsys", "window", "policy"]
        )
        XCTAssertEqual(
            AndroidDeviceLockStateProbe.adbArguments(serial: "192.168.1.25:5555"),
            ["-s", "192.168.1.25:5555", "shell", "dumpsys", "window", "policy"]
        )
    }

    @MainActor
    func testLockedOverlayUsesActionableAutomaticRecoveryCopy() {
        let renderView = MirrorRenderView(frame: NSRect(x: 0, y: 0, width: 390, height: 850))

        renderView.setDeviceLocked(true)
        XCTAssertTrue(renderView.isShowingDeviceLocked)
        XCTAssertEqual(MirrorLockedView.titleText, "Android is locked")
        XCTAssertEqual(MirrorLockedView.messageText, "Unlock your phone to continue mirroring.")
        XCTAssertEqual(MirrorLockedView.resumeText, "Mirroring will resume automatically.")

        renderView.setDeviceLocked(false)
        XCTAssertFalse(renderView.isShowingDeviceLocked)
    }
}

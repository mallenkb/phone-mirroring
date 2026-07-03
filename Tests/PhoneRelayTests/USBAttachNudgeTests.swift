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
}

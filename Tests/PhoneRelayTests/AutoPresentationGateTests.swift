import XCTest
@testable import PhoneRelay

/// Auto-reconnect must never paint windows over another app while Phone
/// Relay has no user-visible presence ("the app isn't even open but windows
/// pop over my browser"). Manual actions and an already-visible app are
/// unaffected.
final class AutoPresentationGateTests: XCTestCase {
    func testInvisibleBackgroundAppMayNotAutoPresent() {
        XCTAssertFalse(AppModel.mayAutoPresentWindows(
            appIsActive: false, hasVisiblePrimaryWindow: false
        ))
    }

    func testActiveAppMayAutoPresent() {
        XCTAssertTrue(AppModel.mayAutoPresentWindows(
            appIsActive: true, hasVisiblePrimaryWindow: false
        ))
    }

    func testVisibleWindowMayAutoPresentEvenWhileInactive() {
        // Mirror floating over the desktop while the user works elsewhere:
        // reconnects may keep using the screen they already occupy.
        XCTAssertTrue(AppModel.mayAutoPresentWindows(
            appIsActive: false, hasVisiblePrimaryWindow: true
        ))
    }
}

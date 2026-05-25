import XCTest
@testable import AndroidMirrorMac

final class MirrorWindowChromeTests: XCTestCase {
    func testChromeArgumentsUseDefaultScrcpyWindowChrome() {
        XCTAssertFalse(
            ScrcpyController.chromeArguments.contains("--window-borderless"),
            "The mirror should keep scrcpy's native macOS titlebar by default."
        )
    }

    func testExpandedFramePreservesAspectRatioAndLeavesRoomForTopBar() {
        let current = CGRect(x: 320, y: 160, width: 520, height: 1040)
        let visibleFrame = NSRect(x: 0, y: 40, width: 1440, height: 860)

        let expanded = MirrorWindowChromeLayout.expandedScrcpyFrame(
            from: current,
            inVisibleFrame: visibleFrame,
            screenHeight: 900,
            chromeHeight: 42,
            padding: 12
        )

        XCTAssertEqual(expanded.width / expanded.height, current.width / current.height, accuracy: 0.001)
        XCTAssertLessThanOrEqual(expanded.width, visibleFrame.width - 24)
        XCTAssertLessThanOrEqual(expanded.height, visibleFrame.height - 42 - 24)

        let expandedBottomInNS = 900 - expanded.maxY
        let expandedTopInNS = 900 - expanded.minY
        XCTAssertGreaterThanOrEqual(expandedBottomInNS, visibleFrame.minY + 12)
        XCTAssertLessThanOrEqual(expandedTopInNS + 42, visibleFrame.maxY - 12)
    }

    func testExpandedFrameCanUseFullVisibleHeightWithoutCustomTopBar() {
        let current = CGRect(x: 320, y: 160, width: 520, height: 1040)
        let visibleFrame = NSRect(x: 0, y: 40, width: 1440, height: 860)

        let expanded = MirrorWindowChromeLayout.expandedScrcpyFrame(
            from: current,
            inVisibleFrame: visibleFrame,
            screenHeight: 900,
            chromeHeight: 0,
            padding: 12
        )

        XCTAssertEqual(expanded.width / expanded.height, current.width / current.height, accuracy: 0.001)
        XCTAssertLessThanOrEqual(expanded.width, visibleFrame.width - 24)
        XCTAssertLessThanOrEqual(expanded.height, visibleFrame.height - 24)
    }

    func testHoverChromeFrameSitsImmediatelyAboveMirrorFrame() {
        let current = CGRect(x: 120, y: 80, width: 520, height: 1040)
        let frame = MirrorWindowChromeLayout.hoverChromeFrame(
            forScrcpyBounds: current,
            screenHeight: 1200,
            height: 50
        )

        XCTAssertEqual(frame.minX, current.minX)
        XCTAssertEqual(frame.width, current.width)
        XCTAssertEqual(frame.minY, 1120)
        XCTAssertEqual(frame.height, 50)
    }
}

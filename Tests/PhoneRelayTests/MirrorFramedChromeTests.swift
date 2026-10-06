import AppKit
import XCTest
@testable import PhoneRelay

final class MirrorFramedChromeTests: XCTestCase {
    func testChromeStyleDefaultsToFloatingAndParsesStoredValue() {
        XCTAssertEqual(AppModel.defaultMirrorChromeStyle(storedValue: nil), .floating)
        XCTAssertEqual(AppModel.defaultMirrorChromeStyle(storedValue: "bogus"), .floating)
        XCTAssertEqual(AppModel.defaultMirrorChromeStyle(storedValue: "framed"), .framed)
    }

    func testFramedWindowWrapsPhoneWithHeaderAndRim() {
        let phone = NSRect(x: 100, y: 200, width: 300, height: 650)
        let frame = MirrorFramedChromeView.windowFrame(around: phone)
        let rim = MirrorFramedChromeView.rimWidth
        let header = MirrorFramedChromeView.headerHeight

        XCTAssertEqual(frame.minX, phone.minX - rim)
        XCTAssertEqual(frame.maxX, phone.maxX + rim)
        XCTAssertEqual(frame.minY, phone.minY - rim)
        XCTAssertEqual(frame.maxY, phone.maxY + header)
    }

    func testFramedRevealZoneIsOnlyTheStripAbovePhone() {
        let phone = NSRect(x: 100, y: 200, width: 300, height: 650)
        let zone = MirrorFramedChromeView.revealZone(above: phone)

        XCTAssertTrue(zone.contains(NSPoint(x: phone.midX, y: phone.maxY + 10)))
        XCTAssertFalse(zone.contains(NSPoint(x: phone.midX, y: phone.maxY - 10)), "status bar must not reveal")
        XCTAssertFalse(zone.contains(NSPoint(x: phone.midX, y: phone.midY)))
        XCTAssertFalse(zone.contains(NSPoint(x: phone.midX, y: phone.maxY + MirrorFramedChromeView.headerHeight + 1)))
    }

    @MainActor
    func testFramedChromeBarDropsCapsuleAndTitle() {
        let bar = MirrorChromeBar()
        bar.isFramedStyle = true
        bar.setControlsVisible(true)
        bar.setBarBackgroundVisible(true, animated: false)

        XCTAssertEqual(bar.backgroundOpacityForTesting, 0)
        XCTAssertTrue(bar.isTitleHiddenForTesting)

        bar.isFramedStyle = false
        XCTAssertEqual(bar.backgroundOpacityForTesting, 1)
        XCTAssertFalse(bar.isTitleHiddenForTesting)
    }

    @MainActor
    func testLastHeaderButtonHoverFollowsFrameTopCorner() throws {
        let bar = MirrorChromeBar()
        bar.setControlsVisible(true)
        bar.setTrailingActionsMode(.full)
        XCTAssertNil(bar.rightmostTopTrailingHoverRadiusForTesting, "floating keeps its capsule rule")

        bar.isFramedStyle = true
        bar.framedTopCornerRadius = 28.8
        // 6pt gap on every side: 4pt padding + 2pt rim to the right, and the
        // highlight trimmed to 26pt tall in the 38pt header.
        XCTAssertEqual(try XCTUnwrap(bar.rightmostTopTrailingHoverRadiusForTesting), 22.8, accuracy: 0.001)
        let hover = try XCTUnwrap(bar.rightmostHoverFrameForTesting)
        XCTAssertEqual(hover.height, MirrorChromeOutlineButton.touchHeight - 4, accuracy: 0.001)

        bar.framedTopCornerRadius = 36
        XCTAssertEqual(try XCTUnwrap(bar.rightmostTopTrailingHoverRadiusForTesting), 30, accuracy: 0.001)

        bar.framedTopCornerRadius = 4
        XCTAssertEqual(
            try XCTUnwrap(bar.rightmostTopTrailingHoverRadiusForTesting),
            MirrorChromeOutlineButton.defaultHoverCornerRadius
        )
    }

    @MainActor
    func testFramedMirrorToolbarSitsBelowPhoneAndExpandsOnReveal() throws {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.mirrorChromeStyle = .framed
        defer { model.mirrorChromeStyle = .floating }
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(controller.toolbarWindowForTesting as? MirrorToolbarWindow)
        let framed = try XCTUnwrap(toolbar.contentView as? MirrorFramedChromeView)

        XCTAssertTrue(toolbar.orderedBelowWindow === window)
        XCTAssertFalse(toolbar.hasShadow)
        let phoneHadShadow = window.hasShadow
        XCTAssertFalse(framed.isExpandedForTesting)

        controller.show()
        try XCTSkipUnless(window.isVisible, "Requires an active window-server session.")
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        controller.simulateRevealZoneHover(true)
        XCTAssertTrue(framed.isExpandedForTesting)
        XCTAssertFalse(controller.toolbarIgnoresMouseEventsForTesting)
        XCTAssertEqual(toolbar.frame, MirrorFramedChromeView.windowFrame(around: window.frame))
        XCTAssertEqual(window.hasShadow, phoneHadShadow, "hovering must not change the phone's shadow")

        // Hovering the phone itself must not keep or bring the header back.
        controller.simulateRevealZoneMouseMoveForTesting(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(controller.isChromeVisibleForTesting)
        XCTAssertFalse(framed.isExpandedForTesting)
        XCTAssertTrue(controller.toolbarIgnoresMouseEventsForTesting)
    }

    @MainActor
    func testLeavingFullscreenRestoresShellCornerRadius() {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 738, height: 1600)
        let windowedRadius = controller.shellCornerRadiusForTesting
        XCTAssertGreaterThan(windowedRadius, 0)

        controller.setFullscreenChromeSuppressedForTesting(true)
        XCTAssertEqual(controller.shellCornerRadiusForTesting, 0)

        // Size limits are restored before the radius is derived from them.
        controller.setFullscreenChromeSuppressedForTesting(false)
        XCTAssertEqual(controller.shellCornerRadiusForTesting, windowedRadius, accuracy: 0.01)
    }

    @MainActor
    func testSwitchingStyleRebuildsToolbarAroundSameBar() throws {
        let model = AppModel(startBackgroundServices: false, pairedPhones: [])
        model.mirrorChromeStyle = .floating
        defer { model.mirrorChromeStyle = .floating }
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        XCTAssertTrue(controller.toolbarWindowForTesting?.contentView === controller.chromeBarForTesting)

        model.mirrorChromeStyle = .framed
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let framed = try XCTUnwrap(controller.toolbarWindowForTesting?.contentView as? MirrorFramedChromeView)
        XCTAssertTrue(framed.chromeBar === controller.chromeBarForTesting)

        model.mirrorChromeStyle = .floating
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(controller.toolbarWindowForTesting?.contentView === controller.chromeBarForTesting)
    }
}

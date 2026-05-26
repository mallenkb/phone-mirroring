import XCTest
@testable import AndroidMirrorMac

final class MirrorWindowChromeTests: XCTestCase {
    @MainActor
    func testChromeViewsDoNotMoveWindow() {
        let model = AppModel()
        let renderView = MirrorRenderView()
        XCTAssertFalse(
            RootWindowView(model: model, renderView: renderView, frame: NSRect(x: 0, y: 0, width: 390, height: 850))
                .mouseDownCanMoveWindow
        )
        XCTAssertFalse(PhoneMirrorContainerView().mouseDownCanMoveWindow)
        XCTAssertFalse(OuterFrameView(model: model, mirroredPhoneView: MirrorRenderView()).mouseDownCanMoveWindow)
        XCTAssertFalse(ToolbarChromeView(model: model).mouseDownCanMoveWindow)
        XCTAssertFalse(ChromeDragView().mouseDownCanMoveWindow)
        XCTAssertFalse(MirrorRenderView().mouseDownCanMoveWindow)
        XCTAssertFalse(MirrorWindowDragArea().mouseDownCanMoveWindow)
    }

    @MainActor
    func testMirrorWindowHasNoNativeTitlebarDragBand() throws {
        let controller = WindowController(model: AppModel())
        let window = try XCTUnwrap(controller.window)

        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertFalse(window.styleMask.contains(NSWindow.StyleMask.fullSizeContentView))
        XCTAssertFalse(window.isMovableByWindowBackground)
    }

    func testMirrorRenderViewFitsPortraitStreamInsideWideBounds() {
        let rect = MirrorRenderView.fittedVideoRect(
            for: CGSize(width: 1080, height: 2400),
            in: CGRect(x: 0, y: 0, width: 600, height: 800)
        )

        XCTAssertEqual(rect.height, 800)
        XCTAssertEqual(rect.width, 360)
        XCTAssertEqual(rect.minX, 120)
        XCTAssertEqual(rect.minY, 0)
    }

    func testMirrorRenderViewFitsPortraitStreamInsideShortBounds() {
        let rect = MirrorRenderView.fittedVideoRect(
            for: CGSize(width: 1080, height: 2400),
            in: CGRect(x: 0, y: 0, width: 360, height: 500)
        )

        XCTAssertEqual(rect.width, 225)
        XCTAssertEqual(rect.height, 500)
        XCTAssertEqual(rect.minX, 67.5)
        XCTAssertEqual(rect.minY, 0)
    }

    @MainActor
    func testNativeMirrorWindowDoesNotExposeEdgeResizeHandles() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)

        XCTAssertFalse(window.styleMask.contains(.resizable))
    }

    @MainActor
    func testBlankNativeMirrorUsesDefaultPhoneAspectBeforeStreamHeader() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let defaultAspect = CGFloat(1080) / CGFloat(2340)

        let initialRatio = window.contentAspectRatio.width / window.contentAspectRatio.height
        let constrained = controller.windowWillResize(
            window,
            to: NSSize(width: 657, height: 900)
        )

        XCTAssertEqual(initialRatio, defaultAspect, accuracy: 0.001)
        XCTAssertEqual(constrained.width, 657)
        XCTAssertEqual(
            constrained.height,
            657 / defaultAspect,
            accuracy: 0.001
        )
    }

    @MainActor
    func testNativeMirrorResizePreservesStreamAspectToAvoidTopBottomBands() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)

        let constrained = controller.windowWillResize(
            window,
            to: NSSize(width: 657, height: 1446)
        )
        let fitted = MirrorRenderView.fittedVideoRect(
            for: CGSize(width: 1080, height: 2340),
            in: CGRect(
                x: 0,
                y: 0,
                width: constrained.width,
                height: constrained.height
            )
        )

        XCTAssertEqual(constrained.width, 657)
        XCTAssertEqual(
            constrained.height,
            1423.5,
            accuracy: 0.001
        )
        XCTAssertEqual(fitted.minY, 0, accuracy: 0.001)
        XCTAssertEqual(
            fitted.height,
            constrained.height,
            accuracy: 0.001
        )
    }

    @MainActor
    func testNativeMirrorWindowHardCapsAtScreenHeightPercentages() {
        let limits = MirrorContentWindowController.sizeLimits(
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 1000),
            aspect: 1080.0 / 2340.0,
            chromeHeight: 0
        )

        XCTAssertEqual(limits.min.height, 450, accuracy: 0.001)
        XCTAssertEqual(limits.max.height, 900, accuracy: 0.001)
        XCTAssertEqual(limits.min.width, 450 * (1080.0 / 2340.0), accuracy: 0.001)
        XCTAssertEqual(limits.max.width, 900 * (1080.0 / 2340.0), accuracy: 0.001)
    }

    @MainActor
    func testNativeMirrorResizeImmediatelyUpdatesVideoLayerFrame() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)

        window.setFrame(
            NSRect(
                x: 0,
                y: 0,
                width: 657,
                height: 1423.5
            ),
            display: true
        )
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        XCTAssertEqual(controller.renderView.sampleBufferDisplayLayer.frame.width, 657, accuracy: 0.001)
        XCTAssertEqual(controller.renderView.sampleBufferDisplayLayer.frame.height, 1423.5, accuracy: 0.001)
    }

    @MainActor
    func testVisibleChromeRenderInsetMatchesReservedChromeHeight() {
        XCTAssertEqual(
            MirrorContentWindowController.visibleChromeRenderTopInset,
            MirrorContentWindowController.chromeHeight
        )
    }

    @MainActor
    func testCenteredScaleKeepsWindowAnchorAtCenter() {
        let original = NSRect(x: 100, y: 200, width: 400, height: 900)
        let scaled = MirrorContentWindowController.scaledFrame(
            from: original,
            scale: 1.10,
            aspect: 400.0 / 900.0,
            chromeHeight: 0,
            minHeight: 300,
            maxHeight: 1200
        )

        XCTAssertEqual(scaled.midX, original.midX, accuracy: 0.001)
        XCTAssertEqual(scaled.midY, original.midY, accuracy: 0.001)
        XCTAssertEqual(scaled.width, 440, accuracy: 0.001)
        XCTAssertEqual(scaled.height, 990, accuracy: 0.001)
    }

    @MainActor
    func testCenteredScaleClampsToMinimumAndMaximumHeight() {
        let original = NSRect(x: 100, y: 200, width: 400, height: 900)

        let minimum = MirrorContentWindowController.scaledFrame(
            from: original,
            scale: 0.10,
            aspect: 400.0 / 900.0,
            chromeHeight: 0,
            minHeight: 300,
            maxHeight: 1200
        )
        let maximum = MirrorContentWindowController.scaledFrame(
            from: original,
            scale: 9.0,
            aspect: 400.0 / 900.0,
            chromeHeight: 0,
            minHeight: 300,
            maxHeight: 1200
        )

        XCTAssertEqual(minimum.width, 300 * (400.0 / 900.0), accuracy: 0.001)
        XCTAssertEqual(minimum.height, 300, accuracy: 0.001)
        XCTAssertEqual(minimum.midX, original.midX, accuracy: 0.001)
        XCTAssertEqual(minimum.midY, original.midY, accuracy: 0.001)
        XCTAssertEqual(maximum.width, 1200 * (400.0 / 900.0), accuracy: 0.001)
        XCTAssertEqual(maximum.height, 1200, accuracy: 0.001)
        XCTAssertEqual(maximum.midX, original.midX, accuracy: 0.001)
        XCTAssertEqual(maximum.midY, original.midY, accuracy: 0.001)
    }

    @MainActor
    func testChromeRevealDoesNotChangeMirrorWindowAspectContract() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        rootView.layoutSubtreeIfNeeded()

        let initialRatio = window.contentAspectRatio.width / window.contentAspectRatio.height
        let initialRenderFrame = controller.renderView.frame
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: window.frame.width / 2, y: window.frame.height - 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseMoved(with: event)
        rootView.layoutSubtreeIfNeeded()

        let revealedRatio = window.contentAspectRatio.width / window.contentAspectRatio.height
        XCTAssertEqual(revealedRatio, initialRatio, accuracy: 0.001)
        XCTAssertEqual(controller.renderView.frame.origin.x, initialRenderFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(controller.renderView.frame.origin.y, initialRenderFrame.origin.y, accuracy: 0.001)
        XCTAssertEqual(controller.renderView.frame.width, initialRenderFrame.width, accuracy: 0.001)
        XCTAssertEqual(controller.renderView.frame.height, initialRenderFrame.height, accuracy: 0.001)
    }

    @MainActor
    func testHiddenChromeDoesNotRevealFromBroadTopContentArea() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let chromeView = try XCTUnwrap(rootView.subviews.first { $0 !== controller.renderView })

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: window.frame.width / 2, y: window.frame.height - 40),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseMoved(with: event)

        XCTAssertTrue(chromeView.isHidden)
    }

    @MainActor
    func testHiddenChromeDoesNotRevealFromAnyMirrorContentPoint() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let chromeView = try XCTUnwrap(rootView.subviews.first { $0 !== controller.renderView })
        rootView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: controller.renderView.frame.midX,
                y: controller.renderView.frame.maxY - 2
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseMoved(with: event)

        XCTAssertTrue(chromeView.isHidden)
    }

    @MainActor
    func testHiddenChromeDoesNotRevealAtMirrorContentBoundary() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let chromeView = try XCTUnwrap(rootView.subviews.first { $0 !== controller.renderView })
        rootView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: controller.renderView.frame.midX,
                y: controller.renderView.frame.maxY
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseMoved(with: event)

        XCTAssertTrue(chromeView.isHidden)
    }

    @MainActor
    func testHiddenChromeRevealsFromToolbarBandAboveMirrorContent() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let chromeView = try XCTUnwrap(window.contentView?.subviews.first { $0 !== controller.renderView })
        let point = NSPoint(
            x: window.frame.midX,
            y: window.frame.maxY + MirrorContentWindowController.chromeHeight / 2
        )

        controller.updateHoverActivationForTesting(at: point)

        XCTAssertFalse(chromeView.isHidden)
    }

    @MainActor
    func testVisibleChromeStaysStableWhenPointerIsInToolbarBand() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let chromeView = try XCTUnwrap(rootView.subviews.first { $0 !== controller.renderView })
        let revealPoint = NSPoint(
            x: window.frame.midX,
            y: window.frame.maxY + MirrorContentWindowController.chromeHeight / 2
        )

        controller.updateHoverActivationForTesting(at: revealPoint)
        rootView.layoutSubtreeIfNeeded()
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: window.frame.width / 2, y: window.frame.height - 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseMoved(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))

        XCTAssertFalse(chromeView.isHidden)
    }

    @MainActor
    func testMirrorContentKeepsOldRoundedPhoneShapeInsideChromeShell() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)

        XCTAssertEqual(controller.renderView.cornerRadius, MirrorContentWindowController.cornerRadius)
        XCTAssertTrue(controller.renderView.sampleBufferDisplayLayer.masksToBounds)
    }

    @MainActor
    func testMirrorRenderViewReportsMouseMovementForChromeHoverTracking() throws {
        let renderView = MirrorRenderView(frame: NSRect(x: 0, y: 0, width: 390, height: 850))
        var reportedEvent: NSEvent?
        renderView.onMouseMoved = { event in
            reportedEvent = event
        }

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 120, y: 300),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        renderView.mouseMoved(with: event)

        XCTAssertIdentical(reportedEvent, event)
    }

    func testChromeArgumentsMakeScrcpyContentNonDraggable() {
        XCTAssertTrue(
            ScrcpyController.chromeArguments.contains("--window-borderless"),
            "The phone pixels should not include scrcpy's native draggable titlebar region."
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

    func testOuterFrameWrapsScrcpyWithoutCoveringPhoneContentOrigin() {
        let current = CGRect(x: 120, y: 80, width: 520, height: 1040)
        let frame = MirrorWindowChromeLayout.overlayFrame(
            forScrcpyBounds: current,
            screenHeight: 1200,
            titleHeight: 44,
            sideInset: 8,
            bottomInset: 8
        )

        XCTAssertEqual(frame.minX, 112)
        XCTAssertEqual(frame.width, 536)
        XCTAssertEqual(frame.minY, 72)
        XCTAssertEqual(frame.height, 1092)
        XCTAssertEqual(frame.minY + 8, 80)
        XCTAssertEqual(frame.maxY - 44, 1120)
    }

    @MainActor
    func testHoverChromeRequiresRoomAboveMirrorFrame() {
        let current = CGRect(x: 24, y: 0, width: 520, height: 1040)
        let screenHeight: CGFloat = 1040
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 1040)
        let frame = MirrorWindowChromeLayout.hoverChromeFrame(
            forScrcpyBounds: current,
            screenHeight: screenHeight,
            height: MirrorFrameWindowController.chromeHeight
        )

        XCTAssertGreaterThan(
            frame.maxY,
            visibleFrame.maxY,
            "When there is no room above the mirror, the hover toolbar should stay hidden instead of overlapping phone pixels."
        )
    }

    func testConstrainedDragFrameKeepsRoomForHoverChrome() {
        let proposed = CGRect(x: 120, y: 0, width: 520, height: 760)
        let visibleFrame = NSRect(x: 0, y: 40, width: 1440, height: 860)
        let screenHeight: CGFloat = 900

        let constrained = MirrorWindowChromeLayout.scrcpyFrameKeepingHoverChromeVisible(
            proposed,
            inVisibleFrame: visibleFrame,
            screenHeight: screenHeight,
            chromeHeight: 44
        )
        let hoverFrame = MirrorWindowChromeLayout.hoverChromeFrame(
            forScrcpyBounds: constrained,
            screenHeight: screenHeight,
            height: 44
        )

        XCTAssertLessThanOrEqual(hoverFrame.maxY, visibleFrame.maxY)
        XCTAssertEqual(constrained.minY, 44)
    }

    func testConstrainedDragFrameDoesNotMoveFrameWhenChromeFits() {
        let proposed = CGRect(x: 120, y: 120, width: 520, height: 700)
        let visibleFrame = NSRect(x: 0, y: 40, width: 1440, height: 860)

        let constrained = MirrorWindowChromeLayout.scrcpyFrameKeepingHoverChromeVisible(
            proposed,
            inVisibleFrame: visibleFrame,
            screenHeight: 900,
            chromeHeight: 44
        )

        XCTAssertEqual(constrained, proposed)
    }

    func testConstrainedDragFramePrioritizesToolbarWhenMirrorIsTooTall() {
        let proposed = CGRect(x: 120, y: 0, width: 520, height: 1040)
        let visibleFrame = NSRect(x: 0, y: 40, width: 1440, height: 860)
        let screenHeight: CGFloat = 900

        let constrained = MirrorWindowChromeLayout.scrcpyFrameKeepingHoverChromeVisible(
            proposed,
            inVisibleFrame: visibleFrame,
            screenHeight: screenHeight,
            chromeHeight: 44
        )
        let hoverFrame = MirrorWindowChromeLayout.hoverChromeFrame(
            forScrcpyBounds: constrained,
            screenHeight: screenHeight,
            height: 44
        )

        XCTAssertLessThanOrEqual(hoverFrame.maxY, visibleFrame.maxY)
    }
}

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
        XCTAssertFalse(ToolbarChromeView(frame: .zero).mouseDownCanMoveWindow)
        XCTAssertFalse(ChromeDragView().mouseDownCanMoveWindow)
        XCTAssertFalse(MirrorRenderView().mouseDownCanMoveWindow)
        XCTAssertFalse(MirrorWindowDragArea().mouseDownCanMoveWindow)
    }

    @MainActor
    func testMirrorWindowUsesNativeTrafficLights() throws {
        let controller = WindowController(model: AppModel())
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertFalse(window.isMovableByWindowBackground)

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let minimize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        XCTAssertFalse(close.isHidden)
        XCTAssertFalse(minimize.isHidden)
        XCTAssertFalse(zoom.isHidden)
    }

    @MainActor
    func testNativeMirrorBorderlessWindowCanReceiveKeyboardFocus() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.canBecomeMain)
        XCTAssertTrue(controller.renderView.acceptsFirstResponder)
    }

    func testScrcpyTextMessageEncodesUtf8Payload() {
        let message = ScrcpyControlChannel.textMessage(for: "Hi")

        XCTAssertEqual(Array(message), [1, 0, 0, 0, 2, 72, 105])
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
    func testMirrorRenderLayerUsesCenteredAspectGravityForLiveFrames() {
        let renderView = MirrorRenderView()

        XCTAssertEqual(renderView.sampleBufferDisplayLayer.videoGravity, .resizeAspect)
    }

    @MainActor
    func testMirrorRenderViewLetsCommandShortcutsReachAppMenu() throws {
        let renderView = MirrorRenderView()
        var forwardedEvents = 0
        renderView.onKeyEvent = { _ in forwardedEvents += 1 }

        let commandQ = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "q",
            charactersIgnoringModifiers: "q",
            isARepeat: false,
            keyCode: 12
        ))

        XCTAssertFalse(renderView.performKeyEquivalent(with: commandQ))
        XCTAssertEqual(forwardedEvents, 0)
    }

    func testMirrorRenderVideoLayerStaysCenteredInBounds() {
        let frame = MirrorRenderView.videoFrame(for: CGRect(x: 0, y: 0, width: 400, height: 900))

        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.width, 400)
        XCTAssertEqual(frame.height, 900)
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
    func testNativeMirrorShellReservesTopChromeBandAbovePhonePixels() {
        XCTAssertEqual(MirrorContentWindowController.screenLeftInset, 0)
        XCTAssertEqual(MirrorContentWindowController.screenRightInset, 0)
        XCTAssertEqual(
            MirrorContentWindowController.visibleChromeRenderTopInset,
            MirrorContentWindowController.chromeHeight
        )
        XCTAssertEqual(MirrorContentWindowController.screenBottomInset, 0)
    }

    @MainActor
    func testNativeMirrorShellCentersInsideVisibleFrame() {
        let frame = MirrorContentWindowController.centeredFrame(
            size: NSSize(width: 514, height: 1148),
            in: NSRect(x: 120, y: 40, width: 1440, height: 860)
        )

        XCTAssertEqual(frame.midX, 840, accuracy: 0.001)
        XCTAssertEqual(frame.midY, 470, accuracy: 0.001)
    }

    @MainActor
    func testNativeMirrorShellWrapsPhonePixelsBelowTopChromeBand() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 738, height: 1600)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView as? MirrorRootView)

        rootView.layoutSubtreeIfNeeded()

        let toolbarHeight = controller.renderTopInsetForTesting
        XCTAssertEqual(controller.renderView.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rootView.bounds.maxX - controller.renderView.frame.maxX, 0, accuracy: 0.001)
        XCTAssertEqual(controller.renderView.frame.minY, 0, accuracy: 0.001)
        XCTAssertEqual(
            rootView.bounds.maxY - controller.renderView.frame.maxY,
            toolbarHeight,
            accuracy: 0.5
        )

        XCTAssertEqual(rootView.bounds.width, controller.renderView.frame.width, accuracy: 0.001)
        XCTAssertEqual(
            rootView.bounds.height,
            controller.renderView.frame.height + toolbarHeight,
            accuracy: 0.5
        )

        let fittedVideo = MirrorRenderView.fittedVideoRect(
            for: CGSize(width: 738, height: 1600),
            in: controller.renderView.bounds
        )
        XCTAssertEqual(fittedVideo.width, controller.renderView.bounds.width, accuracy: 0.5)
        XCTAssertEqual(fittedVideo.height, controller.renderView.bounds.height, accuracy: 1)
    }

    @MainActor
    func testNativeMirrorShellSizeWrapsActualStreamWithoutFixedWidthOrHeight() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 1200)
        let streamSize = NSSize(width: 738, height: 1600)

        let shellSize = MirrorContentWindowController.wrappedShellSize(
            for: streamSize,
            visibleFrame: visibleFrame,
            screenMargin: 80
        )
        let maxShellHeight = visibleFrame.height - 80
        let maxMirrorHeight = maxShellHeight - MirrorContentWindowController.visibleChromeRenderTopInset
        let expectedMirrorWidth = maxMirrorHeight * streamSize.width / streamSize.height

        XCTAssertEqual(shellSize.width, expectedMirrorWidth, accuracy: 0.001)
        XCTAssertEqual(shellSize.height, maxShellHeight, accuracy: 0.001)
    }

    @MainActor
    func testNativeMirrorShellDoesNotUpscaleSmallStreamsToFixedMinimum() {
        let shellSize = MirrorContentWindowController.wrappedShellSize(
            for: NSSize(width: 120, height: 240),
            visibleFrame: NSRect(x: 0, y: 0, width: 1000, height: 1200),
            screenMargin: 80
        )

        XCTAssertEqual(shellSize.width, 120)
        XCTAssertEqual(
            shellSize.height,
            240 + MirrorContentWindowController.visibleChromeRenderTopInset
        )
    }

    @MainActor
    func testBlankNativeMirrorUsesDefaultPhoneAspectBeforeStreamHeader() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let defaultAspect = CGFloat(1080) / CGFloat(2340)
        let verticalShellInset = MirrorContentWindowController.visibleChromeRenderTopInset
        let horizontalShellInset: CGFloat = 0

        let initialRatio = window.contentAspectRatio.width / window.contentAspectRatio.height
        let constrained = controller.windowWillResize(
            window,
            to: NSSize(width: 657, height: 900)
        )

        XCTAssertEqual(initialRatio, window.frame.width / window.frame.height, accuracy: 0.002)
        XCTAssertEqual(constrained.width, 657)
        XCTAssertEqual(
            constrained.height,
            (657 - horizontalShellInset) / defaultAspect + verticalShellInset,
            accuracy: 0.001
        )
    }

    @MainActor
    func testBlankNativeMirrorStartsAtQuarterDefaultMirrorSize() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 390, height: 850)
        let fullDefaultSize = MirrorContentWindowController.wrappedShellSize(
            for: MirrorContentWindowController.defaultMirrorSize,
            visibleFrame: visibleFrame
        )
        let initialSize = MirrorContentWindowController.initialWrappedShellSize(
            for: MirrorContentWindowController.defaultMirrorSize,
            visibleFrame: visibleFrame
        )
        let topChromeInset = MirrorContentWindowController.visibleChromeRenderTopInset

        XCTAssertEqual(window.frame.width, initialSize.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialSize.height, accuracy: 1)
        XCTAssertEqual(initialSize.width, fullDefaultSize.width * 0.25, accuracy: 0.001)
        XCTAssertEqual(
            initialSize.height - topChromeInset,
            (fullDefaultSize.height - topChromeInset) * 0.25,
            accuracy: 0.001
        )
    }

    @MainActor
    func testNativeMirrorStreamStartsAtQuarterMaximumFittedSize() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)
        let visibleFrame = window.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 390, height: 850)
        let fullStreamSize = MirrorContentWindowController.wrappedShellSize(
            for: NSSize(width: 1080, height: 2340),
            visibleFrame: visibleFrame
        )
        let initialStreamSize = MirrorContentWindowController.initialWrappedShellSize(
            for: NSSize(width: 1080, height: 2340),
            visibleFrame: visibleFrame
        )
        let topChromeInset = MirrorContentWindowController.visibleChromeRenderTopInset

        XCTAssertGreaterThanOrEqual(window.frame.width, initialStreamSize.width)
        XCTAssertEqual(initialStreamSize.width, fullStreamSize.width * 0.25, accuracy: 0.001)
        XCTAssertEqual(
            initialStreamSize.height - topChromeInset,
            (fullStreamSize.height - topChromeInset) * 0.25,
            accuracy: 0.001
        )

        let rootView = try XCTUnwrap(window.contentView as? MirrorRootView)
        rootView.layoutSubtreeIfNeeded()
        let fittedVideo = MirrorRenderView.fittedVideoRect(
            for: CGSize(width: 1080, height: 2340),
            in: controller.renderView.bounds
        )
        XCTAssertEqual(fittedVideo.width, controller.renderView.bounds.width, accuracy: 1)
        XCTAssertEqual(fittedVideo.height, controller.renderView.bounds.height, accuracy: 1)
    }

    @MainActor
    func testNativeMirrorResizePreservesStreamAspectToAvoidTopBottomBands() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)
        let verticalShellInset = MirrorContentWindowController.visibleChromeRenderTopInset
        let horizontalShellInset: CGFloat = 0

        let constrained = controller.windowWillResize(
            window,
            to: NSSize(width: 657, height: 1446)
        )
        let fitted = MirrorRenderView.fittedVideoRect(
            for: CGSize(width: 1080, height: 2340),
            in: CGRect(
                x: 0,
                y: 0,
                width: constrained.width - horizontalShellInset,
                height: constrained.height - verticalShellInset
            )
        )

        XCTAssertEqual(constrained.width, 657)
        XCTAssertEqual(
            constrained.height,
            (657 - horizontalShellInset) / (1080.0 / 2340.0) + verticalShellInset,
            accuracy: 0.001
        )
        XCTAssertEqual(fitted.minY, 0, accuracy: 0.001)
        XCTAssertEqual(
            fitted.height,
            constrained.height - verticalShellInset,
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
        XCTAssertEqual(limits.max.height, 980, accuracy: 0.001)
        XCTAssertEqual(limits.min.width, 450 * (1080.0 / 2340.0), accuracy: 0.001)
        XCTAssertEqual(limits.max.width, 980 * (1080.0 / 2340.0), accuracy: 0.001)
    }

    @MainActor
    func testNativeMirrorWindowMaxWidthAccountsForScaledToolbarHeight() {
        let aspect = 1080.0 / 2340.0
        let limits = MirrorContentWindowController.sizeLimits(
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 1000),
            aspect: aspect,
            chromeHeight: MirrorContentWindowController.chromeHeight
        )

        XCTAssertEqual(
            limits.max.width,
            (980 - MirrorContentWindowController.maximumChromeHeight) * aspect,
            accuracy: 0.001
        )
    }

    @MainActor
    func testNativeMirrorResizeImmediatelyUpdatesVideoLayerFrame() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)
        let verticalShellInset = MirrorContentWindowController.visibleChromeRenderTopInset
        let horizontalShellInset: CGFloat = 0
        let contentWidth = CGFloat(657) - horizontalShellInset
        let contentHeight = contentWidth / (1080.0 / 2340.0)

        window.setFrame(
            NSRect(
                x: 0,
                y: 0,
                width: 657,
                height: contentHeight + verticalShellInset
            ),
            display: true
        )
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        XCTAssertEqual(controller.renderView.sampleBufferDisplayLayer.frame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(controller.renderView.sampleBufferDisplayLayer.frame.width, controller.renderView.bounds.width, accuracy: 0.001)
        XCTAssertEqual(
            controller.renderView.sampleBufferDisplayLayer.frame.height,
            controller.renderView.bounds.height,
            accuracy: 0.001
        )
    }

    @MainActor
    func testVisibleChromeReservesMirrorLayoutSpace() {
        XCTAssertEqual(
            MirrorContentWindowController.visibleChromeRenderTopInset,
            MirrorContentWindowController.chromeHeight
        )
    }

    @MainActor
    func testTopToolbarControlsStayVisibleWhenChromeIsNotHovered() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let minimize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        rootView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: controller.renderView.frame.midX,
                y: controller.renderView.frame.midY
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

        XCTAssertFalse(controller.isChromeVisibleForTesting)
        XCTAssertFalse(controller.isChromeBarHiddenForTesting)
        XCTAssertFalse(controller.isChromeBarBackgroundVisibleForTesting)
        XCTAssertFalse(close.isHidden)
        XCTAssertFalse(minimize.isHidden)
        XCTAssertFalse(zoom.isHidden)
        XCTAssertEqual(controller.renderTopInsetForTesting, controller.chromeHeightForTesting, accuracy: 0.001)
    }

    @MainActor
    func testToolbarHorizontalPaddingStaysEightPoints() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let chromeBar = try XCTUnwrap(rootView.subviews.compactMap { $0 as? MirrorChromeBar }.first)

        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(chromeBar.horizontalPaddingForTesting, 8, accuracy: 0.001)
        XCTAssertEqual(chromeBar.trafficLightLeadingPaddingForTesting, 8, accuracy: 0.001)
        XCTAssertEqual(chromeBar.trailingActionsPaddingForTesting, 8, accuracy: 0.001)

        window.setFrame(NSRect(origin: window.frame.origin, size: window.maxSize), display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(chromeBar.horizontalPaddingForTesting, 8, accuracy: 0.001)
        XCTAssertEqual(chromeBar.trafficLightLeadingPaddingForTesting, 8, accuracy: 0.001)
        XCTAssertEqual(chromeBar.trailingActionsPaddingForTesting, 8, accuracy: 0.001)
    }

    @MainActor
    func testToolbarHeightScalesFromOneToMaximumChromeScale() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView as? MirrorRootView)

        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(rootView.chromeActivationHeight, MirrorContentWindowController.chromeHeight, accuracy: 0.001)

        window.setFrame(NSRect(origin: window.frame.origin, size: window.maxSize), display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(
            rootView.chromeActivationHeight,
            MirrorContentWindowController.chromeHeight * 1.6,
            accuracy: 0.001
        )

        let revealEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: window.frame.width / 2,
                y: window.frame.height - MirrorContentWindowController.chromeHeight / 2
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseMoved(with: revealEvent)
        rootView.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.chromeHeightForTesting, MirrorContentWindowController.maximumChromeHeight, accuracy: 0.001)
        XCTAssertEqual(controller.renderTopInsetForTesting, MirrorContentWindowController.maximumChromeHeight, accuracy: 0.001)
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
    func testCenteredScaleUsesMaximumToolbarHeightAtMaximumSize() {
        let aspect = 1080.0 / 2340.0
        let original = NSRect(x: 100, y: 200, width: 300, height: 700)
        let scaled = MirrorContentWindowController.scaledFrame(
            from: original,
            scale: 9.0,
            aspect: aspect,
            chromeHeight: MirrorContentWindowController.chromeHeight,
            minHeight: 450,
            maxHeight: 980
        )

        XCTAssertEqual(scaled.height, 980, accuracy: 0.001)
        XCTAssertEqual(
            scaled.width,
            (980 - MirrorContentWindowController.chromeHeight * 1.6) * aspect,
            accuracy: 0.001
        )
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
        let initialWindowFrame = window.frame
        let revealEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: window.frame.width / 2,
                y: window.frame.height - MirrorContentWindowController.chromeHeight / 2
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseMoved(with: revealEvent)
        rootView.layoutSubtreeIfNeeded()

        let revealedRatio = window.contentAspectRatio.width / window.contentAspectRatio.height
        XCTAssertEqual(revealedRatio, initialRatio, accuracy: 0.001)
        XCTAssertEqual(window.frame.origin.x, initialWindowFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(window.frame.origin.y, initialWindowFrame.origin.y, accuracy: 0.001)
        XCTAssertEqual(window.frame.width, initialWindowFrame.width, accuracy: 0.001)
        XCTAssertEqual(window.frame.height, initialWindowFrame.height, accuracy: 0.001)
        XCTAssertEqual(controller.renderTopInsetForTesting, controller.chromeHeightForTesting, accuracy: 0.001)
    }

    @MainActor
    func testHiddenChromeRevealsFromToolbarBand() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView as? MirrorRootView)

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: window.frame.width / 2,
                y: window.frame.height - MirrorContentWindowController.chromeHeight / 2
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

        XCTAssertTrue(controller.isChromeVisibleForTesting)
    }

    @MainActor
    func testHiddenChromeDoesNotRevealFromMirrorContentMiddle() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        rootView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: controller.renderView.frame.midX,
                y: controller.renderView.frame.midY
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

        XCTAssertFalse(controller.isChromeVisibleForTesting)
    }

    @MainActor
    func testHiddenChromeDoesNotRevealBelowTopOverlayZone() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        rootView.layoutSubtreeIfNeeded()

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: controller.renderView.frame.midX,
                y: controller.renderView.frame.midY
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

        XCTAssertFalse(controller.isChromeVisibleForTesting)
    }

    @MainActor
    func testHiddenChromeRevealsFromToolbarBandAboveMirrorContent() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: window.frame.width / 2,
                y: window.frame.height - MirrorContentWindowController.chromeHeight / 2
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

        XCTAssertTrue(controller.isChromeVisibleForTesting)
        XCTAssertFalse(controller.isChromeBarHiddenForTesting)
    }

    @MainActor
    func testHiddenChromeRevealsWhenPointerEntersToolbarBand() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: window.frame.width / 2,
                y: window.frame.height - MirrorContentWindowController.chromeHeight / 2
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseEntered(with: event)

        XCTAssertTrue(controller.isChromeVisibleForTesting)
        XCTAssertFalse(controller.isChromeBarHiddenForTesting)
    }

    @MainActor
    func testVisibleChromeStaysStableWhenPointerIsInToolbarBand() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let revealEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: window.frame.width / 2,
                y: window.frame.height - MirrorContentWindowController.chromeHeight / 2
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))

        rootView.mouseMoved(with: revealEvent)
        rootView.mouseMoved(with: revealEvent)
        RunLoop.current.run(until: Date().addingTimeInterval(0.20))

        XCTAssertTrue(controller.isChromeVisibleForTesting)
    }

    @MainActor
    func testChromeBarExitDoesNotHideActionsWhenCursorIsStillInToolbarBand() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let chromeBar = try XCTUnwrap(rootView.subviews.compactMap { $0 as? MirrorChromeBar }.first)
        let toolbarPoint = NSPoint(
            x: window.frame.width / 2,
            y: window.frame.height - MirrorContentWindowController.chromeHeight / 2
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: toolbarPoint,
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
        chromeBar.mouseExited(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))

        XCTAssertTrue(controller.isChromeVisibleForTesting)
    }

    @MainActor
    func testToolbarControlsRemainVisibleAfterPointerLeavesToolbar() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let minimize = try XCTUnwrap(window.standardWindowButton(.miniaturizeButton))
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let revealEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(
                x: window.frame.width / 2,
                y: window.frame.height - MirrorContentWindowController.chromeHeight / 2
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        rootView.layoutSubtreeIfNeeded()
        rootView.mouseMoved(with: revealEvent)
        XCTAssertFalse(close.isHidden)
        XCTAssertFalse(minimize.isHidden)
        XCTAssertFalse(zoom.isHidden)
        XCTAssertTrue(controller.isChromeBarBackgroundVisibleForTesting)

        controller.setChromeVisibleForTesting(false)

        XCTAssertFalse(controller.isChromeBarHiddenForTesting)
        XCTAssertFalse(controller.isChromeBarBackgroundVisibleForTesting)
        XCTAssertFalse(close.isHidden)
        XCTAssertFalse(minimize.isHidden)
        XCTAssertFalse(zoom.isHidden)
    }

    @MainActor
    func testMirrorContentKeepsOldRoundedPhoneShapeInsideChromeShell() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)

        XCTAssertLessThanOrEqual(controller.renderView.cornerRadius, MirrorContentWindowController.maximumMirrorCornerRadius)
        XCTAssertTrue(controller.renderView.layer?.masksToBounds ?? false)
    }

    @MainActor
    func testInnerMirrorRadiusLeavesVisibleAppKitShellPadding() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)

        XCTAssertEqual(
            controller.renderView.cornerRadius,
            controller.shellCornerRadiusForTesting - controller.renderBottomInsetForTesting,
            accuracy: 0.001
        )
    }

    @MainActor
    func testInsetsAndCornerRadiiScaleWithWindowSize() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)

        controller.setStreamSize(width: 1080, height: 2340)

        window.setFrame(NSRect(origin: window.frame.origin, size: window.maxSize), display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        window.contentView?.layoutSubtreeIfNeeded()
        let largeBottomInset = controller.renderBottomInsetForTesting
        let largeShellRadius = controller.shellCornerRadiusForTesting
        let largeMirrorRadius = controller.renderView.cornerRadius

        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.renderBottomInsetForTesting, 0)
        XCTAssertEqual(controller.renderView.frame.minY, 0, accuracy: 0.01)
        XCTAssertEqual(controller.renderView.frame.minX, 0, accuracy: 0.01)
        XCTAssertEqual(largeBottomInset, 0)
        XCTAssertLessThan(controller.shellCornerRadiusForTesting, largeShellRadius)
        XCTAssertLessThan(controller.renderView.cornerRadius, largeMirrorRadius)
        XCTAssertEqual(controller.renderView.cornerRadius, MirrorContentWindowController.minimumMirrorCornerRadius, accuracy: 0.01)
        XCTAssertEqual(
            controller.shellCornerRadiusForTesting,
            controller.renderView.cornerRadius + controller.renderBottomInsetForTesting,
            accuracy: 0.001
        )
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
        XCTAssertFalse(
            ScrcpyController.chromeArguments.contains("--turn-screen-off"),
            "Launching the mirror must never blank the phone display."
        )
    }

    @MainActor
    func testFullscreenMirrorSuppressesChromeAndUsesPhoneOnlyInset() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let rootView = try XCTUnwrap(window.contentView)

        controller.setStreamSize(width: 1080, height: 2340)
        controller.setFullscreenChromeSuppressedForTesting(true)

        XCTAssertTrue(controller.isFullscreenChromeSuppressedForTesting)
        XCTAssertEqual(controller.renderTopInsetForTesting, 0, accuracy: 0.001)
        XCTAssertFalse(controller.isChromeVisibleForTesting)
        XCTAssertEqual(
            controller.windowWillResize(window, to: NSSize(width: 1920, height: 1080)),
            NSSize(width: 1920, height: 1080)
        )

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

        XCTAssertFalse(controller.isChromeVisibleForTesting)
    }

    @MainActor
    func testLeavingFullscreenRestoresTopChromeBandLayout() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)

        controller.setFullscreenChromeSuppressedForTesting(true)
        controller.setFullscreenChromeSuppressedForTesting(false)

        XCTAssertFalse(controller.isFullscreenChromeSuppressedForTesting)
        XCTAssertEqual(
            controller.renderTopInsetForTesting,
            MirrorContentWindowController.visibleChromeRenderTopInset,
            accuracy: 0.001
        )
    }

    @MainActor
    func testLeavingFullscreenRestoresPreviousWindowFrame() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let normalFrame = NSRect(x: 120, y: 140, width: 520, height: 980)
        let fullscreenFrame = NSRect(x: 0, y: 0, width: 1920, height: 1080)

        window.setFrame(normalFrame, display: true, animate: false)
        controller.setFullscreenChromeSuppressedForTesting(true)
        window.setFrame(fullscreenFrame, display: true, animate: false)

        controller.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: window))

        XCTAssertFalse(controller.isFullscreenChromeSuppressedForTesting)
        XCTAssertEqual(window.frame.origin.x, normalFrame.origin.x, accuracy: 0.001)
        XCTAssertEqual(window.frame.origin.y, normalFrame.origin.y, accuracy: 0.001)
        XCTAssertEqual(window.frame.width, normalFrame.width, accuracy: 0.001)
        XCTAssertEqual(window.frame.height, normalFrame.height, accuracy: 0.001)
    }

    @MainActor
    func testFullscreenSizedRestoredWindowUsesPhoneOnlyPresentation() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let screenFrame = try XCTUnwrap(NSScreen.main?.frame)

        window.setFrame(screenFrame, display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))

        XCTAssertTrue(controller.isFullscreenChromeSuppressedForTesting)
        XCTAssertEqual(controller.renderTopInsetForTesting, 0, accuracy: 0.001)
        XCTAssertFalse(controller.isChromeVisibleForTesting)
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

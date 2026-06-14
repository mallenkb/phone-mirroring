import XCTest
@testable import PhoneRelay

final class MirrorWindowChromeTests: XCTestCase {
    func testMirrorStartupDoesNotBlockMainActorDuringADBPreparation() async throws {
        let startupStarted = LockedFlag()
        let startupFinished = LockedFlag()
        let ping = LockedFlag()

        let startupTask = MirrorSession.runStartupOffMain {
            startupStarted.set()
            Thread.sleep(forTimeInterval: 2)
            startupFinished.set()
        }
        defer {
            startupTask.cancel()
        }

        let didStart = await waitForFlag(startupStarted)
        XCTAssertTrue(didStart)

        Task { @MainActor in
            ping.set()
        }

        let didPing = await waitForFlag(ping, timeout: 1)
        XCTAssertTrue(didPing, "Mirror startup must not block main-actor UI work while adb prepares the scrcpy tunnel.")
        XCTAssertFalse(startupFinished.value)
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

    @MainActor
    func testNativeMirrorTitleUsesConnectedDeviceName() throws {
        let model = AppModel(startBackgroundServices: false)
        model.selectedDevice = MirrorDevice(
            id: "adb-RFCT10ZLTAJ",
            name: "SM-S906B",
            model: "SM-S906B",
            battery: 39,
            isCharging: false,
            network: "USB debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: "RFCT10ZLTAJ"
        )
        let session = MirrorSession(model: model, serial: model.selectedDevice.adbSerial)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)

        XCTAssertEqual(window.title, "SM-S906B")
        XCTAssertTrue(controller.chromeBarForTesting.allTextFieldValues.contains("SM-S906B"))
        XCTAssertFalse(controller.chromeBarForTesting.allTextFieldValues.contains("Android Device"))
    }

    @MainActor
    func testNativeMirrorTitleUpdatesWhenConnectedDeviceNameArrives() throws {
        let model = AppModel(startBackgroundServices: false)
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)

        model.selectedDevice = MirrorDevice(
            id: "adb-192.168.68.50:5555",
            name: "Work Phone",
            model: "SM-S906B",
            battery: 39,
            isCharging: false,
            network: "Wi-Fi debugging",
            lastSeen: .now,
            states: [.mirroringReady, .companionConnected],
            adbSerial: "192.168.68.50:5555"
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(window.title, "Work Phone")
        XCTAssertTrue(controller.chromeBarForTesting.allTextFieldValues.contains("Work Phone"))
    }

    func testOnboardingQuitDotUsesTrafficLightRedAndThinXStroke() {
        XCTAssertEqual(OnboardingWindowDotStyle.closeRedComponents.red, 1.0, accuracy: 0.001)
        XCTAssertEqual(OnboardingWindowDotStyle.closeRedComponents.green, 0.37, accuracy: 0.001)
        XCTAssertEqual(OnboardingWindowDotStyle.closeRedComponents.blue, 0.34, accuracy: 0.001)
        XCTAssertEqual(OnboardingWindowDotStyle.xStrokeWidth, 1.3, accuracy: 0.001)
    }

    func testScrcpyTextMessageEncodesUtf8Payload() {
        let message = ScrcpyControlChannel.textMessage(for: "Hi")

        XCTAssertEqual(Array(message), [1, 0, 0, 0, 2, 72, 105])
    }

    func testScrcpyKeycodeMessageEncodesControlAForSelectAll() {
        let message = ScrcpyControlChannel.keycodeMessage(
            action: .down,
            key: .a,
            metastate: ScrcpyControlChannel.metaCtrlOn
        )

        XCTAssertEqual(Array(message), [0, 0, 0, 0, 0, 29, 0, 0, 0, 1, 0, 0, 16, 0])
    }

    func testScrcpyKeycodeMessageEncodesControlXForCut() {
        let message = ScrcpyControlChannel.keycodeMessage(
            action: .down,
            key: .x,
            metastate: ScrcpyControlChannel.metaCtrlOn
        )

        XCTAssertEqual(Array(message), [0, 0, 0, 0, 0, 52, 0, 0, 0, 1, 0, 0, 16, 0])
    }

    @MainActor
    func testFunctionVolumeKeysMapToAndroidVolumeControls() throws {
        let mute = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x6D
        ))
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x67
        ))
        let up = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0x6F
        ))

        XCTAssertEqual(MirrorSession.androidKey(for: mute), .volumeMute)
        XCTAssertEqual(MirrorSession.androidKey(for: down), .volumeDown)
        XCTAssertEqual(MirrorSession.androidKey(for: up), .volumeUp)
    }

    @MainActor
    func testHardwareVolumeKeysMapToAndroidVolumeControls() throws {
        let up = try XCTUnwrap(Self.mediaKeyEvent(keyType: 0))
        let down = try XCTUnwrap(Self.mediaKeyEvent(keyType: 1))
        let mute = try XCTUnwrap(Self.mediaKeyEvent(keyType: 7))

        XCTAssertEqual(MirrorSession.androidKey(for: up), .volumeUp)
        XCTAssertEqual(MirrorSession.androidKey(for: down), .volumeDown)
        XCTAssertEqual(MirrorSession.androidKey(for: mute), .volumeMute)
        XCTAssertEqual(MirrorSession.androidKeyAction(for: up), ScrcpyControlChannel.KeyAction.down)
    }

    @MainActor
    func testNonMediaSystemEventsAreIgnoredByAndroidKeyMapping() throws {
        let event = try XCTUnwrap(NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 7,
            data1: 1,
            data2: 1
        ))

        XCTAssertNil(MirrorSession.androidKey(for: event))
        XCTAssertNil(MirrorSession.androidKeyAction(for: event))
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
    func testMirrorLoadingProgressAnimatesStatusAndDeviceNameAsOneUnit() {
        let renderView = MirrorRenderView(frame: NSRect(x: 0, y: 0, width: 390, height: 850))
        renderView.setLoadingDeviceName("Pixel 8 Pro")

        let progressViews = renderView.allSubviews.filter {
            NSStringFromClass(type(of: $0)).contains("LoadingProgressTextView")
        }

        XCTAssertEqual(progressViews.count, 1)
        XCTAssertEqual(progressViews.first?.allTextFieldValues, [
            "Connecting to your",
            "Pixel 8 Pro",
            "Connecting to your",
            "Pixel 8 Pro"
        ])
    }

    @MainActor
    func testMirrorLoadingBackgroundUsesBrandDarkCyan() throws {
        let loadingView = MirrorLoadingView(frame: NSRect(x: 0, y: 0, width: 390, height: 850))
        let gradientLayer = try XCTUnwrap(
            loadingView.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
        )
        let colors = try XCTUnwrap(gradientLayer.colors as? [CGColor])
        let expected = try XCTUnwrap(
            PhoneRelayBrand.deepCyanNSColor.usingColorSpace(.sRGB)
        )

        XCTAssertEqual(colors.count, 3)
        for color in colors {
            let actual = try XCTUnwrap(NSColor(cgColor: color)?.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
            XCTAssertEqual(actual.alphaComponent, expected.alphaComponent, accuracy: 0.001)
        }
    }

    func testConnectionOnboardingDoesNotUseDecorativeAnimatedGlowVisuals() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/PhoneRelay/Views/FigmaMirrorExperienceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("AnimatedOnboardingBackdrop"))
        XCTAssertFalse(source.contains("ConnectionOrbVisual"))
        XCTAssertFalse(source.contains("MacOnboardingHeroVisual"))
        XCTAssertFalse(source.contains("MirroringLoopVisual"))
        XCTAssertFalse(source.contains("TimelineView(.animation)"))
        XCTAssertFalse(source.contains("RadialGradient"))
    }

    func testConnectionSetupOnlyUsesLoadingSurfaceForReconnect() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let packageRoot = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/PhoneRelay/Views/FigmaMirrorExperienceView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("if model.shouldShowReconnectLoadingSurface"))
        XCTAssertTrue(source.contains("MirrorLoadingSurface("))
        XCTAssertTrue(source.contains("statusText: \"Reconnecting to your\""))
        XCTAssertTrue(source.contains("deviceName: model.mirrorLoadingDeviceTitle"))
        XCTAssertFalse(source.contains("shouldShowMirrorLoading"))
        XCTAssertFalse(source.contains("deviceName: model.selectedDevice.name"))
    }

    @MainActor
    func testFloatingToolbarWindowCanBecomeKeyWithoutBecomingMain() {
        let toolbar = MirrorToolbarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(toolbar.canBecomeKey)
        XCTAssertFalse(toolbar.canBecomeMain)
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

    @MainActor
    func testMirrorRenderViewForwardsCommandASelectAllToPhone() throws {
        let renderView = MirrorRenderView()
        var forwardedEvents = 0
        renderView.onKeyEvent = { _ in forwardedEvents += 1 }

        let commandA = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        XCTAssertTrue(renderView.performKeyEquivalent(with: commandA))
        XCTAssertEqual(forwardedEvents, 1)
        XCTAssertTrue(MirrorSession.isSelectAllShortcut(commandA))
        XCTAssertEqual(MirrorSession.androidCommandShortcutKey(for: commandA), .a)
    }

    @MainActor
    func testMirrorRenderViewForwardsCommandXCutToPhone() throws {
        let renderView = MirrorRenderView()
        var forwardedEvents = 0
        renderView.onKeyEvent = { _ in forwardedEvents += 1 }

        let commandX = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        ))

        XCTAssertTrue(renderView.performKeyEquivalent(with: commandX))
        XCTAssertEqual(forwardedEvents, 1)
        XCTAssertEqual(MirrorSession.androidCommandShortcutKey(for: commandX), .x)
    }

    @MainActor
    func testMirrorSessionDoesNotTreatControlAAsSelectAllShortcut() throws {
        let controlA = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .control,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1}",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))

        XCTAssertFalse(MirrorSession.isSelectAllShortcut(controlA))
        XCTAssertNil(MirrorSession.androidCommandShortcutKey(for: controlA))
    }

    func testMirrorAudioIsSupportedForWirelessADBSerials() {
        XCTAssertTrue(MirrorSession.supportsMirrorAudio(serial: "192.0.2.51:5555"))
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
    func testNativeMirrorShellLetsPhonePixelsFillToTopEdge() {
        XCTAssertEqual(MirrorContentWindowController.screenLeftInset, 0)
        XCTAssertEqual(MirrorContentWindowController.screenRightInset, 0)
        // The toolbar overlays the mirror, so no top band is reserved — the
        // render fills the window to the top edge and there is no chrome strip.
        XCTAssertEqual(MirrorContentWindowController.visibleChromeRenderTopInset, 0)
        // The overlay still uses the standard titlebar height when revealed.
        XCTAssertEqual(MirrorContentWindowController.chromeHeight, 28)
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
    func testNativeMirrorLaunchFramePreservesDraggedCenterWhenStreamLoads() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let draggedStageFrame = NSRect(x: 128, y: 176, width: 395, height: 860)
        let controller = MirrorContentWindowController(
            model: model,
            session: session,
            launchFrame: draggedStageFrame
        )

        controller.show()
        controller.setStreamSize(width: 738, height: 1600)

        let window = try XCTUnwrap(controller.window)
        XCTAssertEqual(window.frame.midX, draggedStageFrame.midX, accuracy: 0.5)
        XCTAssertEqual(window.frame.midY, draggedStageFrame.midY, accuracy: 0.5)
        XCTAssertNotEqual(window.frame.size, draggedStageFrame.size)
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
    func testBlankNativeMirrorStartsAtInitialScreenHeightRatio() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 390, height: 850)
        let maximumHeightBasis = MirrorContentWindowController.resolutionHeight(
            for: NSScreen.main,
            fallbackVisibleFrame: visibleFrame
        )
        let fullDefaultSize = MirrorContentWindowController.wrappedShellSize(
            for: MirrorContentWindowController.defaultMirrorSize,
            visibleFrame: NSRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: visibleFrame.width,
                height: maximumHeightBasis
            )
        )
        let initialSize = MirrorContentWindowController.initialWrappedShellSize(
            for: MirrorContentWindowController.defaultMirrorSize,
            visibleFrame: visibleFrame,
            maximumHeightBasis: maximumHeightBasis
        )
        let topChromeInset = MirrorContentWindowController.visibleChromeRenderTopInset
        let targetHeight = min(
            maximumHeightBasis * MirrorContentWindowController.initialScreenHeightRatio,
            fullDefaultSize.height
        )
        let targetScreenHeight = targetHeight - topChromeInset

        XCTAssertEqual(window.frame.width, initialSize.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, initialSize.height, accuracy: 1)
        XCTAssertEqual(
            initialSize.width,
            targetScreenHeight * MirrorContentWindowController.defaultMirrorAspect
                * MirrorContentWindowController.initialMirrorScale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            initialSize.height - topChromeInset,
            targetScreenHeight * MirrorContentWindowController.initialMirrorScale,
            accuracy: 0.001
        )
    }

    @MainActor
    func testNativeMirrorStreamStartsAtInitialScreenHeightRatio() throws {
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
        let targetHeight = min(
            visibleFrame.height * MirrorContentWindowController.initialScreenHeightRatio,
            fullStreamSize.height
        )
        let targetScreenHeight = targetHeight - topChromeInset

        XCTAssertGreaterThanOrEqual(window.frame.width, initialStreamSize.width)
        XCTAssertEqual(
            initialStreamSize.width,
            targetScreenHeight * (1080.0 / 2340.0) * MirrorContentWindowController.initialMirrorScale,
            accuracy: 0.001
        )
        XCTAssertEqual(
            initialStreamSize.height - topChromeInset,
            targetScreenHeight * MirrorContentWindowController.initialMirrorScale,
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
    func testNativeMirrorWindowHonorsMinimumSizeAndCapsAtScreenHeightPercentage() {
        let limits = MirrorContentWindowController.sizeLimits(
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 1000),
            aspect: 1080.0 / 2340.0,
            chromeHeight: 0
        )

        XCTAssertEqual(limits.min.height, AppModel.minimumConnectionWindowSize.height, accuracy: 0.001)
        XCTAssertEqual(limits.max.height, 900, accuracy: 0.001)
        XCTAssertEqual(
            limits.min.width,
            AppModel.minimumConnectionWindowSize.height * (1080.0 / 2340.0),
            accuracy: 0.001
        )
        XCTAssertEqual(limits.max.width, 900 * (1080.0 / 2340.0), accuracy: 0.001)
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
            (900 - MirrorContentWindowController.maximumChromeHeight) * aspect,
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
    func testOverlayChromeDoesNotReserveMirrorLayoutSpace() {
        // The hover toolbar overlays the mirror rather than reserving a band,
        // so it adds zero top inset to the rendered phone pixels.
        XCTAssertEqual(MirrorContentWindowController.visibleChromeRenderTopInset, 0)
    }

    @MainActor
    func testTopToolbarStaysHiddenWhenChromeIsNotHovered() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)

        // Pointer over the phone (not the zone above) → the floating toolbar is
        // hidden and the render fills the window to the top edge (no band).
        controller.simulateRevealZoneHover(false)

        XCTAssertFalse(controller.isChromeVisibleForTesting)
        XCTAssertTrue(controller.isChromeBarHiddenForTesting)
        XCTAssertFalse(controller.isChromeBarBackgroundVisibleForTesting)
        XCTAssertEqual(controller.renderTopInsetForTesting, 0, accuracy: 0.001)
    }

    @MainActor
    func testToolbarHorizontalPaddingStaysEightPoints() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)
        let chromeBar = controller.chromeBarForTesting

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
    func testFloatingToolbarUsesFixedBarHeightAndNeverInsetsRender() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        controller.setStreamSize(width: 1080, height: 2340)
        let window = try XCTUnwrap(controller.window)

        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        XCTAssertEqual(controller.chromeHeightForTesting, MirrorContentWindowController.toolbarBarHeight, accuracy: 0.001)
        XCTAssertEqual(controller.renderTopInsetForTesting, 0, accuracy: 0.001)

        window.setFrame(NSRect(origin: window.frame.origin, size: window.maxSize), display: true, animate: false)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        // Fixed-height floating bar — it does not grow with the window, and it
        // never reserves a top band in the mirror.
        XCTAssertEqual(controller.chromeHeightForTesting, MirrorContentWindowController.toolbarBarHeight, accuracy: 0.001)
        XCTAssertEqual(controller.renderTopInsetForTesting, 0, accuracy: 0.001)
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
        XCTAssertEqual(controller.renderTopInsetForTesting, 0, accuracy: 0.001)
    }

    @MainActor
    func testFloatingToolbarRevealsFromZoneAboveWindow() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)

        controller.simulateRevealZoneHover(true)

        XCTAssertTrue(controller.isChromeVisibleForTesting)
        XCTAssertFalse(controller.isChromeBarHiddenForTesting)
        XCTAssertTrue(controller.isToolbarWindowVisibleForTesting)
    }

    @MainActor
    func testFloatingToolbarStaysHiddenOverMirrorContent() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)

        // The pointer over the phone (not the zone above the window) keeps the
        // toolbar fully hidden.
        controller.simulateRevealZoneHover(false)

        XCTAssertFalse(controller.isChromeVisibleForTesting)
        XCTAssertTrue(controller.isChromeBarHiddenForTesting)
    }

    @MainActor
    func testFloatingToolbarHidesAfterPointerLeavesZone() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)

        controller.simulateRevealZoneHover(true)
        XCTAssertTrue(controller.isChromeVisibleForTesting)

        controller.simulateRevealZoneHover(false)

        XCTAssertFalse(controller.isChromeVisibleForTesting)
        XCTAssertTrue(controller.isChromeBarHiddenForTesting)
    }

    @MainActor
    func testFloatingToolbarIsASeparateChildWindowAboveTheMirror() throws {
        let model = AppModel()
        let session = MirrorSession(model: model, serial: nil)
        let controller = MirrorContentWindowController(model: model, session: session)
        let window = try XCTUnwrap(controller.window)
        let toolbar = try XCTUnwrap(controller.toolbarWindowForTesting)

        // The toolbar is its own window attached to (not inside) the mirror.
        XCTAssertTrue(window.childWindows?.contains(toolbar) ?? false)
        XCTAssertFalse(controller.renderView.subviews.contains(controller.chromeBarForTesting))
        XCTAssertEqual(toolbar.frame.width, window.frame.width, accuracy: 0.5)
        XCTAssertEqual(toolbar.frame.height, MirrorContentWindowController.toolbarBarHeight, accuracy: 0.5)
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

}

private extension NSView {
    var allSubviews: [NSView] {
        subviews + subviews.flatMap(\.allSubviews)
    }

    var allTextFieldValues: [String] {
        allSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}

func waitForFlag(_ flag: LockedFlag, timeout: TimeInterval = 1) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if flag.value {
            return true
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return false
}

private extension MirrorWindowChromeTests {
    static func mediaKeyEvent(keyType: Int, keyState: Int = 0xA) -> NSEvent? {
        NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: (keyType << 16) | (keyState << 8),
            data2: -1
        )
    }
}

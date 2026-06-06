import AppKit
import Combine

private enum MirrorShellStyle {
    static var backgroundColor: NSColor { .windowBackgroundColor }
    static var borderColor: NSColor { .separatorColor.withAlphaComponent(0.28) }
    static let borderWidth: CGFloat = 0
}

/// Owns the in-process mirror window: a borderless, rounded NSWindow whose
/// content is our own `MirrorRenderView` plus a hover-revealed chrome bar.
/// Because the window lives in our process, dragging is a native AppKit
/// window move (`NSWindow.performDrag`) — no cross-process AX chase, smooth
/// at display refresh rate, exactly like Reflect.
@MainActor
final class MirrorContentWindowController: NSWindowController, NSWindowDelegate {
    static let cornerRadius: CGFloat = 34
    /// Standard macOS titlebar height. Anything larger and the AppKit chrome
    /// reads as a heavy banner instead of a window's title bar.
    static let chromeHeight: CGFloat = 28
    /// Compact windows keep the standard macOS titlebar height; large windows
    /// let the hover toolbar grow up to 60% taller so it stays readable.
    static let maximumChromeScale: CGFloat = 1.6
    static var maximumChromeHeight: CGFloat { chromeHeight * maximumChromeScale }
    static let chromeActivationZone: CGFloat = chromeHeight
    /// The hover toolbar floats as an overlay over the top of the mirror, so the
    /// render fills the window all the way to the top edge and no band is
    /// reserved. At rest there is zero chrome footprint — just the phone.
    static var visibleChromeRenderTopInset: CGFloat { 0 }
    /// Keep phone pixels edge-to-edge. The toolbar overlays the top of the
    /// mirror only while revealed on hover.
    static let screenSideInset: CGFloat = 0
    static let minimumScreenSideInset: CGFloat = 0
    static let screenLeftInset: CGFloat = screenSideInset
    static let screenRightInset: CGFloat = screenSideInset
    static let screenBottomInset: CGFloat = 0
    static let defaultMirrorSize = NSSize(width: 1080, height: 2340)
    static let defaultMirrorAspect: CGFloat = 1080.0 / 2340.0
    static let initialMirrorScale: CGFloat = 1.0
    static let minimumMirrorCornerRadius: CGFloat = 24
    static let maximumMirrorCornerRadius: CGFloat = 38
    static let minimumScreenHeightRatio: CGFloat = 0.45
    static let initialScreenHeightRatio: CGFloat = 0.60
    static let maximumScreenHeightRatio: CGFloat = 0.90
    static let chromeHideDelay: TimeInterval = 0.030
    static let chromeHideAnimationDuration: TimeInterval = 0.16
    static let renderCornerRadius: CGFloat = cornerRadius

    static func mirrorCornerRadius(
        forWindowHeight windowHeight: CGFloat,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        let heightRange = max(1, maxHeight - minHeight)
        let cornerScale = windowHeight <= minHeight + 1
            ? 0
            : min(1, max(0, (windowHeight - minHeight) / heightRange))
        return minimumMirrorCornerRadius
            + (maximumMirrorCornerRadius - minimumMirrorCornerRadius) * cornerScale
    }

    static func onboardingCornerRadius(visibleFrame: NSRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 390, height: 850)) -> CGFloat {
        let limits = sizeLimits(
            visibleFrame: visibleFrame,
            aspect: defaultMirrorAspect,
            chromeHeight: verticalShellInset,
            horizontalChromeWidth: horizontalShellInset,
            maximumHeightBasis: resolutionHeight(for: NSScreen.main, fallbackVisibleFrame: visibleFrame)
        )
        return mirrorCornerRadius(
            forWindowHeight: AppModel.onboardingWindowSize.height,
            minHeight: limits.min.height,
            maxHeight: limits.max.height
        )
    }

    /// The detached toolbar floats in its own window above the phone.
    static let toolbarBarHeight: CGFloat = 30
    /// Vertical gap between the top of the mirror window and the floating bar.
    static let toolbarGap: CGFloat = 6
    /// Extra slack added to the reveal zone above the window so the bar is easy
    /// to summon without pixel-perfect aim.
    static let toolbarRevealSlop: CGFloat = 6

    private let model: AppModel
    private weak var session: MirrorSession?

    let renderView = MirrorRenderView()
    private let rootView = MirrorRootView()
    private let chromeBar = MirrorChromeBar()
    private var toolbarWindow: NSWindow?
    private var revealMonitors: [Any] = []
    private var renderTopConstraint: NSLayoutConstraint?
    private var renderLeadingConstraint: NSLayoutConstraint?
    private var renderTrailingConstraint: NSLayoutConstraint?
    private var renderBottomConstraint: NSLayoutConstraint?
    private var hideWorkItem: DispatchWorkItem?
    private var chromeVisible = false
    private var isDraggingChrome = false
    private var isPointerInTopZone = false
    private var isInFullscreen = false
    private var normalWindowFrameBeforeFullscreen: NSRect?
    private var mirrorAspect: CGFloat? = defaultMirrorAspect
    private let launchFrame: NSRect?
    private var recordingStateCancellable: AnyCancellable?
    private var captureCueCancellable: AnyCancellable?
    private var activeCaptureCueView: MirrorCaptureCueView?

    init(model: AppModel, session: MirrorSession, launchFrame: NSRect? = nil) {
        self.model = model
        self.session = session
        self.launchFrame = launchFrame
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 390, height: 850)
        let initialSize = Self.initialWrappedShellSize(
            for: Self.defaultMirrorSize,
            visibleFrame: visible,
            maximumHeightBasis: Self.resolutionHeight(for: NSScreen.main, fallbackVisibleFrame: visible)
        )
        let frame = NSRect(
            x: 0,
            y: 0,
            width: initialSize.width,
            height: initialSize.height
        )
        let window = MirrorContentWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        configure(window: window)
        installContent()
        window.styleMask.remove(.titled)
        window.contentAspectRatio = initialSize
    }

    required init?(coder: NSCoder) { nil }

    private static var verticalShellInset: CGFloat {
        visibleChromeRenderTopInset + screenBottomInset
    }

    private static var horizontalShellInset: CGFloat {
        screenLeftInset + screenRightInset
    }

    private static func normalShellColor(for view: NSView) -> CGColor {
        resolvedCGColor(MirrorShellStyle.backgroundColor, for: view)
    }

    private static func shellBorderColor(for view: NSView) -> CGColor {
        resolvedCGColor(MirrorShellStyle.borderColor, for: view)
    }

    private static func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
        var resolvedColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = (color.usingColorSpace(.deviceRGB) ?? color).cgColor
        }
        return resolvedColor
    }

    static func wrappedShellSize(
        for streamSize: NSSize,
        visibleFrame: NSRect,
        screenMargin: CGFloat = 24
    ) -> NSSize {
        guard streamSize.width > 0, streamSize.height > 0 else {
            return NSSize(width: horizontalShellInset, height: verticalShellInset)
        }

        let maxScreenWidth = max(1, visibleFrame.width - screenMargin - horizontalShellInset)
        let maxScreenHeight = max(1, visibleFrame.height - screenMargin - verticalShellInset)
        let scale = min(1, maxScreenWidth / streamSize.width, maxScreenHeight / streamSize.height)
        let screenWidth = max(1, streamSize.width * scale)
        let screenHeight = max(1, streamSize.height * scale)
        return NSSize(
            width: screenWidth + horizontalShellInset,
            height: screenHeight + verticalShellInset
        )
    }

    static func initialWrappedShellSize(
        for streamSize: NSSize,
        visibleFrame: NSRect,
        screenMargin: CGFloat = 24,
        maximumHeightBasis: CGFloat? = nil
    ) -> NSSize {
        let fullSize = wrappedShellSize(
            for: streamSize,
            visibleFrame: visibleFrame,
            screenMargin: screenMargin
        )
        let maxScreenWidth = max(1, fullSize.width - horizontalShellInset)
        let maxScreenHeight = max(1, fullSize.height - verticalShellInset)
        let heightBasis = max(1, maximumHeightBasis ?? visibleFrame.height)
        let targetShellHeight = min(heightBasis * initialScreenHeightRatio, fullSize.height)
        let targetScreenHeight = max(1, targetShellHeight - verticalShellInset)
        let streamAspect = streamSize.width / max(streamSize.height, 1)
        let targetScreenWidth = min(maxScreenWidth, targetScreenHeight * streamAspect) * initialMirrorScale
        let screenHeight = min(maxScreenHeight, targetScreenWidth / max(streamAspect, 0.001))
        return NSSize(
            width: targetScreenWidth + horizontalShellInset,
            height: screenHeight + verticalShellInset
        )
    }

    static func defaultWrappedShellSize(
        for streamSize: NSSize,
        visibleFrame: NSRect,
        screenMargin: CGFloat = 24
    ) -> NSSize {
        guard streamSize.width > 0, streamSize.height > 0 else {
            return NSSize(width: horizontalShellInset, height: verticalShellInset)
        }

        let resolutionHeight = Self.resolutionHeight(for: NSScreen.main, fallbackVisibleFrame: visibleFrame)
        let targetScreenHeight = max(1, resolutionHeight * initialScreenHeightRatio)
        let maxScreenWidth = max(1, visibleFrame.width - screenMargin - horizontalShellInset)
        let maxScreenHeight = max(1, visibleFrame.height - screenMargin - verticalShellInset)
        let streamAspect = streamSize.width / max(streamSize.height, 1)
        let screenHeight = min(targetScreenHeight, maxScreenHeight)
        let screenWidth = min(maxScreenWidth, screenHeight * streamAspect)
        let fittedScreenHeight = min(maxScreenHeight, screenWidth / max(streamAspect, 0.001))

        return NSSize(
            width: screenWidth + horizontalShellInset,
            height: fittedScreenHeight + verticalShellInset
        )
    }

    static func centeredFrame(size: NSSize, in visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func centeredFrame(
        forContentSize contentSize: NSSize,
        in visibleFrame: NSRect,
        window: NSWindow
    ) -> NSRect {
        let insets = measuredFrameInsets(for: window)
        let frameSize = NSSize(
            width: contentSize.width + insets.width,
            height: contentSize.height + insets.height
        )
        return centeredFrame(size: frameSize, in: visibleFrame)
    }

    private static func measuredFrameInsets(for window: NSWindow) -> NSSize {
        let contentSize = window.contentView?.bounds.size
            ?? window.contentRect(forFrameRect: window.frame).size
        return NSSize(
            width: max(0, window.frame.width - contentSize.width),
            height: max(0, window.frame.height - contentSize.height)
        )
    }

    private static func targetVisibleFrame(for window: NSWindow?, preferWindowScreen: Bool = false) -> NSRect {
        if preferWindowScreen, let visibleFrame = window?.screen?.visibleFrame {
            return visibleFrame
        }

        let mouse = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return mouseScreen.visibleFrame
        }
        if let originScreen = NSScreen.screens.first(where: { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }) {
            return originScreen.visibleFrame
        }
        return NSScreen.main?.visibleFrame
            ?? window?.screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 390, height: 850)
    }

    static func resolutionHeight(for screen: NSScreen?, fallbackVisibleFrame: NSRect) -> CGFloat {
        guard
            let screen,
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return max(1, fallbackVisibleFrame.height)
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let pixelHeight = CGDisplayPixelsHigh(displayID)
        return pixelHeight > 0 ? CGFloat(pixelHeight) : max(1, fallbackVisibleFrame.height)
    }

    // MARK: - Public

    func show() {
        guard let window else { return }
        let frame: NSRect
        if let launchFrame {
            frame = launchFrame
        } else {
            let visible = NSScreen.main?.visibleFrame ?? Self.targetVisibleFrame(for: window)
            let size = Self.initialWrappedShellSize(
                for: Self.defaultMirrorSize,
                visibleFrame: visible,
                maximumHeightBasis: Self.resolutionHeight(for: NSScreen.main, fallbackVisibleFrame: visible)
            )
            frame = Self.centeredFrame(size: size, in: visible)
        }
        Logger.log("MirrorContentWindow show frame=\(frame)")
        window.setFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(renderView)
        updateFullscreenPresentationIfNeeded()
    }

    func setStreamSize(width: UInt32, height: UInt32) {
        guard let window, width > 0, height > 0 else { return }
        renderView.setStreamSize(width: width, height: height)
        let aspect = CGFloat(width) / CGFloat(height)
        mirrorAspect = aspect
        guard !isInFullscreen else {
            window.contentAspectRatio = .zero
            return
        }
        applyWindowSizeLimits(to: window, aspect: aspect)

        if launchFrame != nil {
            window.contentAspectRatio = window.frame.size
            applyScaledRenderInsets()
            return
        }

        let visible = Self.targetVisibleFrame(for: window, preferWindowScreen: true)
        let outerSize = Self.initialWrappedShellSize(
            for: NSSize(width: CGFloat(width), height: CGFloat(height)),
            visibleFrame: visible,
            maximumHeightBasis: Self.resolutionHeight(for: window.screen, fallbackVisibleFrame: visible)
        )
        window.contentAspectRatio = outerSize
        let newFrame = Self.centeredFrame(forContentSize: outerSize, in: visible, window: window)
        Logger.log("MirrorContentWindow streamSize=\(width)x\(height) visible=\(visible) frame=\(newFrame)")
        window.setFrame(newFrame, display: true, animate: false)
        applyScaledRenderInsets()
        tightenWindowAroundRenderContent()
    }

    func scaleWindow(by scale: CGFloat) {
        guard let window else { return }
        guard !isInFullscreen else { return }
        let aspect = mirrorAspect ?? Self.defaultMirrorAspect
        let limits = Self.sizeLimits(
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame,
            aspect: aspect,
            chromeHeight: Self.verticalShellInset,
            horizontalChromeWidth: Self.horizontalShellInset,
            maximumHeightBasis: Self.resolutionHeight(
                for: window.screen,
                fallbackVisibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            )
        )
        let targetFrame = Self.scaledFrame(
            from: window.frame,
            scale: scale,
            aspect: aspect,
            chromeHeight: Self.verticalShellInset,
            horizontalChromeWidth: Self.horizontalShellInset,
            minHeight: limits.min.height,
            maxHeight: limits.max.height
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = scale >= 1 ? 0.18 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: scale >= 1 ? .easeOut : .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    func centerWindow() {
        guard let window else { return }
        guard !isInFullscreen else { return }
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let targetFrame = Self.centeredFrame(size: window.frame.size, in: visible)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    static func scaledFrame(
        from frame: NSRect,
        scale: CGFloat,
        aspect: CGFloat,
        chromeHeight: CGFloat,
        horizontalChromeWidth: CGFloat = 0,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> NSRect {
        let minimumChromeHeight = max(0, chromeHeight)
        let maximumChromeHeight = minimumChromeHeight > 0 ? minimumChromeHeight * maximumChromeScale : 0
        let currentChromeHeight = interpolatedChromeHeight(
            forWindowHeight: frame.height,
            minimumChromeHeight: minimumChromeHeight,
            maximumChromeHeight: maximumChromeHeight,
            minHeight: minHeight,
            maxHeight: maxHeight
        )
        let contentHeight = max(1, frame.height - currentChromeHeight)
        let minContentHeight = max(1, minHeight - minimumChromeHeight)
        let maxContentHeight = max(minContentHeight, maxHeight - maximumChromeHeight)
        let scaledContentHeight = min(max(contentHeight * scale, minContentHeight), maxContentHeight)
        let contentRange = max(1, maxContentHeight - minContentHeight)
        let progress = min(1, max(0, (scaledContentHeight - minContentHeight) / contentRange))
        let targetChromeHeight = minimumChromeHeight
            + (maximumChromeHeight - minimumChromeHeight) * progress
        let height = scaledContentHeight + targetChromeHeight
        let width = scaledContentHeight * max(aspect, 0.001) + horizontalChromeWidth
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private static func interpolatedChromeHeight(
        forWindowHeight height: CGFloat,
        minimumChromeHeight: CGFloat,
        maximumChromeHeight: CGFloat,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> CGFloat {
        let heightRange = max(1, maxHeight - minHeight)
        let progress = min(1, max(0, (height - minHeight) / heightRange))
        return minimumChromeHeight + (maximumChromeHeight - minimumChromeHeight) * progress
    }

    // MARK: - Setup

    private func configure(window: NSWindow) {
        window.title = "Android device"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isRestorable = false
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        let defaultShellSize = Self.initialWrappedShellSize(
            for: Self.defaultMirrorSize,
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame,
            maximumHeightBasis: Self.resolutionHeight(
                for: window.screen ?? NSScreen.main,
                fallbackVisibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            )
        )
        window.contentAspectRatio = defaultShellSize
        applyWindowSizeLimits(to: window, aspect: Self.defaultMirrorAspect)
        window.level = .normal
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }

    private func applyWindowSizeLimits(to window: NSWindow, aspect: CGFloat) {
        let limits = Self.sizeLimits(
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame,
            aspect: aspect,
            chromeHeight: Self.verticalShellInset,
            horizontalChromeWidth: Self.horizontalShellInset,
            maximumHeightBasis: Self.resolutionHeight(
                for: window.screen,
                fallbackVisibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            )
        )
        window.minSize = limits.min
        window.maxSize = limits.max
    }

    private func scaledScreenInset(for window: NSWindow) -> CGFloat {
        let limits = Self.sizeLimits(
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame,
            aspect: mirrorAspect ?? Self.defaultMirrorAspect,
            chromeHeight: Self.verticalShellInset,
            horizontalChromeWidth: Self.horizontalShellInset,
            maximumHeightBasis: Self.resolutionHeight(
                for: window.screen,
                fallbackVisibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            )
        )
        let scale = min(1, max(0, window.frame.height / max(1, limits.max.height)))
        return max(Self.minimumScreenSideInset, Self.screenSideInset * scale)
    }

    private func applyScaledChromeHeight() {
        guard window != nil, !isInFullscreen else { return }
        // The toolbar is a fixed-height floating window above the phone, so the
        // render always fills this window to the top edge (no reserved band).
        renderTopConstraint?.constant = 0
    }

    private func applyScaledRenderInsets() {
        guard let window, !isInFullscreen else { return }
        applyScaledChromeHeight()
        let inset = scaledScreenInset(for: window)
        let mirrorRadius = Self.mirrorCornerRadius(
            forWindowHeight: window.frame.height,
            minHeight: window.minSize.height,
            maxHeight: window.maxSize.height
        )
        let shellRadius = mirrorRadius
        renderLeadingConstraint?.constant = inset
        renderTrailingConstraint?.constant = -inset
        renderBottomConstraint?.constant = -inset
        renderTopConstraint?.constant = 0
        rootView.layer?.cornerRadius = shellRadius
        renderView.cornerRadius = mirrorRadius
    }

    private func tightenWindowAroundRenderContent() {
        guard let window, !isInFullscreen, let aspect = mirrorAspect, aspect > 0 else { return }

        rootView.layoutSubtreeIfNeeded()
        let contentWidth = max(1, rootView.bounds.width - Self.horizontalShellInset)
        let targetRootHeight = contentWidth / aspect + Self.screenBottomInset
        let frameInsets = Self.measuredFrameInsets(for: window)
        let targetFrameSize = NSSize(
            width: window.frame.width,
            height: targetRootHeight + frameInsets.height
        )

        guard abs(window.frame.height - targetFrameSize.height) > 0.5 else { return }

        window.contentAspectRatio = NSSize(width: rootView.bounds.width, height: targetRootHeight)
        let targetFrame = NSRect(
            x: window.frame.midX - targetFrameSize.width / 2,
            y: window.frame.midY - targetFrameSize.height / 2,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
        window.setFrame(targetFrame, display: true, animate: false)
        applyScaledRenderInsets()
    }

    static func sizeLimits(
        visibleFrame: NSRect,
        aspect: CGFloat,
        chromeHeight: CGFloat,
        horizontalChromeWidth: CGFloat = 0,
        maximumHeightBasis: CGFloat? = nil
    ) -> (min: NSSize, max: NSSize) {
        let visibleHeight = max(1, visibleFrame.height)
        let heightBasis = max(1, maximumHeightBasis ?? visibleHeight)
        let maxHeight = heightBasis * maximumScreenHeightRatio
        let minHeight = min(maxHeight, max(AppModel.minimumConnectionWindowSize.height, visibleHeight * minimumScreenHeightRatio))
        let maxChromeHeight = chromeHeight > 0 ? chromeHeight * maximumChromeScale : 0
        let minContentHeight = max(1, minHeight - chromeHeight)
        let maxContentHeight = max(minContentHeight, maxHeight - maxChromeHeight)
        return (
            min: NSSize(width: minContentHeight * aspect + horizontalChromeWidth, height: minHeight),
            max: NSSize(width: maxContentHeight * aspect + horizontalChromeWidth, height: maxHeight)
        )
    }

    private func installContent() {
        guard let window else { return }
        rootView.frame = NSRect(origin: .zero, size: window.frame.size)
        rootView.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = Self.cornerRadius
        rootView.layer?.masksToBounds = true
        rootView.layer?.backgroundColor = Self.normalShellColor(for: rootView)
        rootView.layer?.borderColor = Self.shellBorderColor(for: rootView)
        rootView.layer?.borderWidth = MirrorShellStyle.borderWidth
        rootView.layer?.setValue("continuous", forKey: "cornerCurve")
        rootView.onHoverChange = { [weak self] _ in self?.evaluateRevealZone() }
        rootView.onAppearanceChange = { [weak self] in
            self?.applyNormalShellAppearance()
        }

        renderView.translatesAutoresizingMaskIntoConstraints = false
        renderView.cornerRadius = Self.renderCornerRadius
        renderView.setLoadingDeviceName(model.selectedDevice.name)
        rootView.addSubview(renderView)

        chromeBar.configure(
            deviceName: model.selectedDevice.name,
            onHome: { [weak self] in self?.model.sendAndroidKey("KEYCODE_HOME") },
            onRecentApps: { [weak self] in self?.model.sendAndroidKey("KEYCODE_APP_SWITCH") },
            onScreenshot: { [weak self] in self?.model.takeScreenshot() },
            onRecordingToggle: { [weak self] in self?.model.toggleScreenRecording() }
        )
        recordingStateCancellable = model.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self else { return }
                self.chromeBar.setRecording(isRecording)
                if isRecording && !self.isInFullscreen {
                    self.hideWorkItem?.cancel()
                    self.setChromeVisible(true)
                } else {
                    self.evaluateRevealZone()
                }
            }
        captureCueCancellable = model.$captureCue
            .receive(on: RunLoop.main)
            .sink { [weak self] cue in
                guard let cue else { return }
                self?.showCaptureCue(cue)
            }
        chromeBar.onClose = { NSApplication.shared.terminate(nil) }
        chromeBar.onMinimize = { [weak self] in self?.window?.miniaturize(nil) }
        chromeBar.onZoom = { [weak self] in self?.toggleFullScreenFromChrome() }
        chromeBar.chromeHeight = Self.toolbarBarHeight
        chromeBar.setControlsVisible(false)
        chromeBar.setBarBackgroundVisible(true, animated: false)
        chromeVisible = false
        chromeBar.onDragStateChange = { [weak self] isDragging in
            self?.setChromeDragging(isDragging)
        }
        chromeBar.onDragMouseDown = { [weak self] event in
            self?.dragWindowFromChrome(with: event)
        }
        chromeBar.onHoverChange = { [weak self] _ in self?.evaluateRevealZone() }

        // The toolbar lives in its own borderless child window floating above
        // the phone — not inside this content view.
        installToolbarWindow(parent: window)

        let renderTopConstraint = renderView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.visibleChromeRenderTopInset)
        let renderLeadingConstraint = renderView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: Self.screenLeftInset)
        let renderTrailingConstraint = renderView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -Self.screenRightInset)
        let renderBottomConstraint = renderView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -Self.screenBottomInset)
        self.renderTopConstraint = renderTopConstraint
        self.renderLeadingConstraint = renderLeadingConstraint
        self.renderTrailingConstraint = renderTrailingConstraint
        self.renderBottomConstraint = renderBottomConstraint
        NSLayoutConstraint.activate([
            renderTopConstraint,
            renderLeadingConstraint,
            renderTrailingConstraint,
            renderBottomConstraint
        ])
        applyScaledRenderInsets()

        window.contentView = rootView
        window.makeFirstResponder(renderView)

        renderView.onMouseMoved = { [weak self] event in
            self?.handleRenderMouseMoved(event)
        }
        renderView.onPointerEvent = { [weak self] event in
            self?.session?.forwardPointerEvent(event, in: self?.renderView ?? MirrorRenderView())
        }
        renderView.onKeyEvent = { [weak self] event in
            guard self?.model.keyboardInputEnabled ?? true else { return }
            self?.session?.forwardKeyEvent(event)
        }
        renderView.onDropFiles = { [weak self] urls in
            self?.model.handleDroppedFiles(urls)
        }
    }

    // MARK: - Hover

    private func applyNormalShellAppearance() {
        guard !isInFullscreen else { return }
        rootView.layer?.backgroundColor = Self.normalShellColor(for: rootView)
        rootView.layer?.borderColor = Self.shellBorderColor(for: rootView)
    }

    private func showCaptureCue(_ cue: AppModel.CaptureCue) {
        activeCaptureCueView?.removeFromSuperview()

        let cueView = MirrorCaptureCueView(cue: cue)
        rootView.addSubview(cueView)
        activeCaptureCueView = cueView

        NSLayoutConstraint.activate([
            cueView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            cueView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 18),
        ])

        cueView.alphaValue = 0
        cueView.layer?.transform = CATransform3DMakeScale(0.94, 0.94, 1)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            cueView.animator().alphaValue = 1
            cueView.layer?.transform = CATransform3DIdentity
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self, weak cueView] in
            guard let self, let cueView, self.activeCaptureCueView === cueView else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                cueView.animator().alphaValue = 0
            } completionHandler: { [weak self, weak cueView] in
                Task { @MainActor [weak self, weak cueView] in
                    guard let self, let cueView, self.activeCaptureCueView === cueView else { return }
                    cueView.removeFromSuperview()
                    self.activeCaptureCueView = nil
                }
            }
        }
    }

    private func handleRenderMouseMoved(_ event: NSEvent) {
        evaluateRevealZone()
    }

    // MARK: - Floating toolbar window

    private func installToolbarWindow(parent: NSWindow) {
        // The chrome bar becomes this window's content view, so let AppKit drive
        // its frame directly instead of Auto Layout.
        chromeBar.translatesAutoresizingMaskIntoConstraints = true
        chromeBar.autoresizingMask = [.width, .height]

        let toolbar = MirrorToolbarWindow(
            contentRect: NSRect(x: 0, y: 0, width: parent.frame.width, height: Self.toolbarBarHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        toolbar.isOpaque = false
        toolbar.backgroundColor = .clear
        toolbar.hasShadow = true
        toolbar.level = .normal
        toolbar.ignoresMouseEvents = false
        toolbar.contentView = chromeBar
        toolbar.alphaValue = 0
        parent.addChildWindow(toolbar, ordered: .above)
        toolbarWindow = toolbar
        repositionToolbarWindow()
        startRevealMonitoring()
    }

    private func repositionToolbarWindow() {
        guard let window, let toolbar = toolbarWindow else { return }
        let frame = window.frame
        var originY = frame.maxY + Self.toolbarGap
        if let visible = window.screen?.visibleFrame,
           originY + Self.toolbarBarHeight > visible.maxY {
            // Window is near the menu bar — there's no room above, so tuck the
            // bar against the very top of the phone rather than off-screen.
            originY = frame.maxY - Self.toolbarBarHeight
        }
        toolbar.setFrame(
            NSRect(x: frame.minX, y: originY, width: frame.width, height: Self.toolbarBarHeight),
            display: true
        )
    }

    private func startRevealMonitoring() {
        guard revealMonitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] event in
            self?.evaluateRevealZone()
            return event
        }) {
            revealMonitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] _ in
            self?.evaluateRevealZone()
        }) {
            revealMonitors.append(global)
        }
    }

    private func stopRevealMonitoring() {
        for monitor in revealMonitors {
            NSEvent.removeMonitor(monitor)
        }
        revealMonitors.removeAll()
    }

    /// The reveal zone is the band directly **above** the mirror window (plus the
    /// floating bar's own frame) — never over the phone's own content.
    private func revealZoneContains(_ point: NSPoint) -> Bool {
        guard let window, let toolbar = toolbarWindow else { return false }
        let frame = window.frame
        let zone = NSRect(
            x: frame.minX,
            y: frame.maxY,
            width: frame.width,
            height: Self.toolbarGap + Self.toolbarBarHeight + Self.toolbarRevealSlop
        )
        return zone.contains(point) || toolbar.frame.contains(point)
    }

    private func evaluateRevealZone() {
        guard !isInFullscreen else {
            hideChromeImmediately()
            return
        }
        guard !model.isRecording else {
            hideWorkItem?.cancel()
            setChromeVisible(true)
            return
        }
        if revealZoneContains(NSEvent.mouseLocation) {
            isPointerInTopZone = true
            hideWorkItem?.cancel()
            setChromeVisible(true)
        } else {
            isPointerInTopZone = false
            scheduleHide()
        }
    }

    // MARK: - Testing accessors

    var isChromeVisibleForTesting: Bool {
        chromeVisible
    }

    var isChromeBarHiddenForTesting: Bool {
        !chromeVisible
    }

    var isChromeBarBackgroundVisibleForTesting: Bool {
        chromeVisible
    }

    var isToolbarWindowVisibleForTesting: Bool {
        chromeVisible
    }

    var toolbarWindowForTesting: NSWindow? {
        toolbarWindow
    }

    var chromeBarForTesting: MirrorChromeBar {
        chromeBar
    }

    var renderTopInsetForTesting: CGFloat {
        renderTopConstraint?.constant ?? 0
    }

    var chromeHeightForTesting: CGFloat {
        Self.toolbarBarHeight
    }

    var renderBottomInsetForTesting: CGFloat {
        abs(renderBottomConstraint?.constant ?? 0)
    }

    var shellCornerRadiusForTesting: CGFloat {
        rootView.layer?.cornerRadius ?? 0
    }

    var isFullscreenChromeSuppressedForTesting: Bool {
        isInFullscreen
    }

    /// Drives reveal/hide as if the cursor entered or left the zone above the
    /// window — used by tests that can't position a real cursor.
    func simulateRevealZoneHover(_ inside: Bool) {
        if inside {
            isPointerInTopZone = true
            hideWorkItem?.cancel()
            setChromeVisible(true)
        } else {
            isPointerInTopZone = false
            setChromeVisible(false)
        }
    }

    private func scheduleHide() {
        guard !model.isRecording else {
            hideWorkItem?.cancel()
            setChromeVisible(true)
            return
        }
        guard !isDraggingChrome, !isPointerInTopZone else {
            isPointerInTopZone = true
            return
        }
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isDraggingChrome else { return }
            if self.isPointerInTopZone {
                self.isPointerInTopZone = true
                return
            }
            self.setChromeVisible(false)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chromeHideDelay, execute: workItem)
    }

    private func setChromeVisible(_ visible: Bool) {
        guard chromeVisible != visible else { return }
        chromeVisible = visible
        guard let toolbar = toolbarWindow else { return }

        if visible {
            repositionToolbarWindow()
            chromeBar.setControlsVisible(true)
            toolbar.orderFront(nil)
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? MirrorChromeBar.barRevealDuration : MirrorChromeBar.barHideDuration
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
            toolbar.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !self.chromeVisible {
                    self.chromeBar.setControlsVisible(false)
                }
            }
        })
    }

    private func hideChromeImmediately() {
        hideWorkItem?.cancel()
        chromeVisible = false
        isPointerInTopZone = false
        toolbarWindow?.alphaValue = 0
        chromeBar.setControlsVisible(false)
    }

    private func toggleFullScreenFromChrome() {
        guard let window else { return }
        hideChromeImmediately()
        captureNormalWindowFrameBeforeFullscreen(from: window)
        setFullscreenChromeSuppressed(true)
        window.toggleFullScreen(nil)
    }

    private func captureNormalWindowFrameBeforeFullscreen(from window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !isEffectivelyFullscreen(window) else { return }
        normalWindowFrameBeforeFullscreen = window.frame
    }

    private func restoreNormalWindowFrameAfterFullscreenIfNeeded(animated: Bool) {
        guard let window, let normalFrame = normalWindowFrameBeforeFullscreen else { return }
        normalWindowFrameBeforeFullscreen = nil

        let alreadyRestored = abs(window.frame.minX - normalFrame.minX) < 1
            && abs(window.frame.minY - normalFrame.minY) < 1
            && abs(window.frame.width - normalFrame.width) < 1
            && abs(window.frame.height - normalFrame.height) < 1
        guard !alreadyRestored else { return }

        window.setFrame(normalFrame, display: true, animate: animated)
    }

    private func updateFullscreenPresentationIfNeeded() {
        guard let window else { return }
        let shouldSuppress = window.styleMask.contains(.fullScreen)
            || isEffectivelyFullscreen(window)
        if shouldSuppress != isInFullscreen {
            setFullscreenChromeSuppressed(shouldSuppress)
        }
    }

    private func isEffectivelyFullscreen(_ window: NSWindow) -> Bool {
        guard let screen = window.screen else { return false }
        let frame = window.frame
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let widthMatches = abs(frame.width - screenFrame.width) <= 2
        let heightMatchesScreen = abs(frame.height - screenFrame.height) <= 2
        let heightMatchesVisible = abs(frame.height - visibleFrame.height) <= 2
        return widthMatches && (heightMatchesScreen || heightMatchesVisible)
    }

    private func setFullscreenChromeSuppressed(_ suppressed: Bool) {
        guard isInFullscreen != suppressed else { return }
        isInFullscreen = suppressed
        rootView.chromeRevealEnabled = !suppressed

        if suppressed {
            if let window {
                captureNormalWindowFrameBeforeFullscreen(from: window)
            }
            hideChromeImmediately()
            stopRevealMonitoring()
            toolbarWindow?.orderOut(nil)
            window?.backgroundColor = .black
            rootView.layer?.cornerRadius = 0
            rootView.layer?.backgroundColor = NSColor.black.cgColor
            rootView.layer?.borderWidth = 0
            renderView.cornerRadius = 0
            renderTopConstraint?.constant = 0
            renderLeadingConstraint?.constant = 0
            renderTrailingConstraint?.constant = 0
            renderBottomConstraint?.constant = 0
            window?.contentAspectRatio = .zero
            window?.minSize = NSSize(width: 1, height: 1)
            window?.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            window?.backgroundColor = .clear
            chromeBar.setControlsVisible(false)
            chromeBar.setBarBackgroundVisible(true, animated: false)
            rootView.layer?.cornerRadius = Self.cornerRadius
            rootView.layer?.backgroundColor = Self.normalShellColor(for: rootView)
            rootView.layer?.borderColor = Self.shellBorderColor(for: rootView)
            rootView.layer?.borderWidth = MirrorShellStyle.borderWidth
            applyScaledChromeHeight()
            applyScaledRenderInsets()
            if let window, let aspect = mirrorAspect {
                let contentHeight = max(1, window.frame.height - Self.verticalShellInset)
                let outerWidth = contentHeight * aspect + Self.horizontalShellInset
                window.contentAspectRatio = NSSize(width: outerWidth, height: window.frame.height)
                applyWindowSizeLimits(to: window, aspect: aspect)
            }
            if let window, let toolbar = toolbarWindow {
                window.addChildWindow(toolbar, ordered: .above)
            }
            repositionToolbarWindow()
            startRevealMonitoring()
        }

        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
        renderView.updateVideoLayerFrame()
    }

    func setFullscreenChromeSuppressedForTesting(_ suppressed: Bool) {
        setFullscreenChromeSuppressed(suppressed)
    }

    private func dragWindowFromChrome(with event: NSEvent) {
        guard let window else { return }
        setChromeDragging(true)
        defer { setChromeDragging(false) }

        // The mouse-down originates in the detached toolbar window, so a
        // cross-window `performDrag` is unreliable. Track the drag explicitly
        // and move the mirror window (its child toolbar follows automatically).
        let startMouse = NSEvent.mouseLocation
        let startOrigin = window.frame.origin
        trackingLoop: while true {
            guard let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }

            switch next.type {
            case .leftMouseUp:
                break trackingLoop
            default:
                let current = NSEvent.mouseLocation
                window.setFrameOrigin(NSPoint(
                    x: startOrigin.x + (current.x - startMouse.x),
                    y: startOrigin.y + (current.y - startMouse.y)
                ))
                repositionToolbarWindow()
            }
        }
    }

    private func setChromeDragging(_ isDragging: Bool) {
        isDraggingChrome = isDragging
        if isDragging {
            hideWorkItem?.cancel()
            setChromeVisible(true)
        } else {
            scheduleHide()
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        hideWorkItem?.cancel()
        stopRevealMonitoring()
        if let window, let toolbar = toolbarWindow {
            window.removeChildWindow(toolbar)
            toolbar.orderOut(nil)
        }
        toolbarWindow = nil
        session?.stop()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !isInFullscreen else { return frameSize }
        guard let mirrorAspect, mirrorAspect > 0, frameSize.width > 0 else {
            return frameSize
        }

        let insets = Self.measuredFrameInsets(for: sender)
        let proposedContentSize = NSSize(
            width: max(1, frameSize.width - insets.width),
            height: max(1, frameSize.height - insets.height)
        )
        let constrainedContentSize = NSSize(
            width: proposedContentSize.width,
            height: max(1, proposedContentSize.width - Self.horizontalShellInset) / mirrorAspect + Self.verticalShellInset
        )
        return NSSize(
            width: constrainedContentSize.width + insets.width,
            height: constrainedContentSize.height + insets.height
        )
    }

    func windowDidMove(_ notification: Notification) {
        updateFullscreenPresentationIfNeeded()
        repositionToolbarWindow()
    }

    func windowDidResize(_ notification: Notification) {
        updateFullscreenPresentationIfNeeded()
        applyScaledRenderInsets()
        rootView.layoutSubtreeIfNeeded()
        renderView.updateVideoLayerFrame()
        repositionToolbarWindow()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window {
            captureNormalWindowFrameBeforeFullscreen(from: window)
        }
        setFullscreenChromeSuppressed(true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window, let screenFrame = window.screen?.frame else { return }
        window.setFrame(screenFrame, display: true, animate: false)
        rootView.layoutSubtreeIfNeeded()
        renderView.updateVideoLayerFrame()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        hideChromeImmediately()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        setFullscreenChromeSuppressed(false)
        restoreNormalWindowFrameAfterFullscreenIfNeeded(animated: true)
    }
}

private final class MirrorContentWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless child window that hosts the floating toolbar above the mirror.
/// It never becomes key so clicking its buttons doesn't steal focus from the
/// mirror, and it carries its own drop shadow as a detached bar.
final class MirrorToolbarWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Root container

/// Root view — rounded mask, cursor tracking for chrome reveal.
final class MirrorRootView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onAppearanceChange: (() -> Void)?
    var chromeRevealEnabled = true
    var chromeActivationHeight = MirrorContentWindowController.chromeHeight
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { update(with: event) }
    override func mouseEntered(with event: NSEvent) { update(with: event) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    private func update(with event: NSEvent) {
        guard chromeRevealEnabled else {
            onHoverChange?(false)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let toolbarZoneMinY = bounds.height - chromeActivationHeight
        onHoverChange?(point.y > toolbarZoneMinY)
    }
}

// MARK: - Capture cue

private final class MirrorCaptureCueView: NSView {
    init(cue: AppModel.CaptureCue) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        layer?.cornerRadius = 8
        layer?.setValue("continuous", forKey: "cornerCurve")
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = NSSize(width: 0, height: -3)

        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: cue.symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        imageView.contentTintColor = cue.kind == .recordingStarted ? .systemRed : .white
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: cue.title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [imageView, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            widthAnchor.constraint(lessThanOrEqualToConstant: 240),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Chrome bar

/// Full-width macOS-style chrome that occupies a separate top band on hover.
/// Traffic lights at the left, the device-name title just inside them, and the
/// screenshot/recording actions at the trailing edge.
/// Background is a solid default AppKit surface so desktop content never bleeds through.
final class MirrorChromeBar: NSView {
    /// How small the bar shrinks when hidden. A more pronounced ratio makes
    /// the growing effect actually read on screen.
    static let barHiddenScale: CGFloat = 0.9
    /// Reveal is slightly longer than hide so the bar "lands" into place;
    /// hide is a hair quicker so the chrome doesn't overstay its welcome.
    /// Both stay short (≈200–300ms) so the motion feels responsive, not sluggish.
    static let barRevealDuration: CFTimeInterval = 0.30
    static let barHideDuration: CFTimeInterval = 0.20

    /// `cubic-bezier(0.16, 1, 0.3, 1)` — "ease-out-expo", the velvet curve
    /// many Apple-style sheet/popover entrances use. Front-loaded velocity
    /// that decelerates into a soft stop, so the bar feels like it gently
    /// lands into position.
    static let revealTiming = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    /// `cubic-bezier(0.5, 0, 0.75, 0)` — gentle ease-in that accelerates as
    /// it disappears, so the exit feels graceful rather than abrupt.
    static let hideTiming = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)

    private let backgroundView = NSView()
    private let dragArea = MirrorWindowDragArea()
    private let trafficLights = MirrorTrafficLights()
    var onDragStateChange: ((Bool) -> Void)?
    var onDragMouseDown: ((NSEvent) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// Window controls, forwarded to the in-bar traffic lights.
    var onClose: (() -> Void)? {
        get { trafficLights.onClose } set { trafficLights.onClose = newValue }
    }
    var onMinimize: (() -> Void)? {
        get { trafficLights.onMinimize } set { trafficLights.onMinimize = newValue }
    }
    var onZoom: (() -> Void)? {
        get { trafficLights.onZoom } set { trafficLights.onZoom = newValue }
    }
    private var trackingArea: NSTrackingArea?
    private var trafficLightsLeadingConstraint: NSLayoutConstraint?
    private var rightStackTrailingConstraint: NSLayoutConstraint?
    private static let horizontalPadding: CGFloat = 8
    /// Corner radius of the detached floating bar.
    private static let barCornerRadius: CGFloat = 9

    private let titleLabel = MirrorChromeTitleLabel(labelWithString: "")
    private let homeBtn = MirrorChromeOutlineButton(
        resource: "chrome-home",
        accessibilityDescription: "Home"
    )
    private let recentAppsBtn = MirrorChromeOutlineButton(
        symbol: "rectangle.stack",
        accessibilityDescription: "Recent apps"
    )
    private let recordingBtn = MirrorChromeOutlineButton(
        resource: "chrome-record",
        accessibilityDescription: "Screen recording"
    )
    private let screenshotBtn = MirrorChromeOutlineButton(
        resource: "chrome-screenshot",
        accessibilityDescription: "Screenshot"
    )
    private let rightStack: NSStackView
    private var isRecording = false {
        didSet {
            if isRecording {
                recordingBtn.setSymbol("stop.circle.fill")
            } else {
                recordingBtn.setResource("chrome-record")
            }
            recordingBtn.isActive = isRecording
            recordingBtn.toolTip = isRecording ? "Stop screen recording" : "Start screen recording"
        }
    }
    var chromeHeight: CGFloat = MirrorContentWindowController.chromeHeight {
        didSet {
            homeBtn.chromeScale = chromeScale
            recentAppsBtn.chromeScale = chromeScale
            recordingBtn.chromeScale = chromeScale
            screenshotBtn.chromeScale = chromeScale
        }
    }

    private var chromeScale: CGFloat {
        min(
            MirrorContentWindowController.maximumChromeScale,
            max(1, chromeHeight / MirrorContentWindowController.chromeHeight)
        )
    }

    override init(frame frameRect: NSRect) {
        rightStack = NSStackView(views: [recordingBtn, screenshotBtn, homeBtn, recentAppsBtn])
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    func configure(
        deviceName: String,
        onHome: @escaping () -> Void,
        onRecentApps: @escaping () -> Void,
        onScreenshot: @escaping () -> Void,
        onRecordingToggle: @escaping () -> Void
    ) {
        titleLabel.stringValue = deviceName
        homeBtn.toolTip = "Go to Android home"
        homeBtn.action = onHome
        homeBtn.minimumActionInterval = 0.35
        recentAppsBtn.toolTip = "Show Android recent apps"
        recentAppsBtn.action = onRecentApps
        recentAppsBtn.minimumActionInterval = 0.35
        screenshotBtn.toolTip = "Save screenshot to Downloads"
        screenshotBtn.action = onScreenshot
        recordingBtn.toolTip = "Start screen recording"
        recordingBtn.action = onRecordingToggle
    }

    func setRecording(_ isRecording: Bool) {
        self.isRecording = isRecording
    }

    /// Updates the toolbar title (device name) shown beside the traffic lights.
    func setDeviceName(_ name: String) {
        titleLabel.stringValue = name
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        backgroundView.wantsLayer = true
        applyAppearance()
        backgroundView.layer?.cornerRadius = Self.barCornerRadius
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.setValue("continuous", forKey: "cornerCurve")
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        // The toolbar strip stays visible in normal windowed mode. Pinning the
        // anchor point to dead center keeps background reveal/suppress
        // animations centered when fullscreen hides it.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        backgroundView.layer?.opacity = 1
        backgroundView.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        // Right-side capture actions live at the trailing edge.
        rightStack.orientation = .horizontal
        rightStack.spacing = 6
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rightStack)

        // Drag zone fills the gap between lights and buttons.
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        dragArea.onDragStateChange = { [weak self] isDragging in
            self?.onDragStateChange?(isDragging)
        }
        dragArea.onDragMouseDown = { [weak self] event in
            self?.onDragMouseDown?(event)
        }
        addSubview(dragArea)

        // Traffic lights at the leading edge, just like a macOS title bar.
        trafficLights.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trafficLights)
        let trafficLightsLeadingConstraint = trafficLights.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: Self.horizontalPadding
        )
        self.trafficLightsLeadingConstraint = trafficLightsLeadingConstraint

        // Window title (device name), shown leading just after the traffic
        // lights — the macOS title-bar look. Non-interactive so window drags
        // pass straight through to the drag area beneath it.
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let rightStackTrailingConstraint = rightStack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Self.horizontalPadding
        )
        self.rightStackTrailingConstraint = rightStackTrailingConstraint

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            rightStackTrailingConstraint,
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            trafficLightsLeadingConstraint,
            trafficLights.centerYAnchor.constraint(equalTo: centerYAnchor),

            dragArea.leadingAnchor.constraint(equalTo: trafficLights.trailingAnchor, constant: 10),
            dragArea.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -8),
            dragArea.topAnchor.constraint(equalTo: topAnchor),
            dragArea.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: dragArea.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),
        ])
    }

    func setControlsVisible(_ visible: Bool) {
        trafficLights.isHidden = !visible
        titleLabel.isHidden = !visible
        recentAppsBtn.isHidden = !visible
        recordingBtn.isHidden = !visible
        screenshotBtn.isHidden = !visible
        homeBtn.isHidden = !visible
    }

    func setTrailingActionsVisible(_ visible: Bool) {
        recentAppsBtn.isHidden = !visible
        recordingBtn.isHidden = !visible
        screenshotBtn.isHidden = !visible
        homeBtn.isHidden = !visible
    }

    var isBackgroundVisibleForTesting: Bool {
        (backgroundView.layer?.opacity ?? 0) > 0.5
    }

    var horizontalPaddingForTesting: CGFloat {
        Self.horizontalPadding
    }

    var trafficLightLeadingPaddingForTesting: CGFloat {
        trafficLightsLeadingConstraint?.constant ?? 0
    }

    var trailingActionsPaddingForTesting: CGFloat {
        abs(rightStackTrailingConstraint?.constant ?? 0)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard !bounds.contains(point) else {
            onHoverChange?(true)
            return
        }
        onHoverChange?(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        var resolvedColor = MirrorShellStyle.backgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = (MirrorShellStyle.backgroundColor.usingColorSpace(.deviceRGB) ?? MirrorShellStyle.backgroundColor).cgColor
        }
        backgroundView.layer?.backgroundColor = resolvedColor
    }

    /// Reveals or hides the bar's solid background with an ultra-smooth
    /// growing-scale + fade animation. The transform and opacity changes
    /// share one CATransaction so they stay perfectly synchronized, and the
    /// custom cubic-bezier curves give it that velvety, organic feel. If a
    /// previous animation is still in flight, Core Animation interpolates
    /// from the current presentation values, so rapid hover-in/out reads
    /// fluidly with no snap.
    func setBarBackgroundVisible(_ visible: Bool, animated: Bool = true) {
        CATransaction.begin()
        if !animated {
            CATransaction.setDisableActions(true)
        }
        CATransaction.setAnimationDuration(animated ? (visible ? Self.barRevealDuration : Self.barHideDuration) : 0)
        CATransaction.setAnimationTimingFunction(visible ? Self.revealTiming : Self.hideTiming)
        backgroundView.layer?.transform = visible
            ? CATransform3DIdentity
            : CATransform3DMakeScale(Self.barHiddenScale, Self.barHiddenScale, 1)
        backgroundView.layer?.opacity = visible ? 1 : 0
        CATransaction.commit()
    }
}

// MARK: - Traffic lights

/// macOS-style traffic-light cluster (close / minimize / zoom) for the detached
/// floating toolbar. Because the bar is a separate window, the native window
/// buttons can't live here, so these are custom dots wired to window actions.
/// The glyphs (✕ − ⤢) appear only while the cluster is hovered, matching macOS.
final class MirrorTrafficLights: NSView {
    private let closeButton = MirrorTrafficLightButton(kind: .close)
    private let minimizeButton = MirrorTrafficLightButton(kind: .minimize)
    private let zoomButton = MirrorTrafficLightButton(kind: .zoom)
    private var trackingArea: NSTrackingArea?

    var onClose: (() -> Void)? {
        get { closeButton.action } set { closeButton.action = newValue }
    }
    var onMinimize: (() -> Void)? {
        get { minimizeButton.action } set { minimizeButton.action = newValue }
    }
    var onZoom: (() -> Void)? {
        get { zoomButton.action } set { zoomButton.action = newValue }
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [closeButton, minimizeButton, zoomButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setSymbolsVisible(true) }
    override func mouseExited(with event: NSEvent) { setSymbolsVisible(false) }

    private func setSymbolsVisible(_ visible: Bool) {
        closeButton.setSymbolVisible(visible)
        minimizeButton.setSymbolVisible(visible)
        zoomButton.setSymbolVisible(visible)
    }
}

/// A single traffic-light dot drawn in code and wired to a window action.
final class MirrorTrafficLightButton: NSView {
    enum Kind { case close, minimize, zoom }

    private let kind: Kind
    private let glyph = NSImageView()
    var action: (() -> Void)?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = 6
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = fillColor.cgColor
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 12),
        ])

        glyph.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        glyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 7, weight: .heavy)
        glyph.contentTintColor = NSColor.black.withAlphaComponent(0.55)
        glyph.isHidden = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSymbolVisible(_ visible: Bool) {
        glyph.isHidden = !visible
    }

    private var fillColor: NSColor {
        switch kind {
        case .close: return NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1)
        case .minimize: return NSColor(red: 1.0, green: 0.74, blue: 0.17, alpha: 1)
        case .zoom: return NSColor(red: 0.15, green: 0.78, blue: 0.25, alpha: 1)
        }
    }

    private var symbolName: String {
        switch kind {
        case .close: return "xmark"
        case .minimize: return "minus"
        case .zoom: return "arrow.up.left.and.arrow.down.right"
        }
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = (fillColor.blended(withFraction: 0.25, of: .black) ?? fillColor).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = fillColor.cgColor
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { action?() }
    }
}

// MARK: - Title label

/// Non-interactive title label (device name) for the chrome bar. Returns `nil`
/// from `hitTest` so window-drag gestures pass through to the drag area below.
private final class MirrorChromeTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Outline icon button

/// Small outline-style button for the right side of the chrome bar.
final class MirrorChromeOutlineButton: NSView {
    private enum IconSource: Equatable {
        case system(String)
        case resource(String)
    }

    private let imageView = NSImageView()
    private var iconSource: IconSource
    private var lastActionTime: TimeInterval = 0
    var action: (() -> Void)?
    var minimumActionInterval: TimeInterval = 0
    var chromeScale: CGFloat = 1 {
        didSet { needsLayout = true }
    }
    var isActive = false {
        didSet { applyTint() }
    }

    init(symbol: String, accessibilityDescription: String? = nil) {
        iconSource = .system(symbol)
        super.init(frame: .zero)
        setup(accessibilityDescription: accessibilityDescription)
    }

    init(resource: String, accessibilityDescription: String? = nil) {
        iconSource = .resource(resource)
        super.init(frame: .zero)
        setup(accessibilityDescription: accessibilityDescription)
    }

    private func setup(accessibilityDescription: String?) {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        layer?.cornerRadius = 6
        layer?.setValue("continuous", forKey: "cornerCurve")

        imageView.image = Self.image(for: iconSource, accessibilityDescription: accessibilityDescription)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        applyTint()
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let iconSize = min(18, max(14, 14 * chromeScale))
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
    }

    func setSymbol(_ symbol: String) {
        setIconSource(.system(symbol))
    }

    func setResource(_ resource: String) {
        setIconSource(.resource(resource))
    }

    private func setIconSource(_ source: IconSource) {
        guard iconSource != source else { return }
        iconSource = source
        imageView.image = Self.image(
            for: source,
            accessibilityDescription: imageView.image?.accessibilityDescription
        )
        applyTint()
        needsLayout = true
    }

    private static func image(for source: IconSource, accessibilityDescription: String?) -> NSImage? {
        switch source {
        case .system(let symbol):
            return NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
        case .resource(let name):
            guard let url = Bundle.module.url(forResource: name, withExtension: "svg") else {
                return nil
            }
            let image = NSImage(contentsOf: url)
            image?.isTemplate = true
            return image
        }
    }

    private func applyTint() {
        imageView.contentTintColor = isActive
            ? NSColor.systemRed
            : NSColor.white.withAlphaComponent(0.72)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea(_:))
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = nil
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard minimumActionInterval <= 0 || now - lastActionTime >= minimumActionInterval else { return }
        lastActionTime = now
        action?()
    }
}

// MARK: - Drag area

/// Forwards mouseDown to NSWindow.performDrag — native in-process drag at display refresh rate.
final class MirrorWindowDragArea: NSView {
    var onDragStateChange: ((Bool) -> Void)?
    var onDragMouseDown: ((NSEvent) -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onDragStateChange?(true)
        defer { onDragStateChange?(false) }
        if let onDragMouseDown {
            onDragMouseDown(event)
        } else {
            window?.performDrag(with: event)
        }
    }
}

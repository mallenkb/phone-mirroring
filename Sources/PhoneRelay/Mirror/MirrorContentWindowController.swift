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
    private static weak var activeController: MirrorContentWindowController?

    static let cornerRadius: CGFloat = 34
    /// Standard macOS titlebar height. Anything larger and the AppKit chrome
    /// reads as a heavy banner instead of a window's title bar.
    static let chromeHeight: CGFloat = 28
    /// Compact windows keep the standard macOS titlebar height; large windows
    /// let the hover toolbar grow up to 60% taller so it stays readable.
    static let maximumChromeScale: CGFloat = 1.6
    static var maximumChromeHeight: CGFloat { chromeHeight * maximumChromeScale }
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
    static let chromeHideDelay: TimeInterval = 0.012
    static let chromeHideAnimationDuration: TimeInterval = 0.18
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

    nonisolated static func onboardingCornerRadius(
        visibleFrame: NSRect = NSRect(x: 0, y: 0, width: 390, height: 850)
    ) -> CGFloat {
        let minimumWindowHeight: CGFloat = 688
        let maximumScreenHeightRatio: CGFloat = 0.90
        let minimumCornerRadius: CGFloat = 24
        let maximumCornerRadius: CGFloat = 38
        let windowHeight = min(max(minimumWindowHeight, visibleFrame.height * 0.82), 720)
        let heightRange = max(1, visibleFrame.height * maximumScreenHeightRatio - minimumWindowHeight)
        let cornerScale = windowHeight <= minimumWindowHeight + 1
            ? 0
            : min(1, max(0, (windowHeight - minimumWindowHeight) / heightRange))
        return minimumCornerRadius
            + (maximumCornerRadius - minimumCornerRadius) * cornerScale
    }

    /// The detached toolbar floats in its own window above the phone.
    static let toolbarBarHeight: CGFloat = 38
    /// Vertical gap between the top of the mirror window and the floating bar.
    static let toolbarGap: CGFloat = 6
    /// Extra slack added to the reveal zone above the window so the bar is easy
    /// to summon without pixel-perfect aim.
    static let toolbarRevealSlop: CGFloat = 6
    static let toolbarAnimationOffset: CGFloat = 6

    var acceptsKeyboardInput: Bool {
        window?.isKeyWindow == true
    }

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
    private var toolbarAnimationGeneration = 0
    private var chromeVisible = false
    private var isDraggingChrome = false
    private var isPointerInTopZone = false
    private var isInFullscreen = false
    private var normalWindowFrameBeforeFullscreen: NSRect?
    private var mirrorAspect: CGFloat? = defaultMirrorAspect
    private let launchFrame: NSRect?
    private var hasUserMovedWindow = false
    private var isApplyingProgrammaticFrame = false
    private var captureCueCancellable: AnyCancellable?
    private var transferActivityCancellable: AnyCancellable?
    private var deviceTitleCancellable: AnyCancellable?
    private var alwaysOnTopCancellable: AnyCancellable?
    private var alwaysOnTopToolbarCancellable: AnyCancellable?
    private var recordingToolbarCancellable: AnyCancellable?
    private var appActivationObservers: [NSObjectProtocol] = []
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
        installAppActivationObservers()
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
        Self.closeSupersededMirrorWindows(keeping: self)
        Self.activeController = self
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
        setWindowFrame(frame, display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(renderView)
        updateFullscreenPresentationIfNeeded()
    }

    static func supersededMirrorWindows(
        in windows: [NSWindow],
        activeWindow: NSWindow?
    ) -> [NSWindow] {
        windows.filter { window in
            window !== activeWindow
                && !window.isMiniaturized
                && window is MirrorContentWindow
        }
    }

    private static func closeSupersededMirrorWindows(keeping controller: MirrorContentWindowController) {
        let activeWindow = controller.window
        let staleWindows = supersededMirrorWindows(in: NSApp.windows, activeWindow: activeWindow)
        guard !staleWindows.isEmpty else { return }
        Logger.log("Closing \(staleWindows.count) superseded mirror window(s) before showing the active mirror.")
        for window in staleWindows {
            window.delegate = nil
            window.childWindows?.forEach { child in
                child.delegate = nil
                child.close()
            }
            window.close()
        }
        if let active = activeController, active !== controller {
            active.window?.delegate = nil
            active.close()
        }
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

        let visible = Self.targetVisibleFrame(for: window, preferWindowScreen: true)
        let outerSize = Self.initialWrappedShellSize(
            for: NSSize(width: CGFloat(width), height: CGFloat(height)),
            visibleFrame: visible,
            maximumHeightBasis: Self.resolutionHeight(
                for: window.screen,
                fallbackVisibleFrame: visible
            )
        )
        window.contentAspectRatio = outerSize
        let newFrame: NSRect
        if hasUserMovedWindow || launchFrame != nil {
            let insets = Self.measuredFrameInsets(for: window)
            let frameSize = NSSize(
                width: outerSize.width + insets.width,
                height: outerSize.height + insets.height
            )
            newFrame = Self.frame(size: frameSize, centeredOn: window.frame.center)
        } else {
            let visible = Self.targetVisibleFrame(for: window, preferWindowScreen: true)
            newFrame = Self.centeredFrame(forContentSize: outerSize, in: visible, window: window)
        }
        Logger.log("MirrorContentWindow streamSize=\(width)x\(height) visible=\(visible) frame=\(newFrame)")
        setWindowFrame(newFrame, display: true, animate: false)
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
        window.title = model.mirrorWindowDeviceTitle
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
        setWindowFrame(targetFrame, display: true, animate: false)
        applyScaledRenderInsets()
    }

    private static func frame(size: NSSize, centeredOn center: NSPoint) -> NSRect {
        NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func setWindowFrame(_ frame: NSRect, display: Bool, animate: Bool) {
        guard let window else { return }
        isApplyingProgrammaticFrame = true
        window.setFrame(frame, display: display, animate: animate)
        isApplyingProgrammaticFrame = false
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
        renderView.setLoadingText(
            statusText: model.mirrorLoadingStatusText,
            deviceName: model.mirrorLoadingDeviceTitle
        )
        rootView.addSubview(renderView)

        chromeBar.configure(
            deviceName: model.mirrorWindowDeviceTitle,
            onHome: { [weak self] in self?.model.sendAndroidKey("KEYCODE_HOME") },
            onRecentApps: { [weak self] in self?.model.sendAndroidKey("KEYCODE_APP_SWITCH") },
            onScreenshot: { [weak self] in self?.model.takeScreenshot() },
            onStopRecording: { [weak self] in self?.model.toggleScreenRecording() }
        )
        captureCueCancellable = model.$captureCue
            .receive(on: RunLoop.main)
            .sink { [weak self] cue in
                guard let cue else { return }
                self?.showCaptureCue(cue)
            }
        transferActivityCancellable = model.$transferActivity
            .receive(on: RunLoop.main)
            .sink { [weak self] activity in
                guard let activity else {
                    self?.hideActiveStatusCue()
                    return
                }
                self?.showTransferActivity(activity)
            }
        chromeBar.onClose = { NSApplication.shared.terminate(nil) }
        chromeBar.onMinimize = { [weak self] in self?.miniaturizeFromChrome() }
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
        chromeBar.configureAlwaysOnTop(
            isEnabled: model.mirrorAlwaysOnTopEnabled,
            onToggle: { [weak model] in
                model?.toggleMirrorAlwaysOnTop()
            }
        )
        alwaysOnTopToolbarCancellable = model.$mirrorAlwaysOnTopEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.chromeBar.setAlwaysOnTopEnabled(enabled)
            }
        chromeBar.setRecordingActive(model.isRecording)
        recordingToolbarCancellable = model.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                self?.chromeBar.setRecordingActive(isRecording)
            }
        applyDeviceTitle()
        deviceTitleCancellable = model.$selectedDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyDeviceTitle()
            }

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
        applyAlwaysOnTop(model.mirrorAlwaysOnTopEnabled)
        alwaysOnTopCancellable = model.$mirrorAlwaysOnTopEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.applyAlwaysOnTop(enabled)
            }

        renderView.onMouseMoved = { [weak self] event in
            self?.handleRenderMouseMoved(event)
        }
        renderView.onPointerEvent = { [weak self] event in
            self?.session?.forwardPointerEvent(event, in: self?.renderView ?? MirrorRenderView())
        }
        renderView.onKeyEvent = { [weak self] event in
            guard self?.model.keyboardInputEnabled ?? true else { return }
            guard !MirrorSession.isVolumeKeyEvent(event) else { return }
            self?.session?.forwardKeyEvent(event)
        }
        renderView.onDropFiles = { [weak self] urls in
            self?.model.handleDroppedFiles(urls)
        }
    }

    private func applyDeviceTitle() {
        let deviceName = model.mirrorWindowDeviceTitle
        window?.title = deviceName
        toolbarWindow?.title = deviceName
        chromeBar.setDeviceName(deviceName)
        renderView.setLoadingText(
            statusText: model.mirrorLoadingStatusText,
            deviceName: model.mirrorLoadingDeviceTitle
        )
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

    private func showTransferActivity(_ activity: AppModel.TransferActivity) {
        activeCaptureCueView?.removeFromSuperview()

        let cueView = MirrorCaptureCueView(activity: activity)
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

        guard !activity.isInProgress else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self, weak cueView] in
            guard let self, let cueView, self.activeCaptureCueView === cueView else { return }
            self.hideActiveStatusCue()
        }
    }

    private func hideActiveStatusCue() {
        guard let cueView = activeCaptureCueView else { return }
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
        toolbar.ignoresMouseEvents = true
        toolbar.contentView = chromeBar
        toolbar.alphaValue = 0
        parent.addChildWindow(toolbar, ordered: .above)
        toolbarWindow = toolbar
        applyAlwaysOnTop(model.mirrorAlwaysOnTopEnabled)
        repositionToolbarWindow()
        startRevealMonitoring()
    }

    private func applyAlwaysOnTop(_ enabled: Bool) {
        let level: NSWindow.Level = enabled ? .floating : .normal
        window?.level = level
        toolbarWindow?.level = level
    }

    private func repositionToolbarWindow() {
        guard let window, let toolbar = toolbarWindow else { return }
        toolbar.setFrame(toolbarVisibleFrame(for: window), display: true)
    }

    private func toolbarVisibleFrame(for window: NSWindow) -> NSRect {
        let frame = window.frame
        var originY = frame.maxY + Self.toolbarGap
        if let visible = window.screen?.visibleFrame,
           originY + Self.toolbarBarHeight > visible.maxY {
            // Window is near the menu bar — there's no room above, so tuck the
            // bar against the very top of the phone rather than off-screen.
            originY = frame.maxY - Self.toolbarBarHeight
        }
        return NSRect(x: frame.minX, y: originY, width: frame.width, height: Self.toolbarBarHeight)
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
        guard let window else { return false }
        let frame = window.frame
        let zone = NSRect(
            x: frame.minX,
            y: frame.maxY,
            width: frame.width,
            height: Self.toolbarGap + Self.toolbarBarHeight + Self.toolbarRevealSlop
        )
        return zone.contains(point) || toolbarVisibleFrame(for: window).contains(point)
    }

    private func evaluateRevealZone() {
        guard window?.isMiniaturized != true, window?.isVisible == true else {
            hideChromeImmediately(orderOutToolbar: true)
            return
        }
        guard NSApp.isActive else {
            hideChromeImmediately(orderOutToolbar: true)
            return
        }
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

    var toolbarIgnoresMouseEventsForTesting: Bool {
        toolbarWindow?.ignoresMouseEvents ?? false
    }

    var toolbarIsVisibleForTesting: Bool {
        toolbarWindow?.isVisible ?? false
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

    func simulateAppResignActiveForTesting() {
        hideChromeImmediately(orderOutToolbar: true)
    }

    func simulateWindowWillMiniaturizeForTesting() {
        windowWillMiniaturize(Notification(name: NSWindow.willMiniaturizeNotification, object: window))
    }

    func simulateWindowDidMiniaturizeForTesting() {
        windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification, object: window))
    }

    func simulateWindowDidDeminiaturizeForTesting() {
        windowDidDeminiaturize(Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
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
        guard !visible || (window?.isMiniaturized != true && window?.isVisible == true) else {
            hideChromeImmediately(orderOutToolbar: true)
            return
        }
        guard chromeVisible != visible else { return }
        chromeVisible = visible
        guard let toolbar = toolbarWindow else { return }

        // The bar floats in its own child window. Animating that window's
        // *frame* every step is what made the reveal feel choppy — per-frame
        // child-window repositioning never composites cleanly. So the window
        // now stays pinned at its on-screen position and the slide rides the
        // bar's layer instead: a GPU-composited transform that stays glassy and
        // stays interruptible, so darting the pointer in and out reads as a
        // single fluid motion rather than a snap. The fade is the window's
        // alpha, which also carries the drop shadow so it dissolves in step.
        let visibleFrame = window.map(toolbarVisibleFrame(for:)) ?? toolbar.frame
        toolbar.setFrame(visibleFrame, display: false)

        if visible {
            if toolbar.alphaValue <= 0.01 {
                // Coming from fully hidden: jump (no animation) to the tucked
                // pose so the spring below has somewhere to travel from rather
                // than popping in at full size.
                chromeBar.setBarRevealed(false, animated: false)
            }
            chromeBar.setControlsVisible(true)
            toolbar.ignoresMouseEvents = false
            toolbar.orderFront(nil)
        } else {
            toolbar.ignoresMouseEvents = true
        }

        // Geometry springs; opacity eases. Kicking the spring off alongside the
        // fade group (not inside it) keeps the two independent so the motion
        // settles on its own natural clock while the bar is already solid.
        chromeBar.setBarRevealed(visible, animated: true)

        toolbarAnimationGeneration += 1
        let animationGeneration = toolbarAnimationGeneration
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? MirrorChromeBar.barRevealDuration : Self.chromeHideAnimationDuration
            context.timingFunction = visible ? MirrorChromeBar.revealTiming : MirrorChromeBar.hideTiming
            toolbar.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.toolbarAnimationGeneration == animationGeneration else { return }
                if !self.chromeVisible {
                    self.chromeBar.setControlsVisible(false)
                }
            }
        })
    }

    private func hideChromeImmediately(orderOutToolbar: Bool = false) {
        hideWorkItem?.cancel()
        chromeVisible = false
        isPointerInTopZone = false
        toolbarWindow?.alphaValue = 0
        toolbarWindow?.ignoresMouseEvents = true
        if let window, let toolbarWindow {
            toolbarWindow.setFrame(toolbarVisibleFrame(for: window), display: false)
        }
        // Snap the layer back to its tucked pose with no animation so the next
        // reveal springs up cleanly from below.
        chromeBar.setBarRevealed(false, animated: false)
        if orderOutToolbar {
            toolbarWindow?.orderOut(nil)
        }
        chromeBar.setControlsVisible(false)
    }

    private func installAppActivationObservers() {
        let center = NotificationCenter.default
        appActivationObservers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let controller = self else { return }
            Task { @MainActor in
                controller.hideChromeImmediately(orderOutToolbar: true)
            }
        })
    }

    private func toggleFullScreenFromChrome() {
        guard let window else { return }
        hideChromeImmediately()
        captureNormalWindowFrameBeforeFullscreen(from: window)
        setFullscreenChromeSuppressed(true)
        window.toggleFullScreen(nil)
    }

    private func miniaturizeFromChrome() {
        guard let window else { return }
        prepareForMiniaturize()
        window.miniaturize(nil)
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
                hasUserMovedWindow = true
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        hideWorkItem?.cancel()
        stopRevealMonitoring()
        for observer in appActivationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        appActivationObservers.removeAll()
        if let window, let toolbar = toolbarWindow {
            window.removeChildWindow(toolbar)
            toolbar.orderOut(nil)
        }
        toolbarWindow = nil
        session?.stop()
    }

    func windowWillMiniaturize(_ notification: Notification) {
        prepareForMiniaturize()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        prepareForMiniaturize()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window else { return }
        if let toolbar = toolbarWindow {
            window.addChildWindow(toolbar, ordered: .above)
        }
        repositionToolbarWindow()
        startRevealMonitoring()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(renderView)
        renderView.updateVideoLayerFrame()
        evaluateRevealZone()
    }

    private func prepareForMiniaturize() {
        hideChromeImmediately(orderOutToolbar: true)
        hideActiveStatusCue()
        stopRevealMonitoring()
        if let window, let toolbar = toolbarWindow {
            window.removeChildWindow(toolbar)
            toolbar.orderOut(nil)
        }
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
        if !isApplyingProgrammaticFrame {
            hasUserMovedWindow = true
        }
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

    /// Tell AppKit to fill the whole screen during its own native zoom, so we
    /// never have to `setFrame` the window ourselves. Doing that manually (in
    /// `windowDidEnterFullScreen`) used to overwrite the window's remembered
    /// pre-fullscreen frame, which is exactly why exit then needed a second,
    /// visible restore animation — the part that looked like a hack.
    func window(_ window: NSWindow, willUseFullScreenContentSize proposedSize: NSSize) -> NSSize {
        window.screen?.frame.size ?? proposedSize
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window {
            captureNormalWindowFrameBeforeFullscreen(from: window)
        }
        setFullscreenChromeSuppressed(true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        // No manual setFrame — AppKit already sized us to the fullscreen space.
        // Just relayout the content to whatever size it gave us.
        rootView.layoutSubtreeIfNeeded()
        renderView.updateVideoLayerFrame()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        hideChromeImmediately()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        setFullscreenChromeSuppressed(false)
        // AppKit's native exit already animated back to the pre-fullscreen
        // frame, so this is just an instant snap-correct for the rare case it
        // lands a hair off. Animating it (as before) ran a second resize on top
        // of the native one — that double-animation was the hacky exit.
        restoreNormalWindowFrameAfterFullscreenIfNeeded(animated: false)
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}

private final class MirrorContentWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Borderless child window that hosts the floating toolbar above the mirror.
/// It may become key because AppKit can key child windows during ordering, but
/// it never becomes main so the mirror window remains the primary document.
final class MirrorToolbarWindow: NSWindow {
    override var canBecomeKey: Bool { true }
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
        let tintColor: NSColor = cue.kind == .recordingStarted ? .systemRed : .white
        super.init(frame: .zero)
        setup(title: cue.title, detail: nil, symbolName: cue.symbolName, tintColor: tintColor)
    }

    init(activity: AppModel.TransferActivity) {
        let tintColor: NSColor = activity.phase == .failed ? .systemYellow : .white
        super.init(frame: .zero)
        setup(
            title: activity.title,
            detail: activity.detail.isEmpty ? nil : activity.detail,
            symbolName: activity.symbolName,
            tintColor: tintColor
        )
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func setup(title: String, detail: String?, symbolName: String, tintColor: NSColor) {
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
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        imageView.contentTintColor = tintColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail

        let textViews: [NSView]
        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
            detailLabel.textColor = NSColor.white.withAlphaComponent(0.72)
            detailLabel.lineBreakMode = .byTruncatingMiddle

            let textStack = NSStackView(views: [titleLabel, detailLabel])
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 1
            textViews = [textStack]
        } else {
            textViews = [titleLabel]
        }

        let stack = NSStackView(views: [imageView] + textViews)
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
            widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }
}

// MARK: - Chrome bar

/// Full-width macOS-style chrome that occupies a separate top band on hover.
/// Traffic lights at the left, the device-name title just inside them, and the
/// screenshot/recording actions at the trailing edge.
/// Background is a solid default AppKit surface so desktop content never bleeds through.
final class MirrorChromeBar: NSView {
    enum TrailingActionsMode {
        case full
        case alwaysOnTopOnly
        case hidden
    }

    /// How small the bar shrinks when hidden. A more pronounced ratio makes
    /// the growing effect actually read on screen.
    static let barHiddenScale: CGFloat = 0.96
    static let barRevealDuration: CFTimeInterval = 0.28
    static let barHideDuration: CFTimeInterval = 0.18
    /// The opacity fade rides these curves; the *motion* (slide + grow) rides a
    /// spring (below). Apple eases opacity but springs geometry — so do we.
    /// `revealTiming` is an ease-out-expo so the bar is fully solid well before
    /// the spring finishes its last bit of settle.
    static let revealTiming = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    static let hideTiming = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
    /// Reveal/hide geometry springs rather than eases — the momentum-and-settle
    /// is what reads as Apple-grade rather than "a thing that fades in". Damping
    /// stays high so a *toolbar* feels composed (presence, no bouncy wobble);
    /// `response` is the perceptual duration, mirroring SwiftUI's
    /// `.spring(response:dampingFraction:)`.
    static let revealSpringResponse: CFTimeInterval = 0.42
    static let revealSpringDamping: CGFloat = 0.86
    static let hideSpringResponse: CFTimeInterval = 0.30
    static let hideSpringDamping: CGFloat = 1.0

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
    private var titleLeadingAfterTrafficLightsConstraint: NSLayoutConstraint?
    private static let leadingPadding: CGFloat = 12
    private static let titleLeadingAfterTrafficLights: CGFloat = 12
    private static let trailingPadding: CGFloat = (MirrorContentWindowController.toolbarBarHeight - MirrorChromeOutlineButton.touchHeight) / 2
    private var controlsVisible = false
    private var trailingActionsMode: TrailingActionsMode = .full
    private var recordingActive = false
    /// Corner radius of the detached floating bar.
    private static var barCornerRadius: CGFloat {
        MirrorContentWindowController.toolbarBarHeight / 2
    }
    static var controlHoverCornerRadius: CGFloat {
        // 18pt — the trailing action's hover sits one point inside the bar's own
        // rounded corner (bar radius is 19), so the pill cap reads as concentric
        // with the glass edge instead of a smaller rounded square floating in it.
        barCornerRadius - 1
    }

    private let titleLabel = MirrorChromeTitleLabel(labelWithString: "")
    private let homeBtn = MirrorChromeOutlineButton(
        resource: "chrome-home",
        accessibilityDescription: "Home"
    )
    private let recentAppsBtn = MirrorChromeOutlineButton(
        symbol: "rectangle.stack.fill",
        accessibilityDescription: "Recent apps",
        hoverCornerRadius: MirrorChromeBar.controlHoverCornerRadius,
        hoverLeadingCornerRadius: MirrorChromeOutlineButton.defaultHoverCornerRadius
    )
    private let screenshotBtn = MirrorChromeOutlineButton(
        resource: "chrome-screenshot",
        accessibilityDescription: "Screenshot"
    )
    private let alwaysOnTopBtn = MirrorChromeOutlineButton(
        symbol: "pin.fill",
        accessibilityDescription: "Pin mirror on top"
    )
    private let recordingPill = MirrorRecordingStatusPill()
    private let rightStack: NSStackView
    var chromeHeight: CGFloat = MirrorContentWindowController.chromeHeight {
        didSet {
            homeBtn.chromeScale = chromeScale
            recentAppsBtn.chromeScale = chromeScale
            screenshotBtn.chromeScale = chromeScale
            alwaysOnTopBtn.chromeScale = chromeScale
        }
    }

    private var chromeScale: CGFloat {
        min(
            MirrorContentWindowController.maximumChromeScale,
            max(1, chromeHeight / MirrorContentWindowController.chromeHeight)
        )
    }

    override init(frame frameRect: NSRect) {
        rightStack = NSStackView(views: [alwaysOnTopBtn, screenshotBtn, recordingPill, homeBtn, recentAppsBtn])
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
        onStopRecording: @escaping () -> Void
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
        recordingPill.toolTip = "Stop screen recording"
        recordingPill.action = onStopRecording
    }

    func configureAlwaysOnTop(isEnabled: Bool, onToggle: @escaping () -> Void) {
        alwaysOnTopBtn.action = onToggle
        alwaysOnTopBtn.minimumActionInterval = 0.2
        setAlwaysOnTopEnabled(isEnabled)
    }

    func setAlwaysOnTopEnabled(_ enabled: Bool) {
        alwaysOnTopBtn.setSymbol(enabled ? "pin.slash.fill" : "pin.fill")
        alwaysOnTopBtn.toolTip = enabled ? "Unpin mirror from top" : "Pin mirror on top"
        alwaysOnTopBtn.isActive = enabled
    }

    func setRecordingActive(_ active: Bool) {
        recordingActive = active
        recordingPill.setRecording(active)
        applyActionVisibility()
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
        rightStack.spacing = 0
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
            constant: Self.leadingPadding
        )
        self.trafficLightsLeadingConstraint = trafficLightsLeadingConstraint

        // Window title (device name), shown leading just after the traffic
        // lights — the macOS title-bar look. Non-interactive so window drags
        // pass straight through to the drag area beneath it.
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor.labelColor
        titleLabel.alignment = .left
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        let rightStackTrailingConstraint = rightStack.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -Self.trailingPadding
        )
        self.rightStackTrailingConstraint = rightStackTrailingConstraint
        let titleLeadingAfterTrafficLightsConstraint = dragArea.leadingAnchor.constraint(
            equalTo: trafficLights.trailingAnchor,
            constant: Self.titleLeadingAfterTrafficLights
        )
        self.titleLeadingAfterTrafficLightsConstraint = titleLeadingAfterTrafficLightsConstraint

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            rightStackTrailingConstraint,
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            trafficLightsLeadingConstraint,
            trafficLights.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLeadingAfterTrafficLightsConstraint,
            dragArea.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -8),
            dragArea.topAnchor.constraint(equalTo: topAnchor),
            dragArea.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: dragArea.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),
        ])
        updateTrailingActionHoverCorners()
    }

    func setControlsVisible(_ visible: Bool) {
        controlsVisible = visible
        trafficLights.isHidden = !visible
        titleLabel.isHidden = !visible
        applyActionVisibility()
    }

    private func applyActionVisibility() {
        guard controlsVisible, trailingActionsMode != .hidden else {
            alwaysOnTopBtn.isHidden = true
            screenshotBtn.isHidden = true
            recordingPill.isHidden = true
            homeBtn.isHidden = true
            recentAppsBtn.isHidden = true
            updateTrailingActionHoverCorners()
            return
        }
        guard trailingActionsMode == .full else {
            alwaysOnTopBtn.isHidden = false
            screenshotBtn.isHidden = true
            recordingPill.isHidden = true
            homeBtn.isHidden = true
            recentAppsBtn.isHidden = true
            updateTrailingActionHoverCorners()
            return
        }
        alwaysOnTopBtn.isHidden = recordingActive
        screenshotBtn.isHidden = recordingActive
        recordingPill.isHidden = !recordingActive
        homeBtn.isHidden = false
        recentAppsBtn.isHidden = recordingActive
        updateTrailingActionHoverCorners()
    }

    private func updateTrailingActionHoverCorners() {
        let actionButtons = [alwaysOnTopBtn, screenshotBtn, homeBtn, recentAppsBtn]
        for button in actionButtons {
            button.setHoverCornerRadius(MirrorChromeOutlineButton.defaultHoverCornerRadius)
        }
        rightmostActionButtonForCurrentMode()?.setHoverCornerRadius(
            Self.controlHoverCornerRadius,
            leadingRadius: MirrorChromeOutlineButton.defaultHoverCornerRadius
        )
    }

    private func rightmostActionButtonForCurrentMode() -> MirrorChromeOutlineButton? {
        switch trailingActionsMode {
        case .hidden:
            return nil
        case .alwaysOnTopOnly:
            return alwaysOnTopBtn
        case .full:
            return recordingActive ? homeBtn : recentAppsBtn
        }
    }

    /// Springs the whole bar — background *and* controls, moved as one layer —
    /// between its tucked pose and its resting pose. Using a spring rather than
    /// a bezier is the difference between "premium" and "fine": it carries a
    /// little momentum and settles like glass. The fade itself stays on the host
    /// window's alpha (which also carries the drop shadow, so the two dissolve in
    /// step). Reading the *in-flight* presentation value as the spring's start
    /// lets a fast hover-in/out reverse mid-motion without snapping.
    func setBarRevealed(_ revealed: Bool, animated: Bool) {
        guard let layer else { return }
        let target = revealed ? CATransform3DIdentity : hiddenBarTransform()
        guard animated else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = target
            CATransaction.commit()
            return
        }
        let response = revealed ? Self.revealSpringResponse : Self.hideSpringResponse
        let damping = revealed ? Self.revealSpringDamping : Self.hideSpringDamping
        let omega = (2 * CGFloat.pi) / CGFloat(response)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = omega * omega          // k = ω₀²·m
        spring.damping = 2 * damping * omega       // c = 2ζ·ω₀·m
        spring.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? layer.transform)
        spring.toValue = NSValue(caTransform3D: target)
        spring.duration = spring.settlingDuration
        spring.isRemovedOnCompletion = true
        layer.transform = target
        layer.add(spring, forKey: "barRevealSpring")
    }

    /// The tucked pose the bar springs out of: a hair smaller and nudged down.
    /// The shrink is taken about the bar's own centre via the matrix (rather
    /// than moving the layer's anchor point), so the content-view layer never
    /// jumps when the pose is applied.
    private func hiddenBarTransform() -> CATransform3D {
        let bounds = layer?.bounds ?? self.bounds
        let cx = bounds.midX
        let cy = bounds.midY
        let s = Self.barHiddenScale
        let centeredScale = CATransform3DConcat(
            CATransform3DConcat(
                CATransform3DMakeTranslation(-cx, -cy, 0),
                CATransform3DMakeScale(s, s, 1)
            ),
            CATransform3DMakeTranslation(cx, cy, 0)
        )
        return CATransform3DConcat(
            centeredScale,
            CATransform3DMakeTranslation(0, -MirrorContentWindowController.toolbarAnimationOffset, 0)
        )
    }

    func setTrailingActionsMode(_ mode: TrailingActionsMode) {
        trailingActionsMode = mode
        applyActionVisibility()
    }

    var horizontalPaddingForTesting: CGFloat {
        Self.trailingPadding
    }

    var backgroundCornerRadiusForTesting: CGFloat {
        backgroundView.layer?.cornerRadius ?? 0
    }

    var trafficLightLeadingPaddingForTesting: CGFloat {
        trafficLightsLeadingConstraint?.constant ?? 0
    }

    var trailingActionsPaddingForTesting: CGFloat {
        abs(rightStackTrailingConstraint?.constant ?? 0)
    }

    var trailingActionsSpacingForTesting: CGFloat {
        rightStack.spacing
    }

    var recentAppsIconNameForTesting: String? {
        recentAppsBtn.iconNameForTesting
    }

    var isRecordingPillVisibleForTesting: Bool {
        !recordingPill.isHidden
    }

    var recordingPillTextForTesting: String {
        recordingPill.elapsedTextForTesting
    }

    func triggerRecordingPillForTesting() {
        recordingPill.action?()
    }

    var rightActionVisibilityForTesting: [Bool] {
        [
            !alwaysOnTopBtn.isHidden,
            !screenshotBtn.isHidden,
            !recordingPill.isHidden,
            !homeBtn.isHidden,
            !recentAppsBtn.isHidden,
        ]
    }

    var alwaysOnTopIconNameForTesting: String? {
        alwaysOnTopBtn.iconNameForTesting
    }

    var rightActionHoverCornerRadiiForTesting: [CGFloat] {
        [
            alwaysOnTopBtn.hoverCornerRadiusForTesting,
            screenshotBtn.hoverCornerRadiusForTesting,
            homeBtn.hoverCornerRadiusForTesting,
            recentAppsBtn.hoverCornerRadiusForTesting,
        ]
    }

    var rightActionHoverLeadingCornerRadiiForTesting: [CGFloat?] {
        [
            alwaysOnTopBtn.hoverLeadingCornerRadiusForTesting,
            screenshotBtn.hoverLeadingCornerRadiusForTesting,
            homeBtn.hoverLeadingCornerRadiusForTesting,
            recentAppsBtn.hoverLeadingCornerRadiusForTesting,
        ]
    }

    var rightActionHoverRoundedCornersForTesting: [CACornerMask] {
        [
            alwaysOnTopBtn.hoverRoundedCornersForTesting,
            screenshotBtn.hoverRoundedCornersForTesting,
            homeBtn.hoverRoundedCornersForTesting,
            recentAppsBtn.hoverRoundedCornersForTesting,
        ]
    }

    var rightActionHoverHeightsForTesting: [CGFloat] {
        [
            alwaysOnTopBtn.hoverHeightForTesting,
            screenshotBtn.hoverHeightForTesting,
            homeBtn.hoverHeightForTesting,
            recentAppsBtn.hoverHeightForTesting,
        ]
    }

    var titleLeadingAfterTrafficLightsForTesting: CGFloat {
        titleLeadingAfterTrafficLightsConstraint?.constant ?? 0
    }

    var titleLineBreakModeForTesting: NSLineBreakMode {
        titleLabel.lineBreakMode
    }

    var titleMaximumNumberOfLinesForTesting: Int {
        titleLabel.maximumNumberOfLines
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
/// The glyphs appear only while the cluster is hovered, matching macOS.
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

    static let dotDiameter: CGFloat = 14.4
    static let glyphCanvasDiameter: CGFloat = 12
    static let glyphStrokeWidth: CGFloat = 2.55
    static let glyphInset: CGFloat = 3.7
    static let minimizeGlyphInset: CGFloat = 3.4
    static let zoomGlyphInset: CGFloat = 3.35

    private let kind: Kind
    private let glyph: MirrorTrafficLightGlyphView
    var action: (() -> Void)?

    init(kind: Kind) {
        self.kind = kind
        self.glyph = MirrorTrafficLightGlyphView(kind: kind)
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.cornerRadius = Self.dotDiameter / 2
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        layer?.backgroundColor = fillColor.cgColor
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            heightAnchor.constraint(equalToConstant: Self.dotDiameter),
        ])

        glyph.isHidden = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.widthAnchor.constraint(equalToConstant: Self.glyphCanvasDiameter),
            glyph.heightAnchor.constraint(equalToConstant: Self.glyphCanvasDiameter),
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

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = (fillColor.blended(withFraction: 0.25, of: .black) ?? fillColor).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = fillColor.cgColor
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) { action?() }
    }
}

private final class MirrorTrafficLightGlyphView: NSView {
    private let kind: MirrorTrafficLightButton.Kind

    init(kind: MirrorTrafficLightButton.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = false
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(
            dx: glyphInset,
            dy: glyphInset
        )
        glyphColor.setStroke()
        switch kind {
        case .close:
            strokePath { path in
                path.move(to: NSPoint(x: rect.minX, y: rect.minY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
                path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
            }
        case .minimize:
            strokePath { path in
                path.move(to: NSPoint(x: rect.minX, y: rect.midY))
                path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
            }
        case .zoom:
            strokeZoomGlyph(in: rect)
        }
    }

    private var glyphInset: CGFloat {
        switch kind {
        case .close: return MirrorTrafficLightButton.glyphInset
        case .minimize: return MirrorTrafficLightButton.minimizeGlyphInset
        case .zoom: return MirrorTrafficLightButton.zoomGlyphInset
        }
    }

    private var glyphColor: NSColor {
        switch kind {
        case .close: return NSColor(red: 0.47, green: 0.13, blue: 0.14, alpha: 0.9)
        case .minimize: return NSColor(red: 0.47, green: 0.32, blue: 0.02, alpha: 0.9)
        case .zoom: return NSColor(red: 0.05, green: 0.43, blue: 0.12, alpha: 0.9)
        }
    }

    private func strokePath(_ build: (NSBezierPath) -> Void) {
        let path = NSBezierPath()
        path.lineWidth = MirrorTrafficLightButton.glyphStrokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        build(path)
        path.stroke()
    }

    private func strokeZoomGlyph(in rect: NSRect) {
        strokePath { path in
            let notch: CGFloat = 1.8
            path.move(to: NSPoint(x: rect.minX, y: rect.midY - notch / 2))
            path.line(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.midX - notch / 2, y: rect.minY))

            path.move(to: NSPoint(x: rect.maxX, y: rect.midY + notch / 2))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.line(to: NSPoint(x: rect.midX + notch / 2, y: rect.maxY))
        }
    }
}

// MARK: - Title label

/// Non-interactive title label (device name) for the chrome bar. Returns `nil`
/// from `hitTest` so window-drag gestures pass through to the drag area below.
private final class MirrorChromeTitleLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Recording status pill

final class MirrorRecordingStatusPill: NSView {
    private let iconView = NSImageView()
    private let timeLabel = NSTextField(labelWithString: "00:00")
    private var startedAt: Date?
    private var timer: Timer?
    var action: (() -> Void)?

    var elapsedTextForTesting: String {
        timeLabel.stringValue
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        timer?.invalidate()
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.28).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            action?()
        }
    }

    func setRecording(_ recording: Bool) {
        if recording {
            if startedAt == nil {
                startedAt = Date()
            }
            startTimerIfNeeded()
        } else {
            timer?.invalidate()
            timer = nil
            startedAt = nil
        }
        updateElapsed()
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius = 11
        layer?.masksToBounds = true
        layer?.setValue("continuous", forKey: "cornerCurve")

        iconView.image = NSImage(
            systemSymbolName: "record.circle.fill",
            accessibilityDescription: "Recording"
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        iconView.contentTintColor = .systemRed
        iconView.translatesAutoresizingMaskIntoConstraints = false

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        timeLabel.textColor = .white.withAlphaComponent(0.86)
        timeLabel.alignment = .left
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
            heightAnchor.constraint(equalToConstant: 22),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),

            timeLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateElapsed()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func updateElapsed() {
        guard let startedAt else {
            timeLabel.stringValue = "00:00"
            return
        }
        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        let hours = elapsed / 3600
        let minutes = (elapsed / 60) % 60
        let seconds = elapsed % 60
        if hours > 0 {
            timeLabel.stringValue = String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            timeLabel.stringValue = String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Outline icon button

/// Small outline-style button for the right side of the chrome bar.
final class MirrorChromeOutlineButton: NSView {
    private enum IconSource: Equatable {
        case system(String)
        case resource(String)
    }

    static let touchWidth: CGFloat = 34
    static let touchHeight: CGFloat = 30
    static let visualIconSize: CGFloat = 18
    static let symbolPointSize: CGFloat = 14
    static let defaultHoverCornerRadius: CGFloat = 6

    private let imageView = NSImageView()
    private let hoverBackgroundLayer = CAShapeLayer()
    private var iconSource: IconSource
    private var hoverCornerRadius: CGFloat
    private var hoverLeadingCornerRadius: CGFloat?
    private let hoverRoundedCorners: CACornerMask
    private var lastActionTime: TimeInterval = 0
    var action: (() -> Void)?
    var minimumActionInterval: TimeInterval = 0
    var chromeScale: CGFloat = 1 {
        didSet { needsLayout = true }
    }
    var isActive = false {
        didSet { applyTint() }
    }

    var iconNameForTesting: String? {
        switch iconSource {
        case .system(let symbol): return symbol
        case .resource(let name): return name
        }
    }

    var hoverCornerRadiusForTesting: CGFloat {
        hoverCornerRadius
    }

    var hoverLeadingCornerRadiusForTesting: CGFloat? {
        hoverLeadingCornerRadius
    }

    var hoverRoundedCornersForTesting: CACornerMask {
        hoverRoundedCorners
    }

    var hoverHeightForTesting: CGFloat {
        layoutSubtreeIfNeeded()
        return hoverBackgroundLayer.frame.height
    }

    init(
        symbol: String,
        accessibilityDescription: String? = nil,
        hoverCornerRadius: CGFloat = MirrorChromeOutlineButton.defaultHoverCornerRadius,
        hoverLeadingCornerRadius: CGFloat? = nil,
        hoverRoundedCorners: CACornerMask = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner,
        ]
    ) {
        iconSource = .system(symbol)
        self.hoverCornerRadius = hoverCornerRadius
        self.hoverLeadingCornerRadius = hoverLeadingCornerRadius
        self.hoverRoundedCorners = hoverRoundedCorners
        super.init(frame: .zero)
        setup(accessibilityDescription: accessibilityDescription)
    }

    init(
        resource: String,
        accessibilityDescription: String? = nil,
        hoverCornerRadius: CGFloat = MirrorChromeOutlineButton.defaultHoverCornerRadius,
        hoverLeadingCornerRadius: CGFloat? = nil,
        hoverRoundedCorners: CACornerMask = [
            .layerMinXMinYCorner,
            .layerMaxXMinYCorner,
            .layerMinXMaxYCorner,
            .layerMaxXMaxYCorner,
        ]
    ) {
        iconSource = .resource(resource)
        self.hoverCornerRadius = hoverCornerRadius
        self.hoverLeadingCornerRadius = hoverLeadingCornerRadius
        self.hoverRoundedCorners = hoverRoundedCorners
        super.init(frame: .zero)
        setup(accessibilityDescription: accessibilityDescription)
    }

    private func setup(accessibilityDescription: String?) {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.touchWidth),
            heightAnchor.constraint(equalToConstant: Self.touchHeight),
        ])
        layer?.setValue("continuous", forKey: "cornerCurve")
        hoverBackgroundLayer.fillColor = nil
        layer?.addSublayer(hoverBackgroundLayer)

        imageView.image = Self.image(for: iconSource, accessibilityDescription: accessibilityDescription)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        applyTint()
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: Self.visualIconSize),
            imageView.heightAnchor.constraint(equalToConstant: Self.visualIconSize),
        ])
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hoverRect = bounds
        hoverBackgroundLayer.frame = hoverRect
        hoverBackgroundLayer.path = Self.hoverPath(
            in: CGRect(origin: .zero, size: hoverRect.size),
            radius: hoverCornerRadius,
            leadingRadius: hoverLeadingCornerRadius,
            roundedCorners: hoverRoundedCorners
        )
        CATransaction.commit()
        let iconSize = min(Self.visualIconSize, max(Self.symbolPointSize, Self.symbolPointSize * chromeScale))
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .regular)
    }

    func setSymbol(_ symbol: String) {
        setIconSource(.system(symbol))
    }

    func setHoverCornerRadius(_ radius: CGFloat, leadingRadius: CGFloat? = nil) {
        hoverCornerRadius = radius
        hoverLeadingCornerRadius = leadingRadius
        needsLayout = true
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

    private static func hoverPath(
        in rect: CGRect,
        radius requestedRadius: CGFloat,
        leadingRadius requestedLeadingRadius: CGFloat?,
        roundedCorners: CACornerMask
    ) -> CGPath {
        // Each corner is limited by the vertical edge it shares (height / 2).
        // Horizontally, the trailing and leading radii share the top/bottom
        // edges, so it's their *sum* that must fit the width — not each one
        // capped at width / 2. Clamping each to width / 2 would pin an 18pt cap
        // down to 17 on a 34pt-wide button even though 18 + 6 easily fits.
        var radius = min(requestedRadius, rect.height / 2)
        var leadingRadius = min(requestedLeadingRadius ?? radius, rect.height / 2)
        let radiiSum = radius + leadingRadius
        if radiiSum > rect.width {
            let widthScale = rect.width / radiiSum
            radius *= widthScale
            leadingRadius *= widthScale
        }
        let minXMinY = roundedCorners.contains(.layerMinXMinYCorner)
        let maxXMinY = roundedCorners.contains(.layerMaxXMinYCorner)
        let maxXMaxY = roundedCorners.contains(.layerMaxXMaxYCorner)
        let minXMaxY = roundedCorners.contains(.layerMinXMaxYCorner)
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX + (minXMinY ? leadingRadius : 0), y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - (maxXMinY ? radius : 0), y: rect.minY))
        if maxXMinY {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                control: CGPoint(x: rect.maxX, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }

        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - (maxXMaxY ? radius : 0)))
        if maxXMaxY {
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rect.minX + (minXMaxY ? leadingRadius : 0), y: rect.maxY))
        if minXMaxY {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - leadingRadius),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }

        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + (minXMinY ? leadingRadius : 0)))
        if minXMinY {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + leadingRadius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        } else {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        }

        path.closeSubpath()
        return path
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
        hoverBackgroundLayer.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
    }
    override func mouseExited(with event: NSEvent) {
        hoverBackgroundLayer.fillColor = nil
    }
    override func mouseDown(with event: NSEvent) {
        hoverBackgroundLayer.fillColor = NSColor.white.withAlphaComponent(0.22).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        hoverBackgroundLayer.fillColor = nil
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

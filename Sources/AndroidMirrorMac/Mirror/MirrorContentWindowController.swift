import AppKit

/// Owns the in-process mirror window: a borderless, rounded NSWindow whose
/// content is our own `MirrorRenderView` plus a hover-revealed chrome bar.
/// Because the window lives in our process, dragging is a native AppKit
/// window move (`NSWindow.performDrag`) — no cross-process AX chase, smooth
/// at display refresh rate, exactly like Reflect.
@MainActor
final class MirrorContentWindowController: NSWindowController, NSWindowDelegate {
    static let cornerRadius: CGFloat = WindowChromeConstants.cornerRadiusIdle
    static let chromeHeight: CGFloat = 38
    static let chromeActivationZone: CGFloat = chromeHeight
    static let visibleChromeRenderTopInset: CGFloat = chromeHeight
    static let defaultMirrorAspect: CGFloat = 1080.0 / 2340.0
    static let minimumScreenHeightRatio: CGFloat = 0.45
    static let maximumScreenHeightRatio: CGFloat = 0.90
    static let chromeHideDelay: TimeInterval = 0.030
    static let chromeHideAnimationDuration: TimeInterval = 0.16

    private let model: AppModel
    private weak var session: MirrorSession?

    let renderView = MirrorRenderView()
    private let rootView = MirrorRootView()
    private let chromeBar = MirrorChromeBar()
    private var renderTopConstraint: NSLayoutConstraint?
    private var hideWorkItem: DispatchWorkItem?
    private var chromeVisible = false
    private var isDraggingChrome = false
    private var isPointerInTopZone = false
    private var isInFullscreen = false
    private var mirrorAspect: CGFloat? = defaultMirrorAspect

    init(model: AppModel, session: MirrorSession) {
        self.model = model
        self.session = session
        let initialWidth: CGFloat = 380
        let frame = NSRect(
            x: 0,
            y: 0,
            width: initialWidth,
            height: initialWidth / Self.defaultMirrorAspect + Self.chromeHeight
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        configure(window: window)
        installContent()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Public

    func show() {
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
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

        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxContentHeight = max(1, visible.height - 80 - Self.chromeHeight)
        let targetWidth = max(280, min(visible.width - 80, maxContentHeight * aspect))
        let mirrorHeight = targetWidth / aspect
        window.contentAspectRatio = NSSize(width: targetWidth, height: mirrorHeight)
        let newFrame = NSRect(
            x: window.frame.midX - targetWidth / 2,
            y: window.frame.midY - (mirrorHeight + Self.chromeHeight) / 2,
            width: targetWidth,
            height: mirrorHeight + Self.chromeHeight
        )
        window.setFrame(newFrame, display: true, animate: false)
    }

    func scaleWindow(by scale: CGFloat) {
        guard let window else { return }
        guard !isInFullscreen else { return }
        let aspect = mirrorAspect ?? Self.defaultMirrorAspect
        let limits = Self.sizeLimits(
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame,
            aspect: aspect,
            chromeHeight: Self.chromeHeight
        )
        let targetFrame = Self.scaledFrame(
            from: window.frame,
            scale: scale,
            aspect: aspect,
            chromeHeight: Self.chromeHeight,
            minHeight: limits.min.height,
            maxHeight: limits.max.height
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = scale >= 1 ? 0.18 : 0.14
            context.timingFunction = CAMediaTimingFunction(name: scale >= 1 ? .easeOut : .easeInEaseOut)
            window.animator().setFrame(targetFrame, display: true)
        }
    }

    static func scaledFrame(
        from frame: NSRect,
        scale: CGFloat,
        aspect: CGFloat,
        chromeHeight: CGFloat,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> NSRect {
        let contentHeight = max(1, frame.height - chromeHeight)
        let minContentHeight = max(1, minHeight - chromeHeight)
        let maxContentHeight = max(minContentHeight, maxHeight - chromeHeight)
        let scaledContentHeight = min(max(contentHeight * scale, minContentHeight), maxContentHeight)
        let height = scaledContentHeight + chromeHeight
        let width = scaledContentHeight * max(aspect, 0.001)
        return NSRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - Setup

    private func configure(window: NSWindow) {
        window.title = "Android Mirror"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isRestorable = false
        window.isMovable = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.contentAspectRatio = NSSize(width: Self.defaultMirrorAspect, height: 1)
        applyWindowSizeLimits(to: window, aspect: Self.defaultMirrorAspect)
        window.level = .normal
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func applyWindowSizeLimits(to window: NSWindow, aspect: CGFloat) {
        let limits = Self.sizeLimits(
            visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame,
            aspect: aspect,
            chromeHeight: Self.chromeHeight
        )
        window.minSize = limits.min
        window.maxSize = limits.max
    }

    static func sizeLimits(
        visibleFrame: NSRect,
        aspect: CGFloat,
        chromeHeight: CGFloat
    ) -> (min: NSSize, max: NSSize) {
        let visibleHeight = max(1, visibleFrame.height)
        let minHeight = visibleHeight * minimumScreenHeightRatio
        let maxHeight = visibleHeight * maximumScreenHeightRatio
        let minContentHeight = max(1, minHeight - chromeHeight)
        let maxContentHeight = max(minContentHeight, maxHeight - chromeHeight)
        return (
            min: NSSize(width: minContentHeight * aspect, height: minHeight),
            max: NSSize(width: maxContentHeight * aspect, height: maxHeight)
        )
    }

    private func installContent() {
        guard let window else { return }
        rootView.frame = NSRect(origin: .zero, size: window.frame.size)
        rootView.autoresizingMask = [.width, .height]
        rootView.wantsLayer = true
        rootView.layer?.cornerRadius = Self.cornerRadius
        rootView.layer?.masksToBounds = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.setValue("continuous", forKey: "cornerCurve")
        rootView.onHoverChange = { [weak self] inTopZone in self?.handleHover(inTopZone) }

        renderView.translatesAutoresizingMaskIntoConstraints = false
        renderView.cornerRadius = Self.cornerRadius
        rootView.addSubview(renderView)

        chromeBar.translatesAutoresizingMaskIntoConstraints = false
        chromeBar.configure(
            onClose: { [weak self] in self?.session?.stop() },
            onMinimize: { [weak self] in self?.window?.miniaturize(nil) },
            onMaximize: { [weak self] in self?.toggleFullScreenFromChrome() },
            onRecents: { [weak self] in self?.session?.sendAndroidKey(.appSwitch) },
            onScreenshot: { [weak self] in self?.session?.takeScreenshot() }
        )
        chromeBar.alphaValue = 0
        chromeBar.isHidden = true
        chromeVisible = false
        chromeBar.onDragStateChange = { [weak self] isDragging in
            self?.setChromeDragging(isDragging)
        }
        chromeBar.onDragMouseDown = { [weak self] event in
            self?.dragWindowFromChrome(with: event)
        }
        chromeBar.onHoverChange = { [weak self] isInside in
            self?.handleChromeHover(isInside)
        }

        rootView.addSubview(chromeBar)

        let renderTopConstraint = renderView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: Self.chromeHeight)
        self.renderTopConstraint = renderTopConstraint
        NSLayoutConstraint.activate([
            chromeBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            chromeBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            chromeBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            chromeBar.heightAnchor.constraint(equalToConstant: Self.chromeHeight),

            renderTopConstraint,
            renderView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            renderView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])

        window.contentView = rootView

        renderView.onMouseMoved = { [weak self] event in
            self?.handleRenderMouseMoved(event)
        }
        renderView.onPointerEvent = { [weak self] event in
            self?.session?.forwardPointerEvent(event, in: self?.renderView ?? MirrorRenderView())
        }
        renderView.onKeyEvent = { [weak self] event in
            self?.session?.forwardKeyEvent(event)
        }
    }

    // MARK: - Hover

    private func handleHover(_ inTopZone: Bool) {
        guard !isInFullscreen else {
            hideChromeImmediately()
            return
        }
        isPointerInTopZone = inTopZone
        if inTopZone {
            hideWorkItem?.cancel()
            setChromeVisible(true)
        } else {
            scheduleHide()
        }
    }

    private func handleChromeHover(_ isInside: Bool) {
        guard !isInFullscreen else {
            hideChromeImmediately()
            return
        }
        isPointerInTopZone = isInside
        if isInside {
            hideWorkItem?.cancel()
            setChromeVisible(true)
        } else {
            scheduleHide()
        }
    }

    private func handleRenderMouseMoved(_ event: NSEvent) {
        handleHover(false)
    }

    var isChromeVisibleForTesting: Bool {
        chromeVisible && !chromeBar.isHidden
    }

    var isChromeBarHiddenForTesting: Bool {
        chromeBar.isHidden
    }

    var renderTopInsetForTesting: CGFloat {
        renderTopConstraint?.constant ?? 0
    }

    var isFullscreenChromeSuppressedForTesting: Bool {
        isInFullscreen
    }

    private func scheduleHide() {
        guard !isDraggingChrome, !isPointerInTopZone, !isMouseCurrentlyInToolbarBand() else {
            isPointerInTopZone = true
            return
        }
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isDraggingChrome else { return }
            if self.isPointerInTopZone || self.isMouseCurrentlyInToolbarBand() {
                self.isPointerInTopZone = true
                return
            }
            self.setChromeVisible(false)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chromeHideDelay, execute: workItem)
    }

    private func isMouseCurrentlyInToolbarBand() -> Bool {
        guard !isInFullscreen else { return false }
        guard let window else { return false }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return windowPoint.x >= 0
            && windowPoint.x <= window.frame.width
            && windowPoint.y > window.frame.height - Self.chromeHeight
            && windowPoint.y <= window.frame.height
    }

    private func setChromeVisible(_ visible: Bool) {
        guard chromeVisible != visible else { return }
        chromeVisible = visible

        if visible {
            chromeBar.isHidden = false
            chromeBar.alphaValue = 0
            chromeBar.setBarBackgroundVisible(true)
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.10 : Self.chromeHideAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
            rootView.layer?.backgroundColor = visible
                ? NSColor.windowBackgroundColor.cgColor
                : NSColor.clear.cgColor
            chromeBar.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            guard let self else { return }
            if !visible {
                self.chromeBar.isHidden = true
                self.chromeBar.setBarBackgroundVisible(false)
                self.rootView.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    private func hideChromeImmediately() {
        hideWorkItem?.cancel()
        chromeVisible = false
        isPointerInTopZone = false
        chromeBar.isHidden = true
        chromeBar.alphaValue = 0
        chromeBar.setBarBackgroundVisible(false, animated: false)
        rootView.layer?.backgroundColor = isInFullscreen
            ? NSColor.black.cgColor
            : NSColor.clear.cgColor
    }

    private func toggleFullScreenFromChrome() {
        guard let window else { return }
        hideChromeImmediately()
        setFullscreenChromeSuppressed(true)
        window.toggleFullScreen(nil)
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
            hideChromeImmediately()
            window?.backgroundColor = .black
            rootView.layer?.cornerRadius = 0
            rootView.layer?.backgroundColor = NSColor.black.cgColor
            renderTopConstraint?.constant = 0
            window?.contentAspectRatio = .zero
            window?.minSize = NSSize(width: 1, height: 1)
            window?.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            window?.backgroundColor = .clear
            rootView.layer?.cornerRadius = Self.cornerRadius
            rootView.layer?.backgroundColor = NSColor.clear.cgColor
            renderTopConstraint?.constant = Self.chromeHeight
            if let window, let aspect = mirrorAspect {
                window.contentAspectRatio = NSSize(width: aspect, height: 1)
                applyWindowSizeLimits(to: window, aspect: aspect)
            }
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

        let startMouse = NSEvent.mouseLocation
        let startFrame = window.frame
        while true {
            guard let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }

            if next.type == .leftMouseUp {
                break
            }

            let mouse = NSEvent.mouseLocation
            var frame = startFrame
            frame.origin.x += mouse.x - startMouse.x
            frame.origin.y += mouse.y - startMouse.y
            window.setFrame(frame, display: true)
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
        session?.stop()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !isInFullscreen else { return frameSize }
        guard let mirrorAspect, mirrorAspect > 0, frameSize.width > 0 else {
            return frameSize
        }

        return NSSize(
            width: frameSize.width,
            height: frameSize.width / mirrorAspect + Self.chromeHeight
        )
    }

    func windowDidMove(_ notification: Notification) {
        updateFullscreenPresentationIfNeeded()
    }

    func windowDidResize(_ notification: Notification) {
        updateFullscreenPresentationIfNeeded()
        rootView.layoutSubtreeIfNeeded()
        renderView.updateVideoLayerFrame()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
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
    }
}

// MARK: - Root container

/// Root view — rounded mask, cursor tracking for chrome reveal.
final class MirrorRootView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var chromeRevealEnabled = true
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }

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
    override func mouseEntered(with event: NSEvent) {}
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    private func update(with event: NSEvent) {
        guard chromeRevealEnabled else {
            onHoverChange?(false)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let toolbarZoneMinY = bounds.height - MirrorContentWindowController.chromeHeight
        onHoverChange?(point.y > toolbarZoneMinY)
    }
}

// MARK: - Chrome bar

/// Full-width macOS-style chrome that occupies a separate top band on hover.
/// Traffic lights at the left (20 pt inset), outline action buttons at the right.
/// Background is a solid default AppKit surface so desktop content never bleeds through.
final class MirrorChromeBar: NSView {
    /// How small the bar shrinks when hidden. A more pronounced ratio makes
    /// the growing effect actually read on screen.
    static let barHiddenScale: CGFloat = 0.82
    /// Reveal is slightly longer than hide so the bar "lands" into place;
    /// hide is a hair quicker so the chrome doesn't overstay its welcome.
    static let barRevealDuration: CFTimeInterval = 0.32
    static let barHideDuration: CFTimeInterval = 0.24

    /// `cubic-bezier(0.16, 1, 0.3, 1)` — "ease-out-expo", the velvet curve
    /// many Apple-style sheet/popover entrances use. Front-loaded velocity
    /// that decelerates into a soft stop, so the bar feels like it gently
    /// lands into position.
    private static let revealTiming = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
    /// `cubic-bezier(0.5, 0, 0.75, 0)` — gentle ease-in that accelerates as
    /// it disappears, so the exit feels graceful rather than abrupt.
    private static let hideTiming = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0)

    private let backgroundView = NSView()
    private let dragArea = MirrorWindowDragArea()
    var onDragStateChange: ((Bool) -> Void)?
    var onDragMouseDown: ((NSEvent) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    private let closeBtn = MirrorTrafficLight(kind: .close)
    private let minimizeBtn = MirrorTrafficLight(kind: .minimize)
    private let maximizeBtn = MirrorTrafficLight(kind: .zoom)
    private let screenshotBtn = MirrorChromeOutlineButton(symbol: "camera")
    private let recentsBtn    = MirrorChromeOutlineButton(symbol: "square.grid.3x3")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    func configure(
        onClose: @escaping () -> Void,
        onMinimize: @escaping () -> Void,
        onMaximize: @escaping () -> Void,
        onRecents: @escaping () -> Void,
        onScreenshot: @escaping () -> Void
    ) {
        recentsBtn.action  = onRecents
        screenshotBtn.action = onScreenshot

        closeBtn.action = onClose
        minimizeBtn.action = onMinimize
        maximizeBtn.action = onMaximize
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        // Hide the bar background by default. The buttons (traffic lights +
        // outline icons) stay visible — only this background panel scales
        // in/out as the cursor enters/leaves the chrome region.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundView.layer?.opacity = 0
        backgroundView.layer?.transform = CATransform3DMakeScale(
            Self.barHiddenScale, Self.barHiddenScale, 1
        )
        CATransaction.commit()

        // Traffic lights — each button uses its native intrinsic size; the
        // stack uses the macOS-default 6 pt gap between buttons.
        let lightsStack = NSStackView(views: [closeBtn, minimizeBtn, maximizeBtn])
        lightsStack.orientation = .horizontal
        lightsStack.spacing = 6
        lightsStack.alignment = .centerY
        lightsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lightsStack)

        // Right-side outline buttons.
        let rightStack = NSStackView(views: [screenshotBtn, recentsBtn])
        rightStack.orientation = .horizontal
        rightStack.spacing = 6
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

        NSLayoutConstraint.activate([
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            lightsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            lightsStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            dragArea.leadingAnchor.constraint(equalTo: lightsStack.trailingAnchor, constant: 8),
            dragArea.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -8),
            dragArea.topAnchor.constraint(equalTo: topAnchor),
            dragArea.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
        onHoverChange?(false)
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

// MARK: - Traffic light

private enum TrafficLightKind {
    case close
    case minimize
    case zoom

    var color: NSColor {
        switch self {
        case .close:
            return NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1)
        case .minimize:
            return NSColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1)
        case .zoom:
            return NSColor(red: 0.20, green: 0.78, blue: 0.28, alpha: 1)
        }
    }
}

private final class MirrorTrafficLight: NSView {
    private let kind: TrafficLightKind
    var action: (() -> Void)?

    init(kind: TrafficLightKind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 12),
            heightAnchor.constraint(equalToConstant: 12),
        ])
        layer?.cornerRadius = 6
        layer?.backgroundColor = kind.color.cgColor
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { action?() }
}

// MARK: - Outline icon button

/// Small outline-style button for the right side of the chrome bar.
final class MirrorChromeOutlineButton: NSView {
    private let imageView = NSImageView()
    var action: (() -> Void)?

    init(symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        layer?.cornerRadius = 6
        layer?.setValue("continuous", forKey: "cornerCurve")

        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        imageView.contentTintColor = NSColor.white.withAlphaComponent(0.72)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        if bounds.contains(p) { action?() }
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

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

    private let model: AppModel
    private weak var session: MirrorSession?

    let renderView = MirrorRenderView()
    private let rootView = MirrorRootView()
    private let chromeBar = MirrorChromeBar()
    private var renderTopConstraint: NSLayoutConstraint?
    private var chromeTopConstraint: NSLayoutConstraint?
    private var globalMouseMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private var chromeVisible = false
    private var isDraggingChrome = false
    private var isPointerInTopZone = false
    private var mirrorAspect: CGFloat? = defaultMirrorAspect

    init(model: AppModel, session: MirrorSession) {
        self.model = model
        self.session = session
        let initialWidth: CGFloat = 380
        let frame = NSRect(
            x: 0,
            y: 0,
            width: initialWidth,
            height: initialWidth / Self.defaultMirrorAspect
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.delegate = self
        configure(window: window)
        installContent()
        installHoverMonitors()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    // MARK: - Public

    func show() {
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func setStreamSize(width: UInt32, height: UInt32) {
        guard let window, width > 0, height > 0 else { return }
        renderView.setStreamSize(width: width, height: height)
        let aspect = CGFloat(width) / CGFloat(height)
        mirrorAspect = aspect
        applyWindowSizeLimits(to: window, aspect: aspect)

        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxContentHeight = min(visible.height - 80, 900)
        let targetWidth = max(280, min(visible.width - 80, maxContentHeight * aspect))
        let mirrorHeight = targetWidth / aspect
        window.contentAspectRatio = NSSize(width: targetWidth, height: mirrorHeight)
        let newFrame = NSRect(
            x: window.frame.midX - targetWidth / 2,
            y: window.frame.midY - mirrorHeight / 2,
            width: targetWidth,
            height: mirrorHeight
        )
        window.setFrame(newFrame, display: true, animate: false)
    }

    func scaleWindow(by scale: CGFloat) {
        guard let window else { return }
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
            onMaximize: { [weak self] in self?.window?.toggleFullScreen(nil) },
            onRecents: { [weak self] in self?.session?.sendAndroidKey(.appSwitch) },
            onScreenshot: { [weak self] in self?.session?.takeScreenshot() }
        )
        chromeBar.alphaValue = 0
        chromeBar.isHidden = true
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

        let renderTopConstraint = renderView.topAnchor.constraint(equalTo: rootView.topAnchor)
        let chromeTopConstraint = chromeBar.topAnchor.constraint(equalTo: rootView.topAnchor)
        self.renderTopConstraint = renderTopConstraint
        self.chromeTopConstraint = chromeTopConstraint
        NSLayoutConstraint.activate([
            chromeTopConstraint,
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

    private func installHoverMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.updateHoverActivation(at: NSEvent.mouseLocation)
        }
    }

    // MARK: - Hover

    private func handleHover(_ inTopZone: Bool) {
        isPointerInTopZone = inTopZone
        if inTopZone {
            hideWorkItem?.cancel()
            setChromeVisible(true)
        } else {
            scheduleHide()
        }
    }

    private func handleChromeHover(_ isInside: Bool) {
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

    func updateHoverActivationForTesting(at screenPoint: NSPoint) {
        updateHoverActivation(at: screenPoint)
    }

    private func updateHoverActivation(at screenPoint: NSPoint) {
        guard !chromeVisible else { return }
        handleHover(activationFrameForHiddenChrome().contains(screenPoint))
    }

    private func activationFrameForHiddenChrome() -> NSRect {
        guard let window else { return .zero }
        var frame = window.frame
        if chromeVisibleBeforeAnimationHeight(frame.height) {
            frame.size.height = max(1, frame.height - Self.chromeHeight)
        }
        return NSRect(
            x: frame.minX,
            y: frame.maxY,
            width: frame.width,
            height: Self.chromeActivationZone
        )
    }

    private func scheduleHide() {
        guard !isDraggingChrome, !isPointerInTopZone else { return }
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isDraggingChrome, !self.isPointerInTopZone else { return }
            self.setChromeVisible(false)
        }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
    }

    private func setChromeVisible(_ visible: Bool) {
        guard chromeVisible != visible else { return }
        chromeVisible = visible
        if visible {
            chromeBar.isHidden = false
            chromeBar.alphaValue = 0
        }
        rootView.stableHoverBandHeight = visible ? Self.chromeHeight : 0
        if let window, let mirrorAspect {
            applyWindowSizeLimits(to: window, aspect: mirrorAspect)
        }
        let targetFrame = frameForChromeVisibility(visible)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.13 : 0.10
            ctx.allowsImplicitAnimation = true
            ctx.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeIn)
            if let targetFrame {
                window?.animator().setFrame(targetFrame, display: true)
            }
            renderTopConstraint?.animator().constant = visible ? Self.visibleChromeRenderTopInset : 0
            rootView.layer?.backgroundColor = visible
                ? NSColor.windowBackgroundColor.cgColor
                : NSColor.clear.cgColor
            chromeBar.animator().alphaValue = visible ? 1 : 0
            rootView.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if !visible {
                    self.chromeBar.isHidden = true
                    self.rootView.layer?.backgroundColor = NSColor.clear.cgColor
                    self.rootView.stableHoverBandHeight = 0
                }
            }
        }
    }

    private func frameForChromeVisibility(_ visible: Bool) -> NSRect? {
        guard let window, chromeVisibleBeforeAnimationHeight(window.frame.height) != visible else {
            return window?.frame
        }
        var frame = window.frame
        if visible {
            frame.size.height += Self.chromeHeight
        } else {
            frame.size.height = max(1, frame.height - Self.chromeHeight)
        }
        return frame
    }

    private func chromeVisibleBeforeAnimationHeight(_ height: CGFloat) -> Bool {
        guard let aspect = mirrorAspect, let window else { return chromeVisible }
        let expectedMirrorHeight = window.frame.width / aspect
        return height > expectedMirrorHeight + Self.chromeHeight / 2
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
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        session?.stop()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let mirrorAspect, mirrorAspect > 0, frameSize.width > 0 else {
            return frameSize
        }

        return NSSize(
            width: frameSize.width,
            height: frameSize.width / mirrorAspect + (chromeVisible ? Self.chromeHeight : 0)
        )
    }

    func windowDidMove(_ notification: Notification) {}

    func windowDidResize(_ notification: Notification) {
        rootView.layoutSubtreeIfNeeded()
        renderView.updateVideoLayerFrame()
    }
}

// MARK: - Root container

/// Root view — rounded mask, cursor tracking for chrome reveal.
final class MirrorRootView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var stableHoverBandHeight: CGFloat = 0
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
    override func mouseEntered(with event: NSEvent) { update(with: event) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    private func update(with event: NSEvent) {
        guard stableHoverBandHeight > 0 else {
            onHoverChange?(false)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let stableZone = bounds.height - stableHoverBandHeight
        onHoverChange?(point.y >= stableZone)
    }
}

// MARK: - Chrome bar

/// Full-width macOS-style chrome that occupies a separate top band on hover.
/// Traffic lights at the left (20 pt inset), outline action buttons at the right.
/// Background is a solid default AppKit surface so desktop content never bleeds through.
final class MirrorChromeBar: NSView {
    private let backgroundView = NSView()
    private let dragArea = MirrorWindowDragArea()
    var onDragStateChange: ((Bool) -> Void)?
    var onDragMouseDown: ((NSEvent) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    private let closeBtn    = MirrorTrafficLight(kind: .close)
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
        closeBtn.action    = onClose
        minimizeBtn.action = onMinimize
        maximizeBtn.action = onMaximize
        recentsBtn.action  = onRecents
        screenshotBtn.action = onScreenshot
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        // Traffic lights — exactly like macOS: red / yellow / green, 12 pt, 8 pt gap.
        let lightsStack = NSStackView(views: [closeBtn, minimizeBtn, maximizeBtn])
        lightsStack.orientation = .horizontal
        lightsStack.spacing = 8
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

            lightsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
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
}

// MARK: - Traffic light

enum TrafficLightKind {
    case close, minimize, zoom

    var color: NSColor {
        switch self {
        case .close:    return NSColor(srgbRed: 1.000, green: 0.373, blue: 0.337, alpha: 1)
        case .minimize: return NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1)
        case .zoom:     return NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1)
        }
    }

    var symbol: String {
        switch self {
        case .close:    return "xmark"
        case .minimize: return "minus"
        case .zoom:     return "plus"
        }
    }
}

final class MirrorTrafficLight: NSView {
    private let kind: TrafficLightKind
    private let symbolView = NSImageView()
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

        symbolView.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 6, weight: .bold)
        symbolView.contentTintColor = NSColor.black.withAlphaComponent(0.42)
        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.alphaValue = 0
        addSubview(symbolView)
        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            symbolView.animator().alphaValue = 1
        }
    }
    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            symbolView.animator().alphaValue = 0
        }
    }
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

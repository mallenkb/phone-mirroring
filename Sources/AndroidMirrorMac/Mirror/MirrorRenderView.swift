import AppKit
import AVFoundation
import CoreMedia

/// An NSView whose backing layer is an `AVSampleBufferDisplayLayer`. The
/// MirrorSession enqueues each decoded `CMSampleBuffer` and the view paints
/// the latest frame at display refresh rate, in-process — no AX dance, no
/// second NSWindow.
///
/// Also captures mouse and keyboard events and hands them to the session so
/// they can be forwarded to the device over scrcpy's control socket.
final class MirrorRenderView: NSView {
    enum PointerKind { case down, dragged, up, moved, scroll }

    struct PointerEvent {
        var kind: PointerKind
        /// 0..1 coordinates relative to the rendered video frame.
        var normalized: CGPoint
        var scrollDX: CGFloat
        var scrollDY: CGFloat
    }

    let sampleBufferDisplayLayer = AVSampleBufferDisplayLayer()
    private let loadingView = MirrorLoadingView()
    private var aspect: CGSize = .zero
    private var trackingArea: NSTrackingArea?
    private var hasRenderedFirstFrame = false
    private var firstFrameReadyToDisplay = false
    private var loadingStartedAt = Date()
    var cornerRadius: CGFloat = 0 {
        didSet { applyCornerMask() }
    }

    var onPointerEvent: ((PointerEvent) -> Void)?
    var onKeyEvent: ((NSEvent) -> Void)?
    var onMouseMoved: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(sampleBufferDisplayLayer)
        sampleBufferDisplayLayer.videoGravity = .resizeAspect
        sampleBufferDisplayLayer.backgroundColor = NSColor.black.cgColor
        sampleBufferDisplayLayer.actions = [
            "bounds": NSNull(),
            "frame": NSNull(),
            "position": NSNull()
        ]
        setupLoadingView()
        applyCornerMask()
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        updateVideoLayerFrame()
        loadingView.frame = bounds
        applyCornerMask()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func enqueue(_ sample: CMSampleBuffer) {
        if sampleBufferDisplayLayer.status == .failed {
            sampleBufferDisplayLayer.flush()
        }
        sampleBufferDisplayLayer.enqueue(sample)
        hideLoadingViewIfNeeded()
    }

    func setStreamSize(width: UInt32, height: UInt32) {
        aspect = CGSize(width: CGFloat(width), height: CGFloat(height))
        needsLayout = true
        updateVideoLayerFrame()
    }

    func setLoadingDeviceName(_ deviceName: String) {
        loadingView.deviceName = deviceName
    }

    var streamAspect: CGSize { aspect }

    func updateVideoLayerFrame() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sampleBufferDisplayLayer.frame = Self.videoFrame(for: bounds)
        CATransaction.commit()
    }

    private func applyCornerMask() {
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
        layer?.setValue("continuous", forKey: "cornerCurve")
        sampleBufferDisplayLayer.cornerRadius = 0
        sampleBufferDisplayLayer.masksToBounds = false
        loadingView.layer?.cornerRadius = cornerRadius
        loadingView.layer?.masksToBounds = cornerRadius > 0
        loadingView.layer?.setValue("continuous", forKey: "cornerCurve")
    }

    private func setupLoadingView() {
        loadingStartedAt = Date()
        loadingView.frame = bounds
        loadingView.autoresizingMask = [.width, .height]
        loadingView.alphaValue = 1
        loadingView.startProgress(duration: 3)
        addSubview(loadingView)
    }

    private func hideLoadingViewIfNeeded() {
        guard !hasRenderedFirstFrame, !firstFrameReadyToDisplay else { return }
        firstFrameReadyToDisplay = true
        let elapsed = Date().timeIntervalSince(loadingStartedAt)
        let remaining = max(0, 3 - elapsed)
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.finishHidingLoadingView()
            }
            return
        }
        finishHidingLoadingView()
    }

    private func finishHidingLoadingView() {
        guard !hasRenderedFirstFrame else { return }
        hasRenderedFirstFrame = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            loadingView.animator().alphaValue = 0
        } completionHandler: { [weak loadingView] in
            loadingView?.isHidden = true
        }
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emit(event, kind: .down)
    }
    override func mouseDragged(with event: NSEvent) { emit(event, kind: .dragged) }
    override func mouseUp(with event: NSEvent) { emit(event, kind: .up) }
    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(event)
        emit(event, kind: .moved)
    }
    override func scrollWheel(with event: NSEvent) {
        guard let point = normalizedPoint(for: event) else { return }
        onPointerEvent?(PointerEvent(
            kind: .scroll,
            normalized: point,
            scrollDX: event.scrollingDeltaX,
            scrollDY: event.scrollingDeltaY
        ))
    }
    override func keyDown(with event: NSEvent) { onKeyEvent?(event) }
    override func keyUp(with event: NSEvent) { onKeyEvent?(event) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            // ⌘V pastes the Mac clipboard into the phone; let every other
            // command shortcut (⌘Q, app menu, etc.) bubble up untouched.
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
                onKeyEvent?(event)
                return true
            }
            return false
        }
        onKeyEvent?(event)
        return true
    }

    private func emit(_ event: NSEvent, kind: PointerKind) {
        guard let point = normalizedPoint(for: event) else { return }
        onPointerEvent?(PointerEvent(kind: kind, normalized: point, scrollDX: 0, scrollDY: 0))
    }

    /// Map the cursor position from view coordinates into the video's own
    /// 0..1 coordinate system, accounting for letterbox bands when the
    /// window aspect doesn't match the stream aspect.
    private func normalizedPoint(for event: NSEvent) -> CGPoint? {
        guard aspect.width > 0, aspect.height > 0 else { return nil }
        let local = convert(event.locationInWindow, from: nil)
        let renderedFrame = Self.fittedVideoRect(for: aspect, in: Self.videoFrame(for: bounds))
        let nx = (local.x - renderedFrame.minX) / max(renderedFrame.width, 1)
        let ny = 1 - (local.y - renderedFrame.minY) / max(renderedFrame.height, 1)
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return CGPoint(x: nx, y: ny)
    }

    static func fittedVideoRect(for aspect: CGSize, in bounds: CGRect) -> CGRect {
        guard aspect.width > 0, aspect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let videoAspect = aspect.width / aspect.height
        let boundsAspect = bounds.width / bounds.height
        var fittedSize = bounds.size

        if boundsAspect > videoAspect {
            fittedSize.width = bounds.height * videoAspect
        } else {
            fittedSize.height = bounds.width / videoAspect
        }

        let origin = CGPoint(
            x: bounds.minX + (bounds.width - fittedSize.width) / 2,
            y: bounds.minY + (bounds.height - fittedSize.height) / 2
        )
        return CGRect(origin: origin, size: fittedSize)
    }

    static func videoFrame(for bounds: CGRect) -> CGRect {
        bounds
    }
}

private final class MirrorLoadingView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let progressText = LoadingProgressTextView(deviceName: "Android Device")

    var deviceName: String = "" {
        didSet {
            let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            progressText.deviceName = trimmedName.isEmpty ? "Android Device" : trimmedName
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
        progressText.layoutSubtreeIfNeeded()
    }

    func startProgress(duration: TimeInterval) {
        progressText.startProgress(duration: duration)
    }

    private func setupView() {
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        gradientLayer.colors = [
            NSColor(calibratedRed: 0.0, green: 0.48, blue: 0.43, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.0, green: 0.35, blue: 0.31, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.0, green: 0.22, blue: 0.19, alpha: 1).cgColor
        ]
        gradientLayer.locations = [0, 0.46, 1]
        gradientLayer.startPoint = CGPoint(x: 0.06, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.96, y: 0)
        layer?.addSublayer(gradientLayer)

        progressText.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressText)

        NSLayoutConstraint.activate([
            progressText.centerXAnchor.constraint(equalTo: centerXAnchor),
            progressText.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressText.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            progressText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }
}

private final class LoadingProgressTextView: NSView {
    private let baseStack = NSStackView()
    private let fillStack = NSStackView()
    private let baseStatusLabel = NSTextField(labelWithString: "Connecting")
    private let baseDeviceLabel: NSTextField
    private let fillStatusLabel = NSTextField(labelWithString: "Connecting")
    private let fillDeviceLabel: NSTextField
    private let fillContainer = NSView()
    private var fillExtentConstraint: NSLayoutConstraint?
    private var progressTimer: Timer?
    private var progress: CGFloat = 0 {
        didSet { updateProgress() }
    }

    var deviceName: String {
        get { baseDeviceLabel.stringValue }
        set {
            baseDeviceLabel.stringValue = newValue
            fillDeviceLabel.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(deviceName: String) {
        baseDeviceLabel = NSTextField(labelWithString: deviceName)
        fillDeviceLabel = NSTextField(labelWithString: deviceName)
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        baseStack.intrinsicContentSize
    }

    override func layout() {
        super.layout()
        updateProgress()
    }

    func startProgress(duration: TimeInterval) {
        progressTimer?.invalidate()
        progress = 0
        let startedAt = Date()
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            self.progress = min(1, max(0, elapsed / duration))
            if self.progress >= 1 {
                timer.invalidate()
                self.progressTimer = nil
            }
        }
        progressTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        [baseStatusLabel, fillStatusLabel].forEach { label in
            label.font = .systemFont(ofSize: 19, weight: .semibold)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        [baseDeviceLabel, fillDeviceLabel].forEach { label in
            label.font = .systemFont(ofSize: 42, weight: .heavy)
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        [baseStatusLabel, baseDeviceLabel].forEach {
            $0.textColor = NSColor.white.withAlphaComponent(0.34)
        }
        fillStatusLabel.textColor = NSColor.white.withAlphaComponent(0.86)
        fillDeviceLabel.textColor = NSColor.white.withAlphaComponent(0.92)

        [baseStack, fillStack].forEach { stack in
            stack.orientation = .vertical
            stack.alignment = .centerX
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
        }
        baseStack.addArrangedSubview(baseStatusLabel)
        baseStack.addArrangedSubview(baseDeviceLabel)
        fillStack.addArrangedSubview(fillStatusLabel)
        fillStack.addArrangedSubview(fillDeviceLabel)

        fillContainer.translatesAutoresizingMaskIntoConstraints = false
        fillContainer.wantsLayer = true
        fillContainer.layer?.masksToBounds = true

        addSubview(baseStack)
        addSubview(fillContainer)
        fillContainer.addSubview(fillStack)

        fillExtentConstraint = fillContainer.heightAnchor.constraint(equalToConstant: 0)
        fillExtentConstraint?.isActive = true

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalTo: baseStack.widthAnchor),
            heightAnchor.constraint(equalTo: baseStack.heightAnchor),

            baseStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            baseStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            baseStack.topAnchor.constraint(equalTo: topAnchor),
            baseStack.bottomAnchor.constraint(equalTo: bottomAnchor),

            fillContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            fillContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            fillStack.leadingAnchor.constraint(equalTo: fillContainer.leadingAnchor),
            fillStack.bottomAnchor.constraint(equalTo: fillContainer.bottomAnchor),
            fillStack.widthAnchor.constraint(equalTo: baseStack.widthAnchor),
            fillStack.heightAnchor.constraint(equalTo: baseStack.heightAnchor)
        ])
    }

    private func updateProgress() {
        fillExtentConstraint?.constant = bounds.height * progress
    }
}

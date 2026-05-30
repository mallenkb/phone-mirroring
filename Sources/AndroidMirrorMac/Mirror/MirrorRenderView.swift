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
    private let contentStack = NSStackView()
    private let statusLabel = LoadingProgressTextView(text: "Connecting")
    private let deviceLabel = NSTextField(labelWithString: "")

    var deviceName: String = "" {
        didSet {
            let trimmedName = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            deviceLabel.stringValue = trimmedName.isEmpty ? "Android Device" : trimmedName
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
        statusLabel.layoutSubtreeIfNeeded()
    }

    func startProgress(duration: TimeInterval) {
        statusLabel.startProgress(duration: duration)
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

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.heightAnchor.constraint(equalToConstant: 24).isActive = true

        deviceLabel.font = .systemFont(ofSize: 42, weight: .heavy)
        deviceLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        deviceLabel.alignment = .center
        deviceLabel.lineBreakMode = .byTruncatingTail
        deviceLabel.maximumNumberOfLines = 1
        deviceLabel.stringValue = "Android Device"

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 6
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(statusLabel)
        contentStack.addArrangedSubview(deviceLabel)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }
}

private final class LoadingProgressTextView: NSView {
    private let baseLabel: NSTextField
    private let fillLabel: NSTextField
    private let fillContainer = NSView()
    private var fillWidthConstraint: NSLayoutConstraint?
    private var progressTimer: Timer?
    private var progress: CGFloat = 0 {
        didSet { updateProgress() }
    }

    init(text: String) {
        baseLabel = NSTextField(labelWithString: text)
        fillLabel = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        setupView()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let labelSize = baseLabel.intrinsicContentSize
        return NSSize(width: labelSize.width, height: max(24, labelSize.height))
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

        [baseLabel, fillLabel].forEach { label in
            label.font = .systemFont(ofSize: 19, weight: .semibold)
            label.alignment = .center
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 1
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        baseLabel.textColor = NSColor.white.withAlphaComponent(0.34)
        fillLabel.textColor = NSColor.white.withAlphaComponent(0.86)

        fillContainer.translatesAutoresizingMaskIntoConstraints = false
        fillContainer.wantsLayer = true
        fillContainer.layer?.masksToBounds = true

        addSubview(baseLabel)
        addSubview(fillContainer)
        fillContainer.addSubview(fillLabel)

        fillWidthConstraint = fillContainer.widthAnchor.constraint(equalToConstant: 0)
        fillWidthConstraint?.isActive = true

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalTo: baseLabel.widthAnchor),
            heightAnchor.constraint(equalTo: baseLabel.heightAnchor),

            baseLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            baseLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            baseLabel.topAnchor.constraint(equalTo: topAnchor),
            baseLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            fillContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillContainer.topAnchor.constraint(equalTo: topAnchor),
            fillContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            fillLabel.leadingAnchor.constraint(equalTo: fillContainer.leadingAnchor),
            fillLabel.topAnchor.constraint(equalTo: fillContainer.topAnchor),
            fillLabel.bottomAnchor.constraint(equalTo: fillContainer.bottomAnchor),
            fillLabel.widthAnchor.constraint(equalTo: baseLabel.widthAnchor)
        ])
    }

    private func updateProgress() {
        fillWidthConstraint?.constant = bounds.width * progress
    }
}

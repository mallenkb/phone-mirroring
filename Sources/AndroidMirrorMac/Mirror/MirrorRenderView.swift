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
    private var aspect: CGSize = .zero
    private var trackingArea: NSTrackingArea?
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
    }

    func setStreamSize(width: UInt32, height: UInt32) {
        aspect = CGSize(width: CGFloat(width), height: CGFloat(height))
        needsLayout = true
        updateVideoLayerFrame()
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

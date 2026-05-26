import AppKit

/// Root content view for the mirror `NSWindow`.
///
/// Hierarchy (outer → inner):
/// `RootWindowView` → `OuterFrameView` → (`ToolbarChromeView`, `PhoneMirrorContainerView` → `MirrorRenderView`)
final class RootWindowView: NSView {
    var onChromeVisibilityChanged: ((Bool) -> Void)?

    let renderView: MirrorRenderView
    private let outerFrameView: OuterFrameView

    private var trackingArea: NSTrackingArea?
    private var hideWorkItem: DispatchWorkItem?

    private var isChromeVisible = false
    private var isPointerInTopActivationZone = false
    private var isPointerInChrome = false

    init(model: AppModel, renderView: MirrorRenderView, frame frameRect: NSRect) {
        self.renderView = renderView
        outerFrameView = OuterFrameView(model: model, mirroredPhoneView: renderView)
        super.init(frame: frameRect)
        setupView()
        setupCallbacks()
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateTopActivationState(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        updateTopActivationState(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInTopActivationZone = false
        scheduleHideChromeIfNeeded()
    }

    func revealChrome() {
        hideWorkItem?.cancel()
        guard !isChromeVisible else { return }
        applyChromeVisibility(true, animated: true)
    }

    func scheduleHideChromeIfNeeded() {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !isPointerInTopActivationZone && !isPointerInChrome {
                applyChromeVisibility(false, animated: true)
            }
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: workItem)
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        outerFrameView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outerFrameView)
        NSLayoutConstraint.activate([
            outerFrameView.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerFrameView.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerFrameView.topAnchor.constraint(equalTo: topAnchor),
            outerFrameView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupCallbacks() {
        outerFrameView.toolbarChromeView.onPointerEntered = { [weak self] in
            self?.isPointerInChrome = true
            self?.revealChrome()
        }
        outerFrameView.toolbarChromeView.onPointerExited = { [weak self] in
            self?.isPointerInChrome = false
            self?.scheduleHideChromeIfNeeded()
        }
    }

    private func updateTopActivationState(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let isNearTop = location.y >= bounds.height - WindowChromeConstants.hoverActivationHeight

        if isNearTop != isPointerInTopActivationZone {
            isPointerInTopActivationZone = isNearTop
        }

        if isNearTop {
            revealChrome()
        } else {
            scheduleHideChromeIfNeeded()
        }
    }

    private func applyChromeVisibility(_ isVisible: Bool, animated: Bool) {
        hideWorkItem?.cancel()
        isChromeVisible = isVisible
        onChromeVisibilityChanged?(isVisible)
        outerFrameView.applyChromeVisibility(isVisible, animated: animated)
    }
}

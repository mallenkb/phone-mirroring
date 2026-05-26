import AppKit

/// Top toolbar: traffic lights and drag region.
final class ToolbarChromeView: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private let model: AppModel
    private let materialView = NSVisualEffectView()
    private let dragView = ChromeDragView()
    private let closeButton = TrafficLightButton(color: NSColor.systemRed, accessibilityDescription: "Close mirror")
    private let minimizeButton = TrafficLightButton(color: NSColor.systemYellow, accessibilityDescription: "Minimize mirror")
    private let zoomButton = TrafficLightButton(color: NSColor.systemGreen, accessibilityDescription: "Expand mirror")
    private var trackingArea: NSTrackingArea?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        setupView()
        setupLayout()
        wireActions()
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

    override func mouseEntered(with event: NSEvent) { onPointerEntered?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }

    private func setupView() {
        wantsLayer = true
        alphaValue = 0
        isHidden = true

        layer?.cornerRadius = WindowChromeConstants.cornerRadiusHover
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer?.masksToBounds = true

        materialView.material = .hudWindow
        materialView.blendingMode = .withinWindow
        materialView.state = .active
        materialView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(materialView)
    }

    private func setupLayout() {
        [dragView, closeButton, minimizeButton, zoomButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: WindowChromeConstants.trafficLightLeftPadding),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 13),
            closeButton.heightAnchor.constraint(equalToConstant: 13),

            minimizeButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            minimizeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            minimizeButton.widthAnchor.constraint(equalToConstant: 13),
            minimizeButton.heightAnchor.constraint(equalToConstant: 13),

            zoomButton.leadingAnchor.constraint(equalTo: minimizeButton.trailingAnchor, constant: 8),
            zoomButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            zoomButton.widthAnchor.constraint(equalToConstant: 13),
            zoomButton.heightAnchor.constraint(equalToConstant: 13),

            dragView.leadingAnchor.constraint(equalTo: zoomButton.trailingAnchor, constant: 12),
            dragView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragView.topAnchor.constraint(equalTo: topAnchor),
            dragView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func wireActions() {
        closeButton.onAction = { [weak self] in
            self?.model.closeMirrorWindow()
        }
        minimizeButton.onAction = { [weak self] in
            self?.model.minimizeMirrorWindow()
        }
        zoomButton.onAction = { [weak self] in
            self?.model.toggleMirrorFullscreen()
        }
    }
}

final class TrafficLightButton: NSView {
    var onAction: (() -> Void)?

    private let color: NSColor

    init(color: NSColor, accessibilityDescription: String) {
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityDescription)
        wantsLayer = true
        layer?.cornerRadius = 6.5
        layer?.backgroundColor = color.cgColor
        toolTip = accessibilityDescription
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        layer?.opacity = 0.72
    }

    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onAction?()
        }
    }
}

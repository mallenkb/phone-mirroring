import AppKit

/// Top toolbar: native traffic lights, drag region, and mirror controls.
final class ToolbarChromeView: NSView {
    var onPointerEntered: (() -> Void)?
    var onPointerExited: (() -> Void)?

    private let materialView = NSVisualEffectView()
    private let dragView = ChromeDragView()
    private var trackingArea: NSTrackingArea?
    private var didInstallNativeTrafficLights = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
        setupLayout()
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installNativeTrafficLightsIfNeeded()
    }

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
        clipsToBounds = true

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
        dragView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragView)

        NSLayoutConstraint.activate([
            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            dragView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragView.topAnchor.constraint(equalTo: topAnchor),
            dragView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func installNativeTrafficLightsIfNeeded() {
        guard !didInstallNativeTrafficLights, let window else { return }
        guard let close = window.standardWindowButton(.closeButton),
              let minimize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { return }

        didInstallNativeTrafficLights = true

        for button in [close, minimize, zoom] {
            button.isHidden = false
            button.translatesAutoresizingMaskIntoConstraints = false
            if button.superview !== self {
                button.removeFromSuperview()
                addSubview(button)
            }
        }

        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: leadingAnchor, constant: WindowChromeConstants.trafficLightLeftPadding),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),

            minimize.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 6),
            minimize.centerYAnchor.constraint(equalTo: centerYAnchor),

            zoom.leadingAnchor.constraint(equalTo: minimize.trailingAnchor, constant: 6),
            zoom.centerYAnchor.constraint(equalTo: centerYAnchor),

            dragView.leadingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: 12),
        ])
    }
}

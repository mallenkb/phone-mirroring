import AppKit

/// Clips mirrored phone pixels to the device-shaped rounded rect inside the frame.
final class PhoneMirrorContainerView: NSView {
    private let mirroredPhoneView: NSView

    init(contentView: NSView) {
        mirroredPhoneView = contentView
        super.init(frame: .zero)
        setupView()
    }

    convenience init() {
        self.init(contentView: MirrorRenderView())
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    func setChromeVisible(_ isVisible: Bool) {
        layer?.cornerRadius = isVisible
            ? WindowChromeConstants.cornerRadiusHover
            : WindowChromeConstants.cornerRadiusIdle
    }

    private func setupView() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = WindowChromeConstants.cornerRadiusIdle
        layer?.setValue("continuous", forKey: "cornerCurve")
        layer?.backgroundColor = NSColor.black.cgColor

        mirroredPhoneView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(mirroredPhoneView)
        NSLayoutConstraint.activate([
            mirroredPhoneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            mirroredPhoneView.trailingAnchor.constraint(equalTo: trailingAnchor),
            mirroredPhoneView.topAnchor.constraint(equalTo: topAnchor),
            mirroredPhoneView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

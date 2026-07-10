import AppKit

final class MirrorLockedView: NSView {
    static let titleText = "Android is locked"
    static let messageText = "Unlock your phone to continue mirroring."
    static let resumeText = "Mirroring will resume automatically."

    private let gradientLayer = CAGradientLayer()
    private let contentStack = NSStackView()

    var cornerRadius: CGFloat = 0 {
        didSet { applyCornerMask() }
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
        applyCornerMask()
    }

    private func setupView() {
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(gradientLayer)

        let deepCyan = PhoneRelayBrand.deepCyanNSColor
        gradientLayer.colors = [
            (deepCyan.blended(withFraction: 0.24, of: .black) ?? deepCyan).cgColor,
            deepCyan.cgColor,
            (deepCyan.blended(withFraction: 0.14, of: .white) ?? deepCyan).cgColor
        ]
        gradientLayer.locations = [0, 0.56, 1]
        gradientLayer.startPoint = CGPoint(x: 0.1, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.9, y: 0)

        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: Self.titleText)
        symbol.contentTintColor = NSColor.white.withAlphaComponent(0.94)
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .semibold)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        symbol.translatesAutoresizingMaskIntoConstraints = false

        let title = label(Self.titleText, size: 23, weight: .semibold, alpha: 0.96)
        let message = label(Self.messageText, size: 15, weight: .regular, alpha: 0.86)
        let resume = label(Self.resumeText, size: 12, weight: .regular, alpha: 0.62)

        contentStack.orientation = .vertical
        contentStack.alignment = .centerX
        contentStack.spacing = 9
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(symbol)
        contentStack.setCustomSpacing(18, after: symbol)
        contentStack.addArrangedSubview(title)
        contentStack.addArrangedSubview(message)
        contentStack.setCustomSpacing(5, after: message)
        contentStack.addArrangedSubview(resume)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 46),
            symbol.heightAnchor.constraint(equalToConstant: 46),
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.titleText)
        setAccessibilityHelp("\(Self.messageText) \(Self.resumeText)")
        applyCornerMask()
    }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        alpha: CGFloat
    ) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor.white.withAlphaComponent(alpha)
        label.alignment = .center
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func applyCornerMask() {
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = cornerRadius > 0
        layer?.setValue("continuous", forKey: "cornerCurve")
    }
}

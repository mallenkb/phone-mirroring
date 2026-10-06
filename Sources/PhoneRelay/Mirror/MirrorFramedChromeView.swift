import AppKit
import QuartzCore

/// Content view for the `.framed` chrome style: a solid frame that sits in a
/// child window *below* the phone window and grows a title strip out from
/// behind the phone's top edge, plus a thin rim around the other three sides.
///
/// Collapsed, the frame's shape is exactly the phone's rect, so the phone
/// window hides it. Expanding animates the shape's path outward, which reads
/// as the header sliding up out of the phone rather than fading in on top of
/// it. The window keeps a fixed frame so nothing repositions per animation
/// frame. The frame casts no shadow of its own: the phone window's shadow is
/// the only one, so it looks the same hovered or not.
final class MirrorFramedChromeView: NSView {
    static let headerHeight: CGFloat = MirrorContentWindowController.toolbarBarHeight
    static let rimWidth: CGFloat = 2
    /// Top corners are slightly tighter than the bottom ones, which follow the phone.
    static let topCornerScale: CGFloat = 0.96

    static let revealDuration: CFTimeInterval = 0.32
    static let hideDuration: CFTimeInterval = 0.22
    static let revealTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    static let hideTiming = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    static let controlsRevealDuration: CFTimeInterval = 0.24
    static let controlsHideDuration: CFTimeInterval = 0.12

    /// Window frame for a phone window occupying `phoneFrame` (screen points).
    static func windowFrame(around phoneFrame: NSRect) -> NSRect {
        NSRect(
            x: phoneFrame.minX - rimWidth,
            y: phoneFrame.minY - rimWidth,
            width: phoneFrame.width + rimWidth * 2,
            height: phoneFrame.height + rimWidth + headerHeight
        )
    }

    /// Only the strip directly above the phone summons the header; hovering
    /// the phone itself never does.
    static func revealZone(above phoneFrame: NSRect) -> NSRect {
        NSRect(
            x: phoneFrame.minX - rimWidth,
            y: phoneFrame.maxY,
            width: phoneFrame.width + rimWidth * 2,
            height: headerHeight
        )
    }

    let chromeBar: MirrorChromeBar
    var phoneCornerRadius: CGFloat = MirrorContentWindowController.cornerRadius {
        didSet {
            guard phoneCornerRadius != oldValue else { return }
            needsLayout = true
        }
    }
    private(set) var isExpanded = false
    private let shapeLayer = CAShapeLayer()

    init(chromeBar: MirrorChromeBar) {
        self.chromeBar = chromeBar
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(shapeLayer)
        applyAppearance()

        chromeBar.translatesAutoresizingMaskIntoConstraints = true
        chromeBar.autoresizingMask = []
        chromeBar.alphaValue = 0
        addSubview(chromeBar)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    override func layout() {
        super.layout()
        let rim = Self.rimWidth
        chromeBar.framedTopCornerRadius = topCornerRadius
        chromeBar.frame = NSRect(
            x: rim,
            y: bounds.height - Self.headerHeight,
            width: max(0, bounds.width - rim * 2),
            height: Self.headerHeight
        )
        // Resizes and radius changes snap; only reveal/hide animates.
        guard shapeLayer.animation(forKey: Self.animationKey) == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shapeLayer.frame = bounds
        shapeLayer.path = path(expanded: isExpanded)
        CATransaction.commit()
    }

    /// Animates the frame out from behind the phone (or back behind it) and
    /// fades the controls in step. `completion` runs once the motion settles.
    func setExpanded(_ expanded: Bool, animated: Bool, completion: (() -> Void)? = nil) {
        // Settle any pending layout in the *current* pose first, so the
        // animation has a real starting shape. Starting from the in-flight
        // shape lets a quick in/out reverse smoothly.
        layoutSubtreeIfNeeded()
        let from = shapeLayer.presentation()?.path ?? shapeLayer.path
        isExpanded = expanded
        let target = path(expanded: expanded)

        guard animated, from != nil else {
            shapeLayer.removeAnimation(forKey: Self.animationKey)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shapeLayer.frame = bounds
            shapeLayer.path = target
            CATransaction.commit()
            chromeBar.alphaValue = expanded ? 1 : 0
            chromeBar.setBarRevealed(expanded, animated: false)
            completion?()
            return
        }

        let pathAnimation = CABasicAnimation(keyPath: "path")
        pathAnimation.fromValue = from
        pathAnimation.toValue = target
        pathAnimation.duration = expanded ? Self.revealDuration : Self.hideDuration
        pathAnimation.timingFunction = expanded ? Self.revealTiming : Self.hideTiming

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        CATransaction.setDisableActions(true)
        shapeLayer.path = target
        shapeLayer.add(pathAnimation, forKey: Self.animationKey)
        CATransaction.commit()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = expanded ? Self.controlsRevealDuration : Self.controlsHideDuration
            context.timingFunction = expanded ? Self.revealTiming : Self.hideTiming
            chromeBar.animator().alphaValue = expanded ? 1 : 0
        }
        // The bar's own spring adds a small rise as the header opens.
        chromeBar.setBarRevealed(expanded, animated: true)
    }

    private static let animationKey = "framedChromeReveal"

    /// Expanded top corner radius, a little tighter than the bottom corners.
    private var topCornerRadius: CGFloat {
        (phoneCornerRadius + Self.rimWidth) * Self.topCornerScale
    }

    private func applyAppearance() {
        // Same surface colour as the floating bar.
        var resolved = NSColor.windowBackgroundColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = (NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor).cgColor
        }
        shapeLayer.fillColor = resolved
    }

    /// Collapsed: exactly the phone's rect, hidden behind the phone window.
    /// Expanded: the phone's rect plus the rim and header. Both come from the
    /// same builder so Core Animation can interpolate between them.
    private func path(expanded: Bool) -> CGPath {
        let rim = Self.rimWidth
        let phone = NSRect(
            x: rim,
            y: rim,
            width: max(0, bounds.width - rim * 2),
            height: max(0, bounds.height - rim - Self.headerHeight)
        )
        let radius = phoneCornerRadius
        guard expanded else {
            return Self.roundedPath(phone, topRadius: radius, bottomRadius: radius)
        }
        return Self.roundedPath(
            bounds,
            topRadius: topCornerRadius,
            bottomRadius: radius + rim
        )
    }

    private static func roundedPath(_ rect: NSRect, topRadius: CGFloat, bottomRadius: CGFloat) -> CGPath {
        let top = min(topRadius, rect.width / 2, rect.height / 2)
        let bottom = min(bottomRadius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + bottom, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - bottom, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + bottom), radius: bottom)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - top))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - top, y: rect.maxY), radius: top)
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - top), radius: top)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bottom))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + bottom, y: rect.minY), radius: bottom)
        path.closeSubpath()
        return path
    }

    var isExpandedForTesting: Bool { isExpanded }
}

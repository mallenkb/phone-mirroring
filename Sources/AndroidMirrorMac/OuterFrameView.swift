import AppKit
import QuartzCore

/// Device shell inside the window: background, border, and corner radius.
/// Contains the toolbar chrome and the clipped phone mirror container.
final class OuterFrameView: NSView {
    let toolbarChromeView: ToolbarChromeView
    let phoneMirrorContainerView: PhoneMirrorContainerView

    private var phoneTopConstraint: NSLayoutConstraint!
    private var phoneLeadingConstraint: NSLayoutConstraint!
    private var phoneTrailingConstraint: NSLayoutConstraint!
    private var phoneBottomConstraint: NSLayoutConstraint!
    private var chromeTopConstraint: NSLayoutConstraint!

    init(model: AppModel, mirroredPhoneView: MirrorRenderView) {
        toolbarChromeView = ToolbarChromeView(model: model)
        phoneMirrorContainerView = PhoneMirrorContainerView(contentView: mirroredPhoneView)
        super.init(frame: .zero)
        setupView()
        setupLayout()
        applyChromeVisibility(false, animated: false)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    func applyChromeVisibility(_ isVisible: Bool, animated: Bool) {
        phoneTopConstraint.constant = WindowChromeConstants.idleContentInset
        phoneLeadingConstraint.constant = WindowChromeConstants.idleContentInset
        phoneTrailingConstraint.constant = -WindowChromeConstants.idleContentInset
        phoneBottomConstraint.constant = -WindowChromeConstants.idleContentInset
        chromeTopConstraint.constant = isVisible ? 0 : -WindowChromeConstants.toolbarSlideDistance

        toolbarChromeView.isHidden = false
        phoneMirrorContainerView.setChromeVisible(isVisible)

        let updates = {
            self.layer?.cornerRadius = isVisible
                ? WindowChromeConstants.cornerRadiusHover
                : WindowChromeConstants.cornerRadiusIdle
            self.layer?.borderWidth = isVisible ? 1 : 0
            self.layer?.backgroundColor = isVisible
                ? NSColor.windowBackgroundColor.withAlphaComponent(0.22).cgColor
                : NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1).cgColor
            self.toolbarChromeView.animator().alphaValue = isVisible ? 1 : 0
            self.layoutSubtreeIfNeeded()
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = isVisible
                    ? WindowChromeConstants.toolbarFadeInDuration
                    : WindowChromeConstants.toolbarFadeOutDuration
                context.allowsImplicitAnimation = true
                context.timingFunction = CAMediaTimingFunction(name: isVisible ? .easeOut : .easeIn)
                updates()
            } completionHandler: {
                if !isVisible {
                    self.toolbarChromeView.isHidden = true
                }
            }
        } else {
            toolbarChromeView.alphaValue = isVisible ? 1 : 0
            updates()
            toolbarChromeView.isHidden = !isVisible
        }
    }

    private func setupView() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = WindowChromeConstants.cornerRadiusIdle
        layer?.setValue("continuous", forKey: "cornerCurve")
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.backgroundColor = NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1).cgColor
    }

    private func setupLayout() {
        toolbarChromeView.translatesAutoresizingMaskIntoConstraints = false
        phoneMirrorContainerView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(phoneMirrorContainerView)
        addSubview(toolbarChromeView)

        phoneTopConstraint = phoneMirrorContainerView.topAnchor.constraint(equalTo: topAnchor)
        phoneLeadingConstraint = phoneMirrorContainerView.leadingAnchor.constraint(equalTo: leadingAnchor)
        phoneTrailingConstraint = phoneMirrorContainerView.trailingAnchor.constraint(equalTo: trailingAnchor)
        phoneBottomConstraint = phoneMirrorContainerView.bottomAnchor.constraint(equalTo: bottomAnchor)
        chromeTopConstraint = toolbarChromeView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: -WindowChromeConstants.toolbarSlideDistance
        )

        NSLayoutConstraint.activate([
            phoneTopConstraint,
            phoneLeadingConstraint,
            phoneTrailingConstraint,
            phoneBottomConstraint,

            chromeTopConstraint,
            toolbarChromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarChromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarChromeView.heightAnchor.constraint(equalToConstant: WindowChromeConstants.toolbarHeight),
        ])
    }
}

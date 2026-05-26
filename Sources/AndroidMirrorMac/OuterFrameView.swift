import AppKit
import QuartzCore

/// Device shell inside the window: background, border, and corner radius.
/// Contains the toolbar chrome and the clipped phone mirror container.
final class OuterFrameView: NSView {
    let toolbarChromeView: ToolbarChromeView
    let phoneMirrorContainerView: PhoneMirrorContainerView

    private var toolbarHeightConstraint: NSLayoutConstraint!
    private var phoneTopGapConstraint: NSLayoutConstraint!
    private var phoneLeadingConstraint: NSLayoutConstraint!
    private var phoneTrailingConstraint: NSLayoutConstraint!
    private var phoneBottomConstraint: NSLayoutConstraint!

    private var isChromeVisible = false

    init(model: AppModel, mirroredPhoneView: MirrorRenderView) {
        toolbarChromeView = ToolbarChromeView(frame: .zero)
        phoneMirrorContainerView = PhoneMirrorContainerView(contentView: mirroredPhoneView)
        super.init(frame: .zero)
        setupView()
        setupLayout()
        applyChromeVisibility(false, animated: false)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }

    func applyChromeVisibility(_ isVisible: Bool, animated: Bool) {
        guard !animated || isChromeVisible != isVisible else { return }
        isChromeVisible = isVisible

        if isVisible {
            toolbarChromeView.isHidden = false
        }

        let sideInset = isVisible ? WindowChromeConstants.hoverSideInset : WindowChromeConstants.idleContentInset
        let bottomInset = isVisible ? WindowChromeConstants.hoverBottomInset : WindowChromeConstants.idleContentInset
        let topGap = isVisible ? WindowChromeConstants.toolbarContentGap : 0
        let toolbarHeight = isVisible ? WindowChromeConstants.toolbarHeight : 0
        let toolbarAlpha: CGFloat = isVisible ? 1 : 0

        let updates = {
            self.toolbarHeightConstraint.constant = toolbarHeight
            self.phoneTopGapConstraint.constant = topGap
            self.phoneLeadingConstraint.constant = sideInset
            self.phoneTrailingConstraint.constant = -sideInset
            self.phoneBottomConstraint.constant = -bottomInset

            self.toolbarChromeView.alphaValue = toolbarAlpha
            self.phoneMirrorContainerView.setChromeVisible(isVisible)

            self.layer?.cornerRadius = WindowChromeConstants.cornerRadiusIdle
            self.layer?.borderWidth = isVisible ? 1 : 0
            self.layer?.backgroundColor = isVisible
                ? NSColor.windowBackgroundColor.withAlphaComponent(0.22).cgColor
                : NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1).cgColor

            self.layoutSubtreeIfNeeded()
        }

        if animated {
            ToolbarChromeAnimator.run(visible: isVisible, animations: updates) {
                if !isVisible {
                    self.toolbarChromeView.isHidden = true
                }
            }
        } else {
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

        toolbarHeightConstraint = toolbarChromeView.heightAnchor.constraint(equalToConstant: 0)
        phoneTopGapConstraint = phoneMirrorContainerView.topAnchor.constraint(
            equalTo: toolbarChromeView.bottomAnchor,
            constant: 0
        )
        phoneLeadingConstraint = phoneMirrorContainerView.leadingAnchor.constraint(equalTo: leadingAnchor)
        phoneTrailingConstraint = phoneMirrorContainerView.trailingAnchor.constraint(equalTo: trailingAnchor)
        phoneBottomConstraint = phoneMirrorContainerView.bottomAnchor.constraint(equalTo: bottomAnchor)

        NSLayoutConstraint.activate([
            toolbarChromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarChromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarChromeView.topAnchor.constraint(equalTo: topAnchor),
            toolbarHeightConstraint,

            phoneTopGapConstraint,
            phoneLeadingConstraint,
            phoneTrailingConstraint,
            phoneBottomConstraint,
        ])
    }
}

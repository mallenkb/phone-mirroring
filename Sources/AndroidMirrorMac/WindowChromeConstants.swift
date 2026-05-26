import AppKit

enum WindowChromeConstants {
    static let windowWidth: CGFloat = 390
    static let windowHeight: CGFloat = 850

    static let cornerRadiusIdle: CGFloat = 34
    static let cornerRadiusHover: CGFloat = cornerRadiusIdle

    static let toolbarHeight: CGFloat = 42
    static let hoverActivationHeight: CGFloat = 56

    static let idleContentInset: CGFloat = 0
    static let hoverSideInset: CGFloat = 8
    static let hoverBottomInset: CGFloat = 8
    /// Gap between the toolbar and phone content when the chrome is revealed.
    static let toolbarContentGap: CGFloat = 2

    static let toolbarFadeInDuration: TimeInterval = ToolbarChromeAnimator.showDuration
    static let toolbarFadeOutDuration: TimeInterval = ToolbarChromeAnimator.hideDuration

    static let trafficLightLeftPadding: CGFloat = 12
    static let trafficLightTopPadding: CGFloat = 12

    static let rightButtonSize: CGFloat = 24
    static let rightButtonGap: CGFloat = 10
    static let rightButtonTrailingPadding: CGFloat = 14
}

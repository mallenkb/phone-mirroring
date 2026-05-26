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
    static let hoverTopInset: CGFloat = 44

    static let toolbarFadeInDuration: TimeInterval = 0.13
    static let toolbarFadeOutDuration: TimeInterval = 0.10

    static let contentInsetAnimationDuration: TimeInterval = 0.13
    static let toolbarSlideDistance: CGFloat = 10

    static let trafficLightLeftPadding: CGFloat = 12
    static let trafficLightTopPadding: CGFloat = 12

    static let rightButtonSize: CGFloat = 24
    static let rightButtonGap: CGFloat = 10
    static let rightButtonTrailingPadding: CGFloat = 14
}

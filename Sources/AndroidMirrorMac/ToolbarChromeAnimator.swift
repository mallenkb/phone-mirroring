import AppKit
import QuartzCore

/// Shared timing for toolbar grow / shrink transitions.
enum ToolbarChromeAnimator {
    static let showDuration: TimeInterval = 0.52
    static let hideDuration: TimeInterval = 0.42

    /// Smooth deceleration into the revealed state (Reflect-style ease-out).
    private static let showTiming = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
    /// Gentle ease-in-out collapse without feeling sluggish.
    private static let hideTiming = CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.25, 1.0)

    static func run(
        visible: Bool,
        animations: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? showDuration : hideDuration
            context.timingFunction = visible ? showTiming : hideTiming
            context.allowsImplicitAnimation = true
            animations()
        } completionHandler: {
            completion?()
        }
    }
}

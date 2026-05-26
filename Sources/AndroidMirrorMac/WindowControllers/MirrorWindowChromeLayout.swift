import AppKit
import CoreGraphics

enum MirrorWindowChromeLayout {
    static func hoverChromeFrame(
        forScrcpyBounds bounds: CGRect,
        screenHeight: CGFloat,
        height: CGFloat
    ) -> NSRect {
        return NSRect(
            x: bounds.minX,
            y: screenHeight - bounds.minY,
            width: bounds.width,
            height: height
        )
    }

    static func scrcpyFrameKeepingHoverChromeVisible(
        _ proposed: CGRect,
        inVisibleFrame visibleFrame: NSRect,
        screenHeight: CGFloat,
        chromeHeight: CGFloat
    ) -> CGRect {
        guard proposed.width > 0, proposed.height > 0 else { return proposed }

        var frame = proposed
        let minYWithRoomForChrome = screenHeight - visibleFrame.maxY + chromeHeight
        let maxYKeepingBottomVisible = screenHeight - visibleFrame.minY - frame.height

        if maxYKeepingBottomVisible >= minYWithRoomForChrome {
            frame.origin.y = min(max(frame.origin.y, minYWithRoomForChrome), maxYKeepingBottomVisible)
        } else {
            frame.origin.y = max(frame.origin.y, minYWithRoomForChrome)
        }

        let maxXKeepingRightVisible = visibleFrame.maxX - frame.width
        if maxXKeepingRightVisible >= visibleFrame.minX {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), maxXKeepingRightVisible)
        } else {
            frame.origin.x = visibleFrame.minX
        }
        return frame
    }

    static func overlayFrame(
        forScrcpyBounds bounds: CGRect,
        screenHeight: CGFloat,
        titleHeight: CGFloat,
        sideInset: CGFloat,
        bottomInset: CGFloat
    ) -> NSRect {
        let scrcpyBottomNS = screenHeight - bounds.maxY
        return NSRect(
            x: bounds.minX - sideInset,
            y: scrcpyBottomNS - bottomInset,
            width: bounds.width + sideInset * 2,
            height: bounds.height + bottomInset + titleHeight
        )
    }

    static func titleBarFrame(
        forScrcpyBounds bounds: CGRect,
        screenHeight: CGFloat,
        titleHeight: CGFloat,
        outset: CGFloat
    ) -> NSRect {
        let overlay = overlayFrame(
            forScrcpyBounds: bounds,
            screenHeight: screenHeight,
            titleHeight: titleHeight,
            sideInset: outset,
            bottomInset: outset
        )
        return NSRect(
            x: overlay.minX,
            y: overlay.maxY - titleHeight,
            width: overlay.width,
            height: titleHeight
        )
    }

    static func expandedScrcpyFrame(
        from current: CGRect,
        inVisibleFrame visibleFrame: NSRect,
        screenHeight: CGFloat,
        chromeHeight: CGFloat,
        padding: CGFloat
    ) -> CGRect {
        guard current.width > 0, current.height > 0 else { return current }

        let availableWidth = max(1, visibleFrame.width - padding * 2)
        let availableHeight = max(1, visibleFrame.height - chromeHeight - padding * 2)
        let aspectRatio = current.width / current.height

        var targetWidth = availableWidth
        var targetHeight = targetWidth / aspectRatio
        if targetHeight > availableHeight {
            targetHeight = availableHeight
            targetWidth = targetHeight * aspectRatio
        }

        let contentBottom = visibleFrame.minY + padding
        let contentTop = visibleFrame.maxY - chromeHeight - padding
        let contentHeight = max(1, contentTop - contentBottom)
        let bottomNS = contentBottom + max(0, (contentHeight - targetHeight) / 2)
        let x = visibleFrame.midX - targetWidth / 2
        let y = screenHeight - (bottomNS + targetHeight)

        return CGRect(
            x: x,
            y: y,
            width: targetWidth,
            height: targetHeight
        )
    }
}

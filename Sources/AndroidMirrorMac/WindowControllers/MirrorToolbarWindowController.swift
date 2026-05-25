import AppKit
import SwiftUI

/// Borderless floating panel that hosts the MirrorToolbarView and tracks the
/// scrcpy window so the toolbar stays anchored above it.
@MainActor
final class MirrorToolbarWindowController {
    private weak var model: AppModel?
    private let scrcpyPid: pid_t
    private let onMirrorWindowFound: (() -> Void)?
    private var window: NSPanel?
    private var hostingView: NSHostingView<MirrorToolbarView>?
    private var trackingTimer: Timer?
    private var lastFrame: NSRect = .zero
    private var loggedFoundScrcpy = false

    static let fallbackSize = NSSize(width: 340, height: 52)

    init(model: AppModel, scrcpyPid: pid_t, onMirrorWindowFound: (() -> Void)? = nil) {
        self.model = model
        self.scrcpyPid = scrcpyPid
        self.onMirrorWindowFound = onMirrorWindowFound
        present()
    }

    func close() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }

    private func present() {
        guard let model else { return }
        let hosting = NSHostingView(rootView: MirrorToolbarView(model: model))
        hosting.layoutSubtreeIfNeeded()
        let intrinsic = hosting.fittingSize
        let size = NSSize(
            width: intrinsic.width > 10 ? intrinsic.width : Self.fallbackSize.width,
            height: intrinsic.height > 10 ? intrinsic.height : Self.fallbackSize.height
        )

        // Initial position: top-center of main screen so the toolbar is visible
        // even before scrcpy's window appears.
        let primary = NSScreen.main ?? NSScreen.screens.first
        let initialFrame: NSRect
        if let primary {
            let visible = primary.visibleFrame
            initialFrame = NSRect(
                x: visible.midX - size.width / 2,
                y: visible.maxY - size.height - 12,
                width: size.width,
                height: size.height
            )
        } else {
            initialFrame = NSRect(origin: .zero, size: size)
        }

        hosting.frame = NSRect(origin: .zero, size: size)
        hostingView = hosting

        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.setFrame(initialFrame, display: true)
        panel.orderFrontRegardless()
        window = panel
        lastFrame = initialFrame

        Logger.log("Toolbar presented at \(NSStringFromRect(initialFrame)) for pid=\(scrcpyPid)")
        startTracking()
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        followScrcpy()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.followScrcpy() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func followScrcpy() {
        guard let window else { return }
        guard let bounds = ScrcpyController.windowBounds(pid: scrcpyPid) else {
            return
        }

        if !loggedFoundScrcpy {
            loggedFoundScrcpy = true
            Logger.log("Located scrcpy window: \(bounds)")
            onMirrorWindowFound?()
        }

        let toolbarSize = window.frame.size
        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height

        let centerX = bounds.midX
        let topYInCG = bounds.minY
        let gap: CGFloat = 10
        let toolbarBottomNS = primaryHeight - topYInCG + MirrorFrameWindowController.chromeHeight + gap

        var newFrame = NSRect(
            x: centerX - toolbarSize.width / 2,
            y: toolbarBottomNS,
            width: toolbarSize.width,
            height: toolbarSize.height
        )

        // Pick the screen the scrcpy window is on (convert its CG midpoint to NS coords).
        let scrcpyNSPoint = NSPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(scrcpyNSPoint) }) ?? primary
        let visible = targetScreen.visibleFrame
        if newFrame.maxX > visible.maxX { newFrame.origin.x = visible.maxX - newFrame.width - 8 }
        if newFrame.minX < visible.minX { newFrame.origin.x = visible.minX + 8 }
        if newFrame.maxY > visible.maxY {
            // No room above scrcpy — tuck the toolbar at the top of its display.
            newFrame.origin.y = visible.maxY - newFrame.height - 4
        }

        if newFrame.equalTo(lastFrame) { return }
        lastFrame = newFrame
        window.setFrame(newFrame, display: true)
    }
}

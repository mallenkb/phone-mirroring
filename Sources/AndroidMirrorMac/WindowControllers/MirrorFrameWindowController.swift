import AppKit
import SwiftUI
import Combine

/// Reflect-style hover chrome that overlays the top edge of the live scrcpy
/// frame. When the cursor leaves the chrome zone the panel ignores mouse
/// events so the phone screen underneath stays fully interactive.
@MainActor
final class MirrorFrameWindowController {
    /// Visibility binding shared with `MirrorTopBarView`. The controller drives
    /// `isVisible` from a global mouse-position poll so detection works even
    /// when the panel ignores mouse events. `isDragging` is driven by the view
    /// so the controller can pause its hover logic while a window drag is in
    /// flight (the cursor often leaves the panel rect mid-drag).
    final class Visibility: ObservableObject {
        @Published var isVisible: Bool = false
        @Published var isDragging: Bool = false
    }

    private weak var model: AppModel?
    private let scrcpyPid: pid_t
    private let onMirrorWindowFound: (() -> Void)?
    private let visibility = Visibility()
    private var titleBarWindow: NSPanel?
    private var trackingTimer: Timer?
    private var lastTitleBarFrame: NSRect = .zero
    private var loggedFoundScrcpy = false

    /// Height of the chrome overlay (drops down from the top of the scrcpy
    /// window). Sized to roughly match the phone's status-bar area.
    static let chromeHeight: CGFloat = 44

    // Kept for backward compatibility with older callers.
    static let titleHeight: CGFloat = chromeHeight
    static let collapsedTitleHeight: CGFloat = chromeHeight
    static let expandedTitleHeight: CGFloat = chromeHeight
    static let outset: CGFloat = 8

    init(model: AppModel, scrcpyPid: pid_t, onMirrorWindowFound: (() -> Void)? = nil) {
        self.model = model
        self.scrcpyPid = scrcpyPid
        self.onMirrorWindowFound = onMirrorWindowFound
        present()
    }

    func close() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        titleBarWindow?.orderOut(nil)
        titleBarWindow = nil
    }

    private func present() {
        guard let model else { return }

        let titleHosting = NSHostingView(
            rootView: MirrorTopBarView(model: model, visibility: visibility)
        )
        titleHosting.frame = NSRect(
            origin: .zero,
            size: NSSize(width: 420, height: Self.chromeHeight)
        )
        titleHosting.autoresizingMask = [.width, .height]

        let titlePanel = NSPanel(
            contentRect: titleHosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configure(panel: titlePanel)
        titlePanel.contentView = titleHosting
        titlePanel.orderFrontRegardless()
        titleBarWindow = titlePanel

        startTracking()
    }

    private func configure(panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Start in pass-through mode so the phone screen stays interactive.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        tick()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func tick() {
        guard let titleBarWindow else { return }
        // Hold position while a drag is in flight — both AX (issuing
        // setWindowFrame on every gesture event) and this poll (reading the
        // possibly-stale CGWindow bounds) race each other and produce visible
        // jitter. The next non-drag tick will resync the panel to scrcpy.
        if visibility.isDragging {
            return
        }
        guard let bounds = ScrcpyController.windowBounds(pid: scrcpyPid) else {
            titleBarWindow.orderOut(nil)
            lastTitleBarFrame = .zero
            if visibility.isVisible { visibility.isVisible = false }
            titleBarWindow.ignoresMouseEvents = true
            return
        }
        if !titleBarWindow.isVisible {
            titleBarWindow.orderFrontRegardless()
        }

        if !loggedFoundScrcpy {
            loggedFoundScrcpy = true
            Logger.log("Located scrcpy window for frame: \(bounds)")
            onMirrorWindowFound?()
        }

        guard let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height

        // Title bar sits STRICTLY ABOVE the scrcpy window — no overlap. That
        // way the drag handle can never intercept events meant for the phone
        // screen (notification swipes, status bar taps, etc.).
        let scrcpyTopNS = primaryHeight - bounds.minY
        var titleBarFrame = NSRect(
            x: bounds.minX,
            y: scrcpyTopNS,
            width: bounds.width,
            height: Self.chromeHeight
        )

        let scrcpyNSPoint = NSPoint(x: bounds.midX, y: primaryHeight - bounds.midY)
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(scrcpyNSPoint) }) ?? primary
        let visible = targetScreen.visibleFrame
        if titleBarFrame.maxY > visible.maxY {
            titleBarFrame.origin.y = visible.maxY - titleBarFrame.height
        }
        if titleBarFrame.minY < visible.minY {
            titleBarFrame.origin.y = visible.minY
        }

        if !titleBarFrame.equalTo(lastTitleBarFrame) {
            lastTitleBarFrame = titleBarFrame
            titleBarWindow.setFrame(titleBarFrame, display: true)
        }

        updateHoverState(panelFrame: titleBarFrame)
    }

    /// Global mouse poll — works even when the panel is set to ignore mouse
    /// events. We treat the panel rect itself as the hover zone so the chrome
    /// shows whenever the cursor is inside the top strip of the mirror.
    private func updateHoverState(panelFrame: NSRect) {
        guard let titleBarWindow else { return }
        // While a drag is in progress, keep the chrome visible and the panel
        // accepting events. The cursor often slips out of the panel rect mid
        // drag (the panel follows scrcpy via AX, which lags the cursor); we
        // do not want the chrome to disappear or stop receiving the drag.
        if visibility.isDragging {
            if !visibility.isVisible { visibility.isVisible = true }
            titleBarWindow.ignoresMouseEvents = false
            return
        }
        let mouse = NSEvent.mouseLocation
        let inZone = panelFrame.contains(mouse)
        if inZone != visibility.isVisible {
            visibility.isVisible = inZone
            // When chrome is visible, accept clicks for the controls; when
            // hidden, pass mouse events through to the phone screen below.
            titleBarWindow.ignoresMouseEvents = !inZone
        }
    }
}

import AppKit

/// Owns the mirror `NSWindow` and the layered view hierarchy from the architecture diagram.
@MainActor
final class WindowController: NSWindowController, NSWindowDelegate {
    let renderView = MirrorRenderView()
    private(set) var rootView: RootWindowView?

    private let model: AppModel
    private weak var mirrorSession: MirrorSession?

    init(model: AppModel) {
        self.model = model
        let window = MirrorWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: WindowChromeConstants.windowWidth,
                height: WindowChromeConstants.windowHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configure(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        guard let window else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        show()
    }

    func attachMirrorSession(_ session: MirrorSession) {
        mirrorSession = session
        renderView.onPointerEvent = { [weak session, weak renderView] event in
            guard let session, let renderView else { return }
            session.forwardPointerEvent(event, in: renderView)
        }
        renderView.onKeyEvent = { [weak session] event in
            session?.forwardKeyEvent(event)
        }
    }

    func setStreamSize(width: UInt32, height: UInt32) {
        guard let window, width > 0, height > 0 else { return }
        renderView.setStreamSize(width: width, height: height)
        let aspect = CGFloat(width) / CGFloat(height)
        window.contentAspectRatio = NSSize(width: aspect, height: 1)

        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let targetHeight = min(visible.height - 80, 900)
        let targetWidth = max(280, min(visible.width - 80, targetHeight * aspect))
        let newHeight = targetWidth / aspect
        let newFrame = NSRect(
            x: window.frame.midX - targetWidth / 2,
            y: window.frame.midY - newHeight / 2,
            width: targetWidth,
            height: newHeight
        )
        window.setFrame(newFrame, display: true, animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        mirrorSession?.stop()
    }

    func windowDidResize(_ notification: Notification) {}

    private func configure(window: NSWindow) {
        window.delegate = self
        window.title = "Android Mirror"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 320, height: 640)
        window.collectionBehavior = [.fullScreenPrimary, .managed]

        model.registerMirrorWindowController(self)

        let rootView = RootWindowView(
            model: model,
            renderView: renderView,
            frame: NSRect(origin: .zero, size: window.frame.size)
        )
        rootView.autoresizingMask = [.width, .height]
        window.contentView = rootView
        self.rootView = rootView
    }
}

private final class MirrorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

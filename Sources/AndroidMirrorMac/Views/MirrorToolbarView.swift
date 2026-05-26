import AppKit
import SwiftUI

/// Reflect-style hover chrome that overlays the top edge of the scrcpy
/// window. Visibility is driven by the window controller (which polls the
/// global cursor) so the controls only appear when the user mouses into the
/// top strip — exactly like Reflect.
struct MirrorTopBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var visibility: MirrorFrameWindowController.Visibility

    private let chromeHeight: CGFloat = MirrorFrameWindowController.chromeHeight
    private let cornerRadius: CGFloat = 14

    var body: some View {
        ZStack(alignment: .top) {
            chromeBar
                .opacity(visibility.isVisible ? 1 : 0)
                .offset(y: visibility.isVisible ? 0 : -4)
        }
        .frame(height: chromeHeight, alignment: .top)
        .animation(.easeOut(duration: 0.14), value: visibility.isVisible)
    }

    private var chromeBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                MirrorTrafficButton(color: Color(red: 1.00, green: 0.32, blue: 0.34), help: "Close mirror") {
                    model.closeMirrorWindow()
                }
                MirrorTrafficButton(color: Color(red: 1.00, green: 0.76, blue: 0.18), help: "Minimize mirror") {
                    model.minimizeMirrorWindow()
                }
                MirrorTrafficButton(color: Color(red: 0.22, green: 0.78, blue: 0.34), help: "Expand mirror") {
                    model.toggleMirrorFullscreen()
                }
            }
            .padding(.leading, 12)

            dragHandle

            HStack(spacing: 4) {
                MirrorTopBarIconButton(systemName: "square.grid.3x3", help: "Recents") {
                    model.sendAndroidKey("KEYCODE_APP_SWITCH")
                }
                MirrorTopBarIconButton(systemName: "camera.viewfinder", help: "Screenshot to Desktop") {
                    model.takeScreenshot()
                }
            }
            .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: chromeHeight)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        )
    }

    private var dragHandle: some View {
        MirrorTitleDragHandle(model: model, visibility: visibility)
            .frame(maxWidth: .infinity, minHeight: chromeHeight)
            .help("Drag mirror")
    }
}

/// Non-interactive visual frame that sits around the external frameless
/// scrcpy window. It deliberately draws only the chrome bands, leaving the
/// center transparent so Android pixels remain visible and clickable.
struct MirrorOuterFrameView: View {
    private let chromeHeight: CGFloat = MirrorFrameWindowController.chromeHeight
    private let sideInset: CGFloat = MirrorFrameWindowController.sideInset
    private let bottomInset: CGFloat = MirrorFrameWindowController.bottomInset
    private let cornerRadius: CGFloat = 18

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let phoneHeight = max(0, height - chromeHeight - bottomInset)
            let sideHeight = max(0, height - chromeHeight - bottomInset)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                    .shadow(color: .black.opacity(0.30), radius: 22, y: 14)

                Rectangle()
                    .fill(Color.black.opacity(0.72))
                    .frame(width: width, height: chromeHeight)

                Rectangle()
                    .fill(Color.black.opacity(0.72))
                    .frame(width: sideInset, height: sideHeight)
                    .offset(x: 0, y: chromeHeight)

                Rectangle()
                    .fill(Color.black.opacity(0.72))
                    .frame(width: sideInset, height: sideHeight)
                    .offset(x: width - sideInset, y: chromeHeight)

                Rectangle()
                    .fill(Color.black.opacity(0.72))
                    .frame(width: width, height: bottomInset)
                    .offset(x: 0, y: chromeHeight + phoneHeight)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MirrorTitleDragHandle: NSViewRepresentable {
    let model: AppModel
    let visibility: MirrorFrameWindowController.Visibility

    func makeNSView(context: Context) -> TitleBarDragNSView {
        let view = TitleBarDragNSView()
        view.model = model
        view.visibility = visibility
        return view
    }

    func updateNSView(_ nsView: TitleBarDragNSView, context: Context) {
        nsView.model = model
        nsView.visibility = visibility
    }
}

final class TitleBarDragNSView: NSView {
    weak var model: AppModel?
    weak var visibility: MirrorFrameWindowController.Visibility?

    private var startMouse: NSPoint?
    private var startPanelOrigin: NSPoint?
    private var pendingCursorDelta: CGSize?
    private var dragTimer: Timer?
    private var dragID = 0

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragID += 1
        startMouse = NSEvent.mouseLocation
        startPanelOrigin = window?.frame.origin
        pendingCursorDelta = .zero
        visibility?.isDragging = true
        visibility?.isVisible = true
        window?.ignoresMouseEvents = false
        window?.orderFrontRegardless()
        model?.beginMirrorWindowDrag()
        startDragTimer()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startMouse else { return }
        let now = NSEvent.mouseLocation
        // Coalesce: mouseDragged fires per cursor event (often >120/s).
        // Just record the latest delta; the 60Hz timer drives the AX move and
        // panel reposition together so the cursor, the scrcpy window, and the
        // chrome panel can never diverge mid-drag.
        pendingCursorDelta = CGSize(width: now.x - start.x, height: -(now.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        let completedDragID = dragID
        stopDragTimer()
        applyPendingDrag()
        startMouse = nil
        startPanelOrigin = nil
        pendingCursorDelta = nil
        visibility?.isVisible = true
        model?.endMirrorWindowDrag()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak visibility] in
            guard self?.dragID == completedDragID else { return }
            visibility?.isDragging = false
        }
    }

    private func startDragTimer() {
        stopDragTimer()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.applyPendingDrag()
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func stopDragTimer() {
        dragTimer?.invalidate()
        dragTimer = nil
    }

    private func applyPendingDrag() {
        guard let delta = pendingCursorDelta,
              let panelOrigin = startPanelOrigin else { return }
        let appliedTranslation = model?.dragMirrorWindow(translation: delta) ?? delta
        window?.setFrameOrigin(NSPoint(
            x: panelOrigin.x + appliedTranslation.width,
            y: panelOrigin.y - appliedTranslation.height
        ))
    }
}

struct MirrorTrafficButton: View {
    let color: Color
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 13, height: 13)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(isHovering ? 0.32 : 0.14), lineWidth: 0.8)
                )
                .scaleEffect(isHovering ? 1.08 : 1)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
    }
}

struct MirrorTopBarIconButton: View {
    let systemName: String
    var iconSize: CGFloat = 17
    var tint: Color = Color.white.opacity(0.74)
    var background: Color = .clear
    let help: String
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 31, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(background.opacity(background == .clear ? 0 : 1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(highlightOpacity))
                        )
                )
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.12), value: isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var highlightOpacity: Double {
        if isPressed { return 0.16 }
        if isHovering { return 0.10 }
        return 0
    }
}

/// Decorative outline drawn around the live scrcpy window.
struct MirrorFrameOutlineView: View {
    private let titleHeight: CGFloat = MirrorFrameWindowController.titleHeight
    private let outset: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let phoneWidth = max(0, proxy.size.width - outset * 2)
            let phoneHeight = max(0, proxy.size.height - titleHeight - outset * 2)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.38),
                                Color.white.opacity(0.12),
                                Color.black.opacity(0.40)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.4
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.clear)
                    )
                    .shadow(color: .black.opacity(0.38), radius: 28, y: 18)
                    .frame(width: phoneWidth, height: phoneHeight)
                    .position(
                        x: proxy.size.width / 2,
                        y: titleHeight + outset + phoneHeight / 2
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

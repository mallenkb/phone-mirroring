import AppKit
import SwiftUI

/// Floating toolbar overlay shown alongside the live scrcpy mirror window.
struct MirrorToolbarView: View {
    @ObservedObject var model: AppModel
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            MirrorToolbarIconButton(icon: "arrow-left", help: "Back") {
                model.sendAndroidKey("KEYCODE_BACK")
            }
            MirrorToolbarIconButton(icon: "house", help: "Home") {
                model.sendAndroidKey("KEYCODE_HOME")
            }
            MirrorToolbarIconButton(icon: "layout-grid", help: "Recents") {
                model.sendAndroidKey("KEYCODE_APP_SWITCH")
            }

            separator

            MirrorToolbarIconButton(icon: "camera", help: "Screenshot to Desktop") {
                model.takeScreenshot()
            }

            MirrorToolbarIconButton(
                icon: model.isRecording ? "square" : "circle",
                iconSize: model.isRecording ? 14 : 16,
                tint: .toolbarRecord,
                background: .clear,
                help: model.isRecording ? "Stop recording" : "Record screen"
            ) {
                model.toggleScreenRecording()
            }

            separator

            MirrorToolbarTextButton(title: "-", help: "Make mirror smaller") {
                model.resizeMirror(scale: 0.90)
            }
            MirrorToolbarTextButton(title: "+", help: "Make mirror bigger") {
                model.resizeMirror(scale: 1.10)
            }

            separator

            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRecording ? Color.toolbarRecord : Color.successGreen)
                    .frame(width: 6, height: 6)
                Text(model.isRecording ? "Recording" : "Mirroring")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.toolbarIconMuted)
            }
            .padding(.trailing, 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.toolbarSurface.opacity(isHovering ? 0.98 : 0.92))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.toolbarStroke, lineWidth: 1)
            }
        )
        .shadow(color: .black.opacity(isHovering ? 0.22 : 0.16), radius: isHovering ? 22 : 16, y: 8)
        .fixedSize()
        .onHover { isHovering = $0 }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.black.opacity(0.10))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 8)
    }
}

struct MirrorToolbarIconButton: View {
    let icon: String
    var iconSize: CGFloat = 18
    var tint: Color = .toolbarIcon
    var background: Color = .clear
    var help: String? = nil
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            LucideIcon(name: icon, size: iconSize)
                .foregroundStyle(tint)
                .frame(width: 42, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(background.opacity(background == .clear ? 0 : 1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(highlightOpacity))
                )
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var highlightOpacity: Double {
        if isPressed { return 0.10 }
        if isHovering { return 0.06 }
        return 0
    }
}

struct MirrorToolbarTextButton: View {
    let title: String
    var help: String? = nil
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.toolbarIcon)
                .frame(width: 42, height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(highlightOpacity))
                )
                .contentShape(Rectangle())
                .scaleEffect(isPressed ? 0.94 : 1.0)
                .animation(.easeOut(duration: 0.12), value: isPressed)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .help(help ?? "")
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }

    private var highlightOpacity: Double {
        if isPressed { return 0.10 }
        if isHovering { return 0.06 }
        return 0
    }
}

/// Reflect-style hover chrome that overlays the top edge of the scrcpy
/// window. Visibility is driven by the window controller (which polls the
/// global cursor) so the controls only appear when the user mouses into the
/// top strip — exactly like Reflect.
struct MirrorTopBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var visibility: MirrorFrameWindowController.Visibility

    @State private var isDragging = false

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
        HStack(spacing: 14) {
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
            .padding(.leading, 14)

            dragHandle

            HStack(spacing: 6) {
                MirrorTopBarIconButton(
                    systemName: "rectangle.on.rectangle",
                    tint: Color(red: 0.18, green: 0.86, blue: 0.34),
                    background: Color(red: 0.08, green: 0.34, blue: 0.12),
                    help: "Expand mirror"
                ) {
                    model.toggleMirrorFullscreen()
                }
                MirrorTopBarIconButton(systemName: "square.grid.3x3", help: "Recents") {
                    model.sendAndroidKey("KEYCODE_APP_SWITCH")
                }
                MirrorTopBarIconButton(systemName: "camera.viewfinder", help: "Screenshot to Desktop") {
                    model.takeScreenshot()
                }
                MirrorTopBarIconButton(systemName: "magnifyingglass", help: "Make mirror bigger") {
                    model.resizeMirror(scale: 1.10)
                }
            }
            .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: chromeHeight)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var dragHandle: some View {
        // AppKit-native drag handle. Behaves exactly like a real NSWindow
        // title bar: events stay anchored to the view that captured mouseDown
        // until mouseUp, even if the cursor leaves the view rect mid-drag.
        // Each mouseDragged moves BOTH scrcpy (via AX) and the panel directly
        // so they stay locked together — no SwiftUI re-layout in the loop.
        MirrorTitleDragHandle(model: model, visibility: visibility)
            .frame(maxWidth: .infinity, minHeight: chromeHeight)
            .help("Drag mirror")
    }
}

/// SwiftUI bridge for `TitleBarDragNSView`.
private struct MirrorTitleDragHandle: NSViewRepresentable {
    let model: AppModel
    let visibility: MirrorFrameWindowController.Visibility

    func makeNSView(context: Context) -> TitleBarDragNSView {
        let v = TitleBarDragNSView()
        v.model = model
        v.visibility = visibility
        return v
    }

    func updateNSView(_ nsView: TitleBarDragNSView, context: Context) {
        nsView.model = model
        nsView.visibility = visibility
    }
}

/// AppKit-native title-bar drag area. Captures mouseDown and tracks
/// mouseDragged in global screen coordinates until mouseUp — exactly how
/// `NSWindow.performDrag(with:)` behaves internally. We move both scrcpy (via
/// AX) and the host panel (via `setFrameOrigin`) on every event so the chrome
/// stays glued to the mirror with no visible lag or oscillation.
final class TitleBarDragNSView: NSView {
    weak var model: AppModel?
    weak var visibility: MirrorFrameWindowController.Visibility?

    private var startMouse: NSPoint?
    private var startPanelOrigin: NSPoint?

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        startMouse = NSEvent.mouseLocation
        startPanelOrigin = window?.frame.origin
        visibility?.isDragging = true
        model?.beginMirrorWindowDrag()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startMouse,
              let panelOrigin = startPanelOrigin else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dyNS = now.y - start.y  // NS: +Y is up

        // 1. Move scrcpy. The model's API takes a CG translation where +Y is
        // DOWN, so flip the Y sign.
        model?.dragMirrorWindow(translation: CGSize(width: dx, height: -dyNS))

        // 2. Move the host panel in lockstep. setFrameOrigin uses NS coords.
        // Doing this directly here (instead of waiting for the next tick
        // poll) is what eliminates the "bar lags / disappears" feel.
        window?.setFrameOrigin(NSPoint(
            x: panelOrigin.x + dx,
            y: panelOrigin.y + dyNS
        ))
    }

    override func mouseUp(with event: NSEvent) {
        startMouse = nil
        startPanelOrigin = nil
        visibility?.isDragging = false
        model?.endMirrorWindowDrag()
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

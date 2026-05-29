import SwiftUI
import AppKit

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        FigmaMirrorExperienceView()
            .environmentObject(model)
            .background(WindowRegistrationView(model: model))
    }
}

/// Registers the host window with AppModel so it can be reopened when a mirror
/// session ends.
struct WindowRegistrationView: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        model.registerConnectionWindow(window)
        window.styleMask.remove(.titled)
        window.styleMask.insert(.resizable)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = AppModel.minimumConnectionWindowSize
        window.contentMinSize = AppModel.minimumConnectionWindowSize
        if let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            window.maxSize = NSSize(
                width: max(window.minSize.width, (visibleFrame.width - 40) * AppModel.maximumConnectionWindowScale),
                height: max(window.minSize.height, (visibleFrame.height - 40) * AppModel.maximumConnectionWindowScale)
            )
        }
    }
}

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
        window.minSize = NSSize(width: 308, height: 689)
    }
}

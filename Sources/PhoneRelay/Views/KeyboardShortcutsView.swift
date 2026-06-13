import SwiftUI

/// A compact reference of the app's keyboard and mouse shortcuts. Shown from
/// Help ▸ Keyboard Shortcuts in its own content-sized window.
struct KeyboardShortcutsView: View {
    private struct Shortcut: Identifiable {
        let id = UUID()
        let keys: String
        let action: String
    }

    private let groups: [(title: String, items: [Shortcut])] = [
        ("Mirroring", [
            Shortcut(keys: "⌘M", action: "Start or stop mirroring"),
            Shortcut(keys: "⌘R", action: "Scan for Android devices"),
            Shortcut(keys: "⌘+", action: "Zoom in"),
            Shortcut(keys: "⌘−", action: "Zoom out"),
            Shortcut(keys: "⌘0", action: "Center the mirror"),
        ]),
        ("Phone controls", [
            Shortcut(keys: "⌘H", action: "Home"),
            Shortcut(keys: "⌘L", action: "Turn phone screen on or off"),
            Shortcut(keys: "⇧⌘L", action: "Switch between portrait and landscape"),
            Shortcut(keys: "⌘[", action: "Back"),
            Shortcut(keys: "⌘]", action: "Recent apps"),
            Shortcut(keys: "⇧⌘S", action: "Take a screenshot"),
            Shortcut(keys: "⇧⌘R", action: "Start or stop screen recording"),
        ]),
        ("Pointer", [
            Shortcut(keys: "Click", action: "Tap"),
            Shortcut(keys: "Click + drag", action: "Swipe / scroll content"),
            Shortcut(keys: "Scroll", action: "Scroll the phone screen"),
            Shortcut(keys: "Type", action: "Send keystrokes to the phone"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 22, weight: .semibold))

            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.items) { item in
                        HStack(spacing: 12) {
                            Text(item.keys)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .frame(width: 96, alignment: .leading)
                                .foregroundStyle(.primary)
                            Text(item.action)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}

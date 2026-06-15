import SwiftUI

/// One keyboard/mouse shortcut entry. Shared by the Help ▸ Keyboard Shortcuts
/// window and the Settings ▸ Shortcuts tab so the two lists never drift apart.
struct ShortcutReference: Identifiable {
    let id = UUID()
    let keys: String
    let action: String
}

/// The single source of truth for the app's documented shortcuts.
enum KeyboardShortcutsCatalog {
    static let groups: [(title: String, items: [ShortcutReference])] = [
        ("Mirroring", [
            ShortcutReference(keys: "⌘M", action: "Start or stop mirroring"),
            ShortcutReference(keys: "⌘R", action: "Scan for Android devices"),
            ShortcutReference(keys: "⌘+", action: "Zoom in"),
            ShortcutReference(keys: "⌘−", action: "Zoom out"),
            ShortcutReference(keys: "⌘0", action: "Center the mirror"),
        ]),
        ("Phone controls", [
            ShortcutReference(keys: "⌘H", action: "Home"),
            ShortcutReference(keys: "⌘L", action: "Turn phone screen on or off"),
            ShortcutReference(keys: "⌘[", action: "Back"),
            ShortcutReference(keys: "⌘]", action: "Recent apps"),
            ShortcutReference(keys: "⇧⌘S", action: "Take a screenshot"),
            ShortcutReference(keys: "⇧⌘R", action: "Start or stop screen recording"),
            ShortcutReference(keys: "Volume keys", action: "Phone volume up / down / mute"),
        ]),
        ("Editing & clipboard", [
            ShortcutReference(keys: "⌘A", action: "Select all"),
            ShortcutReference(keys: "⌘C", action: "Copy (syncs to Mac)"),
            ShortcutReference(keys: "⌘X", action: "Cut"),
            ShortcutReference(keys: "⌘V", action: "Paste from Mac"),
            ShortcutReference(keys: "⌘Z", action: "Undo"),
        ]),
        ("Text input", [
            ShortcutReference(keys: "Type", action: "Send text to the focused phone field"),
            ShortcutReference(keys: "Return / Enter", action: "Submit or add a line, depending on the app"),
            ShortcutReference(keys: "⌘Return", action: "Send in apps that use Ctrl+Enter"),
            ShortcutReference(keys: "Tab", action: "Move focus on the phone"),
            ShortcutReference(keys: "Delete", action: "Delete backward"),
            ShortcutReference(keys: "Forward Delete", action: "Delete forward"),
            ShortcutReference(keys: "Arrow keys", action: "Move the cursor or selection"),
        ]),
        ("Pointer", [
            ShortcutReference(keys: "Click", action: "Tap"),
            ShortcutReference(keys: "Click + drag", action: "Swipe / scroll content"),
            ShortcutReference(keys: "Scroll", action: "Scroll the phone screen"),
            ShortcutReference(keys: "Esc", action: "Back"),
        ]),
    ]
}

/// A compact reference of the app's keyboard and mouse shortcuts. Shown from
/// Help ▸ Keyboard Shortcuts in its own content-sized window.
struct KeyboardShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 22, weight: .semibold))

            ForEach(KeyboardShortcutsCatalog.groups, id: \.title) { group in
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

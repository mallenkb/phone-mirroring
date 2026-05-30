import AppKit
import Foundation

/// Keeps the macOS pasteboard and the Android device clipboard in sync while a
/// mirror session is active.
///
/// - Phone → Mac: the scrcpy server pushes a clipboard message whenever the
///   device clipboard changes (its `clipboard_autosync` is on by default); the
///   control channel delivers it to `deviceClipboardChanged(_:)`.
/// - Mac → phone: macOS has no clipboard-change notification, so we poll
///   `NSPasteboard.changeCount` and forward new text with SET_CLIPBOARD.
///
/// `lastText` guards both directions against echo loops: text we just received
/// is never sent back, and text we just sent is never re-applied locally.
@MainActor
final class ClipboardBridge {
    private weak var channel: ScrcpyControlChannel?
    private let pasteboard: NSPasteboard
    private var pollTask: Task<Void, Never>?
    private var lastChangeCount: Int
    private var lastText: String?

    private static let pollInterval: UInt64 = 500_000_000 // 0.5s in ns

    init(channel: ScrcpyControlChannel, pasteboard: NSPasteboard = .general) {
        self.channel = channel
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        // Seed the device with whatever is currently on the Mac clipboard so the
        // user can paste it on the phone right away. The server suppresses the
        // echo for text it is actively applying, so this does not loop back.
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            lastText = text
            channel?.sendSetClipboard(text)
        }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                self?.pollHostClipboard()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Phone → Mac. Called (hopped to the main actor) by the control channel.
    func deviceClipboardChanged(_ text: String) {
        guard !text.isEmpty, text != lastText else { return }
        lastText = text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Record the bump we just caused so the poller treats it as in-sync.
        lastChangeCount = pasteboard.changeCount
    }

    /// Mac → phone.
    private func pollHostClipboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        guard let text = pasteboard.string(forType: .string),
              !text.isEmpty,
              text != lastText else { return }
        lastText = text
        channel?.sendSetClipboard(text)
    }
}

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
    private let onImagePaste: (Data) -> Void
    private var pollTask: Task<Void, Never>?
    private var lastChangeCount: Int
    private var lastText: String?

    private static let pollInterval: UInt64 = 500_000_000 // 0.5s in ns

    init(
        channel: ScrcpyControlChannel,
        pasteboard: NSPasteboard = .general,
        onImagePaste: @escaping (Data) -> Void = { _ in }
    ) {
        self.channel = channel
        self.pasteboard = pasteboard
        self.onImagePaste = onImagePaste
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

    /// ⌘V in the mirror window: push the current Mac clipboard and ask the
    /// device to paste it into the focused field. Records the text so the poller
    /// does not redundantly resend it.
    func pasteToDevice() {
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            lastText = text
            lastChangeCount = pasteboard.changeCount
            channel?.sendSetClipboard(text, paste: true)
            return
        }

        if let pngData = Self.pngData(from: pasteboard) {
            lastChangeCount = pasteboard.changeCount
            onImagePaste(pngData)
        }
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

    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png), !data.isEmpty {
            return data
        }
        guard let tiff = pasteboard.data(forType: .tiff),
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              !png.isEmpty else {
            return nil
        }
        return png
    }
}

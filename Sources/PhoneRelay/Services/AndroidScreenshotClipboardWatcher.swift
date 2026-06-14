import AppKit
import Foundation

protocol ImagePasteboardWriting: AnyObject {
    func writePNGToPasteboard(_ data: Data)
}

extension NSPasteboard: ImagePasteboardWriting {
    func writePNGToPasteboard(_ data: Data) {
        clearContents()
        setData(data, forType: .png)
    }
}

@MainActor
final class AndroidScreenshotClipboardWatcher {
    nonisolated static let defaultPollIntervalNanoseconds: UInt64 = 750_000_000

    struct Screenshot: Equatable {
        var modifiedTime: Double
        var path: String
    }

    private let serial: String?
    private weak var pasteboard: ImagePasteboardWriting?
    private var pollTask: Task<Void, Never>?
    private var lastCopiedPath: String?
    private var lastCopiedModifiedTime: Double?
    private let pollIntervalNanoseconds: UInt64

    init(
        serial: String?,
        pasteboard: ImagePasteboardWriting = NSPasteboard.general,
        pollIntervalNanoseconds: UInt64 = AndroidScreenshotClipboardWatcher.defaultPollIntervalNanoseconds
    ) {
        self.serial = serial
        self.pasteboard = pasteboard
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.seedCurrentLatestScreenshot()
            while !Task.isCancelled {
                await self?.copyLatestScreenshotIfNeeded()
                try? await Task.sleep(nanoseconds: self?.pollIntervalNanoseconds ?? Self.defaultPollIntervalNanoseconds)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func seedCurrentLatestScreenshot() async {
        guard let screenshot = await Self.fetchLatestScreenshot(serial: serial) else { return }
        lastCopiedPath = screenshot.path
        lastCopiedModifiedTime = screenshot.modifiedTime
    }

    func copyLatestScreenshotIfNeeded() async {
        guard let screenshot = await Self.fetchLatestScreenshot(serial: serial),
              screenshot.path != lastCopiedPath || screenshot.modifiedTime != lastCopiedModifiedTime else {
            return
        }
        guard let data = await Self.pullScreenshotData(serial: serial, path: screenshot.path),
              !data.isEmpty else {
            return
        }
        pasteboard?.writePNGToPasteboard(data)
        lastCopiedPath = screenshot.path
        lastCopiedModifiedTime = screenshot.modifiedTime
        Logger.log("Copied Android screenshot to Mac clipboard: \(screenshot.path)")
    }

    nonisolated static func latestScreenshot(from output: String) -> Screenshot? {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Screenshot? in
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2,
                      let modifiedTime = Double(parts[0]) else {
                    return nil
                }
                let path = parts[1]
                guard path.localizedCaseInsensitiveContains("/screenshots/"),
                      path.localizedCaseInsensitiveContains("screenshot"),
                      path.lowercased().hasSuffix(".png")
                        || path.lowercased().hasSuffix(".jpg")
                        || path.lowercased().hasSuffix(".jpeg") else {
                    return nil
                }
                return Screenshot(modifiedTime: modifiedTime, path: path)
            }
            .max { lhs, rhs in lhs.modifiedTime < rhs.modifiedTime }
    }

    private static func fetchLatestScreenshot(serial: String?) async -> Screenshot? {
        let script = """
        find /sdcard/DCIM/Screenshots /sdcard/Pictures/Screenshots -maxdepth 1 -type f \\( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \\) -printf "%T@ %p\\n" 2>/dev/null
        """
        let args = adbDeviceArguments(serial: serial) + ["shell", script]
        let result = await Task.detached {
            Tooling.runResult("adb", arguments: args, timeout: 15)
        }.value
        guard result.succeeded else { return nil }
        return latestScreenshot(from: result.output)
    }

    private static func pullScreenshotData(serial: String?, path: String) async -> Data? {
        let args = adbDeviceArguments(serial: serial) + ["exec-out", "cat", path]
        let result = await Task.detached {
            Tooling.runDataResult("adb", arguments: args, timeout: 15)
        }.value
        guard result.succeeded else { return nil }
        return result.data
    }

    private static func adbDeviceArguments(serial: String?) -> [String] {
        guard let serial, !serial.isEmpty else { return [] }
        return ["-s", serial]
    }
}

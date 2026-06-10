import AppKit
import Foundation
import UserNotifications

/// Forwards Android notifications into the macOS Notification Center without any
/// companion app on the phone.
///
/// It polls `dumpsys notification` over adb — the adb `shell` user already holds
/// the `DUMP` permission, so no APK and no `NotificationListenerService` are
/// required — diffs the result against what it has already shown, and posts a
/// native banner for anything new.
///
/// This is deliberately a *read-only* poller: it never runs `connect`/`tcpip`,
/// so it cannot perturb the Wi-Fi reconnect logic in `AppModel`. If the device
/// is offline the fetch simply fails and the cycle is skipped; it self-heals on
/// the next tick (including across Wi-Fi address changes, since the serial is
/// re-read from the model every cycle).
@MainActor
final class NotificationForwarder {
    /// One active Android notification, distilled from the dumpsys text dump.
    struct Entry: Equatable {
        /// Stable StatusBarNotification key, e.g. `0|com.foo|7|tag|10337`.
        var key: String
        var pkg: String
        var title: String
        var text: String
        var flags: Int

        /// Identity used for "have I already shown this?". Includes title/text so
        /// a re-posted notification with new content (same key, new message) is
        /// treated as new and forwarded again.
        var fingerprint: String { "\(key)\u{1}\(title)\u{1}\(text)" }
    }

    /// `Notification.flags` bits we never forward: collapsed group headers and
    /// persistent status items (music transport, navigation, "charging", VPN…).
    nonisolated static let flagOngoingEvent = 0x0000_0002
    nonisolated static let flagForegroundService = 0x0000_0040
    nonisolated static let flagGroupSummary = 0x0000_0200

    private weak var model: AppModel?
    private var task: Task<Void, Never>?

    /// Fingerprints already delivered (or present at baseline). Bounded via
    /// `seenOrder` so a long-running session can't grow it without limit.
    private var seen = Set<String>()
    private var seenOrder = [String]()
    private var baselineSerial: String?
    private var hasBaseline = false
    private var iconAttachmentCache: [String: URL] = [:]

    /// Cadence while a device is connected. `dumpsys notification` is cheap on a
    /// modern phone, so a few seconds keeps banners prompt without busy-looping.
    private let pollInterval: TimeInterval = 3
    /// Slower tick while no real device is selected — just enough to notice when
    /// one connects.
    private let idleInterval: TimeInterval = 5
    private static let maxSeen = 600

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard task == nil else { return }
        // Re-signing or re-bundling the app resets its Notification Center
        // identity, after which posts fail silently; logging the status at
        // every start makes that visible in the log instead of a mystery.
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Logger.log("Notification forwarding starting authorizationStatus=\(settings.authorizationStatus.rawValue) alertSetting=\(settings.alertSetting.rawValue)")
        }
        task = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        seen.removeAll()
        seenOrder.removeAll()
        baselineSerial = nil
        hasBaseline = false
        iconAttachmentCache.removeAll()
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let serial = model?.selectedDevice.adbSerial, !serial.isEmpty else {
                try? await Task.sleep(nanoseconds: UInt64(idleInterval * 1_000_000_000))
                continue
            }

            // Switching phones re-baselines, so the new device's existing backlog
            // isn't dumped onto the Mac all at once.
            if serial != baselineSerial {
                baselineSerial = serial
                hasBaseline = false
                seen.removeAll()
                seenOrder.removeAll()
            }

            let dump = await Task.detached(priority: .utility) {
                Self.fetchDump(serial: serial)
            }.value

            if !Task.isCancelled, let dump {
                deliver(Self.parse(dump))
            }

            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Records the baseline silently on the first pass for a device; afterwards
    /// posts anything new.
    private func deliver(_ entries: [Entry]) {
        guard hasBaseline else {
            for entry in entries where Self.isForwardable(entry) { remember(entry.fingerprint) }
            hasBaseline = true
            return
        }

        for entry in Self.unseenForwardable(entries, seen: seen) {
            remember(entry.fingerprint)
            post(entry, serial: baselineSerial)
        }
    }

    private func remember(_ fingerprint: String) {
        guard seen.insert(fingerprint).inserted else { return }
        seenOrder.append(fingerprint)
        if seenOrder.count > Self.maxSeen {
            seen.remove(seenOrder.removeFirst())
        }
    }

    private func post(_ entry: Entry, serial: String?) {
        let content = Self.notificationContent(for: entry, serial: serial)
        if let serial,
           let attachmentURL = iconAttachmentURL(for: entry.pkg, serial: serial),
           let attachment = try? UNNotificationAttachment(
            identifier: "\(entry.pkg)-icon",
            url: attachmentURL,
            options: nil
           ) {
            content.attachments = [attachment]
        }
        let pkg = entry.pkg
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            // Without this, an unauthorized identity (fresh signature/bundle
            // id) drops every banner with no trace in the log.
            if let error {
                Logger.log("Notification delivery failed pkg=\(pkg): \(error.localizedDescription)")
            }
        }
        // Log the key, never the title/text: message previews must not end up
        // in the plaintext log file users share when reporting bugs.
        Logger.log("Forwarded notification pkg=\(entry.pkg) key=\(entry.key)")
    }

    /// Builds the macOS notification for a forwarded entry. A default sound is
    /// attached so the banner pops audibly like it does on the phone — without it
    /// the banner is delivered silently. Pure/inspectable so it can be unit-tested.
    nonisolated static func notificationContent(for entry: Entry, serial: String? = nil) -> UNMutableNotificationContent {
        _ = serial
        let content = UNMutableNotificationContent()
        let sourceApp = appLabel(for: entry.pkg)
        content.title = notificationTitle(sourceApp: sourceApp, entryTitle: entry.title)
        if !entry.text.isEmpty { content.body = entry.text }
        // Group banners by source app in Notification Center.
        content.threadIdentifier = entry.pkg
        content.sound = .default
        return content
    }

    nonisolated static func notificationTitle(sourceApp: String, entryTitle: String) -> String {
        let source = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = entryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return title }
        guard !title.isEmpty else { return source }
        if title.localizedCaseInsensitiveCompare(source) == .orderedSame {
            return title
        }
        return "\(source) • \(title)"
    }

    private func iconAttachmentURL(for pkg: String, serial: String) -> URL? {
        let cacheKey = "\(serial)\u{1}\(pkg)"
        if let cached = iconAttachmentCache[cacheKey],
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        guard let url = Self.buildIconAttachment(pkg: pkg, serial: serial) else { return nil }
        iconAttachmentCache[cacheKey] = url
        return url
    }

    // MARK: - adb fetch

    private nonisolated static func fetchDump(serial: String) -> String? {
        var args: [String] = []
        if !serial.isEmpty { args += ["-s", serial] }
        // The full dump is ~1 MB; an on-device `grep` trims it to the handful of
        // lines we parse so we don't stream that over the (possibly congested)
        // Wi-Fi link every cycle. Plain multi-`-e` grep (no `-E`/regex) keeps it
        // portable across device shells.
        args += [
            "shell",
            "dumpsys notification --noredact | grep -e NotificationRecord -e android.title= -e android.text="
        ]
        let result = Tooling.runResult("adb", arguments: args, timeout: 4)
        guard result.succeeded else { return nil }
        return result.output
    }

    // MARK: - App icon attachment

    /// Best-effort source-app icon: pulls the notifying package's APK, extracts
    /// its highest-density launcher PNG/WebP, and badges it with this app icon so
    /// the banner still reads as forwarded by Android Mirroring.
    private nonisolated static func buildIconAttachment(pkg: String, serial: String) -> URL? {
        guard !pkg.isEmpty, !serial.isEmpty else { return nil }
        let apkPaths = apkPaths(for: pkg, serial: serial)
        guard !apkPaths.isEmpty else { return nil }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMirrorMacNotificationIcons", isDirectory: true)
        let workDir = tempRoot
            .appendingPathComponent(Self.sanitizedFilename(serial), isDirectory: true)
            .appendingPathComponent(Self.sanitizedFilename(pkg), isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let iconURL = workDir.appendingPathComponent("source-icon")
        let outputURL = workDir.appendingPathComponent("forwarded-icon.png")

        for (index, apkPath) in apkPaths.enumerated() {
            let apkURL = workDir.appendingPathComponent("package-\(index).apk")
            let pull = Tooling.runResult("adb", arguments: ["-s", serial, "pull", apkPath, apkURL.path], timeout: 8)
            guard pull.succeeded else { continue }
            guard let iconPath = launcherIconPath(in: apkURL) else { continue }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", apkURL.path, iconPath]
            do {
                let data = try runProcessCapturingData(process, timeout: 4)
                guard !data.isEmpty else { continue }
                try data.write(to: iconURL)
                if let composed = composeForwardedIcon(sourceIconURL: iconURL, outputURL: outputURL) {
                    return composed
                }
            } catch {
                continue
            }
        }
        return nil
    }

    private nonisolated static func apkPaths(for pkg: String, serial: String) -> [String] {
        let result = Tooling.runResult("adb", arguments: ["-s", serial, "shell", "pm", "path", pkg], timeout: 4)
        guard result.succeeded else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("package:") else { return nil }
                let path = String(trimmed.dropFirst("package:".count))
                return path.hasSuffix(".apk") ? path : nil
            }
    }

    private nonisolated static func launcherIconPath(in apkURL: URL) -> String? {
        let result = Tooling.runResult("unzip", arguments: ["-Z1", apkURL.path], timeout: 4)
        guard result.succeeded else { return nil }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { path in
                let lowercased = path.lowercased()
                guard lowercased.hasPrefix("res/") else { return false }
                guard lowercased.hasSuffix(".png") || lowercased.hasSuffix(".webp") else { return false }
                guard lowercased.contains("mipmap") || lowercased.contains("drawable") else { return false }
                guard lowercased.contains("ic_launcher")
                    || lowercased.contains("launcher")
                    || lowercased.contains("icon")
                    || lowercased.contains("logo") else {
                    return false
                }
                return !lowercased.contains("background")
                    && !lowercased.contains("monochrome")
            }
            .max { iconScore($0) < iconScore($1) }
    }

    private nonisolated static func iconScore(_ path: String) -> Int {
        let lowercased = path.lowercased()
        var score = 0
        if lowercased.contains("xxxhdpi") { score += 700 }
        else if lowercased.contains("xxhdpi") { score += 600 }
        else if lowercased.contains("xhdpi") { score += 500 }
        else if lowercased.contains("hdpi") { score += 400 }
        else if lowercased.contains("mdpi") { score += 300 }
        if lowercased.contains("mipmap") { score += 40 }
        if lowercased.contains("round") { score += 20 }
        if lowercased.contains("foreground") { score -= 50 }
        if lowercased.hasSuffix(".png") { score += 10 }
        return score
    }

    private nonisolated static func composeForwardedIcon(sourceIconURL: URL, outputURL: URL) -> URL? {
        guard let sourceImage = NSImage(contentsOf: sourceIconURL) else { return nil }
        let canvasSize = NSSize(width: 160, height: 160)
        let output = NSImage(size: canvasSize)
        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        sourceImage.draw(
            in: NSRect(x: 8, y: 8, width: 144, height: 144),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        let badgeRect = NSRect(x: 100, y: 0, width: 58, height: 58)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 14, yRadius: 14).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: badgeRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14).stroke()

        if let badge = NSImage(named: NSImage.applicationIconName) {
            badge.draw(
                in: badgeRect.insetBy(dx: 7, dy: 7),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        output.unlockFocus()
        guard let tiff = output.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        do {
            try png.write(to: outputURL)
            return outputURL
        } catch {
            return nil
        }
    }

    private nonisolated static func runProcessCapturingData(_ process: Process, timeout: TimeInterval) throws -> Data {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return Data()
        }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }

    private nonisolated static func sanitizedFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce(into: "") {
            $0.append($1)
        }
    }

    // MARK: - Parsing (pure; unit-tested)

    /// Parses `dumpsys notification` output (full or grep-filtered) into entries.
    ///
    /// Strategy: a `NotificationRecord(0x…` line opens a record (carrying pkg,
    /// key, and flags); the first `android.title=`/`android.text=` line after it
    /// supplies title/body, with `android.bigText` as a safe fallback when
    /// `android.text` is missing/empty.
    nonisolated static func parse(_ dump: String) -> [Entry] {
        var entries: [Entry] = []
        var current: Entry?
        var haveTitle = false
        var haveText = false
        var fallbackText: String?

        func flush() {
            if var entry = current {
                if entry.text.isEmpty, let fallbackText, !fallbackText.isEmpty {
                    entry.text = fallbackText
                }
                entries.append(entry)
            }
            current = nil
            haveTitle = false
            haveText = false
            fallbackText = nil
        }

        for rawLine in dump.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.contains("NotificationRecord(0x") {
                flush()
                current = Entry(
                    key: value(after: "key=", in: line, until: ": Notification") ?? "",
                    pkg: token(after: "pkg=", in: line) ?? "",
                    title: "",
                    text: "",
                    flags: hexValue(after: "flags=0x", in: line) ?? 0
                )
                fallbackText = nil
            } else if current != nil, !haveTitle, line.hasPrefix("android.title=") {
                current?.title = bundleValue(line) ?? ""
                haveTitle = true
            } else if current != nil, !haveText, line.hasPrefix("android.text=") {
                if let text = bundleValue(line), !text.isEmpty {
                    current?.text = text
                    haveText = true
                }
            } else if current != nil, !haveText, line.hasPrefix("android.bigText=") {
                if let nextText = bundleValue(line), !nextText.isEmpty {
                    fallbackText = nextText
                }
            }
        }
        flush()
        return entries
    }

    /// Whether an entry should reach the Mac: drop group summaries and ongoing /
    /// foreground-service items, and anything with neither title nor text.
    nonisolated static func isForwardable(_ entry: Entry) -> Bool {
        if entry.flags & (flagGroupSummary | flagOngoingEvent | flagForegroundService) != 0 {
            return false
        }
        return !(entry.title.isEmpty && entry.text.isEmpty)
    }

    /// Pure diff used by `deliver`: forwardable entries not yet seen, in order.
    nonisolated static func unseenForwardable(_ entries: [Entry], seen: Set<String>) -> [Entry] {
        entries.filter { isForwardable($0) && !seen.contains($0.fingerprint) }
    }

    /// Extracts a value from an Android bundle dump line, e.g.
    /// `android.title=String (Uber)` → `Uber`; `android.text=null` → nil. Handles
    /// values that themselves contain parentheses by spanning to the outermost.
    nonisolated static func bundleValue(_ line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let rhs = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if rhs == "null" || rhs.isEmpty { return nil }
        guard let open = rhs.firstIndex(of: "("),
              let close = rhs.lastIndex(of: ")"),
              open < close else {
            return rhs
        }
        let inner = rhs[rhs.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? nil : inner
    }

    /// Best-effort friendly name when a notification has no title: a readable
    /// segment of the package id (`com.twitter.android` → `Twitter`).
    nonisolated static func appLabel(for pkg: String) -> String {
        switch pkg {
        case "com.google.android.apps.messaging":
            return "Messages"
        case "com.whatsapp":
            return "WhatsApp"
        case "com.whatsapp.w4b":
            return "WhatsApp Business"
        case "com.instagram.android":
            return "Instagram"
        case "com.facebook.orca":
            return "Messenger"
        case "com.facebook.katana":
            return "Facebook"
        case "com.twitter.android":
            return "X"
        case "com.google.android.gm":
            return "Gmail"
        default:
            break
        }

        let parts = pkg.split(separator: ".")
        let candidate: Substring
        if let last = parts.last, last == "android", parts.count >= 2 {
            candidate = parts[parts.count - 2]
        } else {
            candidate = parts.last ?? Substring(pkg)
        }
        guard let first = candidate.first else { return pkg }
        return first.uppercased() + candidate.dropFirst()
    }

    // MARK: - Header field helpers

    /// `pkg=com.foo ` → `com.foo` (token ends at the next space).
    nonisolated private static func token(after prefix: String, in line: String) -> String? {
        guard let r = line.range(of: prefix) else { return nil }
        let rest = line[r.upperBound...]
        let end = rest.firstIndex(of: " ") ?? rest.endIndex
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// Text between `prefix` and `terminator` (falls back to the next space).
    nonisolated private static func value(after prefix: String, in line: String, until terminator: String) -> String? {
        guard let r = line.range(of: prefix) else { return nil }
        let rest = line[r.upperBound...]
        if let t = rest.range(of: terminator) {
            return String(rest[..<t.lowerBound])
        }
        let end = rest.firstIndex(of: " ") ?? rest.endIndex
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value
    }

    /// Reads the hex run after `flags=0x` into an Int.
    nonisolated private static func hexValue(after prefix: String, in line: String) -> Int? {
        guard let r = line.range(of: prefix) else { return nil }
        let rest = line[r.upperBound...]
        return Int(rest.prefix(while: { $0.isHexDigit }), radix: 16)
    }
}

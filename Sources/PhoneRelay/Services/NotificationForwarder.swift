import AppKit
import Foundation
import Intents
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
    /// Keys stashed in a banner's `userInfo` so the click/reply handler can act
    /// on the originating notification (open it, or reply to it) on the phone.
    enum UserInfoKey {
        static let sourcePackage = "phoneRelay.sourcePackage"
        static let deviceSerial = "phoneRelay.deviceSerial"
        static let notificationKey = "phoneRelay.notificationKey"
        static let notificationTitle = "phoneRelay.notificationTitle"
        static let notificationText = "phoneRelay.notificationText"
    }

    /// `UNNotificationCategory` identifiers chosen per entry: message-style
    /// notifications get the inline Reply action, everything else just Open.
    enum Category {
        static let standard = "phoneRelay.standard"
        static let message = "phoneRelay.message"
    }

    /// `UNNotificationAction` identifiers wired to the categories above.
    enum Action {
        static let open = "phoneRelay.open"
        static let reply = "phoneRelay.reply"
        static let clear = "phoneRelay.clear"
        static let markRead = "phoneRelay.markRead"
    }

    /// One active Android notification, distilled from the dumpsys text dump.
    struct Entry: Equatable {
        /// Stable StatusBarNotification key, e.g. `0|com.foo|7|tag|10337`.
        var key: String
        var pkg: String
        var title: String
        var text: String
        var flags: Int
        /// `Notification.category`, e.g. `msg` for a chat message.
        var category: String = ""
        /// `android.template`, e.g. `android.app.Notification$MessagingStyle`.
        var template: String = ""

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
    private var sourceIconCache: [String: URL] = [:]

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
        sourceIconCache.removeAll()
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
            // Track the app so it shows in the Settings mute list (even muted ones,
            // so they can be un-muted), then apply the user's privacy gates.
            model?.registerObservedNotificationApp(package: entry.pkg, label: Self.appLabel(for: entry.pkg))
            guard shouldPost(entry) else { continue }
            post(entry, serial: baselineSerial)
        }
    }

    /// User-controlled gates applied after the baseline/dedup pass: pause while
    /// recording, per-app mute, and security-code suppression.
    private func shouldPost(_ entry: Entry) -> Bool {
        guard let model else { return true }
        if model.notificationPauseWhileRecordingEnabled, model.isRecording { return false }
        if model.isNotificationPackageMuted(entry.pkg) { return false }
        if model.notificationSuppressSecurityCodesEnabled, Self.isLikelySecurityCode(entry) { return false }
        return true
    }

    private func remember(_ fingerprint: String) {
        guard seen.insert(fingerprint).inserted else { return }
        seenOrder.append(fingerprint)
        if seenOrder.count > Self.maxSeen {
            seen.remove(seenOrder.removeFirst())
        }
    }

    private func post(_ entry: Entry, serial: String?) {
        let pkg = entry.pkg

        // The source-app icon + composed badge come from a per-device+package
        // cache. On a hit this is just a file-exists check, so deliver inline.
        // On a miss the icon has to be fetched by pulling the app's APK,
        // unzipping its launcher icon, and compositing the badge — all blocking
        // work that must NOT run on the main actor. Doing it here froze the whole
        // UI (window dragging, menus, clicks) for as long as the pull took every
        // time a notification arrived from an app we hadn't cached yet.
        guard let serial else {
            postResolved(entry: entry, serial: nil, avatarURL: nil, attachmentURL: nil)
            return
        }
        let cacheKey = "\(serial)\u{1}\(pkg)"
        if let avatarURL = cachedIcon(sourceIconCache, key: cacheKey),
           let attachmentURL = cachedIcon(iconAttachmentCache, key: cacheKey) {
            postResolved(entry: entry, serial: serial, avatarURL: avatarURL, attachmentURL: attachmentURL)
            return
        }

        Task { [weak self] in
            let icons = await Task.detached(priority: .utility) {
                Self.resolveIcons(pkg: pkg, serial: serial)
            }.value
            guard let self else { return }
            if let avatarURL = icons.avatar { self.sourceIconCache[cacheKey] = avatarURL }
            if let attachmentURL = icons.attachment { self.iconAttachmentCache[cacheKey] = attachmentURL }
            self.postResolved(
                entry: entry,
                serial: serial,
                avatarURL: icons.avatar,
                attachmentURL: icons.attachment
            )
        }
    }

    /// Builds and delivers the macOS banner once the source-app icon URLs are
    /// known. Pure main-actor work — no blocking I/O — so it's safe to run inline
    /// on a cache hit or after the off-main icon fetch in `post` resolves.
    private func postResolved(entry: Entry, serial: String?, avatarURL: URL?, attachmentURL: URL?) {
        let hideBody = model?.notificationHideBodyEnabled ?? false
        let content = Self.notificationContent(for: entry, serial: serial, hideBody: hideBody)
        let pkg = entry.pkg

        // Always attach the composed badge (source icon + PhoneRelay corner) as
        // the guaranteed fallback: if the communication style below isn't applied
        // (e.g. the entitlement isn't honored by the current signing), the banner
        // still shows the source icon on the right exactly as before.
        if let attachmentURL,
           let attachment = try? UNNotificationAttachment(
            identifier: "\(pkg)-icon",
            url: attachmentURL,
            options: nil
           ) {
            content.attachments = [attachment]
        }

        // Prefer the communication-notification style (iPhone-Mirroring look):
        // the raw source app icon becomes the large left avatar and macOS
        // auto-badges PhoneRelay into the corner. Falls back to `content` when it
        // can't be built or the style isn't authorized.
        var finalContent: UNNotificationContent = content
        if let avatarURL,
           let communication = Self.communicationContent(from: content, entry: entry, avatarURL: avatarURL, hideBody: hideBody) {
            finalContent = communication
        }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: finalContent, trigger: nil)
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

    /// Upgrades a forwarded banner to a communication notification so the source
    /// app icon shows as the large left avatar (with PhoneRelay auto-badged in
    /// the corner), mirroring how iPhone Mirroring presents phone notifications.
    /// Returns nil — leaving the caller's attachment-based content in place — when
    /// the style can't be applied (e.g. the `com.apple.developer.usernotifications.communication`
    /// entitlement isn't authorized by the app's signing).
    nonisolated static func communicationContent(
        from content: UNMutableNotificationContent,
        entry: Entry,
        avatarURL: URL,
        hideBody: Bool = false
    ) -> UNNotificationContent? {
        let avatar = INImage(url: avatarURL)
        let sender = INPerson(
            personHandle: INPersonHandle(value: entry.pkg, type: .unknown),
            nameComponents: nil,
            displayName: content.title,
            image: avatar,
            contactIdentifier: nil,
            customIdentifier: entry.pkg
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: (entry.text.isEmpty || hideBody) ? nil : entry.text,
            speakableGroupName: nil,
            conversationIdentifier: entry.key.isEmpty ? entry.pkg : entry.key,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        // The sender avatar is carried by `INPerson(image:)` above; the
        // `intent.setImage(_:forParameterNamed:)` helper is unavailable on macOS.

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)

        return try? content.updating(from: intent)
    }

    /// Builds the macOS notification for a forwarded entry. A default sound is
    /// attached so the banner pops audibly like it does on the phone — without it
    /// the banner is delivered silently. Pure/inspectable so it can be unit-tested.
    nonisolated static func notificationContent(for entry: Entry, serial: String? = nil, hideBody: Bool = false) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let sourceApp = appLabel(for: entry.pkg)
        content.title = notificationTitle(sourceApp: sourceApp, entryTitle: entry.title)
        // Body is hidden for privacy when requested; the real text still rides in
        // userInfo below so click-to-open can still locate the row on the phone.
        if !entry.text.isEmpty, !hideBody { content.body = entry.text }
        // Group banners by source app in Notification Center.
        content.threadIdentifier = entry.pkg
        // Carry the originating notification's identity so a click or reply can
        // act on it back on the phone, and pick the category that decides which
        // actions (Open, or Open + inline Reply) the banner offers.
        var userInfo: [String: String] = [
            UserInfoKey.sourcePackage: entry.pkg,
            UserInfoKey.notificationKey: entry.key,
            UserInfoKey.notificationTitle: entry.title,
            UserInfoKey.notificationText: entry.text
        ]
        if let serial, !serial.isEmpty {
            userInfo[UserInfoKey.deviceSerial] = serial
        }
        content.userInfo = userInfo
        content.categoryIdentifier = isRepliable(entry) ? Category.message : Category.standard
        content.sound = .default
        return content
    }

    /// Whether a notification exposes a sensible inline-reply surface: a chat
    /// message (`category=msg`) or a `MessagingStyle` notification. These are
    /// the ones that carry a RemoteInput "Reply" action we can drive.
    nonisolated static func isRepliable(_ entry: Entry) -> Bool {
        if entry.category.caseInsensitiveCompare("msg") == .orderedSame { return true }
        return entry.template.localizedCaseInsensitiveContains("MessagingStyle")
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

    /// Returns a cached icon URL only when the file still exists on disk; a stale
    /// temp-dir entry (the OS clears the temporary directory) falls through to a
    /// fresh fetch instead of handing back a dead path.
    private func cachedIcon(_ cache: [String: URL], key: String) -> URL? {
        guard let url = cache[key], FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Resolves the raw source-app avatar and the composed badge attachment for a
    /// package in one shot, pulling the APK at most once (the avatar is the
    /// badge's own input). Blocking — only call from a detached task, never the
    /// main actor, or the UI freezes for the duration of the pull.
    private nonisolated static func resolveIcons(pkg: String, serial: String) -> (avatar: URL?, attachment: URL?) {
        guard let avatar = extractSourceIcon(pkg: pkg, serial: serial) else { return (nil, nil) }
        let attachment = composeForwardedIcon(
            sourceIconURL: avatar,
            outputURL: avatar.deletingLastPathComponent().appendingPathComponent("forwarded-icon.png")
        )
        return (avatar, attachment)
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
            "dumpsys notification --noredact | grep -e NotificationRecord -e android.title= -e android.text= -e android.template="
        ]
        let result = Tooling.runResult("adb", arguments: args, timeout: 4)
        guard result.succeeded else { return nil }
        return result.output
    }

    // MARK: - App icon attachment

    /// Best-effort *raw* source-app icon: pulls the notifying package's APK and
    /// extracts its highest-density launcher PNG/WebP to `source-icon`. Used both
    /// as the communication-notification avatar and as the input to the composed
    /// fallback badge.
    private nonisolated static func extractSourceIcon(pkg: String, serial: String) -> URL? {
        guard !pkg.isEmpty, !serial.isEmpty else { return nil }
        let apkPaths = apkPaths(for: pkg, serial: serial)
        guard !apkPaths.isEmpty else { return nil }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelayNotificationIcons", isDirectory: true)
        let workDir = tempRoot
            .appendingPathComponent(Self.sanitizedFilename(serial), isDirectory: true)
            .appendingPathComponent(Self.sanitizedFilename(pkg), isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let iconURL = workDir.appendingPathComponent("source-icon")

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
                return iconURL
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

        // The PhoneRelay app icon already is a rounded black card, so it stands
        // on its own as the badge — no extra card fill or border around it.
        // Draw it scaled to fill the badge footprint.
        let badgeRect = NSRect(x: 100, y: 0, width: 58, height: 58)
        if let badge = NSImage(named: NSImage.applicationIconName) {
            badge.draw(
                in: badgeRect,
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
                    flags: hexValue(after: "flags=0x", in: line) ?? 0,
                    category: token(after: "category=", in: line) ?? ""
                )
                fallbackText = nil
            } else if current != nil, !haveTitle, line.hasPrefix("android.title=") {
                current?.title = bundleValue(line) ?? ""
                haveTitle = true
            } else if current != nil, line.hasPrefix("android.template=") {
                current?.template = bundleValue(line) ?? ""
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

    /// Heuristic for a one-time / security-code notification (2FA, OTP, login
    /// code). True when the text carries an isolated 4–8 digit code *and* either a
    /// verification keyword is present or the body is just the code — so order
    /// numbers, prices, and times don't get swept up. Pure and unit-tested.
    nonisolated static func isLikelySecurityCode(_ entry: Entry) -> Bool {
        isLikelySecurityCode(title: entry.title, text: entry.text)
    }

    nonisolated static func isLikelySecurityCode(title: String, text: String) -> Bool {
        let haystack = "\(title) \(text)"
        guard let code = firstStandaloneCode(in: haystack) else { return false }
        let lowered = haystack.lowercased()
        let keywords = [
            "code", "otp", "one-time", "one time", "verification", "verify",
            "2fa", "two-factor", "two factor", "password", "passcode", "pin",
            "security", "authenticat", "log in", "login", "sign in", "sign-in", "confirm"
        ]
        if keywords.contains(where: { lowered.contains($0) }) {
            return true
        }
        // No keyword: only suppress when the body is essentially just the code,
        // so "Order #1234 shipped" or "Meeting at 1430" still come through.
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == code
    }

    /// First run of 4–8 digits bounded by non-digits (so 10-digit phone numbers
    /// and longer ids don't match), or nil if there isn't one.
    nonisolated static func firstStandaloneCode(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])[0-9]{4,8}(?![0-9])") else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[matchRange])
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
        guard let open = rhs.firstIndex(of: "(") else {
            return rhs
        }
        let typeName = rhs[..<open].trimmingCharacters(in: .whitespaces)
        guard !typeName.isEmpty, typeName.allSatisfy({ $0.isLetter || $0 == "." || $0 == "$" }) else {
            return rhs
        }
        let close = rhs.lastIndex(of: ")")
        let end = close.map { open < $0 ? $0 : rhs.endIndex } ?? rhs.endIndex
        let inner = rhs[rhs.index(after: open)..<end].trimmingCharacters(in: .whitespaces)
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

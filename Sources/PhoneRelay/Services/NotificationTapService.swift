import AppKit
import Foundation
import ImageIO
import Vision

/// Acts on a forwarded Android notification by driving its row in the phone's
/// expanded notification shade. Tapping the row fires the notification's real
/// `contentIntent` — extras and all — so a tweet opens the tweet and a chat
/// opens the chat; tapping the row's inline "Reply" action lets us type a reply
/// straight into the phone. `adb` cannot fire a notification's `contentIntent`
/// or a RemoteInput `PendingIntent` directly, so genuinely driving the on-device
/// UI is the only general path.
///
/// The row is located by screenshotting the shade and running Vision OCR on
/// the Mac, not `uiautomator dump`: dumping waits for the UI to go idle and
/// any constantly-updating notification (data-speed meters, media progress)
/// makes it fail with "could not get idle state" after ~12 s.
enum NotificationTapService {
    /// Serialized: two banner interactions in quick succession must not
    /// interleave (the first flow's shade collapse would yank the shade out
    /// from under the second flow's screenshot).
    static let tapQueue = DispatchQueue(
        label: "phone-relay.notification-tap",
        qos: .userInitiated
    )

    /// A line of text recognized on a phone screenshot, with its tap point in
    /// physical screen pixels (the same space `input tap` uses).
    struct ShadeTextLine: Equatable {
        var text: String
        var center: CGPoint
    }

    // MARK: - Open (tap-through)

    /// Tapping a collapsed group only expands it, so up to three OCR/tap passes
    /// run until window focus leaves the shade. On failure the shade is
    /// collapsed again so the user is never left staring at the notification
    /// tree, and the caller falls back to launching the source app.
    static func tapForwardedNotificationInShade(
        serial: String,
        notificationKey: String?,
        title: String?,
        text: String?
    ) -> Bool {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty || !text.isEmpty else { return false }

        guard wakeUnlockAndExpandShade(serial: serial, notificationKey: notificationKey) else {
            return false
        }

        var tappedAtLeastOnce = false
        var scrolledShade = false
        for pass in 1...3 {
            Thread.sleep(forTimeInterval: pass == 1 ? 0.8 : 0.6)
            guard let screenshot = capturePhoneScreenPNG(serial: serial) else {
                Logger.log("Could not capture phone screen for forwarded notification key=\(notificationKey ?? "")")
                break
            }
            let lines = recognizedTextLines(inPNG: screenshot)
            guard let point = forwardedNotificationTapPoint(in: lines, title: title, text: text) else {
                // A previous tap may have landed while the shade was still
                // animating closed when we checked focus; recheck before giving
                // up. Otherwise the first pass may simply have raced the shade
                // animation, so look once more.
                if tappedAtLeastOnce, !notificationShadeIsFocused(serial: serial) {
                    Logger.log("Opened forwarded notification content key=\(notificationKey ?? "")")
                    return true
                }
                if pass == 1 { continue }
                // The row may sit below the fold of a full shade; scroll once
                // and take a final look before giving up.
                if !scrolledShade, !tappedAtLeastOnce, pass == 2,
                   let size = pngPixelSize(screenshot) {
                    scrolledShade = true
                    let x = Int(size.width / 2)
                    _ = Tooling.runResult(
                        "adb",
                        arguments: [
                            "-s", serial, "shell", "input", "swipe",
                            "\(x)", "\(Int(size.height * 0.72))",
                            "\(x)", "\(Int(size.height * 0.30))",
                            "250"
                        ],
                        timeout: 2
                    )
                    continue
                }
                Logger.log("Forwarded notification was not visible in notification shade key=\(notificationKey ?? "")")
                break
            }

            let tap = Tooling.runResult(
                "adb",
                arguments: [
                    "-s", serial,
                    "shell",
                    "input", "tap",
                    "\(Int(point.x.rounded()))",
                    "\(Int(point.y.rounded()))"
                ],
                timeout: 2
            )
            guard tap.succeeded else {
                Logger.log("Could not tap forwarded notification key=\(notificationKey ?? ""): \(tap.output)")
                break
            }
            tappedAtLeastOnce = true
            Thread.sleep(forTimeInterval: 0.6)
            if !notificationShadeIsFocused(serial: serial) {
                Logger.log("Opened forwarded notification content key=\(notificationKey ?? "")")
                return true
            }
        }

        // Never leave the user staring at a pulled-down shade after a failure.
        collapseShade(serial: serial)
        return false
    }

    // MARK: - Inline reply (best-effort)

    /// Replies to a message-style notification through its inline RemoteInput
    /// action in the shade: locate the row, tap its "Reply" affordance, type
    /// the reply, then tap the send glyph. This is best-effort and
    /// app/locale-dependent — it only matches an English "Reply" action and the
    /// send button is icon-only, so it returns `false` on any miss and the
    /// caller falls back to simply opening the conversation so the user can
    /// type by hand. The shade is always collapsed again on the way out.
    static func replyToForwardedNotificationInShade(
        serial: String,
        notificationKey: String?,
        title: String?,
        text: String?,
        reply: String
    ) -> Bool {
        let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reply.isEmpty, !title.isEmpty || !text.isEmpty else { return false }

        guard wakeUnlockAndExpandShade(serial: serial, notificationKey: notificationKey) else {
            return false
        }

        var replyPoint: CGPoint?
        var imageSize: CGSize?
        for pass in 1...2 {
            Thread.sleep(forTimeInterval: pass == 1 ? 0.8 : 0.6)
            guard let screenshot = capturePhoneScreenPNG(serial: serial) else { break }
            imageSize = pngPixelSize(screenshot)
            let lines = recognizedTextLines(inPNG: screenshot)
            guard let rowPoint = forwardedNotificationTapPoint(in: lines, title: title, text: text) else {
                if pass == 1 { continue }
                break
            }
            let band = (imageSize?.height ?? 0) * 0.25
            replyPoint = replyAffordancePoint(in: lines, belowRowY: rowPoint.y, maxDistance: band)
            break
        }

        guard let replyPoint, let imageWidth = imageSize?.width else {
            Logger.log("No inline reply action found for forwarded notification key=\(notificationKey ?? "")")
            collapseShade(serial: serial)
            return false
        }

        let tapReply = Tooling.runResult(
            "adb",
            arguments: [
                "-s", serial, "shell", "input", "tap",
                "\(Int(replyPoint.x.rounded()))", "\(Int(replyPoint.y.rounded()))"
            ],
            timeout: 2
        )
        guard tapReply.succeeded else {
            collapseShade(serial: serial)
            return false
        }

        // Let the keyboard slide up and the inline field take focus.
        Thread.sleep(forTimeInterval: 0.9)

        let typed = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "input", "text", shellEscapedForInputText(reply)],
            timeout: 4
        )
        guard typed.succeeded else {
            Logger.log("Could not type reply for forwarded notification key=\(notificationKey ?? ""): \(typed.output)")
            collapseShade(serial: serial)
            return false
        }

        // The send button is an icon at the right end of the input field, so it
        // can't be OCR'd directly. Re-screenshot to find the y of our just-typed
        // text and tap to its right; fall back to the reply affordance's y.
        Thread.sleep(forTimeInterval: 0.4)
        var sendY = replyPoint.y
        if let screenshot = capturePhoneScreenPNG(serial: serial) {
            let lines = recognizedTextLines(inPNG: screenshot)
            if let typedPoint = forwardedNotificationTapPoint(in: lines, title: nil, text: reply) {
                sendY = typedPoint.y
            }
        }
        _ = Tooling.runResult(
            "adb",
            arguments: [
                "-s", serial, "shell", "input", "tap",
                "\(Int((imageWidth * 0.93).rounded()))", "\(Int(sendY.rounded()))"
            ],
            timeout: 2
        )

        Thread.sleep(forTimeInterval: 0.4)
        collapseShade(serial: serial)
        Logger.log("Sent inline reply for forwarded notification key=\(notificationKey ?? "")")
        return true
    }

    // MARK: - Dismiss / Mark as read (best-effort)

    /// Dismisses a forwarded notification by swiping its row out of the shade.
    /// Best-effort: returns false if the row can't be located. The shade is always
    /// collapsed again on the way out.
    static func dismissForwardedNotificationInShade(
        serial: String,
        notificationKey: String?,
        title: String?,
        text: String?
    ) -> Bool {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty || !text.isEmpty else { return false }
        guard wakeUnlockAndExpandShade(serial: serial, notificationKey: notificationKey) else { return false }

        for pass in 1...2 {
            Thread.sleep(forTimeInterval: pass == 1 ? 0.8 : 0.6)
            guard let screenshot = capturePhoneScreenPNG(serial: serial) else { break }
            let lines = recognizedTextLines(inPNG: screenshot)
            guard let point = forwardedNotificationTapPoint(in: lines, title: title, text: text),
                  let size = pngPixelSize(screenshot) else {
                if pass == 1 { continue }
                break
            }
            let dismissed = swipeRowAway(serial: serial, point: point, imageWidth: size.width)
            Thread.sleep(forTimeInterval: 0.3)
            collapseShade(serial: serial)
            if dismissed {
                Logger.log("Dismissed forwarded notification key=\(notificationKey ?? "")")
            }
            return dismissed
        }

        collapseShade(serial: serial)
        return false
    }

    /// Marks a forwarded notification as read via its inline "Mark as read" action,
    /// or — when the app doesn't expose one — swipes the row away (which clears the
    /// unread state for most apps). Best-effort and English-only for the explicit
    /// action; the dismiss fallback is locale-independent.
    static func markReadForwardedNotificationInShade(
        serial: String,
        notificationKey: String?,
        title: String?,
        text: String?
    ) -> Bool {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty || !text.isEmpty else { return false }
        guard wakeUnlockAndExpandShade(serial: serial, notificationKey: notificationKey) else { return false }

        for pass in 1...2 {
            Thread.sleep(forTimeInterval: pass == 1 ? 0.8 : 0.6)
            guard let screenshot = capturePhoneScreenPNG(serial: serial) else { break }
            let size = pngPixelSize(screenshot)
            let lines = recognizedTextLines(inPNG: screenshot)
            guard let rowPoint = forwardedNotificationTapPoint(in: lines, title: title, text: text) else {
                if pass == 1 { continue }
                break
            }

            let band = (size?.height ?? 0) * 0.25
            if let markPoint = markReadAffordancePoint(in: lines, belowRowY: rowPoint.y, maxDistance: band) {
                let tap = Tooling.runResult(
                    "adb",
                    arguments: ["-s", serial, "shell", "input", "tap",
                                "\(Int(markPoint.x.rounded()))", "\(Int(markPoint.y.rounded()))"],
                    timeout: 2
                )
                Thread.sleep(forTimeInterval: 0.3)
                collapseShade(serial: serial)
                if tap.succeeded {
                    Logger.log("Marked forwarded notification as read key=\(notificationKey ?? "")")
                }
                return tap.succeeded
            }

            // No explicit affordance — dismissing clears the unread state for most apps.
            guard let size else { break }
            let dismissed = swipeRowAway(serial: serial, point: rowPoint, imageWidth: size.width)
            Thread.sleep(forTimeInterval: 0.3)
            collapseShade(serial: serial)
            if dismissed {
                Logger.log("Mark-as-read fell back to dismissing notification key=\(notificationKey ?? "")")
            }
            return dismissed
        }

        collapseShade(serial: serial)
        return false
    }

    /// Swipes a located shade row horizontally off the right edge to dismiss it.
    private static func swipeRowAway(serial: String, point: CGPoint, imageWidth: CGFloat) -> Bool {
        Tooling.runResult(
            "adb",
            arguments: [
                "-s", serial, "shell", "input", "swipe",
                "\(Int(point.x.rounded()))", "\(Int(point.y.rounded()))",
                "\(Int((imageWidth * 0.98).rounded()))", "\(Int(point.y.rounded()))",
                "250"
            ],
            timeout: 2
        ).succeeded
    }

    // MARK: - Shade preparation

    /// Wakes the phone, clears a swipe keyguard (waiting briefly for a secure
    /// one to be unlocked by hand), and pulls the notification shade down.
    /// Returns false — with nothing left expanded — if the phone stays locked
    /// or the shade won't open, so the caller can fall back to launching the app.
    private static func wakeUnlockAndExpandShade(serial: String, notificationKey: String?) -> Bool {
        _ = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "input", "keyevent", "KEYCODE_WAKEUP"],
            timeout: 2
        )
        // The keyguard's `showing=` flag lags the wakeup by a beat (Samsung
        // reports false while the display is off); give it a moment so a
        // locked phone isn't misread as unlocked.
        Thread.sleep(forTimeInterval: 0.4)

        // A locked phone shows the lockscreen shade, where content is hidden
        // from the screenshot and taps would bounce off the keyguard anyway.
        // Dismiss a swipe keyguard outright; for a secure one this raises the
        // bouncer (visible in the mirror), so wait for the user to unlock.
        if keyguardIsShowing(serial: serial) {
            _ = Tooling.runResult(
                "adb",
                arguments: ["-s", serial, "shell", "wm", "dismiss-keyguard"],
                timeout: 2
            )
            let unlockDeadline = Date().addingTimeInterval(15)
            while keyguardIsShowing(serial: serial), Date() < unlockDeadline {
                Thread.sleep(forTimeInterval: 0.5)
            }
            guard !keyguardIsShowing(serial: serial) else {
                Logger.log("Phone stayed locked; launching the source app instead for key=\(notificationKey ?? "")")
                return false
            }
        }

        let expand = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "cmd", "statusbar", "expand-notifications"],
            timeout: 2
        )
        guard expand.succeeded else {
            Logger.log("Could not expand notification shade for forwarded notification key=\(notificationKey ?? ""): \(expand.output)")
            return false
        }
        return true
    }

    private static func collapseShade(serial: String) {
        _ = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "cmd", "statusbar", "collapse"],
            timeout: 2
        )
    }

    // MARK: - Matching (pure; unit-tested)

    /// Picks the recognized line that best matches the forwarded notification.
    /// The message text is the strong signal — it identifies one specific
    /// notification — while the title is weaker evidence (sender names and app
    /// labels repeat across rows), so title-only matches are discounted.
    static func forwardedNotificationTapPoint(
        in lines: [ShadeTextLine],
        title: String?,
        text: String?
    ) -> CGPoint? {
        let titleTokens = matchTokens(title ?? "")
        let textTokens = matchTokens(text ?? "")
        guard !titleTokens.isEmpty || !textTokens.isEmpty else { return nil }

        // A very short text ("01:32" on a calendar reminder, "ok") is weak
        // evidence: it collides with the shade's own clock header and other
        // rows, so it must not outweigh a solid title match on the real row.
        let textWeight = textTokens.count >= 3 ? 1.0 : 0.7
        var scored: [(score: Double, line: ShadeTextLine)] = []
        for line in lines {
            let candidateTokens = matchTokens(line.text)
            guard !candidateTokens.isEmpty else { continue }
            let score = max(
                tokenRunScore(label: textTokens, candidate: candidateTokens) * textWeight,
                tokenRunScore(label: titleTokens, candidate: candidateTokens) * 0.8
            )
            if score >= 0.5 { scored.append((score, line)) }
        }
        guard let maxScore = scored.map(\.score).max() else { return nil }
        // When the same app stacks similarly-worded notifications (e.g. two
        // messages from the same sender, both truncated to the same prefix), the
        // text/title match can tie across rows. Break the tie toward the row
        // highest on screen: Android puts the newest notification at the top, and
        // the banner that was just clicked is the newest one. This replaces the
        // old "first match wins" behavior, which depended on Vision's result
        // ordering rather than on-screen position.
        let epsilon = 0.001
        return scored
            .filter { $0.score >= maxScore - epsilon }
            .min(by: { $0.line.center.y < $1.line.center.y })?
            .line.center
    }

    /// Finds a notification row's inline "Reply" action: the closest line that
    /// reads "reply" sitting just below the matched row (action buttons render
    /// under the message text within the same card). `maxDistance` keeps a
    /// "Reply" from an unrelated card further down the shade from matching.
    static func replyAffordancePoint(
        in lines: [ShadeTextLine],
        belowRowY: CGFloat,
        maxDistance: CGFloat
    ) -> CGPoint? {
        var best: (distance: CGFloat, point: CGPoint)?
        for line in lines where matchTokens(line.text).contains("reply") {
            let distance = line.center.y - belowRowY
            guard distance > 0, distance <= maxDistance else { continue }
            if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (distance, line.center)
            }
        }
        return best?.point
    }

    /// Finds a notification row's inline "Mark as read" action: the closest line
    /// below the matched row that contains both "mark" and "read" (English-only).
    /// Same vertical-band guard as the reply affordance.
    static func markReadAffordancePoint(
        in lines: [ShadeTextLine],
        belowRowY: CGFloat,
        maxDistance: CGFloat
    ) -> CGPoint? {
        var best: (distance: CGFloat, point: CGPoint)?
        for line in lines {
            let tokens = matchTokens(line.text)
            guard tokens.contains("mark"), tokens.contains("read") else { continue }
            let distance = line.center.y - belowRowY
            guard distance > 0, distance <= maxDistance else { continue }
            if distance < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (distance, line.center)
            }
        }
        return best?.point
    }

    /// Escapes a reply for `adb shell input text`: spaces become `%s` (the
    /// `input` convention) and characters special to the device shell are
    /// backslash-escaped, since adb reassembles everything after `shell` and
    /// runs it through `/system/bin/sh`.
    static func shellEscapedForInputText(_ reply: String) -> String {
        let specials = Set("\\\"'`$&;|<>()*?[]{}~#!")
        var escaped = ""
        for character in reply {
            if character == " " {
                escaped += "%s"
            } else if specials.contains(character) {
                escaped.append("\\")
                escaped.append(character)
            } else {
                escaped.append(character)
            }
        }
        return escaped
    }

    /// Lowercased alphanumeric words. Emoji and punctuation — and whatever OCR
    /// renders them as — collapse into separators, so the dumpsys-sourced
    /// notification text and the on-screen text align.
    static func matchTokens(_ value: String) -> [String] {
        value.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// Longest run of consecutive label tokens appearing contiguously in the
    /// candidate, scaled against how much of the label can plausibly be visible
    /// (the shade truncates long texts after roughly one line, so a capped
    /// denominator keeps truncated rows scoring high). 1.0 means fully present.
    static func tokenRunScore(label: [String], candidate: [String]) -> Double {
        guard !label.isEmpty, !candidate.isEmpty else { return 0 }
        var longest = 0
        for start in candidate.indices {
            for labelStart in label.indices {
                var length = 0
                while start + length < candidate.count,
                      labelStart + length < label.count,
                      candidate[start + length] == label[labelStart + length] {
                    length += 1
                }
                longest = max(longest, length)
            }
        }
        guard longest >= min(2, label.count) else { return 0 }
        return min(1, Double(longest) / Double(min(label.count, 8)))
    }

    // MARK: - Vision OCR

    /// Vision loads its text-recognition models lazily and the first request in
    /// a process can take several seconds; recognizing one tiny synthetic image
    /// up front moves that cost to app startup so the first real notification
    /// click stays fast.
    static func warmUpTextRecognition() {
        let width = 120
        let height = 40
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributed = NSAttributedString(string: "warm up", attributes: [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ])
        context.textPosition = CGPoint(x: 8, y: 12)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        guard let image = context.makeImage() else { return }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    }

    /// OCRs a phone screenshot into tappable text lines. Lines in the status
    /// bar strip (top 5%) and the shade's bottom action row (Clear /
    /// Notification settings) are dropped so a stray match can't tap them.
    static func recognizedTextLines(inPNG data: Data) -> [ShadeTextLine] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return []
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }

        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            // Vision reports normalized bottom-left boxes; taps use top-left pixels.
            let center = CGPoint(x: box.midX * width, y: (1 - box.midY) * height)
            guard center.y > height * 0.05, center.y < height * 0.93 else { return nil }
            return ShadeTextLine(text: candidate.string, center: center)
        }
    }

    // MARK: - Device state

    /// Hard timeout: a hung adb here would otherwise wedge the serial tap
    /// queue forever, silently swallowing every future banner click.
    private static func capturePhoneScreenPNG(serial: String) -> Data? {
        let result = Tooling.runDataResult(
            "adb",
            arguments: ["-s", serial, "exec-out", "screencap", "-p"],
            timeout: 10
        )
        guard result.succeeded, !result.data.isEmpty else { return nil }
        return result.data
    }

    /// The shade window holds focus (`NotificationShade` on Android 11+,
    /// `StatusBar` before) until a tapped row's content intent fires.
    private static func notificationShadeIsFocused(serial: String) -> Bool {
        let result = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "dumpsys window | grep mCurrentFocus"],
            timeout: 3
        )
        guard result.succeeded else { return false }
        return result.output.contains("NotificationShade") || result.output.contains("StatusBar")
    }

    /// Whether the lockscreen is up or the device still needs credentials.
    /// Two signals because each lags differently: the KeyguardServiceDelegate
    /// `showing=` flag (leading space distinguishes it from
    /// `showingAndNotOccluded=`) reads false while the display is off, and
    /// `deviceLocked=` stays 0 on swipe-only keyguards. Parse failures count
    /// as unlocked so the tap flow degrades to its normal fallback path.
    private static func keyguardIsShowing(serial: String) -> Bool {
        let policy = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "dumpsys window policy | grep ' showing='"],
            timeout: 3
        )
        if policy.succeeded, policy.output.contains("showing=true") {
            return true
        }
        let trust = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "dumpsys trust | grep deviceLocked="],
            timeout: 3
        )
        return trust.succeeded && trust.output.contains("deviceLocked=1")
    }

    private static func pngPixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: width, height: height)
    }
}

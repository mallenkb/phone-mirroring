import AppKit
import Foundation
import ImageIO
import Vision

/// Opens a forwarded Android notification by genuinely tapping its row in the
/// phone's expanded notification shade, which fires the notification's real
/// `contentIntent` — extras and all — so a tweet opens the tweet, a chat opens
/// the chat.
///
/// The row is located by screenshotting the shade and running Vision OCR on
/// the Mac, not `uiautomator dump`: dumping waits for the UI to go idle and
/// any constantly-updating notification (data-speed meters, media progress)
/// makes it fail with "could not get idle state" after ~12 s.
enum NotificationTapService {
    /// Serialized: two banner clicks in quick succession must not interleave
    /// (the first flow's shade collapse would yank the shade out from under
    /// the second flow's screenshot).
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
        _ = Tooling.runResult(
            "adb",
            arguments: ["-s", serial, "shell", "cmd", "statusbar", "collapse"],
            timeout: 2
        )
        return false
    }

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
        var best: (score: Double, point: CGPoint)?
        for line in lines {
            let candidateTokens = matchTokens(line.text)
            guard !candidateTokens.isEmpty else { continue }
            let score = max(
                tokenRunScore(label: textTokens, candidate: candidateTokens) * textWeight,
                tokenRunScore(label: titleTokens, candidate: candidateTokens) * 0.8
            )
            if score >= 0.5, score > (best?.score ?? 0) {
                best = (score, line.center)
            }
        }
        return best?.point
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

import XCTest
@testable import AndroidMirrorMac

final class NotificationLaunchTests: XCTestCase {
    func testLaunchSourceAppArgumentsTargetSelectedSerialAndPackage() {
        XCTAssertEqual(
            AppModel.launchSourceAppArguments(serial: "ABC123", package: "com.whatsapp"),
            [
                "-s", "ABC123",
                "shell",
                "monkey",
                "-p", "com.whatsapp",
                "-c", "android.intent.category.LAUNCHER",
                "1"
            ]
        )
    }

    func testTapPointMatchesSimpleTitleAndTextRows() {
        let lines = [
            AppModel.ShadeTextLine(text: "Mom", center: CGPoint(x: 135, y: 340)),
            AppModel.ShadeTextLine(text: "Dinner at 7?", center: CGPoint(x: 265, y: 387)),
            AppModel.ShadeTextLine(text: "Other notification", center: CGPoint(x: 265, y: 445))
        ]

        let point = AppModel.forwardedNotificationTapPoint(
            in: lines,
            title: "Mom",
            text: "Dinner at 7?"
        )

        XCTAssertEqual(point, CGPoint(x: 265, y: 387))
    }

    // The shade merges title and text onto one OCR line and truncates with an
    // ellipsis; the row must still match its full dumpsys-sourced text.
    func testTapPointMatchesMergedTitleAndTruncatedText() {
        let lines = [
            AppModel.ShadeTextLine(text: "Fabrizio Romano •\" •• Vedat Muriqi to Fe...", center: CGPoint(x: 600, y: 1617)),
            AppModel.ShadeTextLine(text: "Glitched Deals ok the FIFA World Cup freebie...", center: CGPoint(x: 603, y: 1694)),
            AppModel.ShadeTextLine(text: "Down: 88 kb/s Up: 80 kb/s Signal 10...", center: CGPoint(x: 549, y: 1833))
        ]

        let point = AppModel.forwardedNotificationTapPoint(
            in: lines,
            title: "Glitched Deals",
            text: "ok the FIFA World Cup freebie pile is getting out of hand"
        )

        XCTAssertEqual(point, CGPoint(x: 603, y: 1694))
    }

    // Emoji in the notification text don't survive OCR; matching must tolerate
    // the leading garbage they become.
    func testTapPointIgnoresEmojiAndPunctuationDifferences() {
        let lines = [
            AppModel.ShadeTextLine(text: "Wallet 20:54", center: CGPoint(x: 297, y: 1147)),
            AppModel.ShadeTextLine(text: ".• Be early to the biggest IPO in history", center: CGPoint(x: 600, y: 1212))
        ]

        let point = AppModel.forwardedNotificationTapPoint(
            in: lines,
            title: "Wallet",
            text: "🖼 🚀 Be early to the biggest IPO in history"
        )

        XCTAssertEqual(point, CGPoint(x: 600, y: 1212))
    }

    // Several rows can share a title (same sender); the message text must pick
    // the right one.
    func testTapPointPrefersExactTextOverSharedTitle() {
        let lines = [
            AppModel.ShadeTextLine(text: "Duncan @ephraimduncan reposted: I just got Android…", center: CGPoint(x: 500, y: 900)),
            AppModel.ShadeTextLine(text: "Duncan @ephraimduncan replied: wow", center: CGPoint(x: 500, y: 1050))
        ]

        let point = AppModel.forwardedNotificationTapPoint(
            in: lines,
            title: "Duncan",
            text: "@ephraimduncan replied: wow"
        )

        XCTAssertEqual(point, CGPoint(x: 500, y: 1050))
    }

    func testTapPointReturnsNilWithoutPlausibleMatch() {
        let lines = [
            AppModel.ShadeTextLine(text: "Down: 88 kb/s Up: 80 kb/s Signal 10...", center: CGPoint(x: 549, y: 1833)),
            AppModel.ShadeTextLine(text: "Mobile: 778.1 MB WiFi: 10.04 GB", center: CGPoint(x: 495, y: 1884))
        ]

        XCTAssertNil(
            AppModel.forwardedNotificationTapPoint(
                in: lines,
                title: "Mom",
                text: "Dinner at 7?"
            )
        )
    }

    func testTokenRunScoreRequiresContiguousOverlap() {
        XCTAssertEqual(
            AppModel.tokenRunScore(
                label: AppModel.matchTokens("Dinner at 7?"),
                candidate: AppModel.matchTokens("Dinner at 7?")
            ),
            1
        )
        // Scattered single-word coincidences must not count as a match.
        XCTAssertEqual(
            AppModel.tokenRunScore(
                label: AppModel.matchTokens("up the signal hill"),
                candidate: AppModel.matchTokens("Down: 88 kb/s Up: 80 kb/s Signal 10")
            ),
            0
        )
    }

    // A long text truncated to one shade line still scores as fully present
    // thanks to the capped denominator.
    func testTokenRunScoreToleratesTruncation() {
        let score = AppModel.tokenRunScore(
            label: AppModel.matchTokens("ok the FIFA World Cup freebie pile is getting out of hand"),
            candidate: AppModel.matchTokens("Glitched Deals ok the FIFA World Cup freebie...")
        )
        XCTAssertGreaterThanOrEqual(score, 0.5)
    }
}

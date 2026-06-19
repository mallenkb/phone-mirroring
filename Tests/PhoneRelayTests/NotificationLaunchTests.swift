import XCTest
@testable import PhoneRelay

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
            NotificationTapService.ShadeTextLine(text: "Mom", center: CGPoint(x: 135, y: 340)),
            NotificationTapService.ShadeTextLine(text: "Dinner at 7?", center: CGPoint(x: 265, y: 387)),
            NotificationTapService.ShadeTextLine(text: "Other notification", center: CGPoint(x: 265, y: 445))
        ]

        let point = NotificationTapService.forwardedNotificationTapPoint(
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
            NotificationTapService.ShadeTextLine(text: "Fabrizio Romano •\" •• Vedat Muriqi to Fe...", center: CGPoint(x: 600, y: 1617)),
            NotificationTapService.ShadeTextLine(text: "Glitched Deals ok the FIFA World Cup freebie...", center: CGPoint(x: 603, y: 1694)),
            NotificationTapService.ShadeTextLine(text: "Down: 88 kb/s Up: 80 kb/s Signal 10...", center: CGPoint(x: 549, y: 1833))
        ]

        let point = NotificationTapService.forwardedNotificationTapPoint(
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
            NotificationTapService.ShadeTextLine(text: "Wallet 20:54", center: CGPoint(x: 297, y: 1147)),
            NotificationTapService.ShadeTextLine(text: ".• Be early to the biggest IPO in history", center: CGPoint(x: 600, y: 1212))
        ]

        let point = NotificationTapService.forwardedNotificationTapPoint(
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
            NotificationTapService.ShadeTextLine(text: "Duncan @ephraimduncan reposted: I just got Android…", center: CGPoint(x: 500, y: 900)),
            NotificationTapService.ShadeTextLine(text: "Duncan @ephraimduncan replied: wow", center: CGPoint(x: 500, y: 1050))
        ]

        let point = NotificationTapService.forwardedNotificationTapPoint(
            in: lines,
            title: "Duncan",
            text: "@ephraimduncan replied: wow"
        )

        XCTAssertEqual(point, CGPoint(x: 500, y: 1050))
    }

    // A notification whose text is just a time ("01:32" — every calendar
    // reminder) collides with the shade's own clock header; a solid title match
    // on the real row must win over the short text's collisions.
    func testTapPointPrefersTitleRowOverHeaderClockForTimeOnlyText() {
        let lines = [
            NotificationTapService.ShadeTextLine(text: "01:32", center: CGPoint(x: 200, y: 250)),
            NotificationTapService.ShadeTextLine(text: "Fri, 13 June", center: CGPoint(x: 420, y: 250)),
            NotificationTapService.ShadeTextLine(text: "Phone Relay deep link check", center: CGPoint(x: 540, y: 1500)),
            NotificationTapService.ShadeTextLine(text: "01:32", center: CGPoint(x: 300, y: 1560))
        ]

        let point = NotificationTapService.forwardedNotificationTapPoint(
            in: lines,
            title: "Phone Relay deep link check",
            text: "01:32"
        )

        XCTAssertEqual(point, CGPoint(x: 540, y: 1500))
    }

    // Two notifications from the same app with identically-truncated text tie on
    // score; the newest (topmost) row is the one the banner is for.
    func testTapPointPrefersNewestRowWhenSameAppRepeatsIdenticalText() {
        let lines = [
            NotificationTapService.ShadeTextLine(text: "Mom", center: CGPoint(x: 120, y: 300)),
            NotificationTapService.ShadeTextLine(text: "You have a new message", center: CGPoint(x: 300, y: 350)),
            NotificationTapService.ShadeTextLine(text: "Mom", center: CGPoint(x: 120, y: 600)),
            NotificationTapService.ShadeTextLine(text: "You have a new message", center: CGPoint(x: 300, y: 650))
        ]

        let point = NotificationTapService.forwardedNotificationTapPoint(
            in: lines,
            title: "Mom",
            text: "You have a new message"
        )

        XCTAssertEqual(point, CGPoint(x: 300, y: 350))
    }

    func testTapPointReturnsNilWithoutPlausibleMatch() {
        let lines = [
            NotificationTapService.ShadeTextLine(text: "Down: 88 kb/s Up: 80 kb/s Signal 10...", center: CGPoint(x: 549, y: 1833)),
            NotificationTapService.ShadeTextLine(text: "Mobile: 778.1 MB WiFi: 10.04 GB", center: CGPoint(x: 495, y: 1884))
        ]

        XCTAssertNil(
            NotificationTapService.forwardedNotificationTapPoint(
                in: lines,
                title: "Mom",
                text: "Dinner at 7?"
            )
        )
    }

    func testTokenRunScoreRequiresContiguousOverlap() {
        XCTAssertEqual(
            NotificationTapService.tokenRunScore(
                label: NotificationTapService.matchTokens("Dinner at 7?"),
                candidate: NotificationTapService.matchTokens("Dinner at 7?")
            ),
            1
        )
        // Scattered single-word coincidences must not count as a match.
        XCTAssertEqual(
            NotificationTapService.tokenRunScore(
                label: NotificationTapService.matchTokens("up the signal hill"),
                candidate: NotificationTapService.matchTokens("Down: 88 kb/s Up: 80 kb/s Signal 10")
            ),
            0
        )
    }

    // A long text truncated to one shade line still scores as fully present
    // thanks to the capped denominator.
    func testTokenRunScoreToleratesTruncation() {
        let score = NotificationTapService.tokenRunScore(
            label: NotificationTapService.matchTokens("ok the FIFA World Cup freebie pile is getting out of hand"),
            candidate: NotificationTapService.matchTokens("Glitched Deals ok the FIFA World Cup freebie...")
        )
        XCTAssertGreaterThanOrEqual(score, 0.5)
    }

    // MARK: - Inline reply affordance

    func testReplyAffordancePicksClosestReplyBelowTheRow() {
        let lines = [
            NotificationTapService.ShadeTextLine(text: "Dinner at 7?", center: CGPoint(x: 265, y: 400)),
            NotificationTapService.ShadeTextLine(text: "Reply", center: CGPoint(x: 180, y: 470)),
            NotificationTapService.ShadeTextLine(text: "Mark as read", center: CGPoint(x: 360, y: 470)),
            NotificationTapService.ShadeTextLine(text: "Reply", center: CGPoint(x: 180, y: 900))
        ]

        let point = NotificationTapService.replyAffordancePoint(
            in: lines,
            belowRowY: 400,
            maxDistance: 300
        )

        XCTAssertEqual(point, CGPoint(x: 180, y: 470))
    }

    func testReplyAffordanceIgnoresReplyAboveOrTooFarBelow() {
        let above = NotificationTapService.replyAffordancePoint(
            in: [NotificationTapService.ShadeTextLine(text: "Reply", center: CGPoint(x: 180, y: 300))],
            belowRowY: 400,
            maxDistance: 300
        )
        XCTAssertNil(above)

        let tooFar = NotificationTapService.replyAffordancePoint(
            in: [NotificationTapService.ShadeTextLine(text: "Reply", center: CGPoint(x: 180, y: 900))],
            belowRowY: 400,
            maxDistance: 300
        )
        XCTAssertNil(tooFar)
    }

    // MARK: - Mark-as-read affordance

    func testMarkReadAffordanceFindsActionBelowRow() {
        let lines = [
            NotificationTapService.ShadeTextLine(text: "Dinner at 7?", center: CGPoint(x: 265, y: 400)),
            NotificationTapService.ShadeTextLine(text: "Reply", center: CGPoint(x: 180, y: 470)),
            NotificationTapService.ShadeTextLine(text: "Mark as read", center: CGPoint(x: 360, y: 470))
        ]

        let point = NotificationTapService.markReadAffordancePoint(
            in: lines,
            belowRowY: 400,
            maxDistance: 300
        )

        XCTAssertEqual(point, CGPoint(x: 360, y: 470))
    }

    func testMarkReadAffordanceRequiresBothMarkAndReadTokens() {
        // "Read more" (read without mark) and a standalone "Mark" must not match.
        let lines = [
            NotificationTapService.ShadeTextLine(text: "Read more", center: CGPoint(x: 200, y: 470)),
            NotificationTapService.ShadeTextLine(text: "Mark important", center: CGPoint(x: 200, y: 500))
        ]
        XCTAssertNil(
            NotificationTapService.markReadAffordancePoint(in: lines, belowRowY: 400, maxDistance: 300)
        )
    }

    // MARK: - Reply text escaping

    func testShellEscapedReplaceSpacesWithPercentS() {
        XCTAssertEqual(
            NotificationTapService.shellEscapedForInputText("hello world"),
            "hello%sworld"
        )
    }

    func testShellEscapedEscapesShellMetacharacters() {
        XCTAssertEqual(
            NotificationTapService.shellEscapedForInputText("it's a (test) & more!"),
            "it\\'s%sa%s\\(test\\)%s\\&%smore\\!"
        )
    }

    func testShellEscapedLeavesPlainTextUntouched() {
        XCTAssertEqual(
            NotificationTapService.shellEscapedForInputText("OnMyWay"),
            "OnMyWay"
        )
    }
}

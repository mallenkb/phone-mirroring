import XCTest
@testable import AndroidMirrorMac

final class NotificationForwarderTests: XCTestCase {
    // A trimmed but faithful slice of real `dumpsys notification --noredact`
    // output: one group-summary header (must be skipped), one ordinary message
    // notification, and one service notification whose text contains parentheses.
    private let dump = """
        NotificationRecord(0x0ab6ea80: pkg=com.twitter.android user=UserHandle{0} id=2147483647 tag=ranker_group importance=3 key=0|com.twitter.android|2147483647|ranker_group|10338|ranker_group: Notification(channel=tweets shortcut=null contentView=null defaults=0x0 flags=0x700 color=0xff1d9bf0 groupKey=ranker_group vis=PRIVATE))
              uid=10338 userId=0
              extras={
                  android.title=String (Twitter)
                  android.text=String (5 new posts)
              }
        NotificationRecord(0x061d2fbf: pkg=com.whatsapp user=UserHandle{0} id=-169 tag=null importance=4 key=0|com.whatsapp|-169|null|10279: Notification(channel=Messages shortcut=null contentView=null defaults=0x0 flags=0x10 color=0xff25d366 category=msg actions=1 vis=PRIVATE))
              uid=10279 userId=0
              extras={
                  android.title=String (Mom)
                  android.template=String (android.app.Notification$MessagingStyle)
                  android.text=String (Dinner at 7?)
                  android.bigText=null
              }
              publicNotification=
                    None
        NotificationRecord(0x02e3d114: pkg=com.ubercab user=UserHandle{0} id=8 tag=trip importance=4 key=0|com.ubercab|8|trip|10337: Notification(channel=trip shortcut=null contentView=null defaults=0x0 flags=0x18 color=0xffdedede vis=PRIVATE))
              uid=10337 userId=0
              extras={
                  android.title=String (Uber)
                  android.subText=null
                  android.text=String (Arriving now (2 min away))
              }
        """

    func testParseExtractsHeaderAndContentFields() {
        let entries = NotificationForwarder.parse(dump)
        XCTAssertEqual(entries.count, 3)

        let whatsapp = entries[1]
        XCTAssertEqual(whatsapp.pkg, "com.whatsapp")
        XCTAssertEqual(whatsapp.key, "0|com.whatsapp|-169|null|10279")
        XCTAssertEqual(whatsapp.title, "Mom")
        XCTAssertEqual(whatsapp.text, "Dinner at 7?")
        XCTAssertEqual(whatsapp.flags, 0x10)
    }

    func testParseTakesFirstTitleAndTextAfterHeader() {
        // `android.template`/`android.bigText` between title and text must not be
        // mistaken for content, and `publicNotification` copies must not win.
        let whatsapp = NotificationForwarder.parse(dump)[1]
        XCTAssertEqual(whatsapp.title, "Mom")
        XCTAssertEqual(whatsapp.text, "Dinner at 7?")
    }

    func testParseHandilesParenthesesInValue() {
        let uber = NotificationForwarder.parse(dump)[2]
        XCTAssertEqual(uber.title, "Uber")
        XCTAssertEqual(uber.text, "Arriving now (2 min away)")
    }

    func testGroupSummaryIsParsedButNotForwardable() {
        let summary = NotificationForwarder.parse(dump)[0]
        XCTAssertEqual(summary.flags, 0x700) // includes FLAG_GROUP_SUMMARY (0x200)
        XCTAssertFalse(NotificationForwarder.isForwardable(summary))
    }

    func testOrdinaryNotificationsAreForwardable() {
        let entries = NotificationForwarder.parse(dump)
        XCTAssertTrue(NotificationForwarder.isForwardable(entries[1]))
        XCTAssertTrue(NotificationForwarder.isForwardable(entries[2]))
    }

    func testOngoingAndForegroundServiceAreSkipped() {
        let ongoing = NotificationForwarder.Entry(
            key: "k", pkg: "com.spotify.music", title: "Spotify", text: "Now playing",
            flags: NotificationForwarder.flagOngoingEvent
        )
        let fgs = NotificationForwarder.Entry(
            key: "k2", pkg: "com.app", title: "Syncing", text: "…",
            flags: NotificationForwarder.flagForegroundService
        )
        XCTAssertFalse(NotificationForwarder.isForwardable(ongoing))
        XCTAssertFalse(NotificationForwarder.isForwardable(fgs))
    }

    func testEmptyTitleAndTextIsNotForwardable() {
        let blank = NotificationForwarder.Entry(key: "k", pkg: "com.app", title: "", text: "", flags: 0)
        XCTAssertFalse(NotificationForwarder.isForwardable(blank))
    }

    func testBundleValueParsesTypesAndNull() {
        XCTAssertEqual(NotificationForwarder.bundleValue("android.title=String (Uber)"), "Uber")
        XCTAssertEqual(NotificationForwarder.bundleValue("android.title=CharSequence (Hi there)"), "Hi there")
        XCTAssertNil(NotificationForwarder.bundleValue("android.text=null"))
        XCTAssertNil(NotificationForwarder.bundleValue("android.text=String ()"))
    }

    func testUnseenForwardableDiffSkipsAlreadySeenAndUpdatesOnNewContent() {
        let entries = NotificationForwarder.parse(dump)
        let forwardable = entries.filter { NotificationForwarder.isForwardable($0) }

        // Nothing seen yet → both real notifications are new.
        let firstPass = NotificationForwarder.unseenForwardable(entries, seen: [])
        XCTAssertEqual(firstPass.map(\.pkg), ["com.whatsapp", "com.ubercab"])

        // After recording their fingerprints, an unchanged re-poll yields nothing.
        let seen = Set(forwardable.map(\.fingerprint))
        XCTAssertTrue(NotificationForwarder.unseenForwardable(entries, seen: seen).isEmpty)

        // The same WhatsApp key with new text is a new fingerprint → forwarded.
        let updated = NotificationForwarder.Entry(
            key: "0|com.whatsapp|-169|null|10279", pkg: "com.whatsapp",
            title: "Mom", text: "Actually, 8?", flags: 0x10
        )
        XCTAssertEqual(
            NotificationForwarder.unseenForwardable([updated], seen: seen).map(\.text),
            ["Actually, 8?"]
        )
    }

    func testAppLabelDerivesReadableName() {
        XCTAssertEqual(NotificationForwarder.appLabel(for: "com.twitter.android"), "Twitter")
        XCTAssertEqual(NotificationForwarder.appLabel(for: "com.ubercab"), "Ubercab")
        XCTAssertEqual(NotificationForwarder.appLabel(for: "com.whatsapp"), "Whatsapp")
    }

    func testForwardedNotificationMessageIncludesLabubu() {
        // A real-world restock alert. The body text must survive parsing and
        // reach the forwarded macOS notification's message verbatim — the message
        // the user sees should include "Labubu".
        let restockDump = """
            NotificationRecord(0x07a1b2c3: pkg=com.popmart.global user=UserHandle{0} id=77 tag=null importance=4 key=0|com.popmart.global|77|null|10501: Notification(channel=restock shortcut=null contentView=null defaults=0x0 flags=0x10 color=0xffe60012 category=promo vis=PRIVATE))
                  uid=10501 userId=0
                  extras={
                      android.title=String (POP MART)
                      android.text=String (Labubu is back in stock!)
                  }
            """

        let entries = NotificationForwarder.parse(restockDump)
        XCTAssertEqual(entries.count, 1)

        let restock = entries[0]
        XCTAssertEqual(restock.pkg, "com.popmart.global")
        XCTAssertEqual(restock.title, "POP MART")
        XCTAssertTrue(
            restock.text.localizedCaseInsensitiveContains("labubu"),
            "Forwarded message should include Labubu, got: \(restock.text)"
        )
        XCTAssertTrue(NotificationForwarder.isForwardable(restock))

        // End-to-end: a fresh poll forwards it with the message text intact.
        let forwarded = NotificationForwarder.unseenForwardable(entries, seen: [])
        XCTAssertEqual(forwarded.map(\.text), ["Labubu is back in stock!"])
    }

    func testForwardedNotificationPopsUpWithSound() {
        let entry = NotificationForwarder.Entry(
            key: "0|com.popmart.global|77|null|10501", pkg: "com.popmart.global",
            title: "POP MART", text: "Labubu is back in stock!", flags: 0x10
        )
        let content = NotificationForwarder.notificationContent(for: entry)
        XCTAssertEqual(content.title, "POP MART")
        XCTAssertEqual(content.body, "Labubu is back in stock!")
        // A sound must be attached or the banner is delivered silently.
        XCTAssertNotNil(content.sound, "Forwarded notifications should pop up with sound")
    }

    func testTitlelessNotificationFallsBackToAppNameWithSound() {
        let entry = NotificationForwarder.Entry(
            key: "k", pkg: "com.popmart.global", title: "", text: "Restock!", flags: 0
        )
        let content = NotificationForwarder.notificationContent(for: entry)
        XCTAssertEqual(content.title, "Global") // appLabel fallback
        XCTAssertEqual(content.body, "Restock!")
        XCTAssertNotNil(content.sound)
    }
}

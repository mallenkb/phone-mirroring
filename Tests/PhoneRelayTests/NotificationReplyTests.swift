import XCTest
@testable import PhoneRelay

final class NotificationReplyTests: XCTestCase {
    func testHierarchyPreservesUnicodeAndNewlines() throws {
        let nodes = try XCTUnwrap(NotificationReplyService.parseHierarchy("""
        <?xml version="1.0"?><hierarchy><node resource-id="com.android.systemui:id/remote_input_text" text="Hello 👋&#10;Next line" enabled="true" focused="true" bounds="[10,20][110,80]"/></hierarchy>
        UI hierarchy dumped to: /dev/tty
        """))
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes.first?.text, "Hello 👋\nNext line")
        XCTAssertEqual(nodes.first?.center?.0, 60)
        XCTAssertEqual(nodes.first?.center?.1, 50)
    }

    func testMalformedHierarchyFailsClosed() {
        XCTAssertNil(NotificationReplyService.parseHierarchy("permission denied"))
        XCTAssertNil(NotificationReplyService.parseHierarchy("<?xml version=\"1.0\"?><hierarchy><node></hierarchy>"))
    }

    func testUncertainSubmissionMustNotBeRetried() {
        XCTAssertTrue(NotificationReplyService.Outcome.unconfirmed.didAttemptSubmission)
        XCTAssertTrue(NotificationReplyService.Outcome.submitted.didAttemptSubmission)
        XCTAssertFalse(NotificationReplyService.Outcome.failed("Unavailable").didAttemptSubmission)
    }

    func testExpandedMessagePreservesLineBreaks() throws {
        let entries = NotificationForwarder.parse("""
        NotificationRecord(0x123: pkg=com.whatsapp key=0|com.whatsapp|1|null|1: Notification(flags=0x0 category=msg))
          extras={
            android.title=String (Alice)
            android.text=String (Preview)
            android.bigText=String (First line
        Second line 👋)
          }
        """)
        XCTAssertEqual(try XCTUnwrap(entries.first).text, "First line\nSecond line 👋")
    }
}

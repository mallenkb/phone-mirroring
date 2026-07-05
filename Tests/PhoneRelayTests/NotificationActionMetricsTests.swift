import XCTest
@testable import PhoneRelay

/// The OCR-drift counters must count, persist, and summarize — and stay
/// silent (empty summary) until an action has actually fired.
final class NotificationActionMetricsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = TestDomainHygiene.sweepOnce
        suiteName = "PhoneRelayTests.metrics.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testUnusedMetricsProduceNoSummary() {
        XCTAssertTrue(NotificationActionMetrics(defaults: defaults).summaryLines.isEmpty)
    }

    func testRecordCountsAndSummarizesPerAction() {
        let metrics = NotificationActionMetrics(defaults: defaults)
        metrics.record(.open, outcome: .exact)
        metrics.record(.open, outcome: .exact)
        metrics.record(.open, outcome: .fallback)
        metrics.record(.reply, outcome: .exact)

        XCTAssertEqual(metrics.count(.open, .exact), 2)
        XCTAssertEqual(metrics.count(.open, .fallback), 1)
        XCTAssertEqual(metrics.count(.reply, .exact), 1)
        XCTAssertEqual(metrics.count(.markRead, .exact), 0)
        XCTAssertEqual(metrics.summaryLines, [
            "Open: 2 exact · 1 app-only",
            "Reply: 1 exact · 0 app-only"
        ])
    }

    func testCountsPersistAcrossInstances() {
        NotificationActionMetrics(defaults: defaults).record(.markRead, outcome: .fallback)
        let reloaded = NotificationActionMetrics(defaults: defaults)
        XCTAssertEqual(reloaded.count(.markRead, .fallback), 1)
        XCTAssertEqual(reloaded.summaryLines, ["Mark as read: 0 exact · 1 app-only"])
    }
}

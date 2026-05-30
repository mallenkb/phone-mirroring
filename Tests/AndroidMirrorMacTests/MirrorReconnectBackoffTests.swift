import XCTest
@testable import AndroidMirrorMac

final class MirrorReconnectBackoffTests: XCTestCase {
    func testFirstQuickFailureDoesNotBackOff() {
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 0), 0)
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 1), 0)
    }

    func testRepeatedQuickFailuresGrowTheBackoff() {
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 2), 10)
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 3), 20)
    }

    func testBackoffIsCappedSoItStillSelfHeals() {
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 4), 30)
        XCTAssertEqual(AppModel.mirrorBackoffInterval(forFailureCount: 50), 30)
    }
}

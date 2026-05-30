import XCTest
@testable import AndroidMirrorMac

final class ScrcpyVideoStreamTests: XCTestCase {
    func testSecondConnectionBecomesControlWhenAudioIsDisabled() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: true,
            hasControl: false
        )

        XCTAssertEqual(role, .control)
    }

    func testRejectsExtraConnectionsAfterVideoAndControlAreAssigned() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: true,
            hasControl: true
        )

        XCTAssertEqual(role, .reject)
    }
}

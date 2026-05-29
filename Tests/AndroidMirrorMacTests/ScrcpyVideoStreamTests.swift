import XCTest
@testable import AndroidMirrorMac

final class ScrcpyVideoStreamTests: XCTestCase {
    func testAcceptsLateAudioConnectionAfterControlWasAssigned() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: true,
            hasAudio: false,
            hasPendingAudioProbe: false,
            hasControl: true
        )

        XCTAssertEqual(role, .audio)
    }
}

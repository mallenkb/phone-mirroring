import XCTest
@testable import AndroidMirrorMac

final class ScrcpyVideoStreamTests: XCTestCase {
    func testSecondConnectionBecomesControlWhenAudioIsDisabled() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: true,
            hasAudio: false,
            hasControl: false,
            expectsAudio: false
        )

        XCTAssertEqual(role, .control)
    }

    func testRejectsExtraConnectionsAfterVideoAndControlAreAssigned() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: true,
            hasAudio: false,
            hasControl: true,
            expectsAudio: false
        )

        XCTAssertEqual(role, .reject)
    }

    // MARK: - Audio-enabled ordering (video → audio → control → reject)

    func testFirstConnectionIsAlwaysVideo() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: false, hasAudio: false, hasControl: false, expectsAudio: true
        )
        XCTAssertEqual(role, .video)
    }

    func testSecondConnectionIsAudioWhenAudioExpected() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: true, hasAudio: false, hasControl: false, expectsAudio: true
        )
        XCTAssertEqual(role, .audio)
    }

    func testThirdConnectionIsControlAfterAudio() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: true, hasAudio: true, hasControl: false, expectsAudio: true
        )
        XCTAssertEqual(role, .control)
    }

    func testRejectsFourthConnectionWithAudio() {
        let role = ScrcpyVideoStream.roleForNextConnection(
            hasVideo: true, hasAudio: true, hasControl: true, expectsAudio: true
        )
        XCTAssertEqual(role, .reject)
    }
}

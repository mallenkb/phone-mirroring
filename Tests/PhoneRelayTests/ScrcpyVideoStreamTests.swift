import XCTest
@testable import PhoneRelay

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

    func testPacketSizeCapsAreBounded() {
        XCTAssertEqual(ScrcpyVideoStream.maxVideoPacketBytes, 32 * 1024 * 1024)
        XCTAssertEqual(ScrcpyVideoStream.maxAudioPacketBytes, 4 * 1024 * 1024)
    }

    func testSupportedAudioCodecIDsIncludeOnlyOpus() {
        XCTAssertTrue(ScrcpyVideoStream.isSupportedAudioCodecID(ScrcpyVideoStream.opusAudioCodecID))
        XCTAssertFalse(ScrcpyVideoStream.isSupportedAudioCodecID(0x0072_6177))
        XCTAssertFalse(ScrcpyVideoStream.isSupportedAudioCodecID(0x6161_6320))
    }

    func testStreamSizeValidationRejectsZeroAndImplausibleDimensions() {
        XCTAssertTrue(ScrcpyVideoStream.isValidStreamSize(width: 1080, height: 2340))
        XCTAssertFalse(ScrcpyVideoStream.isValidStreamSize(width: 0, height: 2340))
        XCTAssertFalse(ScrcpyVideoStream.isValidStreamSize(width: 1080, height: 0))
        XCTAssertFalse(ScrcpyVideoStream.isValidStreamSize(width: 20_000, height: 1080))
        XCTAssertFalse(ScrcpyVideoStream.isValidStreamSize(width: 16_384, height: 16_384))
    }

    func testStreamEndedMessageMarksClosedSocketAsDisconnect() {
        XCTAssertEqual(ScrcpyVideoStream.streamEndedMessage, "scrcpy stream ended")
    }
}

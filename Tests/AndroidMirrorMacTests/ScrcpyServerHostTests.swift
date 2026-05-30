import XCTest
@testable import AndroidMirrorMac

final class ScrcpyServerHostTests: XCTestCase {
    func testDefaultServerArgumentsDisableAudioForStableNativeMirrorStartup() {
        let arguments = ScrcpyServerHost.serverArguments(for: .init(
            scid: 0x1234ABCD,
            localPort: 37283
        ))

        XCTAssertTrue(arguments.contains("audio=false"))
        XCTAssertFalse(arguments.contains("audio=true"))
        XCTAssertFalse(arguments.contains("audio_codec=raw"))
        XCTAssertFalse(arguments.contains("audio_source=output"))
    }

    func testWirelessMirrorServerArgumentsDisableAudioForStableNativeMirrorStartup() {
        let options = ScrcpyServerHost.Options(
            scid: 0x1234ABCD,
            localPort: 37283,
            serial: "192.168.1.24:40719"
        )

        let arguments = ScrcpyServerHost.serverArguments(for: options)

        XCTAssertTrue(arguments.contains("audio=false"))
        XCTAssertFalse(arguments.contains("audio=true"))
        XCTAssertFalse(arguments.contains("audio_codec=raw"))
        XCTAssertFalse(arguments.contains("audio_source=output"))
    }

    func testAudioEnabledAddsRawPlaybackCaptureArgs() {
        let arguments = ScrcpyServerHost.serverArguments(for: .init(
            scid: 0x1234ABCD,
            localPort: 37283,
            audio: true
        ))

        XCTAssertTrue(arguments.contains("audio=true"))
        XCTAssertTrue(arguments.contains("audio_codec=raw"))
        XCTAssertTrue(arguments.contains("audio_source=output"))
    }

    func testServerArgumentsNeverPassStayAwake() {
        // stay_awake=true aborts the server natively on Samsung One UI.
        let withAudio = ScrcpyServerHost.serverArguments(for: .init(scid: 1, localPort: 1, audio: true))
        let withoutAudio = ScrcpyServerHost.serverArguments(for: .init(scid: 1, localPort: 1))
        XCTAssertFalse(withAudio.contains("stay_awake=true"))
        XCTAssertFalse(withoutAudio.contains("stay_awake=true"))
    }
}

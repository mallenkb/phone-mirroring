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
}

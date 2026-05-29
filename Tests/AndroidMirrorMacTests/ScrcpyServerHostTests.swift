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
}

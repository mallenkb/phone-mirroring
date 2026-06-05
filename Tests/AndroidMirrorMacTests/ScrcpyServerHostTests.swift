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
        XCTAssertFalse(arguments.contains("audio_source=playback"))
        XCTAssertFalse(arguments.contains("audio_dup=true"))
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
        XCTAssertFalse(arguments.contains("audio_source=playback"))
        XCTAssertFalse(arguments.contains("audio_dup=true"))
    }

    func testServerArgumentsEnableAudioWithUpstreamDefaultsWhenOptedIn() {
        // Match upstream scrcpy defaults by enabling audio without forcing
        // codec/source/bit-rate options that can crash some Samsung builds.
        let arguments = ScrcpyServerHost.serverArguments(for: .init(
            scid: 0x1234ABCD,
            localPort: 37283,
            audio: true
        ))

        XCTAssertTrue(arguments.contains("audio=true"))
        XCTAssertFalse(arguments.contains("audio=false"))
        XCTAssertFalse(arguments.contains("audio_codec=opus"))
        XCTAssertFalse(arguments.contains("audio_bit_rate=16000"))
        XCTAssertFalse(arguments.contains("audio_source=output"))
        XCTAssertFalse(arguments.contains("audio_source=playback"))
        XCTAssertFalse(arguments.contains("audio_dup=true"))
    }

    func testServerArgumentsNeverPassStayAwake() {
        // stay_awake=true aborts the server natively on Samsung One UI.
        let arguments = ScrcpyServerHost.serverArguments(for: .init(scid: 1, localPort: 1))

        XCTAssertFalse(arguments.contains("stay_awake=true"))
    }

    func testSamsungAudioStackCrashDetection() {
        XCTAssertTrue(ScrcpyServerHost.isSamsungAudioStackCrash(
            code: 134,
            output: """
            [server] INFO: Device: [samsung] samsung SM-S906B (Android 13)
            stack corruption detected (-fstack-protector)
            Aborted
            """
        ))

        XCTAssertFalse(ScrcpyServerHost.isSamsungAudioStackCrash(
            code: 0,
            output: "stack corruption detected (-fstack-protector)"
        ))
        XCTAssertFalse(ScrcpyServerHost.isSamsungAudioStackCrash(
            code: 134,
            output: "Device disconnected"
        ))
    }

    func testRecoverableAudioFailureDoesNotTreatBlankADBExitAsAudioFailure() {
        XCTAssertFalse(ScrcpyServerHost.isRecoverableAudioStartupFailure(code: 255, output: ""))
        XCTAssertFalse(ScrcpyServerHost.isRecoverableAudioStartupFailure(code: 15, output: "[server] INFO: Device disconnected"))
    }

    func testRecoverableAudioFailureCatchesAudioErrors() {
        XCTAssertTrue(ScrcpyServerHost.isRecoverableAudioStartupFailure(
            code: 1,
            output: "[server] ERROR: Audio capture failed"
        ))
        XCTAssertTrue(ScrcpyServerHost.isRecoverableAudioStartupFailure(
            code: 134,
            output: "stack corruption detected (-fstack-protector)"
        ))
    }
}

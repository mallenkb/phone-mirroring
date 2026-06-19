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

    func testDataStallWatchdogDoesNotRunForVideoOnlyStreams() {
        XCTAssertFalse(
            ScrcpyVideoStream.shouldRunDataStallWatchdog(
                expectsAudio: false,
                audioMetaParsed: false,
                audioDisabled: false
            )
        )
    }

    func testDataStallWatchdogRunsOnlyAfterLiveAudioIsConfirmed() {
        XCTAssertFalse(
            ScrcpyVideoStream.shouldRunDataStallWatchdog(
                expectsAudio: true,
                audioMetaParsed: false,
                audioDisabled: false
            )
        )
        XCTAssertTrue(
            ScrcpyVideoStream.shouldRunDataStallWatchdog(
                expectsAudio: true,
                audioMetaParsed: true,
                audioDisabled: false
            )
        )
        XCTAssertFalse(
            ScrcpyVideoStream.shouldRunDataStallWatchdog(
                expectsAudio: true,
                audioMetaParsed: true,
                audioDisabled: true
            )
        )
    }

    // MARK: - Wire-format framing (batched-removeFirst parser)

    func testVideoParserEmitsHeaderThenMediaPacket() {
        let stream = ScrcpyVideoStream(port: 0, expectsAudio: false)
        var header: ScrcpyVideoStream.StreamHeader?
        var packets: [ScrcpyVideoStream.VideoPacket] = []
        stream.onHeader = { header = $0 }
        stream.onPacket = { packets.append($0) }

        var bytes = Data()
        bytes.append(Self.deviceNameField("TestPhone"))
        bytes.append(contentsOf: [0x68, 0x32, 0x36, 0x34]) // codec "h264"
        bytes.append(Self.sessionPacket(width: 1080, height: 2400))
        let payload = Data("ABCDE".utf8)
        bytes.append(Self.mediaPacket(ptsFlags: (UInt64(1) << 61) | 12345, payload: payload))

        stream.ingestVideoBytesForTesting(bytes)

        XCTAssertEqual(header?.deviceName, "TestPhone")
        XCTAssertEqual(header?.codecID, 0x6832_3634)
        XCTAssertEqual(header?.width, 1080)
        XCTAssertEqual(header?.height, 2400)
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.first?.payload, payload)
        XCTAssertEqual(packets.first?.isKeyFrame, true)
        XCTAssertEqual(packets.first?.isConfig, false)
        XCTAssertEqual(packets.first?.pts, 12345)
    }

    func testVideoParserHandlesPacketSplitAcrossChunks() {
        let stream = ScrcpyVideoStream(port: 0, expectsAudio: false)
        var header: ScrcpyVideoStream.StreamHeader?
        var packets: [ScrcpyVideoStream.VideoPacket] = []
        stream.onHeader = { header = $0 }
        stream.onPacket = { packets.append($0) }

        var bytes = Data()
        bytes.append(Self.deviceNameField("P"))
        bytes.append(contentsOf: [0x68, 0x32, 0x36, 0x34])
        bytes.append(Self.sessionPacket(width: 720, height: 1280))
        let payload = Data((0..<200).map { UInt8($0 & 0xFF) })
        bytes.append(Self.mediaPacket(ptsFlags: 99, payload: payload))

        // Split mid-media-packet: header + partial payload, then the remainder.
        let mid = bytes.count - 80
        stream.ingestVideoBytesForTesting(bytes.subdata(in: 0..<mid))
        XCTAssertEqual(header?.width, 720)
        XCTAssertEqual(packets.count, 0, "Incomplete media packet must not emit yet")

        stream.ingestVideoBytesForTesting(bytes.subdata(in: mid..<bytes.count))
        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.first?.payload, payload)
        XCTAssertEqual(packets.first?.isConfig, false)
        XCTAssertEqual(packets.first?.pts, 99)
    }

    func testVideoParserEmitsTwoBackToBackPackets() {
        let stream = ScrcpyVideoStream(port: 0, expectsAudio: false)
        var packets: [ScrcpyVideoStream.VideoPacket] = []
        stream.onPacket = { packets.append($0) }

        var bytes = Data()
        bytes.append(Self.deviceNameField("X"))
        bytes.append(contentsOf: [0x68, 0x32, 0x36, 0x34])
        bytes.append(Self.sessionPacket(width: 100, height: 200))
        bytes.append(Self.mediaPacket(ptsFlags: (UInt64(1) << 62), payload: Data([1, 2, 3]))) // config
        bytes.append(Self.mediaPacket(ptsFlags: 7, payload: Data([4, 5])))

        stream.ingestVideoBytesForTesting(bytes)

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets.first?.isConfig, true)
        XCTAssertNil(packets.first?.pts)
        XCTAssertEqual(packets.first?.payload, Data([1, 2, 3]))
        XCTAssertEqual(packets.last?.payload, Data([4, 5]))
        XCTAssertEqual(packets.last?.pts, 7)
    }

    // MARK: - Annex-B NAL extraction

    func testExtractAnnexBNALUnitsSplitsOnBothStartCodes() {
        let data = Data([0, 0, 0, 1, 7, 0x10, 0, 0, 1, 8, 0x20, 0, 0, 1, 5, 1, 2, 3])
        XCTAssertEqual(
            H264VideoToolboxDecoder.extractAnnexBNALUnits(data),
            [Data([7, 0x10]), Data([8, 0x20]), Data([5, 1, 2, 3])]
        )
    }

    func testExtractAnnexBNALUnitsIgnoresBytesBeforeFirstStartCode() {
        let data = Data([0xAA, 0xBB, 0, 0, 0, 1, 9, 0, 0, 1, 1, 2])
        XCTAssertEqual(
            H264VideoToolboxDecoder.extractAnnexBNALUnits(data),
            [Data([9]), Data([1, 2])]
        )
    }

    func testExtractAnnexBNALUnitsEmptyInput() {
        XCTAssertTrue(H264VideoToolboxDecoder.extractAnnexBNALUnits(Data()).isEmpty)
    }

    // MARK: - Synthetic wire-format builders

    private static func deviceNameField(_ name: String) -> Data {
        var field = Data(name.utf8).prefix(64)
        field.append(contentsOf: Array(repeating: 0, count: 64 - field.count))
        return Data(field)
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ])
    }

    private static func uint64BE(_ value: UInt64) -> Data {
        var data = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> shift) & 0xff))
        }
        return data
    }

    private static func sessionPacket(width: UInt32, height: UInt32) -> Data {
        var packet = Data([0x80, 0, 0, 0]) // byte 0 MSB set = session/resize packet
        packet.append(uint32BE(width))
        packet.append(uint32BE(height))
        return packet
    }

    private static func mediaPacket(ptsFlags: UInt64, payload: Data) -> Data {
        var packet = uint64BE(ptsFlags)
        packet.append(uint32BE(UInt32(payload.count)))
        packet.append(payload)
        return packet
    }
}

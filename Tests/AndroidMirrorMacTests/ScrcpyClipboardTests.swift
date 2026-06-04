import XCTest
@testable import AndroidMirrorMac

final class ScrcpyClipboardTests: XCTestCase {

    // MARK: - SET_CLIPBOARD encoding (host → device)

    func testSetClipboardMessageLayout() {
        let data = ScrcpyControlChannel.setClipboardMessage(text: "hi", paste: true, sequence: 0x0102_0304_0506_0708)
        let bytes = [UInt8](data)

        XCTAssertEqual(bytes[0], 9) // SET_CLIPBOARD
        XCTAssertEqual(Array(bytes[1...8]), [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]) // sequence BE
        XCTAssertEqual(bytes[9], 1) // paste flag
        XCTAssertEqual(Array(bytes[10...13]), [0, 0, 0, 2]) // length BE
        XCTAssertEqual(Array(bytes[14...]), Array("hi".utf8))
    }

    func testSetClipboardPasteFlagFalse() {
        let data = ScrcpyControlChannel.setClipboardMessage(text: "x", paste: false, sequence: 0)
        XCTAssertEqual([UInt8](data)[9], 0)
    }

    func testSetClipboardEmptyTextProducesNoMessage() {
        XCTAssertTrue(ScrcpyControlChannel.setClipboardMessage(text: "", paste: false, sequence: 0).isEmpty)
    }

    func testUtf8TruncationKeepsCodePointsIntact() {
        // "é" is 2 UTF-8 bytes; truncating to 1 must drop the whole character.
        let truncated = ScrcpyControlChannel.utf8Truncated("é", maxBytes: 1)
        XCTAssertEqual(truncated.count, 0)
        // A clean ASCII boundary is preserved exactly.
        XCTAssertEqual(ScrcpyControlChannel.utf8Truncated("abc", maxBytes: 2), Data("ab".utf8))
    }

    // MARK: - Device message parsing (device → host)

    func testParseClipboardDeviceMessage() {
        var data = Data([0]) // TYPE_CLIPBOARD
        data.append(contentsOf: [0, 0, 0, 3]) // length
        data.append(contentsOf: Array("foo".utf8))

        XCTAssertEqual(
            ScrcpyControlChannel.parseDeviceMessage(data),
            .message(.clipboard("foo"), consumed: 8)
        )
    }

    func testParseIncompleteClipboardReturnsIncomplete() {
        var data = Data([0])
        data.append(contentsOf: [0, 0, 0, 5]) // claims 5 bytes
        data.append(contentsOf: Array("ab".utf8)) // only 2 present
        XCTAssertEqual(ScrcpyControlChannel.parseDeviceMessage(data), .incomplete)
    }

    func testParseAckClipboardDeviceMessage() {
        var data = Data([1]) // TYPE_ACK_CLIPBOARD
        data.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 7]) // sequence BE
        XCTAssertEqual(
            ScrcpyControlChannel.parseDeviceMessage(data),
            .message(.ackClipboard(7), consumed: 9)
        )
    }

    func testParseUhidOutputIsConsumedButIgnored() {
        var data = Data([2]) // TYPE_UHID_OUTPUT
        data.append(contentsOf: [0, 9]) // id
        data.append(contentsOf: [0, 2]) // data length
        data.append(contentsOf: [0xAB, 0xCD])
        XCTAssertEqual(
            ScrcpyControlChannel.parseDeviceMessage(data),
            .message(.uhidOutput, consumed: 7)
        )
    }

    func testParseUnknownTypeRequestsReset() {
        XCTAssertEqual(ScrcpyControlChannel.parseDeviceMessage(Data([0x7F])), .reset)
    }

    func testParseEmptyBufferIsIncomplete() {
        XCTAssertEqual(ScrcpyControlChannel.parseDeviceMessage(Data()), .incomplete)
    }

    func testParseRejectsOversizedClipboardLength() {
        var data = Data([0])
        // Length far beyond the 256 KiB cap → desync, request reset.
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(ScrcpyControlChannel.parseDeviceMessage(data), .reset)
    }

    func testParseRejectsInvalidUTF8ClipboardPayload() {
        var data = Data([0])
        data.append(contentsOf: [0, 0, 0, 2])
        data.append(contentsOf: [0xC3, 0x28])

        XCTAssertEqual(ScrcpyControlChannel.parseDeviceMessage(data), .reset)
    }
}

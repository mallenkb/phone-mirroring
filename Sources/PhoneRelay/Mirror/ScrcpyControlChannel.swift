import Foundation
import Network
import AppKit

/// Reader/writer for scrcpy's control protocol. We implement the message types
/// the mirror UI needs: touch, scroll, key, BACK_OR_SCREEN_ON, SET_CLIPBOARD,
/// and SET_DISPLAY_POWER (host → device). The control socket is bidirectional, so we also read the
/// server's *device* messages — currently just clipboard sync (device → host).
/// All wire encoding is big-endian.
final class ScrcpyControlChannel {
    enum MessageType: UInt8 {
        case injectKeycode = 0
        case injectText = 1
        case injectTouch = 2
        case injectScroll = 3
        case backOrScreenOn = 4
        case getClipboard = 8
        case setClipboard = 9
        case setDisplayPower = 10
    }

    /// Messages the device pushes back over the control socket.
    enum DeviceMessage: Equatable {
        case clipboard(String)
        case ackClipboard(UInt64)
        /// UHID output — unused here, but consumed to stay framed.
        case uhidOutput
    }

    enum DeviceMessageType: UInt8 {
        case clipboard = 0
        case ackClipboard = 1
        case uhidOutput = 2
    }

    /// scrcpy caps clipboard payloads at 256 KiB (minus framing). We use this
    /// both to truncate outgoing text and to reject a desynced inbound length.
    static let maxClipboardBytes = (1 << 18) - 14

    enum KeyAction: UInt8 { case down = 0, up = 1 }
    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }
    enum DisplayPowerMode: UInt8 { case off = 0, normal = 2 }

    /// Subset of `AKEYCODE_*` from Android's input.h that we need.
    enum AndroidKey: Int32 {
        case home = 3
        case back = 4
        case a = 29
        case c = 31
        case v = 50
        case x = 52
        case z = 54
        case tab = 61
        case enter = 66
        case delete = 67
        case volumeUp = 24
        case volumeDown = 25
        case volumeMute = 164
        case dpadUp = 19
        case dpadDown = 20
        case dpadLeft = 21
        case dpadRight = 22
        case forwardDelete = 112
        case ctrlLeft = 113
        case pageUp = 92
        case pageDown = 93
        case moveHome = 122
        case moveEnd = 123
        case mediaPlayPause = 85
        case mediaNext = 87
        case mediaPrevious = 88
        case appSwitch = 187
        case menu = 82
    }

    static let pointerIDMouse: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
    static let buttonPrimary: UInt32 = 1
    static let metaCtrlOn: UInt32 = 0x0000_1000

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "scrcpy.control", qos: .userInteractive)
    private var deviceWidth: UInt16 = 0
    private var deviceHeight: UInt16 = 0
    private var lastButtons: UInt32 = 0
    private var pointerDown = false
    /// Accumulates inbound device-message bytes; only touched on `queue`.
    private var rxBuffer = Data()

    /// Invoked (on an internal queue) when the device clipboard changes.
    var onDeviceClipboard: ((String) -> Void)?

    init(connection: NWConnection, startConnection: Bool = true) {
        self.connection = connection
        if startConnection {
            connection.start(queue: queue)
        }
        receiveLoop()
    }

    func close() {
        connection.cancel()
    }

    func updateDeviceSize(width: UInt32, height: UInt32) {
        deviceWidth = UInt16(clamping: width)
        deviceHeight = UInt16(clamping: height)
    }

    // MARK: - High level

    func sendTouch(action: TouchAction, normalized: CGPoint, button: UInt32 = 0) {
        guard deviceWidth > 0, deviceHeight > 0 else { return }
        let x = Int32(min(1.0, max(0.0, normalized.x)) * Double(deviceWidth))
        let y = Int32(min(1.0, max(0.0, normalized.y)) * Double(deviceHeight))

        switch action {
        case .down:
            pointerDown = true
            lastButtons = button
        case .up:
            pointerDown = false
            lastButtons = 0
        case .move:
            break
        }
        let pressure: Float = action == .up ? 0 : 1
        send(touchAction: action, x: x, y: y, pressure: pressure,
             actionButton: action == .down ? button : 0,
             buttons: action == .down ? button : (action == .up ? 0 : lastButtons))
    }

    func sendScroll(normalized: CGPoint, deltaX: CGFloat, deltaY: CGFloat) {
        guard deviceWidth > 0, deviceHeight > 0 else { return }
        let x = Int32(min(1.0, max(0.0, normalized.x)) * Double(deviceWidth))
        let y = Int32(min(1.0, max(0.0, normalized.y)) * Double(deviceHeight))
        let hScrollClamped = Float(max(-1, min(1, deltaX / 64)))
        let vScrollClamped = Float(max(-1, min(1, deltaY / 64)))
        let hFixed = Int16(clamping: Int(hScrollClamped * 32767))
        let vFixed = Int16(clamping: Int(vScrollClamped * 32767))

        var buf = Data(capacity: 21)
        buf.append(MessageType.injectScroll.rawValue)
        Self.appendInt32BE(&buf, UInt32(bitPattern: x))
        Self.appendInt32BE(&buf, UInt32(bitPattern: y))
        Self.appendUInt16BE(&buf, deviceWidth)
        Self.appendUInt16BE(&buf, deviceHeight)
        Self.appendUInt16BE(&buf, UInt16(bitPattern: hFixed))
        Self.appendUInt16BE(&buf, UInt16(bitPattern: vFixed))
        Self.appendUInt32BE(&buf, lastButtons)
        write(buf)
    }

    func sendHorizontalTrackpadSwipe(normalized: CGPoint, deltaX: CGFloat) {
        guard deviceWidth > 0, deviceHeight > 0 else { return }
        let end = Self.horizontalTrackpadSwipeEndPoint(from: normalized, deltaX: deltaX)
        sendTouch(action: .down, normalized: normalized, button: Self.buttonPrimary)
        sendTouch(
            action: .move,
            normalized: CGPoint(x: (normalized.x + end.x) / 2, y: normalized.y),
            button: Self.buttonPrimary
        )
        sendTouch(action: .move, normalized: end, button: Self.buttonPrimary)
        sendTouch(action: .up, normalized: end)
    }

    func sendKeyEvent(_ key: AndroidKey, action: KeyAction = .down, metastate: UInt32 = 0) {
        sendKeycode(action: action, keycode: key.rawValue, metastate: metastate)
        if action == .down {
            sendKeycode(action: .up, keycode: key.rawValue, metastate: metastate)
        }
    }

    func sendControlKeyEvent(_ key: AndroidKey) {
        sendKeycode(action: .down, keycode: AndroidKey.ctrlLeft.rawValue, metastate: Self.metaCtrlOn)
        sendKeycode(action: .down, keycode: key.rawValue, metastate: Self.metaCtrlOn)
        sendKeycode(action: .up, keycode: key.rawValue, metastate: Self.metaCtrlOn)
        sendKeycode(action: .up, keycode: AndroidKey.ctrlLeft.rawValue, metastate: 0)
    }

    func sendDisplayPowerMode(_ mode: DisplayPowerMode) {
        write(Self.displayPowerMessage(mode))
    }

    func sendText(_ text: String) {
        let message = Self.textMessage(for: text)
        guard !message.isEmpty else { return }
        write(message)
    }

    /// Sets the device clipboard (host → device). With `paste: true` the server
    /// also injects a PASTE key into the focused field. `sequence` of 0 means
    /// no acknowledgement is requested (scrcpy's `SEQUENCE_INVALID`).
    func sendSetClipboard(_ text: String, paste: Bool = false, sequence: UInt64 = 0) {
        let message = Self.setClipboardMessage(text: text, paste: paste, sequence: sequence)
        guard !message.isEmpty else { return }
        write(message)
    }

    // MARK: - Inbound device messages

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.drainDeviceMessages()
            }
            if let error {
                Logger.log("ScrcpyControlChannel receive error: \(error)")
                return
            }
            if isComplete { return }
            self.receiveLoop()
        }
    }

    /// Pulls every complete device message out of `rxBuffer`. Runs on `queue`.
    private func drainDeviceMessages() {
        while true {
            switch Self.parseDeviceMessage(rxBuffer) {
            case .incomplete:
                return
            case .reset:
                Logger.log("ScrcpyControlChannel: desynced device stream; dropping buffer")
                rxBuffer.removeAll()
                return
            case let .message(message, consumed):
                rxBuffer.removeFirst(consumed)
                if case let .clipboard(text) = message {
                    onDeviceClipboard?(text)
                }
            }
        }
    }

    // MARK: - Encoding

    static func textMessage(for text: String) -> Data {
        let payload = Data(text.utf8)
        guard !payload.isEmpty else { return Data() }

        var buf = Data(capacity: 5 + payload.count)
        buf.append(MessageType.injectText.rawValue)
        Self.appendUInt32BE(&buf, UInt32(payload.count))
        buf.append(payload)
        return buf
    }

    /// Encodes a SET_CLIPBOARD control message:
    ///   [ type ][ sequence u64 ][ paste flag u8 ][ length u32 ][ utf8 text ]
    static func setClipboardMessage(text: String, paste: Bool, sequence: UInt64) -> Data {
        let payload = Self.utf8Truncated(text, maxBytes: maxClipboardBytes)
        guard !payload.isEmpty else { return Data() }

        var buf = Data(capacity: 14 + payload.count)
        buf.append(MessageType.setClipboard.rawValue)
        Self.appendUInt64BE(&buf, sequence)
        buf.append(paste ? 1 : 0)
        Self.appendUInt32BE(&buf, UInt32(payload.count))
        buf.append(payload)
        return buf
    }

    static func keycodeMessage(action: KeyAction, key: AndroidKey, metastate: UInt32 = 0) -> Data {
        var buf = Data(capacity: 14)
        buf.append(MessageType.injectKeycode.rawValue)
        buf.append(action.rawValue)
        Self.appendUInt32BE(&buf, UInt32(bitPattern: key.rawValue))
        Self.appendUInt32BE(&buf, 0) // repeat
        Self.appendUInt32BE(&buf, metastate)
        return buf
    }

    static func displayPowerMessage(_ mode: DisplayPowerMode) -> Data {
        var buf = Data(capacity: 2)
        buf.append(MessageType.setDisplayPower.rawValue)
        buf.append(mode.rawValue)
        return buf
    }

    static func horizontalTrackpadSwipeEndPoint(from point: CGPoint, deltaX: CGFloat) -> CGPoint {
        let distance = min(0.22, max(0.035, abs(deltaX) / 420))
        let direction: CGFloat = deltaX >= 0 ? -1 : 1
        return CGPoint(
            x: min(0.98, max(0.02, point.x + direction * distance)),
            y: min(0.98, max(0.02, point.y))
        )
    }

    /// Result of attempting to parse one device message from the front of a
    /// buffer. `consumed` is the byte count the message occupied.
    enum ParseResult: Equatable {
        case message(DeviceMessage, consumed: Int)
        /// Not enough bytes buffered yet for a complete message.
        case incomplete
        /// Unknown type or an implausible length — the stream is desynced and
        /// the caller should drop its buffer.
        case reset
    }

    /// Parses a single device message from the front of `buffer` without
    /// mutating it. Pure, so it can be unit-tested directly.
    static func parseDeviceMessage(_ buffer: Data) -> ParseResult {
        guard let typeByte = buffer.first else { return .incomplete }
        guard let type = DeviceMessageType(rawValue: typeByte) else { return .reset }

        switch type {
        case .clipboard:
            guard buffer.count >= 5 else { return .incomplete }
            let length = Int(readUInt32BE(in: buffer, at: 1))
            guard length <= maxClipboardBytes else { return .reset }
            guard buffer.count >= 5 + length else { return .incomplete }
            let start = buffer.index(buffer.startIndex, offsetBy: 5)
            let end = buffer.index(start, offsetBy: length)
            guard let text = String(data: buffer[start..<end], encoding: .utf8) else {
                return .reset
            }
            return .message(.clipboard(text), consumed: 5 + length)
        case .ackClipboard:
            guard buffer.count >= 9 else { return .incomplete }
            return .message(.ackClipboard(readUInt64BE(in: buffer, at: 1)), consumed: 9)
        case .uhidOutput:
            guard buffer.count >= 5 else { return .incomplete }
            let length = Int(readUInt16BE(in: buffer, at: 3))
            guard buffer.count >= 5 + length else { return .incomplete }
            return .message(.uhidOutput, consumed: 5 + length)
        }
    }

    /// Returns `text` as UTF-8, truncated to at most `maxBytes` on a code-point
    /// boundary so a multi-byte character is never split.
    static func utf8Truncated(_ text: String, maxBytes: Int) -> Data {
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return data }
        var end = maxBytes
        // Back up off any UTF-8 continuation bytes (0b10xxxxxx).
        while end > 0, (data[data.index(data.startIndex, offsetBy: end)] & 0xC0) == 0x80 {
            end -= 1
        }
        return data.prefix(end)
    }

    private func sendKeycode(action: KeyAction, keycode: Int32, metastate: UInt32) {
        guard let key = AndroidKey(rawValue: keycode) else { return }
        write(Self.keycodeMessage(action: action, key: key, metastate: metastate))
    }

    private func send(touchAction: TouchAction, x: Int32, y: Int32, pressure: Float,
                      actionButton: UInt32, buttons: UInt32) {
        var buf = Data(capacity: 32)
        buf.append(MessageType.injectTouch.rawValue)
        buf.append(touchAction.rawValue)
        Self.appendUInt64BE(&buf, Self.pointerIDMouse)
        Self.appendInt32BE(&buf, UInt32(bitPattern: x))
        Self.appendInt32BE(&buf, UInt32(bitPattern: y))
        Self.appendUInt16BE(&buf, deviceWidth)
        Self.appendUInt16BE(&buf, deviceHeight)
        let pressureFP = UInt16(clamping: Int(min(1, max(0, pressure)) * 65535))
        Self.appendUInt16BE(&buf, pressureFP)
        Self.appendUInt32BE(&buf, actionButton)
        Self.appendUInt32BE(&buf, buttons)
        write(buf)
    }

    private func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: - BE helpers

    private static func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendInt32BE(_ data: inout Data, _ value: UInt32) {
        Self.appendUInt32BE(&data, value)
    }

    private static func appendUInt64BE(_ data: inout Data, _ value: UInt64) {
        for i in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> i) & 0xff))
        }
    }

    private static func readUInt16BE(in data: Data, at offset: Int) -> UInt16 {
        let start = data.index(data.startIndex, offsetBy: offset)
        return data[start..<data.index(start, offsetBy: 2)]
            .reduce(0) { ($0 << 8) | UInt16($1) }
    }

    private static func readUInt32BE(in data: Data, at offset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        return data[start..<data.index(start, offsetBy: 4)]
            .reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64BE(in data: Data, at offset: Int) -> UInt64 {
        let start = data.index(data.startIndex, offsetBy: offset)
        return data[start..<data.index(start, offsetBy: 8)]
            .reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

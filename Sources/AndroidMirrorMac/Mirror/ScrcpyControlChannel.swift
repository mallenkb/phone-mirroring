import Foundation
import Network
import AppKit

/// Writer for scrcpy's control protocol. We only implement the message
/// types the mirror UI needs: touch, scroll, key, and the BACK_OR_SCREEN_ON
/// shortcut. All wire encoding is big-endian.
final class ScrcpyControlChannel {
    enum MessageType: UInt8 {
        case injectKeycode = 0
        case injectText = 1
        case injectTouch = 2
        case injectScroll = 3
        case backOrScreenOn = 4
    }

    enum KeyAction: UInt8 { case down = 0, up = 1 }
    enum TouchAction: UInt8 { case down = 0, up = 1, move = 2 }

    /// Subset of `AKEYCODE_*` from Android's input.h that we need.
    enum AndroidKey: Int32 {
        case home = 3
        case back = 4
        case tab = 61
        case enter = 66
        case delete = 67
        case dpadUp = 19
        case dpadDown = 20
        case dpadLeft = 21
        case dpadRight = 22
        case forwardDelete = 112
    }

    static let pointerIDMouse: UInt64 = 0xFFFF_FFFF_FFFF_FFFF
    static let buttonPrimary: UInt32 = 1
    static let buttonSecondary: UInt32 = 2

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "scrcpy.control", qos: .userInteractive)
    private var deviceWidth: UInt16 = 0
    private var deviceHeight: UInt16 = 0
    private var lastButtons: UInt32 = 0
    private var pointerDown = false

    init(connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
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
        let hScrollClamped = Float(max(-1, min(1, deltaX / 16)))
        let vScrollClamped = Float(max(-1, min(1, deltaY / 16)))
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

    func sendKeyEvent(_ key: AndroidKey, action: KeyAction = .down) {
        sendKeycode(action: action, keycode: key.rawValue, metastate: 0)
        if action == .down {
            sendKeycode(action: .up, keycode: key.rawValue, metastate: 0)
        }
    }

    func sendBackOrScreenOn() {
        var buf = Data(capacity: 2)
        buf.append(MessageType.backOrScreenOn.rawValue)
        buf.append(KeyAction.down.rawValue)
        write(buf)
    }

    func sendText(_ text: String) {
        let message = Self.textMessage(for: text)
        guard !message.isEmpty else { return }
        write(message)
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

    private func sendKeycode(action: KeyAction, keycode: Int32, metastate: UInt32) {
        var buf = Data(capacity: 14)
        buf.append(MessageType.injectKeycode.rawValue)
        buf.append(action.rawValue)
        Self.appendUInt32BE(&buf, UInt32(bitPattern: keycode))
        Self.appendUInt32BE(&buf, 1) // repeat
        Self.appendUInt32BE(&buf, metastate)
        write(buf)
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
}

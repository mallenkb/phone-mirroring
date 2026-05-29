import AppKit
import Foundation
import Network

/// Orchestrates a single in-process mirror session: spawns the scrcpy server,
/// reads the H.264 stream, decodes via VideoToolbox, pushes samples into the
/// `MirrorRenderView`, and forwards input back over the control socket.
@MainActor
final class MirrorSession {
    enum SessionError: Error, CustomStringConvertible {
        case alreadyRunning
        case start(String)
        var description: String {
            switch self {
            case .alreadyRunning: return "Mirror is already running."
            case .start(let detail): return "Could not start mirror: \(detail)"
            }
        }
    }

    /// Stable enough range to avoid collisions across mirror sessions and any
    /// other adb usage. The actual port is picked by NWListener (port 0 is
    /// fine, but we want a deterministic forward, so pick one in this band).
    private static var nextPortOffset: UInt16 = 0
    private static func allocatePort() -> UInt16 {
        let base: UInt16 = 37283
        let value = base + nextPortOffset
        nextPortOffset = (nextPortOffset + 1) % 64
        return value
    }

    private weak var model: AppModel?
    private let serial: String?
    private let scid: UInt32
    private let localPort: UInt16

    private var serverHost: ScrcpyServerHost?
    private var stream: ScrcpyVideoStream?
    private var decoder = H264VideoToolboxDecoder()
    private(set) var controlChannel: ScrcpyControlChannel?
    private var windowController: MirrorContentWindowController?
    private var streamWidth: UInt32 = 0
    private var streamHeight: UInt32 = 0
    private var isStopping = false

    var onSessionEnded: (() -> Void)?

    init(model: AppModel, serial: String?) {
        self.model = model
        self.serial = serial
        self.scid = UInt32.random(in: 1...UInt32(Int32.max))
        self.localPort = Self.allocatePort()
    }

    func start() throws {
        guard windowController == nil else { throw SessionError.alreadyRunning }

        let stream = ScrcpyVideoStream(port: localPort)
        let host = ScrcpyServerHost(options: ScrcpyServerHost.Options(
            scid: scid,
            localPort: localPort,
            audio: false,
            serial: serial
        ))

        stream.onHeader = { [weak self] header in
            Task { @MainActor in self?.handleHeader(header) }
        }
        stream.onPacket = { [weak self] packet in
            self?.decoder.feed(packet)
        }
        stream.onResize = { [weak self] width, height in
            Task { @MainActor in self?.handleResize(width: width, height: height) }
        }
        stream.onControl = { [weak self] connection in
            Task { @MainActor in self?.attachControl(connection: connection) }
        }
        stream.onError = { error in
            Logger.log("MirrorSession stream error: \(error)")
        }
        decoder.onSample = { [weak self] sample in
            Task { @MainActor in self?.windowController?.renderView.enqueue(sample) }
        }

        do {
            try stream.start()
            self.stream = stream
            try host.prepareTunnel()
            try host.start { [weak self] code, output in
                Task { @MainActor in
                    Logger.log("scrcpy-server exited code=\(code) output=\(output.prefix(400))")
                    self?.stop()
                }
            }
            self.serverHost = host
        } catch let error as ScrcpyServerHost.HostError {
            stream.stop()
            throw SessionError.start(error.description)
        } catch {
            stream.stop()
            throw SessionError.start(error.localizedDescription)
        }

        guard let model else { return }
        let controller = MirrorContentWindowController(model: model, session: self)
        controller.show()
        windowController = controller
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        controlChannel?.close()
        controlChannel = nil
        stream?.stop()
        stream = nil
        serverHost?.stop()
        serverHost = nil
        windowController?.close()
        windowController = nil
        onSessionEnded?()
        isStopping = false
    }

    // MARK: - Forwarding API (called from chrome / render view)

    func sendAndroidKey(_ key: ScrcpyControlChannel.AndroidKey) {
        controlChannel?.sendKeyEvent(key, action: .down)
    }

    func sendAndroidBack() {
        controlChannel?.sendBackOrScreenOn()
    }

    func takeScreenshot() {
        model?.takeScreenshot()
    }

    func toggleScreenRecording() {
        model?.toggleScreenRecording()
    }

    func scaleWindow(by scale: CGFloat) {
        windowController?.scaleWindow(by: scale)
    }

    func centerWindow() {
        windowController?.centerWindow()
    }

    func forwardPointerEvent(_ event: MirrorRenderView.PointerEvent,
                             in view: MirrorRenderView) {
        guard let controlChannel else { return }
        switch event.kind {
        case .down:
            controlChannel.sendTouch(action: .down, normalized: event.normalized,
                                     button: ScrcpyControlChannel.buttonPrimary)
        case .dragged:
            controlChannel.sendTouch(action: .move, normalized: event.normalized,
                                     button: ScrcpyControlChannel.buttonPrimary)
        case .up:
            controlChannel.sendTouch(action: .up, normalized: event.normalized)
        case .moved:
            break // not a touch event on Android; ignore
        case .scroll:
            controlChannel.sendScroll(normalized: event.normalized,
                                      deltaX: event.scrollDX,
                                      deltaY: event.scrollDY)
        }
    }

    func forwardKeyEvent(_ event: NSEvent) {
        guard let controlChannel else { return }
        if let mapped = Self.androidKey(for: event) {
            controlChannel.sendKeyEvent(mapped, action: event.type == .keyDown ? .down : .up)
            return
        }

        guard event.type == .keyDown,
              !event.isARepeat,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [.shift]),
              let text = event.characters,
              !text.isEmpty else {
            return
        }

        controlChannel.sendText(text)
    }

    // MARK: - Stream lifecycle

    private func handleHeader(_ header: ScrcpyVideoStream.StreamHeader) {
        streamWidth = header.width
        streamHeight = header.height
        Logger.log("MirrorSession header: device=\(header.deviceName) codec=\(String(format: "0x%08x", header.codecID)) size=\(header.width)x\(header.height)")
        windowController?.renderView.setLoadingDeviceName(header.deviceName)
        windowController?.setStreamSize(width: header.width, height: header.height)
        controlChannel?.updateDeviceSize(width: header.width, height: header.height)
    }

    private func handleResize(width: UInt32, height: UInt32) {
        streamWidth = width
        streamHeight = height
        Logger.log("MirrorSession resize: \(width)x\(height)")
        windowController?.setStreamSize(width: width, height: height)
        controlChannel?.updateDeviceSize(width: width, height: height)
    }

    private func attachControl(connection: NWConnection) {
        let channel = ScrcpyControlChannel(connection: connection)
        if streamWidth > 0, streamHeight > 0 {
            channel.updateDeviceSize(width: streamWidth, height: streamHeight)
        }
        controlChannel = channel
    }

    private static func androidKey(for event: NSEvent) -> ScrcpyControlChannel.AndroidKey? {
        // macOS virtual key codes (kVK_*). Only a minimal mapping for now.
        switch event.keyCode {
        case 0x35: return .back     // Escape
        case 0x30: return .tab
        case 0x24, 0x4C: return .enter
        case 0x33: return .delete
        case 0x75: return .forwardDelete
        case 0x7E: return .dpadUp
        case 0x7D: return .dpadDown
        case 0x7B: return .dpadLeft
        case 0x7C: return .dpadRight
        case 0x53: return .home     // Keypad 1 — placeholder; user-configurable later
        default: return nil
        }
    }
}

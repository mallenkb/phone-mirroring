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
    /// Random start so a second app instance doesn't race for the same ports.
    private static var nextPortOffset = UInt16.random(in: 0..<64)
    private static func allocatePort() -> UInt16 {
        let base: UInt16 = 37283
        let value = base + nextPortOffset
        nextPortOffset = (nextPortOffset + 1) % 64
        return value
    }

    private weak var model: AppModel?
    private let serial: String?
    private let launchFrame: NSRect?
    private let scid: UInt32
    private let localPort: UInt16

    private var serverHost: ScrcpyServerHost?
    private var startupTask: Task<Void, Error>?
    private var stream: ScrcpyVideoStream?
    private var audioPlayer: MirrorAudioPlayer?
    private var decoder = H264VideoToolboxDecoder()
    private(set) var controlChannel: ScrcpyControlChannel?
    private var clipboardBridge: ClipboardBridge?
    private var windowController: MirrorContentWindowController?
    private var screenOffTask: Task<Void, Never>?
    private var lastRequestedDisplayPowerMode: ScrcpyControlChannel.DisplayPowerMode = .normal
    private var streamWidth: UInt32 = 0
    private var streamHeight: UInt32 = 0
    private var isStopping = false
    private var didStop = false

    var onSessionEnded: ((NSRect?) -> Void)?

    init(model: AppModel, serial: String?, launchFrame: NSRect? = nil) {
        self.model = model
        self.serial = serial
        self.launchFrame = launchFrame
        self.scid = UInt32.random(in: 1...UInt32(Int32.max))
        self.localPort = Self.allocatePort()
    }

    func start() async throws {
        guard windowController == nil else { throw SessionError.alreadyRunning }

        let audioEnabled = (model?.shouldEnableMirrorAudioForNextSession() ?? false) && Self.supportsMirrorAudio(serial: serial)
        Logger.log("MirrorSession audio enabled=\(audioEnabled) serial=\(serial ?? "default")")
        let stream = ScrcpyVideoStream(port: localPort, expectsAudio: audioEnabled)
        let host = ScrcpyServerHost(options: ScrcpyServerHost.Options(
            scid: scid,
            localPort: localPort,
            videoBitRate: UInt32(max(1, model?.mirrorBitRateMbps ?? 8)) * 1_000_000,
            maxSize: UInt16(clamping: model?.mirrorMaxSize ?? 1600),
            maxFps: UInt16(clamping: model?.mirrorMaxFps ?? 60),
            audio: audioEnabled,
            serial: serial
        ))

        if audioEnabled, let audioPlayer = MirrorAudioPlayer() {
            self.audioPlayer = audioPlayer
            stream.onAudioPacket = { data in audioPlayer.enqueue(data) }
            audioPlayer.start()
        }

        stream.onHeader = { [weak self] header in
            Task { @MainActor in
                guard let self, !self.didStop, !self.isStopping else { return }
                self.handleHeader(header)
            }
        }
        stream.onPacket = { [weak self] packet in
            self?.decoder.feed(packet)
        }
        stream.onResize = { [weak self] width, height in
            Task { @MainActor in
                guard let self, !self.didStop, !self.isStopping else { return }
                self.handleResize(width: width, height: height)
            }
        }
        stream.onControl = { [weak self] connection in
            Task { @MainActor in
                guard let self, !self.didStop, !self.isStopping else {
                    connection.cancel()
                    return
                }
                self.attachControl(connection: connection)
            }
        }
        stream.onError = { [weak self] error in
            Logger.log("MirrorSession stream error: \(error)")
            Task { @MainActor in
                guard let self, !self.didStop, !self.isStopping else { return }
                if audioEnabled,
                   String(describing: error).localizedCaseInsensitiveContains("audio") {
                    self.model?.disableMirrorAudioAfterSessionFailure()
                }
                self.stop()
            }
        }
        decoder.onSample = { [weak self] sample in
            Task { @MainActor in
                guard let self, !self.didStop, !self.isStopping else { return }
                self.windowController?.renderView.enqueue(sample)
            }
        }

        do {
            try stream.start()
            self.stream = stream

            if let model {
                let controller = MirrorContentWindowController(model: model, session: self, launchFrame: launchFrame)
                controller.show()
                windowController = controller
                scheduleAutomaticScreenOffIfNeeded()
            }

            let onExit: (Int32, String) -> Void = { [weak self] code, output in
                Task { @MainActor in
                    Logger.log("scrcpy-server exited code=\(code) output=\(output.prefix(400))")
                    guard let self, !self.didStop, !self.isStopping else { return }
                    if audioEnabled,
                       ScrcpyServerHost.isRecoverableAudioStartupFailure(code: code, output: output) {
                        self.model?.disableMirrorAudioAfterSessionFailure()
                    }
                    self.stop()
                }
            }

            self.serverHost = host
            let startupTask = Self.startHostOffMain(host, onExit: onExit)
            self.startupTask = startupTask
            try await startupTask.value
            self.startupTask = nil
            guard !Task.isCancelled, !didStop, !isStopping else {
                Self.stopHostOffMain(host)
                return
            }
        } catch let error as ScrcpyServerHost.HostError {
            startupTask = nil
            serverHost = nil
            stream.stop()
            Self.stopHostOffMain(host)
            guard !Task.isCancelled, !didStop, !isStopping else { return }
            throw SessionError.start(error.description)
        } catch {
            startupTask = nil
            serverHost = nil
            stream.stop()
            Self.stopHostOffMain(host)
            guard !Task.isCancelled, !didStop, !isStopping else { return }
            throw SessionError.start(error.localizedDescription)
        }
    }

    func stop() {
        guard !isStopping, !didStop else { return }
        isStopping = true
        didStop = true

        startupTask?.cancel()
        startupTask = nil
        let serverHost = serverHost
        let sessionEnded = onSessionEnded
        let finalWindowFrame = windowController?.window?.frame
        self.serverHost = nil
        onSessionEnded = nil

        clipboardBridge?.stop()
        clipboardBridge = nil
        screenOffTask?.cancel()
        screenOffTask = nil
        controlChannel?.close()
        controlChannel = nil
        stream?.stop()
        stream = nil
        audioPlayer?.stop()
        audioPlayer = nil
        windowController?.close()
        windowController = nil
        sessionEnded?(finalWindowFrame)

        if let serverHost {
            Self.stopHostOffMain(serverHost)
        }
    }

    private nonisolated static func startHostOffMain(
        _ host: ScrcpyServerHost,
        onExit: @escaping (Int32, String) -> Void
    ) -> Task<Void, Error> {
        runStartupOffMain {
            try host.prepareTunnel()
            try Task.checkCancellation()
            try host.start(onExit: onExit)
        }
    }

    nonisolated static func runStartupOffMain(_ operation: @escaping () throws -> Void) -> Task<Void, Error> {
        Task.detached(priority: .userInitiated) {
            try operation()
        }
    }

    private nonisolated static func stopHostOffMain(_ host: ScrcpyServerHost) {
        Task.detached(priority: .utility) {
            host.stop()
        }
    }

    // MARK: - Forwarding API (called from chrome / render view)

    func scaleWindow(by scale: CGFloat) {
        windowController?.scaleWindow(by: scale)
    }

    func centerWindow() {
        windowController?.centerWindow()
    }

    func turnDeviceScreenOff() {
        setDeviceScreenPower(.off)
    }

    func toggleDeviceScreenPower() {
        setDeviceScreenPower(lastRequestedDisplayPowerMode == .off ? .normal : .off)
    }

    private func setDeviceScreenPower(_ mode: ScrcpyControlChannel.DisplayPowerMode) {
        controlChannel?.sendDisplayPowerMode(mode)
        lastRequestedDisplayPowerMode = mode
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

        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            toggleDeviceScreenPower()
            return
        }

        // ⌘V: push the current Mac clipboard and ask the phone to paste it into
        // the focused field. Handled before key mapping so it can't be typed.
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            guard model?.clipboardSyncEnabled ?? true else { return }
            clipboardBridge?.pasteToDevice()
            return
        }

        if let shortcutKey = Self.androidCommandShortcutKey(for: event) {
            controlChannel.sendKeyEvent(shortcutKey, metastate: ScrcpyControlChannel.metaCtrlOn)
            return
        }

        if let mapped = Self.androidKey(for: event) {
            guard let action = Self.androidKeyAction(for: event) else { return }
            controlChannel.sendKeyEvent(mapped, action: action)
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
        guard Self.isValidStreamSize(width: header.width, height: header.height) else {
            Logger.log("MirrorSession rejected invalid header size: \(header.width)x\(header.height)")
            stop()
            return
        }
        streamWidth = header.width
        streamHeight = header.height
        Logger.log("MirrorSession header: device=\(header.deviceName) codec=\(String(format: "0x%08x", header.codecID)) size=\(header.width)x\(header.height)")
        windowController?.renderView.setLoadingDeviceName(header.deviceName)
        windowController?.setStreamSize(width: header.width, height: header.height)
        controlChannel?.updateDeviceSize(width: header.width, height: header.height)
    }

    private func handleResize(width: UInt32, height: UInt32) {
        guard Self.isValidStreamSize(width: width, height: height) else {
            Logger.log("MirrorSession rejected invalid resize: \(width)x\(height)")
            stop()
            return
        }
        streamWidth = width
        streamHeight = height
        Logger.log("MirrorSession resize: \(width)x\(height)")
        windowController?.setStreamSize(width: width, height: height)
        controlChannel?.updateDeviceSize(width: width, height: height)
    }

    private func attachControl(connection: NWConnection) {
        guard !didStop, !isStopping else {
            connection.cancel()
            return
        }
        let channel = ScrcpyControlChannel(connection: connection, startConnection: false)
        if streamWidth > 0, streamHeight > 0 {
            channel.updateDeviceSize(width: streamWidth, height: streamHeight)
        }
        channel.onDeviceClipboard = { [weak self] text in
            Task { @MainActor in self?.clipboardBridge?.deviceClipboardChanged(text) }
        }
        controlChannel = channel

        setClipboardSyncEnabled(model?.clipboardSyncEnabled ?? true)
    }

    func setClipboardSyncEnabled(_ enabled: Bool) {
        guard let controlChannel else {
            clipboardBridge?.stop()
            clipboardBridge = nil
            return
        }

        if enabled {
            guard clipboardBridge == nil else { return }
            let bridge = ClipboardBridge(channel: controlChannel)
            bridge.start()
            clipboardBridge = bridge
        } else {
            clipboardBridge?.stop()
            clipboardBridge = nil
        }
    }

    private func scheduleAutomaticScreenOffIfNeeded() {
        guard model?.mirrorScreenOffAfterThirtySecondsEnabled ?? true else { return }
        screenOffTask?.cancel()
        screenOffTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !self.didStop, !self.isStopping else { return }
                self.turnDeviceScreenOff()
            }
        }
    }

    private static func isValidStreamSize(width: UInt32, height: UInt32) -> Bool {
        width > 0
            && height > 0
            && width <= ScrcpyVideoStream.maxStreamDimension
            && height <= ScrcpyVideoStream.maxStreamDimension
            && UInt64(width) * UInt64(height) <= ScrcpyVideoStream.maxStreamPixels
    }

    nonisolated static func supportsMirrorAudio(serial: String?) -> Bool {
        true
    }

    static func androidKey(for event: NSEvent) -> ScrcpyControlChannel.AndroidKey? {
        if event.type == .systemDefined, event.subtype.rawValue == 8 {
            switch (event.data1 >> 16) & 0xFFFF {
            case 0: return .volumeUp
            case 1: return .volumeDown
            case 7: return .volumeMute
            default: return nil
            }
        }

        // macOS virtual key codes (kVK_*). Only a minimal mapping for now.
        switch event.keyCode {
        case 0x35: return .back     // Escape
        case 0x30: return .tab
        case 0x24, 0x4C: return .enter
        case 0x33: return .delete
        case 0x75: return .forwardDelete
        case 0x6F: return .volumeUp      // F12 / volume up
        case 0x67: return .volumeDown    // F11 / volume down
        case 0x6D: return .volumeMute    // F10 / mute
        case 0x7E: return .dpadUp
        case 0x7D: return .dpadDown
        case 0x7B: return .dpadLeft
        case 0x7C: return .dpadRight
        case 0x53: return .home     // Keypad 1 — placeholder; user-configurable later
        default: return nil
        }
    }

    static func isMirrorCommandShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        return key == "l"
    }

    static func androidCommandShortcutKey(for event: NSEvent) -> ScrcpyControlChannel.AndroidKey? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return nil
        }

        switch key {
        case "a": return .a
        case "x": return .x
        default: return nil
        }
    }

    static func isSelectAllShortcut(_ event: NSEvent) -> Bool {
        androidCommandShortcutKey(for: event) == .a
    }

    static func androidKeyAction(for event: NSEvent) -> ScrcpyControlChannel.KeyAction? {
        if event.type == .systemDefined, event.subtype.rawValue == 8 {
            switch (event.data1 >> 8) & 0xFF {
            case 0xA: return .down
            case 0xB: return .up
            default: return nil
            }
        }

        switch event.type {
        case .keyDown: return .down
        case .keyUp: return .up
        default: return nil
        }
    }
}

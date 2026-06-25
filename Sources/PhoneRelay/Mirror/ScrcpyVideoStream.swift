import Foundation
import Network

/// Local TCP listener that accepts the scrcpy server's reverse-tunneled
/// sockets and parses the wire protocol into video packets and the control
/// connection.
///
/// Wire format (reverse tunnel mode, video=true audio=false control=true):
///   socket 1 (video):
///     [ 64 bytes device name UTF-8 NUL-padded ]
///     [ 4  bytes codec id big-endian ("h264", "h265", ...) ]
///     [ 4  bytes initial width  big-endian ]
///     [ 4  bytes initial height big-endian ]
///     loop: [ 12 bytes header ] [ payload bytes if media packet ]
///       header byte 0 MSB=1 → session/resize packet:
///         bytes 4..7 new width, bytes 8..11 new height, no payload.
///       header byte 0 MSB=0 → media packet:
///         bytes 0..7 pts_flags (bit 62 = config, bit 61 = keyframe,
///         lower 62 bits = pts µs), bytes 8..11 packet size, then payload.
///   socket 2 (control):
///     bidirectional control message stream (handled by ScrcpyControlChannel).
final class ScrcpyVideoStream {
    enum ConnectionRole: Equatable {
        case video
        case audio
        case control
        case reject
    }

    struct StreamHeader {
        var deviceName: String
        var codecID: UInt32   // 0x68323634 ("h264"), 0x68323635 ("h265"), 0x00617631 ("av1")
        var width: UInt32
        var height: UInt32
    }

    struct VideoPacket {
        var pts: UInt64?     // microseconds; nil for config packets
        var isConfig: Bool
        var isKeyFrame: Bool
        var payload: Data    // raw H.264 / H.265 Annex-B bytes
    }

    typealias HeaderHandler = (StreamHeader) -> Void
    typealias PacketHandler = (VideoPacket) -> Void
    typealias ResizeHandler = (UInt32, UInt32) -> Void
    typealias ControlHandler = (NWConnection) -> Void
    typealias AudioHandler = (Data) -> Void
    typealias ErrorHandler = (Error) -> Void

    /// scrcpy Opus audio codec id. 0 means the device disabled audio.
    static let opusAudioCodecID: UInt32 = 0x6f70_7573
    static let maxVideoPacketBytes = 32 * 1024 * 1024
    static let maxAudioPacketBytes = 4 * 1024 * 1024
    static let maxStreamDimension: UInt32 = 16_384
    static let maxStreamPixels: UInt64 = 67_108_864

    private let port: UInt16
    private let expectsAudio: Bool
    private var listener: NWListener?
    private var videoConnection: NWConnection?
    private var audioConnection: NWConnection?
    private var controlConnection: NWConnection?
    private var streamMetaParsed = false
    private var initialHeaderSent = false
    private var pendingDeviceName = ""
    private var pendingCodecID: UInt32 = 0
    private var videoBuffer = Data()
    private var audioBuffer = Data()
    private var audioMetaParsed = false
    private var audioDisabled = false
    private var isStopped = false
    private var stopQueued = false
    private let queue = DispatchQueue(label: "scrcpy.video.stream", qos: .userInteractive)
    private static let queueKey = DispatchSpecificKey<UInt8>()

    /// Stall watchdog: only valid once live audio is confirmed. Video can go
    /// quiet on a static screen, but Opus packets stream continuously when
    /// audio capture is active, so an audio-data stall is a real disconnect.
    private static let stallTimeout: TimeInterval = 5
    private var lastDataAt = Date()
    private var stallTimer: DispatchSourceTimer?

    var onHeader: HeaderHandler?
    var onPacket: PacketHandler?
    var onResize: ResizeHandler?
    var onControl: ControlHandler?
    var onAudioPacket: AudioHandler?
    var onError: ErrorHandler?

    init(port: UInt16, expectsAudio: Bool = false) {
        self.port = port
        self.expectsAudio = expectsAudio
        queue.setSpecific(key: Self.queueKey, value: 1)
    }

    func start() throws {
        isStopped = false
        stopQueued = false
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            // Detect a half-open socket when the phone's Wi-Fi drops: TCP stays
            // "open" with no FIN/RST, so without this the mirror just freezes on
            // the last frame for minutes. Keepalive probes a silent peer and
            // fails the connection (~5s) — and, unlike a frame-arrival check, it
            // never false-fires on a static screen because a live network still
            // ACKs the probes.
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 2
            tcp.keepaliveInterval = 1
            tcp.keepaliveCount = 3
        }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.onError?(error)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            guard !stopQueued else { return }
            stopQueued = true
            queue.async { [weak self] in
                self?.stopOnQueue()
            }
            return
        }
        queue.sync {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        guard !isStopped || stopQueued else { return }
        isStopped = true
        stopQueued = false
        stallTimer?.cancel()
        stallTimer = nil
        onHeader = nil
        onPacket = nil
        onResize = nil
        onControl = nil
        onAudioPacket = nil
        onError = nil
        videoBuffer.removeAll()
        audioBuffer.removeAll()
        listener?.cancel()
        listener = nil
        videoConnection?.cancel()
        videoConnection = nil
        audioConnection?.cancel()
        audioConnection = nil
        controlConnection?.cancel()
        controlConnection = nil
    }

    private func accept(connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.isStopped else { return }
            switch state {
            case .ready:
                Logger.log("ScrcpyVideoStream connection ready")
            case .failed(let error), .waiting(let error):
                self.onError?(error)
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
        assignAndReceive(connection)
    }

    private func assignAndReceive(_ connection: NWConnection) {
        switch Self.roleForNextConnection(
            hasVideo: videoConnection != nil,
            hasAudio: audioConnection != nil,
            hasControl: controlConnection != nil,
            expectsAudio: expectsAudio
        ) {
        case .video:
            Logger.log("ScrcpyVideoStream assigned video connection")
            videoConnection = connection
            readMore(on: connection, handler: { [weak self] data in self?.feedVideo(data) })
        case .audio:
            Logger.log("ScrcpyVideoStream assigned audio connection")
            audioConnection = connection
            readMore(on: connection, handler: { [weak self] data in self?.feedAudio(data) })
        case .control:
            Logger.log("ScrcpyVideoStream assigned control connection")
            controlConnection = connection
            onControl?(connection)
        case .reject:
            connection.cancel()
        }
    }

    /// The scrcpy server dials sockets in a fixed order: video, then audio
    /// (only when audio is enabled), then control. When audio is enabled the
    /// server always opens the audio socket — even if capture fails it sends a
    /// disable code on it — so assignment by arrival order is deterministic.
    static func roleForNextConnection(
        hasVideo: Bool,
        hasAudio: Bool,
        hasControl: Bool,
        expectsAudio: Bool
    ) -> ConnectionRole {
        guard hasVideo else { return .video }
        if expectsAudio, !hasAudio {
            return .audio
        }
        if !hasControl {
            return .control
        }
        return .reject
    }

    static func isSupportedAudioCodecID(_ codecID: UInt32) -> Bool {
        codecID == opusAudioCodecID
    }

    static func shouldRunDataStallWatchdog(
        expectsAudio: Bool,
        audioMetaParsed: Bool,
        audioDisabled: Bool
    ) -> Bool {
        expectsAudio && audioMetaParsed && !audioDisabled
    }

    /// Starts the data-stall watchdog once live audio is confirmed. Runs on the
    /// stream queue (same queue as the receive callbacks, so `lastDataAt` needs
    /// no extra synchronization).
    private func startStallWatchdog() {
        guard stallTimer == nil else { return }
        guard Self.shouldRunDataStallWatchdog(
            expectsAudio: expectsAudio,
            audioMetaParsed: audioMetaParsed,
            audioDisabled: audioDisabled
        ) else {
            return
        }
        lastDataAt = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopped else { return }
            guard Date().timeIntervalSince(self.lastDataAt) > Self.stallTimeout else { return }
            Logger.log("ScrcpyVideoStream stalled — no data for \(Int(Self.stallTimeout))s; ending session")
            self.failStream("connection lost (no data for \(Int(Self.stallTimeout))s)")
        }
        timer.resume()
        stallTimer = timer
    }

    private func stopStallWatchdog() {
        stallTimer?.cancel()
        stallTimer = nil
    }

    private func readMore(on connection: NWConnection, handler: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isStopped else { return }
            if let error {
                self.onError?(error)
                return
            }
            if let data, !data.isEmpty {
                self.lastDataAt = Date()
                handler(data)
            }
            if isComplete {
                self.failStream(Self.streamEndedMessage)
                return
            }
            self.readMore(on: connection, handler: handler)
        }
    }

    private func feedVideo(_ chunk: Data) {
        videoBuffer.append(chunk)
        parseAvailableVideo()
    }

    /// Test seam: drives the video parser directly with a chunk of wire bytes so
    /// the framing logic can be unit-tested without a live socket.
    func ingestVideoBytesForTesting(_ chunk: Data) {
        feedVideo(chunk)
    }

    private func parseAvailableVideo() {
        // Walk the buffer with a running `consumed` offset and drop the parsed
        // prefix in a single `removeFirst` at the end, instead of an O(remaining)
        // memmove per packet.
        var consumed = 0
        if !streamMetaParsed {
            guard videoBuffer.count >= 64 + 4 else { return }
            let nameData = videoBuffer.prefix(64)
            let nul = nameData.firstIndex(of: 0) ?? nameData.endIndex
            pendingDeviceName = String(data: nameData.prefix(upTo: nul), encoding: .utf8) ?? ""
            pendingCodecID = readUInt32BE(at: 64)
            consumed = 68
            streamMetaParsed = true
        }

        while true {
            guard videoBuffer.count - consumed >= 12 else { break }
            let firstByte = videoBuffer[videoBuffer.index(videoBuffer.startIndex, offsetBy: consumed)]
            if firstByte & 0x80 != 0 {
                // Session/resize packet, header-only.
                let width = readUInt32BE(at: consumed + 4)
                let height = readUInt32BE(at: consumed + 8)
                guard Self.isValidStreamSize(width: width, height: height) else {
                    failStream("invalid stream size \(width)x\(height)")
                    return
                }
                consumed += 12
                if initialHeaderSent {
                    onResize?(width, height)
                } else {
                    initialHeaderSent = true
                    onHeader?(StreamHeader(
                        deviceName: pendingDeviceName,
                        codecID: pendingCodecID,
                        width: width,
                        height: height
                    ))
                }
                continue
            }

            let ptsFlags = readUInt64BE(at: consumed)
            let size = Int(readUInt32BE(at: consumed + 8))
            guard size > 0 else {
                failStream("invalid video packet length 0")
                return
            }
            guard size <= Self.maxVideoPacketBytes else {
                failStream("video packet length \(size) exceeds \(Self.maxVideoPacketBytes)")
                return
            }
            guard videoBuffer.count - consumed >= 12 + size else { break }

            let isConfig = (ptsFlags & (UInt64(1) << 62)) != 0
            let isKey = (ptsFlags & (UInt64(1) << 61)) != 0
            let pts = isConfig ? nil : (ptsFlags & ((UInt64(1) << 61) - 1))

            let payloadStart = videoBuffer.index(videoBuffer.startIndex, offsetBy: consumed + 12)
            let payloadEnd = videoBuffer.index(payloadStart, offsetBy: size)
            let payload = videoBuffer[payloadStart..<payloadEnd]
            let packet = VideoPacket(pts: pts, isConfig: isConfig, isKeyFrame: isKey, payload: Data(payload))
            consumed += 12 + size
            onPacket?(packet)
        }

        if consumed > 0 {
            if consumed <= videoBuffer.count {
                videoBuffer.removeFirst(consumed)
            } else {
                videoBuffer.removeAll()
            }
        }
    }

    private func feedAudio(_ chunk: Data) {
        guard !audioDisabled else { return }
        audioBuffer.append(chunk)
        parseAvailableAudio()
    }

    private func parseAvailableAudio() {
        // First 4 bytes: codec id. 0 = device couldn't capture (continue video
        // only); 1 = fatal config error; otherwise the real codec id.
        if !audioMetaParsed {
            guard audioBuffer.count >= 4 else { return }
            let codecID = readUInt32BE(in: audioBuffer, at: 0)
            audioBuffer.removeFirst(4)
            audioMetaParsed = true
            switch codecID {
            case 0:
                Logger.log("ScrcpyVideoStream: device disabled audio; continuing video only")
                audioDisabled = true
                audioBuffer.removeAll()
                stopStallWatchdog()
                return
            case 1:
                Logger.log("ScrcpyVideoStream: audio configuration error reported by device")
                failStream("audio configuration error reported by device")
                return
            case Self.opusAudioCodecID:
                Logger.log("ScrcpyVideoStream: audio codec=opus")
                startStallWatchdog()
            default:
                Logger.log("ScrcpyVideoStream: unsupported audio codec=\(String(format: "0x%08x", codecID)); ignoring audio")
                audioDisabled = true
                audioBuffer.removeAll()
                stopStallWatchdog()
                return
            }
        }

        // Frame-meta packets: [8 bytes pts/flags][4 bytes size][payload].
        while true {
            guard audioBuffer.count >= 12 else { return }
            let ptsFlags = readUInt64BE(in: audioBuffer, at: 0)
            let size = Int(readUInt32BE(in: audioBuffer, at: 8))
            guard size > 0 else {
                audioBuffer.removeFirst(12)
                continue
            }
            guard size <= Self.maxAudioPacketBytes else {
                failStream("audio packet length \(size) exceeds \(Self.maxAudioPacketBytes)")
                return
            }
            guard audioBuffer.count >= 12 + size else { return }
            let isConfig = (ptsFlags & (UInt64(1) << 62)) != 0
            let start = audioBuffer.index(audioBuffer.startIndex, offsetBy: 12)
            let payload = audioBuffer[start..<audioBuffer.index(start, offsetBy: size)]
            audioBuffer.removeFirst(12 + size)
            // Raw PCM has no config packets, but guard anyway.
            if !isConfig {
                onAudioPacket?(Data(payload))
            }
        }
    }

    private func readUInt32BE(at offset: Int) -> UInt32 {
        readUInt32BE(in: videoBuffer, at: offset)
    }

    private func readUInt64BE(at offset: Int) -> UInt64 {
        readUInt64BE(in: videoBuffer, at: offset)
    }

    private func readUInt32BE(in data: Data, at offset: Int) -> UInt32 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let bytes = data[start..<data.index(start, offsetBy: 4)]
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func readUInt64BE(in data: Data, at offset: Int) -> UInt64 {
        let start = data.index(data.startIndex, offsetBy: offset)
        let bytes = data[start..<data.index(start, offsetBy: 8)]
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    static func isValidStreamSize(width: UInt32, height: UInt32) -> Bool {
        guard width > 0, height > 0,
              width <= maxStreamDimension,
              height <= maxStreamDimension else {
            return false
        }
        return UInt64(width) * UInt64(height) <= maxStreamPixels
    }

    static let streamEndedMessage = "scrcpy stream ended"

    private func failStream(_ message: String) {
        videoBuffer.removeAll()
        audioBuffer.removeAll()
        isStopped = true
        stallTimer?.cancel()
        stallTimer = nil
        let error = NSError(
            domain: "ScrcpyVideoStream",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
        onError?(error)
        videoConnection?.cancel()
        audioConnection?.cancel()
        controlConnection?.cancel()
        listener?.cancel()
    }
}

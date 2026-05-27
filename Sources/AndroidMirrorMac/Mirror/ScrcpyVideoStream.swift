import Foundation
import Network

/// Local TCP listener that accepts the scrcpy server's reverse-tunneled
/// sockets and parses the wire protocol into video packets, optional raw
/// audio packets, and the control connection.
///
/// Wire format (reverse tunnel mode, video=true audio=true control=true):
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
///   socket 2 (audio):
///     [ 4 bytes codec id big-endian ("raw " for PCM 16-bit LE) ]
///     loop: [ 12 bytes packet header ] [ payload bytes ]
///   socket 3 (control):
///     bidirectional control message stream (handled by ScrcpyControlChannel).
final class ScrcpyVideoStream {
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

    struct AudioPacket {
        var pts: UInt64?
        var isConfig: Bool
        var codecID: UInt32
        var payload: Data
    }

    typealias HeaderHandler = (StreamHeader) -> Void
    typealias PacketHandler = (VideoPacket) -> Void
    typealias AudioPacketHandler = (AudioPacket) -> Void
    typealias ResizeHandler = (UInt32, UInt32) -> Void
    typealias ControlHandler = (NWConnection) -> Void
    typealias ErrorHandler = (Error) -> Void

    private let port: UInt16
    private var listener: NWListener?
    private var videoConnection: NWConnection?
    private var audioConnection: NWConnection?
    private var pendingAudioConnection: NWConnection?
    private var pendingAudioProbe: DispatchWorkItem?
    private var controlConnection: NWConnection?
    private var streamMetaParsed = false
    private var initialHeaderSent = false
    private var pendingDeviceName = ""
    private var pendingCodecID: UInt32 = 0
    private var videoBuffer = Data()
    private var audioBuffer = Data()
    private var audioCodecID: UInt32 = 0
    private var audioMetaParsed = false
    private let queue = DispatchQueue(label: "scrcpy.video.stream", qos: .userInteractive)

    var onHeader: HeaderHandler?
    var onPacket: PacketHandler?
    var onAudioPacket: AudioPacketHandler?
    var onResize: ResizeHandler?
    var onControl: ControlHandler?
    var onError: ErrorHandler?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
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
        listener?.cancel()
        listener = nil
        videoConnection?.cancel()
        videoConnection = nil
        pendingAudioProbe?.cancel()
        pendingAudioProbe = nil
        pendingAudioConnection?.cancel()
        pendingAudioConnection = nil
        audioConnection?.cancel()
        audioConnection = nil
        controlConnection?.cancel()
        controlConnection = nil
    }

    private func accept(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Logger.log("ScrcpyVideoStream connection ready")
            case .failed(let error), .waiting(let error):
                self?.onError?(error)
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
        if videoConnection == nil {
            Logger.log("ScrcpyVideoStream assigned video connection")
            videoConnection = connection
            readMore(on: connection, handler: { [weak self] data in self?.feedVideo(data) })
        } else if audioConnection == nil, controlConnection == nil, pendingAudioConnection == nil {
            probeAudioOrControl(connection)
        } else if controlConnection == nil {
            promotePendingAudioIfNeeded()
            Logger.log("ScrcpyVideoStream assigned control connection")
            controlConnection = connection
            onControl?(connection)
        } else {
            connection.cancel()
        }
    }

    private func probeAudioOrControl(_ connection: NWConnection) {
        Logger.log("ScrcpyVideoStream probing second connection for audio")
        pendingAudioConnection = connection

        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection, self.pendingAudioConnection === connection else { return }
            Logger.log("ScrcpyVideoStream second connection had no audio header; using it for control")
            self.pendingAudioConnection = nil
            self.controlConnection = connection
            self.onControl?(connection)
        }
        pendingAudioProbe = timeout
        queue.asyncAfter(deadline: .now() + 0.25, execute: timeout)

        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection, self.pendingAudioConnection === connection else { return }
            if let error {
                self.onError?(error)
                return
            }
            guard let data, data.count == 4 else {
                if isComplete {
                    self.pendingAudioProbe?.cancel()
                    self.pendingAudioProbe = nil
                    self.pendingAudioConnection = nil
                }
                return
            }

            self.pendingAudioProbe?.cancel()
            self.pendingAudioProbe = nil
            self.pendingAudioConnection = nil
            self.audioConnection = connection
            Logger.log("ScrcpyVideoStream assigned audio connection")
            self.feedAudio(data)
            self.readMore(on: connection, handler: { [weak self] data in self?.feedAudio(data) })
        }
    }

    private func promotePendingAudioIfNeeded() {
        guard let pendingAudioConnection else { return }
        pendingAudioProbe?.cancel()
        pendingAudioProbe = nil
        self.pendingAudioConnection = nil
        audioConnection = pendingAudioConnection
        Logger.log("ScrcpyVideoStream assigned pending connection as audio")
        readMore(on: pendingAudioConnection, handler: { [weak self] data in self?.feedAudio(data) })
    }

    private func feedAudio(_ chunk: Data) {
        audioBuffer.append(chunk)
        parseAvailableAudio()
    }

    private func parseAvailableAudio() {
        if !audioMetaParsed {
            guard audioBuffer.count >= 4 else { return }
            audioCodecID = readUInt32BE(in: audioBuffer, at: 0)
            audioBuffer.removeFirst(4)
            audioMetaParsed = true
            Logger.log("ScrcpyVideoStream audio codec=\(String(format: "0x%08x", audioCodecID))")
        }

        while true {
            guard audioBuffer.count >= 12 else { return }
            let ptsFlags = readUInt64BE(in: audioBuffer, at: 0)
            let size = Int(readUInt32BE(in: audioBuffer, at: 8))
            guard size > 0 else {
                onError?(NSError(domain: "ScrcpyVideoStream", code: -2,
                                 userInfo: [NSLocalizedDescriptionKey: "invalid audio packet length 0"]))
                audioBuffer.removeAll()
                return
            }
            guard audioBuffer.count >= 12 + size else { return }

            let isConfig = (ptsFlags & (UInt64(1) << 62)) != 0
            let pts = isConfig ? nil : (ptsFlags & ((UInt64(1) << 61) - 1))
            let payloadStart = audioBuffer.index(audioBuffer.startIndex, offsetBy: 12)
            let payloadEnd = audioBuffer.index(payloadStart, offsetBy: size)
            let payload = audioBuffer[payloadStart..<payloadEnd]
            audioBuffer.removeFirst(12 + size)
            onAudioPacket?(AudioPacket(
                pts: pts,
                isConfig: isConfig,
                codecID: audioCodecID,
                payload: Data(payload)
            ))
        }
    }

    private func readMore(on connection: NWConnection, handler: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let error {
                self?.onError?(error)
                return
            }
            if let data, !data.isEmpty {
                handler(data)
            }
            if isComplete {
                return
            }
            self?.readMore(on: connection, handler: handler)
        }
    }

    private func feedVideo(_ chunk: Data) {
        videoBuffer.append(chunk)
        parseAvailableVideo()
    }

    private func parseAvailableVideo() {
        if !streamMetaParsed {
            guard videoBuffer.count >= 64 + 4 else { return }
            let nameData = videoBuffer.prefix(64)
            let nul = nameData.firstIndex(of: 0) ?? nameData.endIndex
            pendingDeviceName = String(data: nameData.prefix(upTo: nul), encoding: .utf8) ?? ""
            pendingCodecID = readUInt32BE(at: 64)
            videoBuffer.removeFirst(68)
            streamMetaParsed = true
        }

        while true {
            guard videoBuffer.count >= 12 else { return }
            let firstByte = videoBuffer[videoBuffer.startIndex]
            if firstByte & 0x80 != 0 {
                // Session/resize packet, header-only.
                let width = readUInt32BE(at: 4)
                let height = readUInt32BE(at: 8)
                videoBuffer.removeFirst(12)
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

            let ptsFlags = readUInt64BE(at: 0)
            let size = Int(readUInt32BE(at: 8))
            guard size > 0 else {
                onError?(NSError(domain: "ScrcpyVideoStream", code: -1,
                                 userInfo: [NSLocalizedDescriptionKey: "invalid packet length 0"]))
                videoBuffer.removeAll()
                return
            }
            guard videoBuffer.count >= 12 + size else { return }

            let isConfig = (ptsFlags & (UInt64(1) << 62)) != 0
            let isKey = (ptsFlags & (UInt64(1) << 61)) != 0
            let pts = isConfig ? nil : (ptsFlags & ((UInt64(1) << 61) - 1))

            let payloadStart = videoBuffer.index(videoBuffer.startIndex, offsetBy: 12)
            let payloadEnd = videoBuffer.index(payloadStart, offsetBy: size)
            let payload = videoBuffer[payloadStart..<payloadEnd]
            let packet = VideoPacket(pts: pts, isConfig: isConfig, isKeyFrame: isKey, payload: Data(payload))
            videoBuffer.removeFirst(12 + size)
            onPacket?(packet)
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
}

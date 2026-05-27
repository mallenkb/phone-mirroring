import AVFoundation
import Foundation

/// Plays scrcpy RAW audio packets (PCM signed 16-bit little-endian) through
/// the Mac's default audio output.
final class ScrcpyAudioPlayer {
    static let rawCodecID: UInt32 = 0x7261_7720 // "raw "

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    private let queue = DispatchQueue(label: "scrcpy.audio.player", qos: .userInteractive)
    private var started = false
    private var volume: Float = 1

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.player.stop()
            self.engine.stop()
            self.started = false
        }
    }

    func enqueue(_ packet: ScrcpyVideoStream.AudioPacket) {
        guard packet.codecID == Self.rawCodecID, !packet.isConfig, !packet.payload.isEmpty else { return }
        let payload = packet.payload
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureStarted()
            guard let buffer = self.makeBuffer(from: payload) else { return }
            self.player.scheduleBuffer(buffer, completionHandler: nil)
        }
    }

    func setVolume(_ volume: Float) {
        let clamped = min(1, max(0, volume))
        queue.async { [weak self] in
            guard let self else { return }
            self.volume = clamped
            self.player.volume = clamped
        }
    }

    private func ensureStarted() {
        guard !started else { return }
        do {
            try engine.start()
            player.volume = volume
            player.play()
            started = true
        } catch {
            Logger.log("ScrcpyAudioPlayer start failed: \(error)")
        }
    }

    private func makeBuffer(from data: Data) -> AVAudioPCMBuffer? {
        let bytesPerFrame = 4 // stereo, Int16 LE per channel
        let frameCount = data.count / bytesPerFrame
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for frame in 0..<frameCount {
                let offset = frame * bytesPerFrame
                let leftBits = UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
                let rightBits = UInt16(base[offset + 2]) | (UInt16(base[offset + 3]) << 8)
                channels[0][frame] = Float(Int16(bitPattern: leftBits)) / 32768.0
                channels[1][frame] = Float(Int16(bitPattern: rightBits)) / 32768.0
            }
        }
        return buffer
    }
}

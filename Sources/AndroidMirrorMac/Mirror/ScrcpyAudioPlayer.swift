import AVFoundation
import Foundation

/// Plays the device's audio (scrcpy `audio_codec=raw`) on the Mac's speakers.
/// scrcpy raw audio is interleaved PCM: 48 kHz, stereo, signed 16-bit
/// little-endian. We feed each packet straight into an `AVAudioPlayerNode`;
/// the engine resamples/converts to the current output device automatically.
final class ScrcpyAudioPlayer {
    /// scrcpy `AudioConfig`: SAMPLE_RATE=48000, CHANNELS=2, ENCODING=PCM_16BIT.
    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 2
    private static let bytesPerFrame = 4 // 2 channels * 2 bytes (s16)

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var started = false
    private var enabled = true
    private var volume: Float = 1.0

    init() {
        format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: Self.channels,
            interleaved: true
        )!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Feed one raw-PCM packet (called on the stream's queue).
    func enqueue(_ pcm: Data) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, !pcm.isEmpty else { return }
        startLocked()
        guard started else { return }

        let frames = pcm.count / Self.bytesPerFrame
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dst = buffer.int16ChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(dst, base, frames * Self.bytesPerFrame)
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    func setVolume(_ value: Float) {
        lock.lock(); defer { lock.unlock() }
        volume = max(0, min(1, value))
        engine.mainMixerNode.outputVolume = volume
    }

    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = value
        if value {
            startLocked()
        } else {
            player.stop()
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard started else { return }
        player.stop()
        engine.stop()
        started = false
    }

    private func startLocked() {
        guard !started else { return }
        engine.mainMixerNode.outputVolume = volume
        engine.prepare()
        do {
            try engine.start()
            player.play()
            started = true
        } catch {
            Logger.log("ScrcpyAudioPlayer engine start failed: \(error.localizedDescription)")
        }
    }
}

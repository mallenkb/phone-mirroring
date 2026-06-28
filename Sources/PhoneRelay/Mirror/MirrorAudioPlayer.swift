import AVFoundation
import Foundation
import ObjCSupport

/// Plays the phone's audio on the Mac. scrcpy streams Opus at 16 kbps and the
/// player decodes each packet to PCM before scheduling it on the audio engine.
///
/// This is a best-effort, opt-in feature: real-time clock drift isn't corrected,
/// so very long sessions may accumulate a little latency. It never touches the
/// video path.
final class MirrorAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sourceFormat: AVAudioFormat
    private let renderFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let queue = DispatchQueue(label: "mirror.audio.player", qos: .userInitiated)
    private var running = false

    init?() {
        guard
            let source = AVAudioFormat(settings: [
                AVFormatIDKey: kAudioFormatOpus,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2
            ]),
            let render = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
            let converter = AVAudioConverter(from: source, to: render)
        else {
            return nil
        }
        self.sourceFormat = source
        self.renderFormat = render
        self.converter = converter
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: render)
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            do {
                engine.prepare()
                try engine.start()
                // `AVAudioPlayerNode.play()` raises an uncatchable Objective-C
                // exception for certain runtime audio-graph/output-device states
                // (observed crashing the whole app mid-mirror). Audio is a
                // best-effort, opt-in feature, so trap the exception and disable
                // audio rather than aborting the mirror session.
                if let raised = PRRunCatchingObjCException({ self.player.play() }) {
                    Logger.log("MirrorAudioPlayer: player.play() raised, disabling audio: \(raised.localizedDescription)")
                    engine.stop()
                    return
                }
                running = true
            } catch {
                Logger.log("MirrorAudioPlayer: engine start failed: \(error)")
            }
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            player.stop()
            engine.stop()
            running = false
        }
    }

    /// Feed one Opus packet from the stream.
    func enqueue(_ packet: Data) {
        queue.async { [self] in
            guard running, !packet.isEmpty else { return }
            guard let inBuffer = makeInputBuffer(from: packet),
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: renderFormat, frameCapacity: 4096)
            else {
                return
            }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return inBuffer
            }
            guard status != .error else {
                Logger.log("MirrorAudioPlayer: convert failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            player.scheduleBuffer(outBuffer, completionHandler: nil)
        }
    }

    private func makeInputBuffer(from packet: Data) -> AVAudioBuffer? {
        let buffer = AVAudioCompressedBuffer(
            format: sourceFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        packet.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            memcpy(buffer.data, src, packet.count)
        }
        buffer.byteLength = UInt32(packet.count)
        buffer.packetCount = 1
        buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 960,
            mDataByteSize: UInt32(packet.count)
        )
        return buffer
    }
}

import Foundation
import CoreMedia
import VideoToolbox

/// Converts the Annex-B H.264 packets scrcpy emits into `CMSampleBuffer`s
/// ready for `AVSampleBufferDisplayLayer`.
///
/// scrcpy's Android MediaCodec produces Annex-B byte streams: NAL units
/// separated by either 3- or 4-byte start codes (`0x000001` / `0x00000001`).
/// VideoToolbox / AVSampleBufferDisplayLayer want the AVCC variant — each
/// NAL prefixed with its 4-byte big-endian length. We swap start codes for
/// length prefixes, build a `CMVideoFormatDescription` from the SPS/PPS
/// found in the scrcpy "config" packet, then wrap every subsequent NAL
/// burst in a `CMSampleBuffer`.
final class H264VideoToolboxDecoder {
    /// Delivers a decoded sample plus whether it's a keyframe (IDR), so the
    /// renderer can resync on a keyframe after a display-layer flush.
    typealias SampleHandler = (CMSampleBuffer, Bool) -> Void

    private var formatDescription: CMVideoFormatDescription?
    private var spsData: Data?
    private var ppsData: Data?
    private var pendingConfigNALUnits: [Data] = []
    private var presentationTimeScale: CMTimeScale = 1_000_000
    private var loggedPacketCount = 0
    private var totalSampleCount = 0

    var onSample: SampleHandler?

    /// Feed a scrcpy packet. Config packets refresh SPS/PPS; media packets
    /// produce a sample buffer.
    func feed(_ packet: ScrcpyVideoStream.VideoPacket) {
        let nalUnits = Self.extractAnnexBNALUnits(packet.payload)
        if loggedPacketCount < 8 {
            loggedPacketCount += 1
            let firstBytes = packet.payload.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            Logger.log("H264 packet config=\(packet.isConfig) key=\(packet.isKeyFrame) bytes=\(packet.payload.count) nals=\(nalUnits.count) first=\(firstBytes)")
        }
        if packet.isConfig {
            pendingConfigNALUnits = nalUnits
            for nal in nalUnits {
                guard let first = nal.first else { continue }
                let nalType = first & 0x1F
                switch nalType {
                case 7: spsData = nal
                case 8: ppsData = nal
                default: break
                }
            }
            rebuildFormatDescription()
            return
        }

        // Some scrcpy builds prepend SPS/PPS to keyframes inline. Strip those
        // and refresh the format description if they differ.
        var slices: [Data] = []
        let mergedNALUnits: [Data]
        if pendingConfigNALUnits.isEmpty {
            mergedNALUnits = nalUnits
        } else {
            mergedNALUnits = pendingConfigNALUnits + nalUnits
            pendingConfigNALUnits = []
        }

        for nal in mergedNALUnits {
            guard let first = nal.first else { continue }
            let nalType = first & 0x1F
            switch nalType {
            case 7:
                if spsData != nal {
                    spsData = nal
                    rebuildFormatDescription()
                }
            case 8:
                if ppsData != nal {
                    ppsData = nal
                    rebuildFormatDescription()
                }
            default:
                slices.append(nal)
            }
        }
        guard !slices.isEmpty, let formatDescription else { return }
        guard let sample = buildSampleBuffer(slices: slices, pts: packet.pts,
                                             isKeyFrame: packet.isKeyFrame,
                                             format: formatDescription) else {
            return
        }
        totalSampleCount += 1
        // First few frames for startup visibility, then a periodic heartbeat so
        // we can confirm the stream is still flowing without spamming the log.
        if totalSampleCount <= 3 || totalSampleCount % 120 == 0 {
            Logger.log("H264 sample created #\(totalSampleCount) size=\(packet.payload.count) key=\(packet.isKeyFrame)")
        }
        onSample?(sample, packet.isKeyFrame)
    }

    private func rebuildFormatDescription() {
        guard let sps = spsData, let pps = ppsData else { return }
        var newFormat: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                let spsBase = spsRaw.bindMemory(to: UInt8.self).baseAddress!
                let ppsBase = ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointersBuf in
                    sizes.withUnsafeBufferPointer { sizesBuf in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuf.baseAddress!,
                            parameterSetSizes: sizesBuf.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormat
                        )
                    }
                }
            }
        }
        if status == noErr {
            formatDescription = newFormat
            Logger.log("H264 format description ready")
        } else {
            Logger.log("H264 format description creation failed: \(status)")
        }
    }

    private func buildSampleBuffer(slices: [Data], pts: UInt64?, isKeyFrame: Bool,
                                   format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data()
        avcc.reserveCapacity(slices.reduce(0) { $0 + 4 + $1.count })
        for slice in slices {
            var lenBE = UInt32(slice.count).bigEndian
            withUnsafeBytes(of: &lenBE) { raw in
                avcc.append(contentsOf: raw)
            }
            avcc.append(slice)
        }

        var blockBuffer: CMBlockBuffer?
        let bufferSize = avcc.count
        let memoryBlock = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        avcc.withUnsafeBytes { src in
            memoryBlock.update(from: src.bindMemory(to: UInt8.self).baseAddress!, count: bufferSize)
        }
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memoryBlock,
            blockLength: bufferSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bufferSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            memoryBlock.deallocate()
            return nil
        }

        var sampleSizes = [bufferSize]
        var timingInfo: CMSampleTimingInfo = .invalid
        if let pts {
            let cmPts = CMTime(value: CMTimeValue(pts), timescale: presentationTimeScale)
            timingInfo = CMSampleTimingInfo(duration: .invalid,
                                            presentationTimeStamp: cmPts,
                                            decodeTimeStamp: .invalid)
        }

        var sample: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: pts != nil ? 1 : 0,
            sampleTimingArray: pts != nil ? [timingInfo] : nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sample
        )
        guard sampleStatus == noErr, let sample else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKeyFrame {
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }

        return sample
    }

    /// Split an Annex-B byte stream into its constituent NAL units (start
    /// codes stripped). Handles both `0x00000001` and `0x000001` prefixes.
    static func extractAnnexBNALUnits(_ data: Data) -> [Data] {
        var nals: [Data] = []
        let count = data.count
        // Scan the packet in place rather than copying it into a `[UInt8]` first;
        // each retained NAL is still its own copy (unavoidable — they outlive the
        // packet), but the extra full-packet copy per frame is gone.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            var lastStart = -1

            func startCodeLength(at idx: Int) -> Int {
                if idx + 3 < count && base[idx] == 0 && base[idx + 1] == 0
                    && base[idx + 2] == 0 && base[idx + 3] == 1 {
                    return 4
                }
                if idx + 2 < count && base[idx] == 0 && base[idx + 1] == 0
                    && base[idx + 2] == 1 {
                    return 3
                }
                return 0
            }

            while i < count {
                let codeLen = startCodeLength(at: i)
                if codeLen > 0 {
                    if lastStart >= 0, i > lastStart {
                        nals.append(Data(bytes: base + lastStart, count: i - lastStart))
                    }
                    i += codeLen
                    lastStart = i
                } else {
                    i += 1
                }
            }
            if lastStart >= 0 && lastStart < count {
                nals.append(Data(bytes: base + lastStart, count: count - lastStart))
            }
        }
        return nals
    }
}

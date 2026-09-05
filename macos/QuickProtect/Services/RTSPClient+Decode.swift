import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - AVCC/HVCC access units → CMSampleBuffer → display layer, plus
// parameter-set handling and format descriptions.

extension RTSPClient {

    // MARK: - AVCC/HVCC → CMSampleBuffer → display layer

    /// Whether an access unit carries a keyframe NAL (H.264 IDR / HEVC IRAP)
    /// anywhere — SEI/AUD NALs may precede it. Queue-only — reads `codec`.
    func isKeyframeAccessUnit(_ nals: [[UInt8]]) -> Bool {
        RTPParser.accessUnitContainsKeyframe(nals, hevc: codec == "H265")
    }

    func enqueueAccessUnit(_ nals: [[UInt8]], formatDescription: CMVideoFormatDescription) {
        let isKeyframe = isKeyframeAccessUnit(nals)

        // Keep-alive grace: buffer instead of decode while the panel is hidden.
        if renderPaused {
            pausedGOP.add(nals, isKeyframe: isKeyframe)
            return
        }
        // Resume without a replayable GOP: hold the last frame until the stream
        // delivers a keyframe that re-anchors the reference chain.
        if awaitingKeyframeAfterResume {
            guard isKeyframe else { return }
            awaitingKeyframeAfterResume = false
        }

        // Length-prefixed (AVCC/HVCC) access unit, packed by RTPParser; the
        // block buffer owns a malloc'd copy that CoreMedia frees.
        let avcc = RTPParser.nalsToAVCC(nals)
        let totalSize = avcc.count
        guard totalSize > 0, let mem = malloc(totalSize) else { return }
        avcc.withUnsafeBytes { src in _ = memcpy(mem, src.baseAddress, totalSize) }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: totalSize,
            blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
            offsetToData: 0, dataLength: totalSize, flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let block = blockBuffer else { free(mem); return }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration:              CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp:       .invalid)
        sequenceNumber += 1

        var sb: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)

        if let sb {
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
                for dict in attachments {
                    dict[kCMSampleAttachmentKey_DependsOnOthers] = !isKeyframe
                    dict[kCMSampleAttachmentKey_DisplayImmediately] = true
                }
            }
            if displayLayer.status == .failed { displayLayer.flush() }
            // Back-pressure: a layer that stopped draining (display asleep,
            // window occluded) must not accumulate samples without bound. A
            // keyframe re-anchors it — flush what's queued and enqueue; a
            // P-frame is dropped and the stream waits for the next keyframe,
            // since feeding P-frames after a gap only decodes garbage. Never
            // applied before the first frame is up: a layer that hasn't been
            // shown yet reports not-ready too, and the first picture must land.
            if hasFrameSignalled, !displayLayer.isReadyForMoreMediaData {
                if isKeyframe {
                    Self.dbg("[RTSP] display layer not draining — flushed at keyframe")
                    displayLayer.flush()
                } else {
                    if !awaitingKeyframeAfterResume { Self.dbg("[RTSP] display layer not draining — waiting for keyframe") }
                    awaitingKeyframeAfterResume = true
                    return
                }
            }
            displayLayer.enqueue(sb)
            if captureActive { decodeForCapture(sb, format: formatDescription, isKeyframe: isKeyframe) }
            if !hasFrameSignalled {
                hasFrameSignalled = true
                Self.dbg("[RTSP] first frame on screen (\(codec), keyframe=\(isKeyframe), \(nals.count) NALs)")
                if handoverOwner != nil {
                    // Warm-up child: its first frame just replaced the picture —
                    // flag for adoption at the receive-completion tail.
                    readyToAdopt = true
                } else {
                    DispatchQueue.main.async { self.hasFrame = true }
                }
            }
        }
    }

    /// Installs a freshly built format description and publishes its picture
    /// size — whether the parameter sets came from the SDP or arrived in-band.
    func adoptFormatDescription(_ description: CMVideoFormatDescription?) {
        guard let description else { return }
        formatDescription = description
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
        DispatchQueue.main.async { self.videoDimensions = size }
    }

    func makeH264FormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        sps.withUnsafeBufferPointer { spBuf in pps.withUnsafeBufferPointer { ppBuf in
            guard let s = spBuf.baseAddress, let p = ppBuf.baseAddress else { return }
            var ptrs: [UnsafePointer<UInt8>] = [s, p]
            var sizes: [Int] = [sps.count, pps.count]
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 2,
                parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        }}
        return desc
    }

    func makeHEVCFormatDescription(vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var desc: CMVideoFormatDescription?
        vps.withUnsafeBufferPointer { vp in sps.withUnsafeBufferPointer { sp in pps.withUnsafeBufferPointer { pp in
            guard let v = vp.baseAddress, let s = sp.baseAddress, let p = pp.baseAddress else { return }
            var ptrs: [UnsafePointer<UInt8>] = [v, s, p]
            var sizes: [Int] = [vps.count, sps.count, pps.count]
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: 3,
                parameterSetPointers: &ptrs, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        }}}
        return desc
    }
}

import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

/// Plays an AAC audio track through `AVSampleBufferAudioRenderer`, driven by its
/// own `AVSampleBufferRenderSynchronizer` on a sample-counted timeline.
///
/// Audio is far more sensitive to arrival jitter than video, so rather than the
/// host-clock immediate-display timing the video path uses, each access unit gets
/// a monotonic PTS derived purely from a running sample count. The synchronizer
/// starts a fixed lead behind the first packet so the renderer can absorb jitter
/// without underrunning. Lip-sync to the video layer is approximate, not locked.
///
/// All methods are expected to run on the owning RTSPClient's serial queue;
/// `AVSampleBufferAudioRenderer.enqueue` is thread-safe like the display layer.
final class AudioRenderer {

    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let formatDescription: CMAudioFormatDescription
    private let sampleRate: Int32
    private let framesPerPacket: Int64
    private var nextSamplePTS: Int64 = 0
    private var started = false

    /// Build a renderer from the SDP audio description. Prefers the
    /// AudioSpecificConfig (`config=`) for sample rate / channels / object type,
    /// falling back to the rtpmap values. Returns nil if a format description
    /// can't be created.
    init?(audio: RTPParser.SDPAudioInfo, muted: Bool) {
        var objectType = 2          // AAC-LC
        var rate = audio.sampleRate
        var channels = max(1, audio.channels)

        if let asc = audio.config, let parsed = RTPParser.parseAudioSpecificConfig(asc) {
            objectType = parsed.objectType
            if parsed.sampleRate > 0 { rate = parsed.sampleRate }
            if parsed.channels > 0 { channels = parsed.channels }
        }
        guard rate > 0 else { return nil }

        // HE-AAC (SBR) outputs 2048 samples per packet; plain AAC-LC outputs 1024.
        let fpp: Int64 = (objectType == 5 || objectType == 29) ? 2048 : 1024
        self.sampleRate = Int32(rate)
        self.framesPerPacket = fpp

        var asbd = AudioStreamBasicDescription(
            mSampleRate:       Float64(rate),
            mFormatID:         kAudioFormatMPEG4AAC,
            mFormatFlags:      UInt32(objectType),
            mBytesPerPacket:   0,
            mFramesPerPacket:  UInt32(fpp),
            mBytesPerFrame:    0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel:   0,
            mReserved:         0)

        var desc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &desc)
        guard status == noErr, let desc else { return nil }
        self.formatDescription = desc

        renderer.isMuted = muted
        synchronizer.addRenderer(renderer)
    }

    /// Decode-and-play one AAC access unit. Starts the synchronizer on first call.
    func enqueue(_ accessUnit: [UInt8]) {
        guard renderer.status != .failed else { return }
        // Back-pressure: if output stopped draining, drop rather than queue
        // without bound (a glitch on resume beats unbounded growth).
        guard renderer.isReadyForMoreMediaData else { return }
        guard let sample = makeSampleBuffer(accessUnit) else { return }
        renderer.enqueue(sample)
        if !started {
            started = true
            // Start a fixed lead behind PTS 0 so ~200 ms buffers before playback
            // reaches the first packet — smooths network jitter without underrun.
            let lead = CMTime(value: Int64(sampleRate) / 5, timescale: sampleRate)
            synchronizer.setRate(1.0, time: CMTime(value: 0, timescale: sampleRate) - lead)
        }
    }

    func setMuted(_ muted: Bool) { renderer.isMuted = muted }

    /// Stop playback and release the renderer from the synchronizer.
    func stop() {
        synchronizer.setRate(0, time: .invalid)
        renderer.flush()
        synchronizer.removeRenderer(renderer, at: .invalid, completionHandler: nil)
    }

    private func makeSampleBuffer(_ accessUnit: [UInt8]) -> CMSampleBuffer? {
        let size = accessUnit.count
        guard size > 0, let mem = malloc(size) else { return nil }
        accessUnit.withUnsafeBytes { _ = memcpy(mem, $0.baseAddress, size) }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: mem, blockLength: size,
            blockAllocator: kCFAllocatorMalloc, customBlockSource: nil,
            offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let block = blockBuffer else { free(mem); return nil }

        var timing = CMSampleTimingInfo(
            duration:              CMTime(value: framesPerPacket, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: nextSamplePTS, timescale: sampleRate),
            decodeTimeStamp:       .invalid)
        var sampleSize = size

        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: formatDescription, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }

        nextSamplePTS += framesPerPacket
        return sample
    }
}

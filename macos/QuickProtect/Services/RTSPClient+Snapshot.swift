import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - Snapshot capture: a VideoToolbox decode of the live stream, kept
// only while a capture is requested.

extension RTSPClient {

    // MARK: - Snapshot capture (called from main thread)

    /// Enable/disable decoding a copy of the video into a pixel buffer so the UI
    /// can grab a still of the current frame at the streamed resolution. Only the
    /// focused camera turns this on, to avoid decoding every grid tile.
    func setCaptureActive(_ active: Bool) {
        queue.async { [self] in
            guard captureActive != active else { return }
            captureActive = active
            Self.dbg("[Snapshot] capture active=\(active)")
            if !active { teardownCaptureSession() }
        }
    }

    /// A CGImage of the most recently decoded frame, or nil if capture is off or
    /// no frame has been decoded yet. Safe to call from the main thread.
    func snapshotCGImage() -> CGImage? {
        latestFrameLock.lock()
        let pixelBuffer = latestPixelBuffer
        latestFrameLock.unlock()
        guard let pixelBuffer else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        return image
    }

    /// Decode one access unit into the capture pixel buffer. Queue-only.
    /// Re-creates the decompression session when the format description changes,
    /// and only starts decoding at a keyframe — feeding P-frames to a fresh
    /// session just yields kVTVideoDecoderReferenceMissingErr until the next IDR.
    func decodeForCapture(_ sampleBuffer: CMSampleBuffer, format: CMVideoFormatDescription, isKeyframe: Bool) {
        if decompressionSession == nil
            || !CMFormatDescriptionEqual(decompressionFormat, otherFormatDescription: format) {
            teardownCaptureSession()
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()
            ]
            var session: VTDecompressionSession?
            let status = VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                formatDescription: format,
                decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary,
                outputCallback: nil,
                decompressionSessionOut: &session)
            guard status == noErr, let session else {
                Self.dbg("[Snapshot] VTDecompressionSessionCreate failed: \(status)")
                return
            }
            decompressionSession = session
            decompressionFormat = format
            captureLoggedFirstFrame = false
            captureSeenKeyframe = false
            Self.dbg("[Snapshot] capture session created")
        }
        // Wait for the first keyframe before feeding the decoder; once it has a
        // reference, subsequent P-frames decode normally.
        if !captureSeenKeyframe {
            guard isKeyframe else { return }
            captureSeenKeyframe = true
        }
        guard let session = decompressionSession else { return }
        _ = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard let self else { return }
            guard status == noErr, let imageBuffer else {
                if !self.captureLoggedFirstFrame { Self.dbg("[Snapshot] decode status=\(status)") }
                return
            }
            self.latestFrameLock.lock()
            self.latestPixelBuffer = imageBuffer
            self.latestFrameLock.unlock()
            if !self.captureLoggedFirstFrame {
                self.captureLoggedFirstFrame = true
                Self.dbg("[Snapshot] first capture frame \(CVPixelBufferGetWidth(imageBuffer))x\(CVPixelBufferGetHeight(imageBuffer))")
            }
        }
    }

    /// Tear down the decompression session and drop the retained frame. Queue-only.
    func teardownCaptureSession() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        decompressionFormat = nil
        latestFrameLock.lock()
        latestPixelBuffer = nil
        latestFrameLock.unlock()
    }
}

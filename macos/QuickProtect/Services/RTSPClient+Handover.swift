import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - Seamless quality switch: a hidden child client connects and decodes
// the new stream's first frame, then its session is adopted in place.

extension RTSPClient {

    // MARK: - Seamless quality switch (handover)

    /// Switch this stream to a new URL (a quality change) without freezing the
    /// picture: the current session keeps painting while a hidden child client
    /// connects and decodes the new stream's first frame — the moment it lands,
    /// the child's session is adopted wholesale and the old one is torn down.
    /// If the new stream produces no frame within the grace window, the switch
    /// is abandoned and the current stream just keeps playing.
    ///
    /// `completion` (main thread): `true` — the new stream is live, release the
    /// replaced server-side allocation; `false` — the switch was abandoned,
    /// release the *new* allocation instead.
    func switchStream(to url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        queue.async { [self] in
            // A newer switch abandons any warm-up still in flight.
            cancelHandoverOnQueue()

            // Nothing on screen to preserve (initial connect, failed stream):
            // plain reconnect, which is exactly the pre-handover behavior.
            guard connection != nil, hasFrameSignalled else {
                DispatchQueue.main.async { MainActor.assumeIsolated { completion(true) } }
                connect(to: url, pinKey: pinKey, keepLastFrame: true)
                return
            }

            handoverCompletion = completion
            let child = RTSPClient(handoverFor: self)
            handoverChild = child
            handoverGen &+= 1
            let gen = handoverGen
            child.connect(to: url, pinKey: pinKey, keepLastFrame: true)
            queue.asyncAfter(deadline: .now() + Self.handoverGrace) { [weak self] in
                guard let self, self.handoverGen == gen, self.handoverChild != nil else { return }
                Self.dbg("[RTSP] handover timed out — keeping the current stream")
                self.cancelHandoverOnQueue()
            }
        }
    }

    /// Adopt the warm-up child's session wholesale: retire the current
    /// connection, take over the child's connection and parser state, and
    /// re-point the connection's callbacks here. Runs on `queue`, called from
    /// the child's receive-completion tail so no parse is in flight on either
    /// side (the child's buffer cursor is quiescent when it's copied).
    func completeHandover(adopting child: RTSPClient) {
        guard child === handoverChild else { return } // cancelled/superseded meanwhile
        handoverChild = nil
        child.handoverOwner = nil
        child.adoptedBy = self

        retireCurrentSessionOnQueue()
        adoptSessionState(from: child)
        child.connection = nil // the child's state/receive guards bail from now on
        if let conn = connection { installStateHandler(on: conn) }

        // Audio is negotiated per session: rebuild the renderer for the new track.
        audioRenderer?.stop()
        audioRenderer = nil
        aacDepacketizer = nil
        if audioActive, inRTPMode { startAudioRenderer() }

        // The new session anchors its own pause/replay state.
        pausedGOP = PausedGOPBuffer()
        awaitingKeyframeAfterResume = false

        let dims: CGSize? = formatDescription.map {
            let d = CMVideoFormatDescriptionGetDimensions($0)
            return CGSize(width: CGFloat(d.width), height: CGFloat(d.height))
        }
        let audio = audioInfo != nil
        DispatchQueue.main.async { [self] in
            if let dims { videoDimensions = dims }
            hasAudio = audio
            isConnected = true
            error = nil
        }
        Self.dbg("[RTSP] handover complete: \(currentURL.map(Self.redactedDescription(of:)) ?? "?")")
        finishHandover(success: true)
    }

    /// Copy every session-scoped field from the child. Keep in sync with the
    /// queue-only state block at the top of the class (owner-scoped state —
    /// audio routing, capture, pause, handover bookkeeping — stays put).
    func adoptSessionState(from child: RTSPClient) {
        connection        = child.connection
        currentURL        = child.currentURL
        buffer            = child.buffer
        bufferOffset      = child.bufferOffset
        inRTPMode         = child.inRTPMode
        cSeq              = child.cSeq
        sessionId         = child.sessionId
        trackControl      = child.trackControl
        awaiting          = child.awaiting
        audioInfo         = child.audioInfo
        videoRTPChannel   = child.videoRTPChannel
        audioRTPChannel   = child.audioRTPChannel
        codec             = child.codec
        fuBuffer          = child.fuBuffer
        formatDescription = child.formatDescription
        sequenceNumber    = child.sequenceNumber
        hevcVPS           = child.hevcVPS
        hevcSPS           = child.hevcSPS
        hevcPPS           = child.hevcPPS
        h264SPS           = child.h264SPS
        h264PPS           = child.h264PPS
        pendingNALs       = child.pendingNALs
    }

    /// Abandon a warm-up in flight, keeping the current stream. Queue-only.
    func cancelHandoverOnQueue() {
        guard let child = handoverChild else { return }
        handoverChild = nil
        child.handoverOwner = nil
        child.disconnectOnQueue(flushDisplay: false) // never flush the shared layer
        finishHandover(success: false)
    }

    /// Invalidate the grace timeout and deliver the switch outcome. Queue-only.
    func finishHandover(success: Bool) {
        handoverGen &+= 1
        guard let completion = handoverCompletion else { return }
        handoverCompletion = nil
        DispatchQueue.main.async { MainActor.assumeIsolated { completion(success) } }
    }
}

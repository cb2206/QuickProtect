import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

/// RTSP/RTP client using NWConnection.
/// All data processing runs on a dedicated serial queue to keep the main thread free.
/// Only @Published property updates are dispatched to the main thread for SwiftUI.
/// AVSampleBufferDisplayLayer.enqueue() is thread-safe and called from the processing queue.
///
/// Quality switches are seamless (`switchStream(to:completion:)`): the current
/// session keeps painting while a hidden child client — sharing this queue and
/// display layer — connects and decodes the new stream's first frame; that
/// frame replaces the picture in place and the child's session is adopted
/// wholesale. Mirrors the .NET `VideoStreamClient` double-buffered switching.
final class RTSPClient: ObservableObject {

    // MARK: - Published (main-thread only)

    @Published var displayLayer = AVSampleBufferDisplayLayer()
    @Published var isConnected  = false
    /// True once the first frame has actually been enqueued for display.
    /// `isConnected` flips at RTP setup — before any picture exists — so the UI
    /// keys its "now showing video" state off this instead to avoid a black gap.
    @Published var hasFrame     = false
    /// Controller-provided JPEG shown by the views while `hasFrame` is false.
    /// Set for streams whose first keyframe is many seconds away (the 2 fps
    /// package lens joins mid-GOP and can't paint until the next IDR).
    @Published var placeholderImage: CGImage?
    @Published var error: String?
    @Published var videoDimensions: CGSize = .zero
    /// True once an AAC audio track has been negotiated for this stream.
    @Published var hasAudio = false
    /// Whether audio output is muted. Mirrors the global speaker preference.
    @Published var isMuted = true

    // MARK: - Dedicated processing queue
    // All mutable state below is accessed exclusively on this queue.
    // NWConnection callbacks also fire on this queue. A handover child (see
    // switchStream) shares its owner's queue, so a takeover is a plain
    // sequential step on one serial queue, never a cross-queue race.

    private let queue: DispatchQueue

    // MARK: - Resource limits (defend against a hostile/buggy endpoint)
    // RTSP control responses (incl. SDP) are small; an unbounded Content-Length or
    // a header terminator that never arrives must not balloon memory.
    private let maxControlBuffer = 8 * 1024 * 1024   // hard ceiling on the receive buffer
    private let maxContentLength = 4 * 1024 * 1024   // reject larger Content-Length outright
    private let maxHeaderSize    = 64 * 1024         // give up scanning for \r\n\r\n past this
    /// Ceiling on a single reassembled NAL (fragmentation units) and on the
    /// NALs pending for one access unit. A stream whose fragment end or marker
    /// bit never arrives must not grow memory without bound — drop and resync.
    private let maxReassemblyBytes = 4 * 1024 * 1024

    // MARK: - State (queue-only)

    private var connection:  NWConnection?
    private var currentURL:  URL?
    private var buffer       = [UInt8]()
    private var bufferOffset = 0          // read cursor; compact when > 64 KB
    private var inRTPMode    = false
    private var cSeq         = 0
    private var sessionId    = ""
    private var trackControl = ""

    /// Which RTSP request we last sent and are awaiting a response for. Requests
    /// are strictly sequential (one outstanding at a time), so this drives the
    /// setup handshake instead of matching on the bare CSeq counter.
    private enum RTSPRequest { case options, describe, setupVideo, setupAudio, play }
    private var awaiting: RTSPRequest = .options
    /// DESCRIBE answers seen without a video track on this session. The
    /// controller can publish a freshly allocated stream before the camera's
    /// video channel is flowing, so a few re-DESCRIBEs are tried before the
    /// session is failed.
    private var describesWithoutVideo = 0
    private static let maxDescribesWithoutVideo = 3
    private static let describeRetryDelay: TimeInterval = 1.0
    private var audioInfo: RTPParser.SDPAudioInfo?

    /// Interleaved RTP channels actually assigned by the server's SETUP response
    /// Transport header. We propose 0-1 (video) and 2-3 (audio), but the server is
    /// free to renumber, so we read the channel back rather than assume it.
    private var videoRTPChannel: UInt8 = 0
    private var audioRTPChannel: UInt8 = 2

    private var codec            = "H264"
    private var fuBuffer:          [UInt8]?
    /// Set on the queue when the TLS verify block rejected the controller's
    /// certificate, so the generic connection-failed text that follows doesn't
    /// overwrite the actionable "certificate changed" message.
    private var certificateRejected = false
    private var formatDescription: CMVideoFormatDescription?
    private var sequenceNumber:    Int64 = 0

    private var hevcVPS: [UInt8]?
    private var hevcSPS: [UInt8]?
    private var hevcPPS: [UInt8]?
    private var h264SPS: [UInt8]?
    private var h264PPS: [UInt8]?

    private var pendingNALs: [[UInt8]] = []
    private var hasFrameSignalled = false   // queue-only: gates the one-shot hasFrame publish

    // Render pause (stream keep-alive grace) — all queue-only. While paused,
    // access units are buffered instead of enqueued so the display layer does
    // no decode work for a hidden panel; see setRenderPaused(_:).
    private var renderPaused = false
    private var pausedGOP = PausedGOPBuffer()
    private var awaitingKeyframeAfterResume = false

    // Audio (queue-only). The renderer exists only while this client is the
    // focused stream; muting toggles its output without tearing it down.
    private var audioRenderer: AudioRenderer?
    private var audioActive   = false       // true while this client is focused
    private var audioMuted    = true
    private var aacDepacketizer: RTPParser.AACDepacketizer?
    private var audioLoggedFirstAU = false   // queue-only: one-shot enqueue log

    // Snapshot capture. The display layer decodes internally and can't be read
    // back, so when active we run a parallel VTDecompressionSession that keeps
    // only the latest decoded frame. Session state is queue-only; the frame
    // itself is read from the main thread, so it's guarded by a lock.
    // Enabled only for the focused camera to avoid decoding every grid tile.
    private var captureActive = false                          // queue-only
    private var decompressionSession: VTDecompressionSession?  // queue-only
    private var decompressionFormat: CMVideoFormatDescription? // queue-only
    private let latestFrameLock = NSLock()
    private var latestPixelBuffer: CVImageBuffer?              // lock-guarded
    private var captureLoggedFirstFrame = false               // one-shot debug log
    private var captureSeenKeyframe = false                   // gate decode until first IDR

    // Seamless quality switch (queue-only). switchStream(to:) warms the
    // next-quality session up in a hidden child client on this same serial
    // queue while this one keeps painting; the child's whole session is
    // adopted at its first enqueued frame (completeHandover). Mirrors the
    // .NET VideoStreamClient's generation-gated double-buffering.
    private weak var handoverOwner: RTSPClient?    // set only on warm-up children
    private weak var adoptedBy: RTSPClient?        // routes the in-flight receive after adoption
    private var handoverChild: RTSPClient?         // set only on owners
    private var handoverCompletion: ((Bool) -> Void)?
    private var handoverGen = 0                    // guards the grace timeout
    private var readyToAdopt = false               // child: first frame enqueued
    /// How long a warm-up may take before the switch is abandoned and the
    /// current stream simply keeps playing (the pre-handover behavior).
    private static let handoverGrace: TimeInterval = 10

    // MARK: - Init

    init() {
        queue = DispatchQueue(label: "com.quickprotect.rtsp", qos: .userInitiated)
        displayLayer.videoGravity = .resizeAspectFill
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                        sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1.0)
            displayLayer.controlTimebase = tb
        }
    }

    /// A warm-up client for a seamless quality switch: shares the owner's
    /// serial queue and its display layer (already configured — gravity,
    /// timebase), so its first decoded frame replaces the picture in place.
    /// Never handed to views; its @Published state is throwaway.
    private init(handoverFor owner: RTSPClient) {
        queue = owner.queue
        displayLayer = owner.displayLayer
        handoverOwner = owner
    }

    deinit {
        // Safety net only — owners are expected to call disconnect() explicitly.
        // Without this, dropping the last reference leaves the NWConnection
        // established and the controller keeps streaming into it until the
        // session times out. Reading `connection` off-queue is benign here: at
        // deinit no strong references remain, so the only queue work that could
        // still run holds `self` weakly and bails before touching state.
        connection?.cancel()
    }

    // MARK: - Public API (called from main thread)

    /// Opt-in file logging. Off by default; enable with
    ///   defaults write com.cb.quickprotect QPDebugLogging -bool YES
    /// or, for a sandboxed build whose container preferences the shell can't
    /// reach, launch with QUICKPROTECT_DEBUG_LOG=1 in the environment.
    /// Callers must not pass credential material (tokens, passwords) here.
    static let debugLoggingEnabled = UserDefaults.standard.bool(forKey: "QPDebugLogging")
        || debugLoggingViaEnvironment
    /// The environment switch also mirrors every line to NSLog (stderr / the
    /// unified log), since the sandbox container's temp dir is not readable from
    /// a shell — `QUICKPROTECT_DEBUG_LOG=1 QuickProtect.app/Contents/MacOS/QuickProtect 2>log`.
    private static let debugLoggingViaEnvironment =
        ProcessInfo.processInfo.environment["QUICKPROTECT_DEBUG_LOG"] == "1"
    private static let maxLogBytes: UInt64 = 1_048_576  // 1 MB, truncated on rollover

    static func log(_ msg: String) { dbg(msg) }

    /// Scheme, host and port only. The path of a stream URL is a bearer token
    /// for live video and must never reach the log.
    static func redactedDescription(of url: URL) -> String {
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme ?? "?")://\(url.host ?? "?")\(port)/…"
    }
    private static func dbg(_ msg: String) {
        guard debugLoggingEnabled else { return }
        if debugLoggingViaEnvironment { NSLog("%@", msg) }
        let line = "\(Date()) \(msg)\n"
        // NSTemporaryDirectory() resolves to the app's sandbox container temp
        // dir under the App Sandbox, and /private/tmp otherwise — writable in
        // both, unlike a hard-coded /tmp path which the sandbox blocks.
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("quickprotect_debug.log")
        // Cap the file: start fresh once it grows past the limit so it can't
        // accumulate without bound across long-running sessions.
        if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64,
           size > maxLogBytes {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    /// `keepLastFrame` leaves the display layer's current image in place while the
    /// new stream connects (no flush), so a quality switch dissolves into the new
    /// feed instead of flashing the layer's clear colour. Frames carry
    /// DisplayImmediately, so the new stream replaces the held frame on its first
    /// enqueue regardless of timestamps.
    func connect(to url: URL, keepLastFrame: Bool = false) {
        Self.dbg("[RTSP] connect called: \(Self.redactedDescription(of: url))")
        DispatchQueue.main.async { self.hasFrame = false }
        queue.async { [self] in
            disconnectOnQueue(flushDisplay: !keepLastFrame)
            currentURL       = url
            inRTPMode        = false
            buffer           = []
            bufferOffset     = 0
            cSeq             = 0
            sessionId        = ""
            trackControl     = ""
            awaiting         = .options
            describesWithoutVideo = 0
            audioInfo        = nil
            videoRTPChannel  = 0
            audioRTPChannel  = 2
            codec            = "H264"
            fuBuffer         = nil
            hevcVPS          = nil
            hevcSPS          = nil
            hevcPPS          = nil
            h264SPS          = nil
            h264PPS          = nil
            pendingNALs      = []
            sequenceNumber   = 0
            formatDescription = nil
            hasFrameSignalled = false
            renderPaused     = false
            pausedGOP        = PausedGOPBuffer()
            awaitingKeyframeAfterResume = false
            certificateRejected = false

            guard let host = url.host,
                  let rawPort = url.port,
                  let port = NWEndpoint.Port(rawValue: UInt16(rawPort))
            else {
                DispatchQueue.main.async { self.error = "Invalid RTSP URL" }
                return
            }

            let tlsOpts = NWProtocolTLS.Options()
            sec_protocol_options_set_min_tls_protocol_version(tlsOpts.securityProtocolOptions, .TLSv12)
            // Same certificate policy as the HTTPS path (system trust, then
            // trust-on-first-use pinning — see CertificateTrust). The pin is
            // keyed by the configured controller identity, not by the host in
            // the stream URL, so both channels share one pin.
            let pinKey = ControllerAddress.parse(AppSettings.shared.ipAddress)?.pinKey ?? host
            sec_protocol_options_set_verify_block(
                tlsOpts.securityProtocolOptions,
                { [weak self] _, secTrust, complete in
                    let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                    let ok = CertificateTrust.evaluate(pinKey: pinKey, serverHost: host, trust: trust)
                    if !ok {
                        self?.certificateRejected = true
                        DispatchQueue.main.async {
                            self?.error = String(localized: "The controller's certificate changed. Open Settings to review and trust it.")
                        }
                    }
                    complete(ok)
                },
                queue
            )

            let params = NWParameters(tls: tlsOpts)
            let conn   = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
            connection = conn

            installStateHandler(on: conn)

            // Start on our queue — all callbacks fire here, no Task overhead
            conn.start(queue: queue)
            scheduleReceive(conn: conn)
        }
    }

    func disconnect() {
        queue.async { [self] in
            disconnectOnQueue()
        }
    }

    /// (Re)point the connection's state callbacks at this client — used at
    /// connect and again when a handover adopts the child's connection.
    /// Replacing the handler never replays the current state, so re-installing
    /// on an established connection sends no spurious OPTIONS.
    private func installStateHandler(on conn: NWConnection) {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                guard conn === self.connection else { return }
                Self.dbg("[RTSP] NWConnection state: \(state)")
                switch state {
                case .ready:
                    self.sendOptions()
                case .failed(let e):
                    Self.dbg("[RTSP] Connection FAILED: \(e.localizedDescription)")
                    // A certificate rejection already published its own message.
                    if !self.certificateRejected {
                        DispatchQueue.main.async { self.error = e.localizedDescription }
                    }
                case .cancelled:
                    DispatchQueue.main.async { self.isConnected = false }
                default: break
                }
            }
        }
    }

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
    func switchStream(to url: URL, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            // A newer switch abandons any warm-up still in flight.
            cancelHandoverOnQueue()

            // Nothing on screen to preserve (initial connect, failed stream):
            // plain reconnect, which is exactly the pre-handover behavior.
            guard connection != nil, hasFrameSignalled else {
                DispatchQueue.main.async { completion(true) }
                connect(to: url, keepLastFrame: true)
                return
            }

            handoverCompletion = completion
            let child = RTSPClient(handoverFor: self)
            handoverChild = child
            handoverGen &+= 1
            let gen = handoverGen
            child.connect(to: url, keepLastFrame: true)
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
    private func completeHandover(adopting child: RTSPClient) {
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
    private func adoptSessionState(from child: RTSPClient) {
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
    private func cancelHandoverOnQueue() {
        guard let child = handoverChild else { return }
        handoverChild = nil
        child.handoverOwner = nil
        child.disconnectOnQueue(flushDisplay: false) // never flush the shared layer
        finishHandover(success: false)
    }

    /// Invalidate the grace timeout and deliver the switch outcome. Queue-only.
    private func finishHandover(success: Bool) {
        handoverGen &+= 1
        guard let completion = handoverCompletion else { return }
        handoverCompletion = nil
        DispatchQueue.main.async { completion(success) }
    }

    // MARK: - Render pause (called from main thread)

    /// Pause or resume display-layer decode while the stream stays connected.
    /// Used for the keep-alive grace after the panel closes: decoding frames
    /// nobody sees is wasted CPU, but the RTSP session must survive so a quick
    /// reopen is instant. While paused, compressed access units are buffered
    /// from the most recent keyframe (`PausedGOPBuffer`); resume burst-replays
    /// them through the normal enqueue path, catching the picture up to live
    /// immediately. If nothing replayable was buffered (paused mid-GOP, or the
    /// buffer overflowed), the last frame stays on the layer and enqueueing
    /// waits for the next keyframe — feeding P-frames whose references were
    /// never decoded would only produce garbage.
    func setRenderPaused(_ paused: Bool) {
        queue.async { [self] in
            guard renderPaused != paused else { return }
            renderPaused = paused
            if paused { return }
            let gop = pausedGOP.drain()
            if let fmt = formatDescription, !gop.isEmpty {
                for nals in gop { enqueueAccessUnit(nals, formatDescription: fmt) }
            } else {
                awaitingKeyframeAfterResume = true
            }
        }
    }

    // MARK: - Audio control (called from main thread)

    /// Mark this client as the focused stream. Audio is rendered only for the
    /// focused camera; leaving focus tears the renderer down. Negotiation already
    /// happened at connect, so this never reconnects.
    func setAudioActive(_ active: Bool) {
        queue.async { [self] in
            guard audioActive != active else { return }
            audioActive = active
            if active {
                if inRTPMode { startAudioRenderer() }
            } else {
                audioRenderer?.stop()
                audioRenderer = nil
                aacDepacketizer = nil
            }
        }
    }

    /// Mute or unmute audio output. Takes effect immediately; the renderer stays
    /// alive so toggling never re-negotiates or re-buffers.
    func setMuted(_ muted: Bool) {
        DispatchQueue.main.async { self.isMuted = muted }
        queue.async { [self] in
            audioMuted = muted
            audioRenderer?.setMuted(muted)
        }
    }

    /// Create the audio renderer for the current track. Queue-only.
    private func startAudioRenderer() {
        guard audioRenderer == nil, let audio = audioInfo else { return }
        audioLoggedFirstAU = false
        audioRenderer = AudioRenderer(audio: audio, muted: audioMuted)
        aacDepacketizer = RTPParser.AACDepacketizer(
            sizeLength: audio.sizeLength, indexLength: audio.indexLength,
            indexDeltaLength: audio.indexDeltaLength)
        Self.dbg("[RTSP] audio renderer \(audioRenderer == nil ? "FAILED" : "started") muted=\(audioMuted)")
    }

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
    private func decodeForCapture(_ sampleBuffer: CMSampleBuffer, format: CMVideoFormatDescription, isKeyframe: Bool) {
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
    private func teardownCaptureSession() {
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

    // MARK: - Internal disconnect (must be called on queue)

    private func disconnectOnQueue(flushDisplay: Bool = true) {
        cancelHandoverOnQueue() // a warm-up child must not outlive its owner's session
        retireCurrentSessionOnQueue()
        audioRenderer?.stop()
        audioRenderer = nil
        aacDepacketizer = nil
        teardownCaptureSession()
        // Free any GOP held while paused (grace teardown arrives paused).
        renderPaused = false
        pausedGOP = PausedGOPBuffer()
        awaitingKeyframeAfterResume = false
        if flushDisplay { displayLayer.flush() }
        DispatchQueue.main.async { [self] in
            isConnected = false
            hasFrame    = false
            error = nil
        }
    }

    /// TEARDOWN + cancel the current connection without touching the display
    /// layer or published state — used by the full disconnect above and by a
    /// handover retiring the outgoing session while its replacement is already
    /// painting. Queue-only.
    private func retireCurrentSessionOnQueue() {
        // Send TEARDOWN to free server-side resources before closing the connection
        if let conn = connection, let url = currentURL, !sessionId.isEmpty {
            let seq = nextCSeq()
            let msg = "TEARDOWN \(url.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\nSession: \(sessionId)\r\n\r\n"
            // Cancel only once the TEARDOWN has hit the wire — cancelling on the
            // next line raced the send and usually dropped it. The asyncAfter is
            // a backstop for a dead connection whose send never completes;
            // cancel() is idempotent so firing both is fine.
            conn.send(content: Data(msg.utf8), completion: .contentProcessed { _ in
                conn.cancel()
            })
            queue.asyncAfter(deadline: .now() + 1) {
                conn.cancel()
            }
        } else {
            connection?.cancel()
        }
        connection = nil
    }

    // MARK: - Receive loop (runs on queue)

    private func scheduleReceive(conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, err in
            guard let self, conn === self.connection else { return }
            // Already on self.queue (NWConnection dispatches callbacks there)
            if let bytes = data, !bytes.isEmpty {
                self.buffer.append(contentsOf: bytes)
                guard self.bufferCount <= self.maxControlBuffer else {
                    self.failConnection("RTSP buffer exceeded \(self.maxControlBuffer) bytes")
                    return
                }
                self.processBuffer()
            }
            // Warm-up child with its first frame on screen: hand the whole
            // session to the owner now that this chunk's parse has quiesced
            // (adopting mid-parse would snapshot a moving buffer cursor). The
            // re-arm below then runs on the owner, completing the migration.
            if self.readyToAdopt, let owner = self.handoverOwner {
                self.readyToAdopt = false
                owner.completeHandover(adopting: self)
            }
            if let e = err {
                Self.dbg("[RTSP] Receive error: \(e.localizedDescription)")
                DispatchQueue.main.async { self.error = e.localizedDescription }
            } else if !isComplete {
                (self.adoptedBy ?? self).scheduleReceive(conn: conn)
            }
        }
    }

    // MARK: - Buffer dispatch

    private var bufferCount: Int { buffer.count - bufferOffset }

    private func compactBuffer() {
        guard bufferOffset > 65_536 else { return }
        buffer.removeFirst(bufferOffset)
        bufferOffset = 0
    }

    private func consumeBytes(_ n: Int) {
        bufferOffset += n
        compactBuffer()
    }

    private func processBuffer() {
        if inRTPMode { processRTP() } else { processRTSPResponses() }
    }

    /// Tear down the connection with an error. Must be called on `queue`.
    private func failConnection(_ message: String) {
        Self.dbg("[RTSP] failConnection: \(message)")
        // Disconnect first: its main-queue hop clears `error`, and the message
        // must land after that so the user actually sees why the stream ended.
        disconnectOnQueue()
        DispatchQueue.main.async { self.error = message }
    }

    // MARK: - RTSP response parser

    private func processRTSPResponses() {
        guard let headerEnd = findHeaderEnd() else {
            // No header terminator yet. If we've buffered more than a sane header
            // could ever be, the endpoint is misbehaving — give up.
            if bufferCount > maxHeaderSize { failConnection("RTSP header exceeded \(maxHeaderSize) bytes") }
            return
        }

        let headerText = String(bytes: buffer[bufferOffset..<headerEnd], encoding: .utf8) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")

        var contentLength = 0
        var newSession    = ""
        var transport     = ""
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": contentLength = Int(parts[1]) ?? 0
            case "session":        newSession = parts[1].components(separatedBy: ";").first ?? parts[1]
            case "transport":      transport = parts[1]
            default: break
            }
        }
        if !newSession.isEmpty { sessionId = newSession }

        // Record the RTP channel the server actually bound for whichever SETUP
        // this response answers, so the interleaved demux matches reality.
        if let ch = RTPParser.interleavedRTPChannel(transport) {
            if awaiting == .setupVideo { videoRTPChannel = ch }
            if awaiting == .setupAudio { audioRTPChannel = ch }
            Self.dbg("[RTSP] \(awaiting) transport channel=\(ch)")
        }

        guard contentLength >= 0, contentLength <= maxContentLength else {
            failConnection("RTSP Content-Length out of range: \(contentLength)")
            return
        }

        let total = headerEnd + contentLength
        guard buffer.count >= total else { return }

        let body: String? = contentLength > 0
            ? String(bytes: buffer[headerEnd..<total], encoding: .utf8)
            : nil

        consumeBytes(total - bufferOffset)

        let statusLine = lines.first ?? ""
        let statusCode = Int(statusLine.components(separatedBy: " ").dropFirst().first ?? "0") ?? 0
        Self.dbg("[RTSP] \(awaiting) reply \(statusCode) (body \(contentLength) bytes)")

        guard (200...299).contains(statusCode) else {
            // Audio is best-effort: if the server rejects the second SETUP, drop
            // the audio track and still PLAY video rather than failing the stream.
            if awaiting == .setupAudio {
                Self.dbg("[RTSP] audio SETUP rejected (\(statusCode)); continuing video-only")
                audioInfo = nil
                sendPlay()
                if bufferCount > 0 { processRTSPResponses() }
                return
            }
            // Anything else is fatal for this session: close the socket rather
            // than leaving an established connection idling with no state to
            // advance to.
            failConnection("RTSP \(statusCode)")
            return
        }

        switch awaiting {
        case .options:
            sendDescribe()
        case .describe:
            let hasVideo = body.map(parseSDP) ?? false
            // A controller that isn't getting video from the camera answers
            // DESCRIBE with audio tracks only. SETUP against the bare URL would
            // never be answered and the tile would spin forever — fail now, so
            // the user sees why and the retry path applies.
            guard hasVideo else {
                describesWithoutVideo += 1
                if describesWithoutVideo < Self.maxDescribesWithoutVideo {
                    Self.dbg("[RTSP] no video track (attempt \(describesWithoutVideo)) — re-DESCRIBE in \(Self.describeRetryDelay)s")
                    let conn = connection
                    queue.asyncAfter(deadline: .now() + Self.describeRetryDelay) { [weak self] in
                        guard let self, conn === self.connection else { return }
                        self.sendDescribe()
                    }
                    return
                }
                failConnection(String(localized: "The controller isn't sending video for this camera right now."))
                return
            }
            sendSetupVideo()
        case .setupVideo:
            // Negotiate the audio track too when the SDP advertised one, so
            // unmuting later needs no reconnect. Otherwise go straight to PLAY.
            if audioInfo != nil { sendSetupAudio() } else { sendPlay() }
        case .setupAudio:
            sendPlay()
        case .play:
            inRTPMode = true
            let hasAudioTrack = audioInfo != nil
            DispatchQueue.main.async {
                self.isConnected = true
                self.hasAudio = hasAudioTrack
            }
            if audioActive { startAudioRenderer() }
            if !buffer.isEmpty { processRTP() }
        }

        if !inRTPMode && bufferCount > 0 { processRTSPResponses() }
    }

    private func findHeaderEnd() -> Int? {
        guard bufferCount >= 4 else { return nil }
        for i in bufferOffset...(buffer.count - 4) where
            buffer[i] == 0x0D && buffer[i+1] == 0x0A && buffer[i+2] == 0x0D && buffer[i+3] == 0x0A {
            return i + 4
        }
        return nil
    }

    // MARK: - RTSP commands

    @discardableResult
    private func nextCSeq() -> Int { cSeq += 1; return cSeq }

    private func send(_ text: String) {
        guard let conn = connection else { return }
        conn.send(content: Data(text.utf8), completion: .idempotent)
    }

    private func sendOptions() {
        awaiting = .options
        let seq = nextCSeq()
        send("OPTIONS \(currentURL!.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\n\r\n")
    }

    private func sendDescribe() {
        awaiting = .describe
        let seq = nextCSeq()
        send("DESCRIBE \(currentURL!.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\nAccept: application/sdp\r\n\r\n")
    }

    /// Reads codec, control and parameter sets from the DESCRIBE body. Returns
    /// whether the SDP advertised a video track at all.
    @discardableResult
    private func parseSDP(_ sdp: String) -> Bool {
        if Self.debugLoggingEnabled {
            // Media lines only, with any URL reduced to scheme://host (a track
            // control can carry the stream token).
            let media = sdp.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.hasPrefix("m=") || $0.hasPrefix("a=rtpmap") || $0.hasPrefix("a=control") || $0.hasPrefix("a=fmtp") }
                .map { $0.replacingOccurrences(of: #"rtsps?://[^/\s]+/\S*"#, with: "<url>", options: .regularExpression) }
                .map { $0.count > 120 ? String($0.prefix(120)) + "…" : $0 }
            Self.dbg("[RTSP] SDP media: " + media.joined(separator: " | "))
        }
        var inVideoSection = false
        var sawVideoTrack = false
        for rawLine in sdp.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                inVideoSection = line.hasPrefix("m=video")
                if inVideoSection { sawVideoTrack = true }
            }
            guard inVideoSection else { continue }
            if line.hasPrefix("a=rtpmap:") {
                let codecStr = line.components(separatedBy: " ").dropFirst().first?
                    .components(separatedBy: "/").first?.uppercased() ?? ""
                if codecStr == "H264" || codecStr == "H265" || codecStr == "HEVC" {
                    codec = (codecStr == "H264") ? "H264" : "H265"
                }
            }
            if line.hasPrefix("a=control:") {
                let ctrl = String(line.dropFirst("a=control:".count))
                if ctrl != "*" && !ctrl.isEmpty { trackControl = ctrl }
            }
            if line.hasPrefix("a=fmtp:") && line.contains("sprop-parameter-sets=") {
                parseSpropParameterSets(line)
            }
        }

        audioInfo = RTPParser.parseAudioTrack(sdp: sdp)
        if let a = audioInfo {
            Self.dbg("[RTSP] audio track: AAC \(a.sampleRate)Hz/\(a.channels)ch control=\(a.trackControl)")
        }
        if !sawVideoTrack { Self.dbg("[RTSP] SDP has no video track") }
        return sawVideoTrack
    }

    private func parseSpropParameterSets(_ fmtpLine: String) {
        guard let r = fmtpLine.range(of: "sprop-parameter-sets=") else { return }
        let val  = String(fmtpLine[r.upperBound...]).split(separator: ";").first.map(String.init)?
                       .trimmingCharacters(in: .whitespaces) ?? ""
        let parts = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2,
              let spsData = Data(base64Encoded: parts[0]),
              let ppsData = Data(base64Encoded: parts[1]) else { return }
        let sps = [UInt8](spsData), pps = [UInt8](ppsData)
        h264SPS = sps; h264PPS = pps
        if let d = makeH264FormatDescription(sps: sps, pps: pps) {
            formatDescription = d
        }
    }

    /// Resolve a track-control string (absolute URL or relative path) to a full URL.
    private func trackURL(for control: String) -> String {
        if control.hasPrefix("rtsps://") || control.hasPrefix("rtsp://") { return control }
        let base = currentURL!.absoluteString
        return base + (control.hasPrefix("/") ? control : "/\(control)")
    }

    private func sendSetupVideo() {
        awaiting = .setupVideo
        let seq = nextCSeq()
        Self.dbg("[RTSP] SETUP video control=\(trackControl.isEmpty ? "<none>" : trackControl) codec=\(codec)")
        // Video RTP/RTCP on interleaved channels 0/1.
        send("SETUP \(trackURL(for: trackControl)) RTSP/1.0\r\nCSeq: \(seq)\r\n" +
             "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n")
    }

    private func sendSetupAudio() {
        guard let audio = audioInfo else { sendPlay(); return }
        awaiting = .setupAudio
        let seq = nextCSeq()
        // Audio RTP/RTCP on interleaved channels 2/3. Include the Session from the
        // video SETUP so the server aggregates both tracks under one session.
        send("SETUP \(trackURL(for: audio.trackControl)) RTSP/1.0\r\nCSeq: \(seq)\r\n" +
             "Transport: RTP/AVP/TCP;unicast;interleaved=2-3\r\nSession: \(sessionId)\r\n\r\n")
    }

    private func sendPlay() {
        awaiting = .play
        let seq = nextCSeq()
        send("PLAY \(currentURL!.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\nSession: \(sessionId)\r\nRange: npt=0.000-\r\n\r\n")
    }

    // MARK: - RTP interleaved framing  (RFC 2326 §10.12)

    private func processRTP() {
        while bufferCount >= 4 {
            let pos = bufferOffset
            guard buffer[pos] == 0x24 else {
                // Skip stray bytes until next '$'
                var found = false
                for i in (pos + 1) ..< buffer.count where buffer[i] == 0x24 {
                    bufferOffset = i; found = true; break
                }
                if !found { buffer.removeAll(keepingCapacity: true); bufferOffset = 0; return }
                continue
            }
            let channel = buffer[pos + 1]
            let length  = Int(buffer[pos + 2]) << 8 | Int(buffer[pos + 3])
            guard pos + 4 + length <= buffer.count else { break }
            if channel == videoRTPChannel {
                handleRTP(pos + 4, length: length)
            } else if audioInfo != nil && channel == audioRTPChannel {
                handleAudioRTP(pos + 4, length: length)
            }
            bufferOffset = pos + 4 + length
        }
        compactBuffer()
    }

    // MARK: - RTP packet dispatcher (zero-copy from buffer)

    private func handleRTP(_ offset: Int, length: Int) {
        guard length > 12 else { return }
        let flags     = buffer[offset]
        let marker    = (buffer[offset + 1] & 0x80) != 0
        let csrcCount = Int(flags & 0x0F)
        let headerLen = 12 + csrcCount * 4
        guard length > headerLen else { return }
        guard let (payloadStart, end) = rtpPayloadBounds(flags: flags,
                                                         payloadStart: offset + headerLen,
                                                         end: offset + length) else { return }
        let payloadLen = end - payloadStart
        if codec == "H265" {
            handleH265RTP(payloadStart, length: payloadLen)
        } else {
            handleH264RTP(payloadStart, length: payloadLen)
        }
        if marker && !pendingNALs.isEmpty {
            if let fmt = formatDescription {
                enqueueAccessUnit(pendingNALs, formatDescription: fmt)
            }
            pendingNALs.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Audio RTP → AAC access units (RFC 3640, AAC-hbr)

    /// Depacketize an audio RTP packet and feed its AAC access units to the
    /// renderer. No-ops unless this client is the focused stream (renderer == nil).
    /// Cross-packet fragmented AUs are reassembled by the stateful depacketizer.
    private func handleAudioRTP(_ offset: Int, length: Int) {
        guard let renderer = audioRenderer, length > 12 else { return }
        let flags     = buffer[offset]
        let marker    = (buffer[offset + 1] & 0x80) != 0
        let csrcCount = Int(flags & 0x0F)
        guard let (payloadStart, end) = rtpPayloadBounds(flags: flags,
                                                         payloadStart: offset + 12 + csrcCount * 4,
                                                         end: offset + length) else { return }

        let payload = Array(buffer[payloadStart ..< end])
        let aus = aacDepacketizer?.receive(payload, marker: marker) ?? []
        if !aus.isEmpty, !audioLoggedFirstAU {
            audioLoggedFirstAU = true
            Self.dbg("[RTSP] first audio AU enqueued (\(aus[0].count) bytes)")
        }
        for au in aus { renderer.enqueue(au) }
    }

    /// Applies the RTP header's X (extension) and P (padding) bits to a packet's
    /// payload bounds (RFC 3550 §5.1). Returns nil when nothing is left. Shared
    /// by the video and audio paths so both handle the same packets.
    private func rtpPayloadBounds(flags: UInt8, payloadStart: Int, end: Int) -> (Int, Int)? {
        var start = payloadStart
        var end = end
        // Padding: the last byte counts the trailing padding bytes, itself included.
        if (flags & 0x20) != 0 {
            guard end > start else { return nil }
            let padding = Int(buffer[end - 1])
            guard padding > 0, end - padding >= start else { return nil }
            end -= padding
        }
        // Header extension: 16-bit profile, 16-bit length in 32-bit words.
        if (flags & 0x10) != 0 {
            guard start + 4 <= end else { return nil }
            let extWords = Int(buffer[start + 2]) << 8 | Int(buffer[start + 3])
            start += 4 + extWords * 4
        }
        guard start < end else { return nil }
        return (start, end)
    }

    // MARK: - H.264 RTP → NAL units (RFC 6184)

    private func handleH264RTP(_ off: Int, length: Int) {
        guard length > 0 else { return }
        let nalType = buffer[off] & 0x1F

        switch nalType {
        case 1...23:
            emitNAL(Array(buffer[off ..< off + length]))

        case 24:    // STAP-A
            var i = off + 1
            let end = off + length
            while i + 2 <= end {
                let len = Int(buffer[i]) << 8 | Int(buffer[i + 1]); i += 2
                guard i + len <= end else { break }
                emitNAL(Array(buffer[i ..< i + len])); i += len
            }

        case 28:    // FU-A
            guard length > 2 else { return }
            let fuInd  = buffer[off]
            let fuHdr  = buffer[off + 1]
            let (isStart, isEnd, _) = RTPParser.parseFUAFlags(fuHdr)
            if isStart {
                fuBuffer = [RTPParser.reconstructH264FUAHeader(fuIndicator: fuInd, fuHeader: fuHdr)]
                fuBuffer!.append(contentsOf: buffer[(off + 2) ..< (off + length)])
            } else {
                fuBuffer?.append(contentsOf: buffer[(off + 2) ..< (off + length)])
            }
            dropFragmentIfOversized()
            if isEnd, let complete = fuBuffer { emitNAL(complete); fuBuffer = nil }

        default: break
        }
    }

    // MARK: - H.265 RTP → NAL units (RFC 7798)

    private func handleH265RTP(_ off: Int, length: Int) {
        guard length >= 2 else { return }
        let nalType = (buffer[off] >> 1) & 0x3F

        switch nalType {
        case 49:    // Fragmentation Unit
            guard length >= 3 else { return }
            let fuHdr   = buffer[off + 2]
            let (isStart, isEnd, _) = RTPParser.parseH265FUFlags(fuHdr)
            let (hdr0, hdr1) = RTPParser.reconstructH265FUHeader(byte0: buffer[off], byte1: buffer[off + 1], fuHeader: fuHdr)
            if isStart {
                fuBuffer = [hdr0, hdr1]
                fuBuffer!.append(contentsOf: buffer[(off + 3) ..< (off + length)])
            } else {
                fuBuffer?.append(contentsOf: buffer[(off + 3) ..< (off + length)])
            }
            dropFragmentIfOversized()
            if isEnd, let complete = fuBuffer { emitNAL(complete); fuBuffer = nil }

        case 48:    // Aggregation Packet
            var i = off + 2
            let end = off + length
            while i + 2 <= end {
                let len = Int(buffer[i]) << 8 | Int(buffer[i + 1]); i += 2
                guard i + len <= end else { break }
                emitNAL(Array(buffer[i ..< i + len])); i += len
            }

        default:
            emitNAL(Array(buffer[off ..< off + length]))
        }
    }

    /// Queue-only. Discards a fragmented NAL whose end never came (the stream
    /// resyncs at the next fragment start).
    private func dropFragmentIfOversized() {
        if let count = fuBuffer?.count, count > maxReassemblyBytes {
            Self.dbg("[RTSP] dropping fragmented NAL over \(maxReassemblyBytes) bytes")
            fuBuffer = nil
        }
    }

    private func emitNAL(_ nal: [UInt8]) {
        guard !nal.isEmpty else { return }

        if codec == "H265", nal.count >= 2 {
            switch RTPParser.classifyH265NAL(nal[0]) {
            case .vps: hevcVPS = nal
            case .sps: hevcSPS = nal
            case .pps: hevcPPS = nal
            default: break
            }
            if formatDescription == nil, let vps = hevcVPS, let sps = hevcSPS, let pps = hevcPPS {
                formatDescription = makeHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
                if let fd = formatDescription {
                    let dims = CMVideoFormatDescriptionGetDimensions(fd)
                    let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                    DispatchQueue.main.async { self.videoDimensions = size }
                }
            }
            // Don't enqueue parameter sets as picture data.
            switch RTPParser.classifyH265NAL(nal[0]) {
            case .vps, .sps, .pps: return
            default: break
            }
        } else {
            switch RTPParser.classifyH264NAL(nal[0]) {
            case .sps: h264SPS = nal
            case .pps: h264PPS = nal
            default: break
            }
            if formatDescription == nil, let sps = h264SPS, let pps = h264PPS {
                formatDescription = makeH264FormatDescription(sps: sps, pps: pps)
                if let fd = formatDescription {
                    let dims = CMVideoFormatDescriptionGetDimensions(fd)
                    let size = CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                    DispatchQueue.main.async { self.videoDimensions = size }
                }
            }
            // Don't enqueue parameter sets or access-unit delimiters as picture data.
            switch RTPParser.classifyH264NAL(nal[0]) {
            case .sps, .pps, .aud: return
            default: break
            }
        }

        guard formatDescription != nil else { return }
        pendingNALs.append(nal)
        // An access unit whose marker bit never arrives would otherwise pile up
        // forever; a real AU is a handful of NALs and well under the cap.
        if pendingNALs.count > 512 || pendingNALs.reduce(0, { $0 + $1.count }) > maxReassemblyBytes {
            Self.dbg("[RTSP] dropping oversized access unit (\(pendingNALs.count) NALs)")
            pendingNALs.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - AVCC/HVCC → CMSampleBuffer → display layer

    /// Whether an access unit carries a keyframe NAL (H.264 IDR / HEVC IRAP)
    /// anywhere — SEI/AUD NALs may precede it. Queue-only — reads `codec`.
    private func isKeyframeAccessUnit(_ nals: [[UInt8]]) -> Bool {
        RTPParser.accessUnitContainsKeyframe(nals, hevc: codec == "H265")
    }

    private func enqueueAccessUnit(_ nals: [[UInt8]], formatDescription: CMVideoFormatDescription) {
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

        let totalSize = nals.reduce(0) { $0 + 4 + $1.count }
        guard totalSize > 0, let mem = malloc(totalSize) else { return }
        let ptr = mem.bindMemory(to: UInt8.self, capacity: totalSize)
        var offset = 0
        for nal in nals {
            let len = nal.count
            ptr[offset]     = UInt8((len >> 24) & 0xFF)
            ptr[offset + 1] = UInt8((len >> 16) & 0xFF)
            ptr[offset + 2] = UInt8((len >>  8) & 0xFF)
            ptr[offset + 3] = UInt8( len        & 0xFF)
            memcpy(ptr + offset + 4, nal, len)
            offset += 4 + len
        }

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

    private func makeH264FormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
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

    private func makeHEVCFormatDescription(vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
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

import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

/// RTSP/RTP client using NWConnection.
/// All data processing runs on a dedicated serial queue to keep the main thread free.
/// Concurrency: `@unchecked Sendable` because the compiler cannot see the
/// discipline — every stored property below is touched only on `queue`
/// ("queue-only"), the `@Published` ones only on the main thread, and the
/// handful of cross-thread values are locked. Keep it that way when adding
/// state.
/// The class is split across files by stage — handshake (`+RTSP`), RTP
/// depacketising (`+RTP`), decode/display (`+Decode`), seamless switching
/// (`+Handover`) and snapshots (`+Snapshot`) — so its members are module-
/// internal rather than private; the "queue-only" notes say who may touch them.
/// Only @Published property updates are dispatched to the main thread for SwiftUI.
/// AVSampleBufferDisplayLayer.enqueue() is thread-safe and called from the processing queue.
///
/// Quality switches are seamless (`switchStream(to:completion:)`): the current
/// session keeps painting while a hidden child client — sharing this queue and
/// display layer — connects and decodes the new stream's first frame; that
/// frame replaces the picture in place and the child's session is adopted
/// wholesale. Mirrors the .NET `VideoStreamClient` double-buffered switching.
final class RTSPClient: ObservableObject, @unchecked Sendable {

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

    let queue: DispatchQueue

    // MARK: - Resource limits (defend against a hostile/buggy endpoint)
    // RTSP control responses (incl. SDP) are small; an unbounded Content-Length or
    // a header terminator that never arrives must not balloon memory.
    let maxControlBuffer = 8 * 1024 * 1024   // hard ceiling on the receive buffer
    let maxContentLength = 4 * 1024 * 1024   // reject larger Content-Length outright
    let maxHeaderSize    = 64 * 1024         // give up scanning for \r\n\r\n past this
    /// Ceiling on a single reassembled NAL (fragmentation units) and on the
    /// NALs pending for one access unit. A stream whose fragment end or marker
    /// bit never arrives must not grow memory without bound — drop and resync.
    let maxReassemblyBytes = 4 * 1024 * 1024

    // MARK: - State (queue-only)

    var connection:  NWConnection?
    var currentURL:  URL?
    var pinKey:      String?             // certificate-pin identity for currentURL
    var buffer       = [UInt8]()
    var bufferOffset = 0          // read cursor; compact when > 64 KB
    var inRTPMode    = false
    var cSeq         = 0
    var sessionId    = ""
    var trackControl = ""

    /// Which RTSP request we last sent and are awaiting a response for. Requests
    /// are strictly sequential (one outstanding at a time), so this drives the
    /// setup handshake instead of matching on the bare CSeq counter.
    enum RTSPRequest { case options, describe, setupVideo, setupAudio, play }
    var awaiting: RTSPRequest = .options
    /// DESCRIBE answers seen without a video track on this session. The
    /// controller can publish a freshly allocated stream before the camera's
    /// video channel is flowing, so a few re-DESCRIBEs are tried before the
    /// session is failed.
    var describesWithoutVideo = 0
    static let maxDescribesWithoutVideo = 3
    static let describeRetryDelay: TimeInterval = 1.0
    var audioInfo: RTPParser.SDPAudioInfo?

    /// Interleaved RTP channels actually assigned by the server's SETUP response
    /// Transport header. We propose 0-1 (video) and 2-3 (audio), but the server is
    /// free to renumber, so we read the channel back rather than assume it.
    var videoRTPChannel: UInt8 = 0
    var audioRTPChannel: UInt8 = 2

    var codec            = "H264"
    var fuBuffer:          [UInt8]?
    /// Set on the queue when the TLS verify block rejected the controller's
    /// certificate, so the generic connection-failed text that follows doesn't
    /// overwrite the actionable "certificate changed" message.
    var certificateRejected = false
    var formatDescription: CMVideoFormatDescription?
    var sequenceNumber:    Int64 = 0

    var hevcVPS: [UInt8]?
    var hevcSPS: [UInt8]?
    var hevcPPS: [UInt8]?
    var h264SPS: [UInt8]?
    var h264PPS: [UInt8]?

    var pendingNALs: [[UInt8]] = []
    var hasFrameSignalled = false   // queue-only: gates the one-shot hasFrame publish

    // Render pause (stream keep-alive grace) — all queue-only. While paused,
    // access units are buffered instead of enqueued so the display layer does
    // no decode work for a hidden panel; see setRenderPaused(_:).
    var renderPaused = false
    var pausedGOP = PausedGOPBuffer()
    var awaitingKeyframeAfterResume = false

    // Audio (queue-only). The renderer exists only while this client is the
    // focused stream; muting toggles its output without tearing it down.
    var audioRenderer: AudioRenderer?
    var audioActive   = false       // true while this client is focused
    var audioMuted    = true
    var aacDepacketizer: RTPParser.AACDepacketizer?
    var audioLoggedFirstAU = false   // queue-only: one-shot enqueue log

    // Snapshot capture. The display layer decodes internally and can't be read
    // back, so when active we run a parallel VTDecompressionSession that keeps
    // only the latest decoded frame. Session state is queue-only; the frame
    // itself is read from the main thread, so it's guarded by a lock.
    // Enabled only for the focused camera to avoid decoding every grid tile.
    var captureActive = false                          // queue-only
    var decompressionSession: VTDecompressionSession?  // queue-only
    var decompressionFormat: CMVideoFormatDescription? // queue-only
    let latestFrameLock = NSLock()
    var latestPixelBuffer: CVImageBuffer?              // lock-guarded
    var captureLoggedFirstFrame = false               // one-shot debug log
    var captureSeenKeyframe = false                   // gate decode until first IDR

    // Seamless quality switch (queue-only). switchStream(to:) warms the
    // next-quality session up in a hidden child client on this same serial
    // queue while this one keeps painting; the child's whole session is
    // adopted at its first enqueued frame (completeHandover). Mirrors the
    // .NET VideoStreamClient's generation-gated double-buffering.
    weak var handoverOwner: RTSPClient?    // set only on warm-up children
    weak var adoptedBy: RTSPClient?        // routes the in-flight receive after adoption
    var handoverChild: RTSPClient?         // set only on owners
    var handoverCompletion: (@MainActor @Sendable (Bool) -> Void)?
    var handoverGen = 0                    // guards the grace timeout
    var readyToAdopt = false               // child: first frame enqueued
    /// How long a warm-up may take before the switch is abandoned and the
    /// current stream simply keeps playing (the pre-handover behavior).
    static let handoverGrace: TimeInterval = 10

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
    init(handoverFor owner: RTSPClient) {
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
    static let debugLoggingViaEnvironment =
        ProcessInfo.processInfo.environment["QUICKPROTECT_DEBUG_LOG"] == "1"
    static let maxLogBytes: UInt64 = 1_048_576  // 1 MB, truncated on rollover

    static func log(_ msg: String) { dbg(msg) }

    /// Scheme, host and port only. The path of a stream URL is a bearer token
    /// for live video and must never reach the log.
    static func redactedDescription(of url: URL) -> String {
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(url.scheme ?? "?")://\(url.host ?? "?")\(port)/…"
    }
    static func dbg(_ msg: String) {
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
    /// `pinKey` is the identity the server's certificate pin is stored under —
    /// the configured controller's, so video and API share one pin (see
    /// `ControllerAddress.pinKey`). Nil pins by the URL's host, which is what
    /// tests against a local server want.
    func connect(to url: URL, pinKey: String? = nil, keepLastFrame: Bool = false) {
        Self.dbg("[RTSP] connect called: \(Self.redactedDescription(of: url))")
        DispatchQueue.main.async { self.hasFrame = false }
        queue.async { [self] in
            disconnectOnQueue(flushDisplay: !keepLastFrame)
            currentURL       = url
            self.pinKey      = pinKey
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
            let pinKey = self.pinKey ?? host
            sec_protocol_options_set_verify_block(
                tlsOpts.securityProtocolOptions,
                { [weak self] _, secTrust, complete in
                    let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                    let ok = CertificateTrust.evaluate(pinKey: pinKey, serverHost: host, trust: trust)
                    if !ok, let self {
                        self.certificateRejected = true
                        DispatchQueue.main.async {
                            self.error = String(localized: "The controller's certificate changed. Open Settings to review and trust it.")
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
    func installStateHandler(on conn: NWConnection) {
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
    func startAudioRenderer() {
        guard audioRenderer == nil, let audio = audioInfo else { return }
        audioLoggedFirstAU = false
        audioRenderer = AudioRenderer(audio: audio, muted: audioMuted)
        aacDepacketizer = RTPParser.AACDepacketizer(
            sizeLength: audio.sizeLength, indexLength: audio.indexLength,
            indexDeltaLength: audio.indexDeltaLength)
        Self.dbg("[RTSP] audio renderer \(audioRenderer == nil ? "FAILED" : "started") muted=\(audioMuted)")
    }

    // MARK: - Internal disconnect (must be called on queue)

    func disconnectOnQueue(flushDisplay: Bool = true) {
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
    func retireCurrentSessionOnQueue() {
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

    func scheduleReceive(conn: NWConnection) {
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

    var bufferCount: Int { buffer.count - bufferOffset }

    func compactBuffer() {
        guard bufferOffset > 65_536 else { return }
        buffer.removeFirst(bufferOffset)
        bufferOffset = 0
    }

    func consumeBytes(_ n: Int) {
        bufferOffset += n
        compactBuffer()
    }

    func processBuffer() {
        if inRTPMode { processRTP() } else { processRTSPResponses() }
    }

    /// Tear down the connection with an error. Must be called on `queue`.
    func failConnection(_ message: String) {
        Self.dbg("[RTSP] failConnection: \(message)")
        // Disconnect first: its main-queue hop clears `error`, and the message
        // must land after that so the user actually sees why the stream ended.
        disconnectOnQueue()
        DispatchQueue.main.async { self.error = message }
    }

}

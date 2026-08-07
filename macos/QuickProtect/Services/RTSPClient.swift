import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

/// RTSP/RTP client using NWConnection.
/// All data processing runs on a dedicated serial queue to keep the main thread free.
/// Only @Published property updates are dispatched to the main thread for SwiftUI.
/// AVSampleBufferDisplayLayer.enqueue() is thread-safe and called from the processing queue.
final class RTSPClient: ObservableObject {

    // MARK: - Published (main-thread only)

    @Published var displayLayer = AVSampleBufferDisplayLayer()
    @Published var isConnected  = false
    /// True once the first frame has actually been enqueued for display.
    /// `isConnected` flips at RTP setup — before any picture exists — so the UI
    /// keys its "now showing video" state off this instead to avoid a black gap.
    @Published var hasFrame     = false
    @Published var error: String?
    @Published var videoDimensions: CGSize = .zero
    /// True once an AAC audio track has been negotiated for this stream.
    @Published var hasAudio = false
    /// Whether audio output is muted. Mirrors the global speaker preference.
    @Published var isMuted = true

    // MARK: - Dedicated processing queue
    // All mutable state below is accessed exclusively on this queue.
    // NWConnection callbacks also fire on this queue.

    private let queue = DispatchQueue(label: "com.quickprotect.rtsp", qos: .userInitiated)

    // MARK: - Resource limits (defend against a hostile/buggy endpoint)
    // RTSP control responses (incl. SDP) are small; an unbounded Content-Length or
    // a header terminator that never arrives must not balloon memory.
    private let maxControlBuffer = 8 * 1024 * 1024   // hard ceiling on the receive buffer
    private let maxContentLength = 4 * 1024 * 1024   // reject larger Content-Length outright
    private let maxHeaderSize    = 64 * 1024         // give up scanning for \r\n\r\n past this

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
    private var audioInfo: RTPParser.SDPAudioInfo?

    /// Interleaved RTP channels actually assigned by the server's SETUP response
    /// Transport header. We propose 0-1 (video) and 2-3 (audio), but the server is
    /// free to renumber, so we read the channel back rather than assume it.
    private var videoRTPChannel: UInt8 = 0
    private var audioRTPChannel: UInt8 = 2

    private var codec            = "H264"
    private var fuBuffer:          [UInt8]?
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

    // MARK: - Init

    init() {
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
    /// Callers must not pass credential material (tokens, passwords) here.
    static let debugLoggingEnabled = UserDefaults.standard.bool(forKey: "QPDebugLogging")
    private static let maxLogBytes: UInt64 = 1_048_576  // 1 MB, truncated on rollover

    static func log(_ msg: String) { dbg(msg) }
    private static func dbg(_ msg: String) {
        guard debugLoggingEnabled else { return }
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
        Self.dbg("[RTSP] connect called: \(url)")
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

            guard let host = url.host,
                  let rawPort = url.port,
                  let port = NWEndpoint.Port(rawValue: UInt16(rawPort))
            else {
                DispatchQueue.main.async { self.error = "Invalid RTSP URL: \(url)" }
                return
            }

            let tlsOpts = NWProtocolTLS.Options()
            // Trust-on-first-use pinning, same policy as the HTTPS path: accept the
            // self-signed controller cert on first sight, reject if its key later
            // changes (possible MITM). Never writes to the system trust store.
            sec_protocol_options_set_verify_block(
                tlsOpts.securityProtocolOptions,
                { [weak self] _, secTrust, complete in
                    let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                    let ok = CertificateTrust.evaluate(host: host, trust: trust)
                    if !ok {
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
                        DispatchQueue.main.async { self.error = e.localizedDescription }
                    case .cancelled:
                        DispatchQueue.main.async { self.isConnected = false }
                    default: break
                    }
                }
            }

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
            if let e = err {
                Self.dbg("[RTSP] Receive error: \(e.localizedDescription)")
                DispatchQueue.main.async { self.error = e.localizedDescription }
            } else if !isComplete {
                self.scheduleReceive(conn: conn)
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
        DispatchQueue.main.async { self.error = message }
        disconnectOnQueue()
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
            DispatchQueue.main.async { self.error = "RTSP \(statusCode)" }
            return
        }

        switch awaiting {
        case .options:
            sendDescribe()
        case .describe:
            if let sdp = body { parseSDP(sdp) }
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

    private func parseSDP(_ sdp: String) {
        var inVideoSection = false
        for rawLine in sdp.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") { inVideoSection = line.hasPrefix("m=video") }
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
        let marker    = (buffer[offset + 1] & 0x80) != 0
        let csrcCount = Int(buffer[offset] & 0x0F)
        let headerLen = 12 + csrcCount * 4
        guard length > headerLen else { return }
        let payloadStart = offset + headerLen
        let payloadLen   = length - headerLen
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
        var payloadStart = offset + 12 + csrcCount * 4
        let end = offset + length
        // Skip an RTP header extension if the X bit is set.
        if (flags & 0x10) != 0, payloadStart + 4 <= end {
            let extWords = Int(buffer[payloadStart + 2]) << 8 | Int(buffer[payloadStart + 3])
            payloadStart += 4 + extWords * 4
        }
        guard payloadStart < end else { return }

        let payload = Array(buffer[payloadStart ..< end])
        let aus = aacDepacketizer?.receive(payload, marker: marker) ?? []
        if !aus.isEmpty, !audioLoggedFirstAU {
            audioLoggedFirstAU = true
            Self.dbg("[RTSP] first audio AU enqueued (\(aus[0].count) bytes)")
        }
        for au in aus { renderer.enqueue(au) }
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
    }

    // MARK: - AVCC/HVCC → CMSampleBuffer → display layer

    /// Whether an access unit starts with a keyframe NAL (H.264 IDR / HEVC
    /// IRAP). Queue-only — reads `codec`.
    private func isKeyframeAccessUnit(_ nals: [[UInt8]]) -> Bool {
        guard let firstNAL = nals.first, !firstNAL.isEmpty else { return false }
        if codec == "H265", firstNAL.count >= 2 {
            if case .keyframe = RTPParser.classifyH265NAL(firstNAL[0]) { return true }
            return false
        }
        return RTPParser.classifyH264NAL(firstNAL[0]) == .idr
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
            displayLayer.enqueue(sb)
            if captureActive { decodeForCapture(sb, format: formatDescription, isKeyframe: isKeyframe) }
            if !hasFrameSignalled {
                hasFrameSignalled = true
                DispatchQueue.main.async { self.hasFrame = true }
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

import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - RTSP handshake: response parsing and the OPTIONS/DESCRIBE/SETUP/PLAY
// command sequence (RFC 2326).

extension RTSPClient {

    // MARK: - RTSP response parser

    func processRTSPResponses() {
        // Headers first (RTPParser.parseResponseHeader), so a bogus
        // Content-Length is rejected before any body is awaited or buffered.
        guard let head = RTPParser.parseResponseHeader(buffer, from: bufferOffset) else {
            // No header terminator yet. If we've buffered more than a sane header
            // could ever be, the endpoint is misbehaving — give up.
            if bufferCount > maxHeaderSize { failConnection("RTSP header exceeded \(maxHeaderSize) bytes") }
            return
        }

        if let session = head.headers["session"] {
            sessionId = session.components(separatedBy: ";").first ?? session
        }
        // Record the RTP channel the server actually bound for whichever SETUP
        // this response answers, so the interleaved demux matches reality.
        if let transport = head.headers["transport"], let ch = RTPParser.interleavedRTPChannel(transport) {
            if awaiting == .setupVideo { videoRTPChannel = ch }
            if awaiting == .setupAudio { audioRTPChannel = ch }
            Self.dbg("[RTSP] \(awaiting) transport channel=\(ch)")
        }

        let contentLength = head.contentLength
        guard contentLength <= maxContentLength else {
            failConnection("RTSP Content-Length out of range: \(contentLength)")
            return
        }

        // Body still in flight: wait for more bytes.
        guard let response = RTPParser.parseResponse(buffer, from: bufferOffset) else { return }
        consumeBytes(response.totalLength)

        let statusCode = response.statusCode
        let body = response.body
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
            let video = body.flatMap(readSDP)
            let hasVideo = video != nil
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
                failConnection(String(localized: "The controller isn't receiving video from this camera. Restarting the camera in UniFi Protect usually fixes this."))
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

    // MARK: - RTSP commands

    @discardableResult
    func nextCSeq() -> Int { cSeq += 1; return cSeq }

    func send(_ text: String) {
        guard let conn = connection else { return }
        conn.send(content: Data(text.utf8), completion: .idempotent)
    }

    func sendOptions() {
        awaiting = .options
        let seq = nextCSeq()
        send("OPTIONS \(currentURL!.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\n\r\n")
    }

    func sendDescribe() {
        awaiting = .describe
        let seq = nextCSeq()
        send("DESCRIBE \(currentURL!.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\nAccept: application/sdp\r\n\r\n")
    }

    /// Reads codec, control and parameter sets from the DESCRIBE body. Returns
    /// whether the SDP advertised a video track at all.
    @discardableResult
    /// Reads the DESCRIBE body through RTPParser: audio track info is kept,
    /// the video track (codec, control, in-SDP H.264 parameter sets) is applied
    /// to this session. Returns nil when the SDP advertises no decodable video.
    func readSDP(_ sdp: String) -> RTPParser.SDPVideoInfo? {
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

        audioInfo = RTPParser.parseAudioTrack(sdp: sdp)
        if let a = audioInfo {
            Self.dbg("[RTSP] audio track: AAC \(a.sampleRate)Hz/\(a.channels)ch control=\(a.trackControl)")
        }

        guard let video = RTPParser.parseVideoTrack(sdp: sdp) else {
            Self.dbg("[RTSP] SDP has no video track")
            return nil
        }
        codec = video.codec
        trackControl = video.trackControl
        if let sps = video.spropSPS, let pps = video.spropPPS {
            h264SPS = sps; h264PPS = pps
            adoptFormatDescription(makeH264FormatDescription(sps: sps, pps: pps))
        }
        return video
    }

    /// Resolve a track-control string (absolute URL or relative path) to a full URL.
    func trackURL(for control: String) -> String {
        if control.hasPrefix("rtsps://") || control.hasPrefix("rtsp://") { return control }
        let base = currentURL!.absoluteString
        return base + (control.hasPrefix("/") ? control : "/\(control)")
    }

    func sendSetupVideo() {
        awaiting = .setupVideo
        let seq = nextCSeq()
        Self.dbg("[RTSP] SETUP video control=\(trackControl.isEmpty ? "<none>" : trackControl) codec=\(codec)")
        // Video RTP/RTCP on interleaved channels 0/1.
        send("SETUP \(trackURL(for: trackControl)) RTSP/1.0\r\nCSeq: \(seq)\r\n" +
             "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n")
    }

    func sendSetupAudio() {
        guard let audio = audioInfo else { sendPlay(); return }
        awaiting = .setupAudio
        let seq = nextCSeq()
        // Audio RTP/RTCP on interleaved channels 2/3. Include the Session from the
        // video SETUP so the server aggregates both tracks under one session.
        send("SETUP \(trackURL(for: audio.trackControl)) RTSP/1.0\r\nCSeq: \(seq)\r\n" +
             "Transport: RTP/AVP/TCP;unicast;interleaved=2-3\r\nSession: \(sessionId)\r\n\r\n")
    }

    func sendPlay() {
        awaiting = .play
        let seq = nextCSeq()
        send("PLAY \(currentURL!.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\nSession: \(sessionId)\r\nRange: npt=0.000-\r\n\r\n")
    }
}

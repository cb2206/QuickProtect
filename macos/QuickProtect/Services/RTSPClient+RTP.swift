import Foundation
import Network
import AVFoundation
import CoreMedia
import VideoToolbox

// MARK: - RTP: interleaved framing, packet dispatch, AAC/H.264/H.265
// depacketising into access units (RFC 3640, 6184, 7798).

extension RTSPClient {

    // MARK: - RTP interleaved framing  (RFC 2326 §10.12)

    func processRTP() {
        // RTPParser walks the `$`-framed interleaved stream (offsets only — no
        // copies) and reports how far it got: a partial frame at the tail stays
        // in the buffer for the next receive.
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: buffer, offset: bufferOffset)
        for frame in frames {
            if frame.channel == videoRTPChannel {
                handleRTP(frame.payloadOffset, length: frame.payloadLength)
            } else if audioInfo != nil && frame.channel == audioRTPChannel {
                handleAudioRTP(frame.payloadOffset, length: frame.payloadLength)
            }
        }
        bufferOffset = consumed
        if bufferOffset >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            bufferOffset = 0
        } else {
            compactBuffer()
        }
    }

    // MARK: - RTP packet dispatcher (zero-copy from buffer)

    func handleRTP(_ offset: Int, length: Int) {
        guard let (marker, payloadStart, end) = RTPParser.rtpPayloadRange(buffer, offset: offset, length: length)
        else { return }
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
    func handleAudioRTP(_ offset: Int, length: Int) {
        guard let renderer = audioRenderer,
              let (marker, payloadStart, end) = RTPParser.rtpPayloadRange(buffer, offset: offset, length: length)
        else { return }

        let payload = Array(buffer[payloadStart ..< end])
        let aus = aacDepacketizer?.receive(payload, marker: marker) ?? []
        if !aus.isEmpty, !audioLoggedFirstAU {
            audioLoggedFirstAU = true
            Self.dbg("[RTSP] first audio AU enqueued (\(aus[0].count) bytes)")
        }
        for au in aus { renderer.enqueue(au) }
    }

    // MARK: - H.264 RTP → NAL units (RFC 6184)

    func handleH264RTP(_ off: Int, length: Int) {
        guard length > 0 else { return }
        let nalType = buffer[off] & 0x1F

        switch nalType {
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

        default:
            // Single NAL and STAP-A aggregation — the stateless cases live in
            // RTPParser (and its tests); anything it doesn't know is skipped.
            for nal in RTPParser.parseH264Payload(Array(buffer[off ..< off + length])) { emitNAL(nal) }
        }
    }

    // MARK: - H.265 RTP → NAL units (RFC 7798)

    func handleH265RTP(_ off: Int, length: Int) {
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

        default:
            // Single NAL and AP aggregation — stateless, handled by RTPParser.
            for nal in RTPParser.parseH265Payload(Array(buffer[off ..< off + length])) { emitNAL(nal) }
        }
    }

    /// Queue-only. Discards a fragmented NAL whose end never came (the stream
    /// resyncs at the next fragment start).
    func dropFragmentIfOversized() {
        if let count = fuBuffer?.count, count > maxReassemblyBytes {
            Self.dbg("[RTSP] dropping fragmented NAL over \(maxReassemblyBytes) bytes")
            fuBuffer = nil
        }
    }

    func emitNAL(_ nal: [UInt8]) {
        guard !nal.isEmpty else { return }

        if codec == "H265", nal.count >= 2 {
            switch RTPParser.classifyH265NAL(nal[0]) {
            case .vps: hevcVPS = nal
            case .sps: hevcSPS = nal
            case .pps: hevcPPS = nal
            default: break
            }
            if formatDescription == nil, let vps = hevcVPS, let sps = hevcSPS, let pps = hevcPPS {
                adoptFormatDescription(makeHEVCFormatDescription(vps: vps, sps: sps, pps: pps))
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
                adoptFormatDescription(makeH264FormatDescription(sps: sps, pps: pps))
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
}

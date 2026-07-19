import Foundation

/// Pure-logic helpers for RTP/RTSP parsing, extracted from RTSPClient for testability.
/// All methods are static and side-effect free.
enum RTPParser {

    // MARK: - RTP interleaved frame extraction

    struct InterleavedFrame {
        let channel: UInt8
        let payloadOffset: Int   // offset into original buffer
        let payloadLength: Int
        let markerBit: Bool
    }

    /// Extract `$`-delimited RTP interleaved frames from a buffer.
    /// Returns frames found and the number of bytes consumed.
    static func extractInterleavedFrames(from buffer: [UInt8], offset: Int) -> (frames: [InterleavedFrame], consumed: Int) {
        var frames: [InterleavedFrame] = []
        var pos = offset
        while pos + 4 <= buffer.count {
            guard buffer[pos] == 0x24 else {
                // Skip stray bytes to next '$'
                var found = false
                for i in (pos + 1)..<buffer.count where buffer[i] == 0x24 {
                    pos = i; found = true; break
                }
                if !found { return (frames, buffer.count) }
                continue
            }
            let channel = buffer[pos + 1]
            let length  = Int(buffer[pos + 2]) << 8 | Int(buffer[pos + 3])
            guard pos + 4 + length <= buffer.count else { break }

            // Extract marker bit from RTP header (byte 1, bit 7)
            var marker = false
            if length > 1 {
                marker = (buffer[pos + 4 + 1] & 0x80) != 0
            }
            frames.append(InterleavedFrame(channel: channel, payloadOffset: pos + 4, payloadLength: length, markerBit: marker))
            pos = pos + 4 + length
        }
        return (frames, pos)
    }

    // MARK: - RTP header parsing

    /// Parse RTP header: returns (markerBit, headerLength) or nil if invalid.
    static func parseRTPHeader(_ buffer: [UInt8], offset: Int, length: Int) -> (marker: Bool, headerLength: Int)? {
        guard length > 12 else { return nil }
        let marker = (buffer[offset + 1] & 0x80) != 0
        let csrcCount = Int(buffer[offset] & 0x0F)
        let headerLen = 12 + csrcCount * 4
        guard length > headerLen else { return nil }
        return (marker, headerLen)
    }

    // MARK: - H.264 NAL parsing (RFC 6184)

    /// Parse H.264 RTP payload into NAL units.
    static func parseH264Payload(_ payload: [UInt8]) -> [[UInt8]] {
        guard !payload.isEmpty else { return [] }
        let nalType = payload[0] & 0x1F

        switch nalType {
        case 1...23:    // Single NAL
            return [payload]

        case 24:        // STAP-A
            return parseSTAPA(payload)

        default:
            return []   // FU-A (28) handled statefully, others ignored
        }
    }

    /// Parse STAP-A aggregation packet (H.264 type 24).
    static func parseSTAPA(_ payload: [UInt8]) -> [[UInt8]] {
        var nals: [[UInt8]] = []
        var i = 1
        while i + 2 <= payload.count {
            let len = Int(payload[i]) << 8 | Int(payload[i + 1]); i += 2
            guard i + len <= payload.count else { break }
            nals.append(Array(payload[i..<(i + len)])); i += len
        }
        return nals
    }

    // MARK: - H.264 FU-A reassembly

    /// Reconstruct the single-byte H.264 NAL header from FU-A fields.
    static func reconstructH264FUAHeader(fuIndicator: UInt8, fuHeader: UInt8) -> UInt8 {
        let origType = fuHeader & 0x1F
        return (fuIndicator & 0xE0) | origType
    }

    /// Parse FU-A flags: (isStart, isEnd, nalType)
    static func parseFUAFlags(_ fuHeader: UInt8) -> (isStart: Bool, isEnd: Bool, nalType: UInt8) {
        return ((fuHeader & 0x80) != 0, (fuHeader & 0x40) != 0, fuHeader & 0x1F)
    }

    // MARK: - H.265 NAL parsing (RFC 7798)

    /// Parse H.265 RTP payload into NAL units (single NAL and AP only; FU handled statefully).
    static func parseH265Payload(_ payload: [UInt8]) -> [[UInt8]] {
        guard payload.count >= 2 else { return [] }
        let nalType = (payload[0] >> 1) & 0x3F

        switch nalType {
        case 48:        // Aggregation Packet
            return parseAP(payload)
        case 49:
            return []   // FU handled statefully
        default:        // Single NAL (types 0-47)
            return [payload]
        }
    }

    /// Parse AP aggregation packet (H.265 type 48).
    static func parseAP(_ payload: [UInt8]) -> [[UInt8]] {
        var nals: [[UInt8]] = []
        var i = 2   // skip 2-byte payload header
        while i + 2 <= payload.count {
            let len = Int(payload[i]) << 8 | Int(payload[i + 1]); i += 2
            guard i + len <= payload.count else { break }
            nals.append(Array(payload[i..<(i + len)])); i += len
        }
        return nals
    }

    // MARK: - H.265 FU reassembly

    /// Reconstruct the 2-byte H.265 NAL header from FU fields.
    static func reconstructH265FUHeader(byte0: UInt8, byte1: UInt8, fuHeader: UInt8) -> (UInt8, UInt8) {
        let fuNalType = fuHeader & 0x3F
        let hdr0 = (byte0 & 0x81) | (fuNalType << 1)
        let hdr1 = byte1
        return (hdr0, hdr1)
    }

    /// Parse H.265 FU flags: (isStart, isEnd, nalType)
    static func parseH265FUFlags(_ fuHeader: UInt8) -> (isStart: Bool, isEnd: Bool, nalType: UInt8) {
        return ((fuHeader & 0x80) != 0, (fuHeader & 0x40) != 0, fuHeader & 0x3F)
    }

    // MARK: - NAL type classification

    /// Classify H.264 NAL type.
    static func classifyH264NAL(_ firstByte: UInt8) -> H264NALType {
        let t = firstByte & 0x1F
        switch t {
        case 5:  return .idr
        case 7:  return .sps
        case 8:  return .pps
        case 9:  return .aud
        default: return .data(type: t)
        }
    }

    enum H264NALType: Equatable {
        case idr, sps, pps, aud
        case data(type: UInt8)
    }

    /// Classify H.265 NAL type.
    static func classifyH265NAL(_ firstByte: UInt8) -> H265NALType {
        let t = (firstByte >> 1) & 0x3F
        switch t {
        case 32: return .vps
        case 33: return .sps
        case 34: return .pps
        case 16...21: return .keyframe(type: t)
        default: return .data(type: t)
        }
    }

    enum H265NALType: Equatable {
        case vps, sps, pps
        case keyframe(type: UInt8)
        case data(type: UInt8)
    }

    // MARK: - AVCC conversion

    /// Convert an array of NAL units to AVCC format (4-byte BE length prefix per NAL).
    static func nalsToAVCC(_ nals: [[UInt8]]) -> [UInt8] {
        let totalSize = nals.reduce(0) { $0 + 4 + $1.count }
        var avcc = [UInt8](repeating: 0, count: totalSize)
        var offset = 0
        for nal in nals {
            let len = nal.count
            avcc[offset]     = UInt8((len >> 24) & 0xFF)
            avcc[offset + 1] = UInt8((len >> 16) & 0xFF)
            avcc[offset + 2] = UInt8((len >>  8) & 0xFF)
            avcc[offset + 3] = UInt8( len        & 0xFF)
            avcc[(offset + 4)..<(offset + 4 + len)] = nal[0..<len]
            offset += 4 + len
        }
        return avcc
    }

    // MARK: - RTSP response parsing

    struct RTSPResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: String?
        let totalLength: Int  // total bytes consumed from buffer
    }

    /// Find the `\r\n\r\n` header terminator.
    static func findHeaderEnd(in buffer: [UInt8], from offset: Int) -> Int? {
        guard buffer.count - offset >= 4 else { return nil }
        for i in offset...(buffer.count - 4) where
            buffer[i] == 0x0D && buffer[i+1] == 0x0A && buffer[i+2] == 0x0D && buffer[i+3] == 0x0A {
            return i + 4
        }
        return nil
    }

    /// Parse an RTSP response from buffer bytes.
    static func parseResponse(_ buffer: [UInt8], from offset: Int) -> RTSPResponse? {
        guard let headerEnd = findHeaderEnd(in: buffer, from: offset) else { return nil }

        let headerText = String(bytes: buffer[offset..<headerEnd], encoding: .utf8) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            headers[parts[0].lowercased()] = parts[1]
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let total = headerEnd + contentLength
        guard buffer.count >= total else { return nil }

        let body: String? = contentLength > 0
            ? String(bytes: buffer[headerEnd..<total], encoding: .utf8) : nil

        let statusLine = lines.first ?? ""
        let statusCode = Int(statusLine.components(separatedBy: " ").dropFirst().first ?? "0") ?? 0

        return RTSPResponse(statusCode: statusCode, headers: headers, body: body, totalLength: total - offset)
    }

    // MARK: - SDP parsing

    struct SDPVideoInfo {
        let codec: String       // "H264" or "H265"
        let trackControl: String
        let spropSPS: [UInt8]?
        let spropPPS: [UInt8]?
    }

    /// Parse SDP for video track info.
    static func parseVideoTrack(sdp: String) -> SDPVideoInfo? {
        var codec = ""
        var trackControl = ""
        var spropSPS: [UInt8]?
        var spropPPS: [UInt8]?
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
                if let r = line.range(of: "sprop-parameter-sets=") {
                    let val = String(line[r.upperBound...]).split(separator: ";").first
                        .map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                    let parts = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count >= 2 {
                        spropSPS = Data(base64Encoded: parts[0]).map { [UInt8]($0) }
                        spropPPS = Data(base64Encoded: parts[1]).map { [UInt8]($0) }
                    }
                }
            }
        }

        guard !codec.isEmpty else { return nil }
        return SDPVideoInfo(codec: codec, trackControl: trackControl, spropSPS: spropSPS, spropPPS: spropPPS)
    }

    // MARK: - RTSP Transport header

    /// Extract the lower (RTP) channel from an RTSP `Transport` header's
    /// `interleaved=A-B` parameter. Returns nil if absent or malformed.
    static func interleavedRTPChannel(_ transport: String) -> UInt8? {
        for param in transport.components(separatedBy: ";") {
            let kv = param.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
            guard kv.count == 2, kv[0].lowercased() == "interleaved" else { continue }
            let lower = kv[1].components(separatedBy: "-").first ?? kv[1]
            return UInt8(lower.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: - SDP audio parsing (RFC 3640 — MPEG4-GENERIC / AAC-hbr)

    struct SDPAudioInfo: Equatable {
        let codec: String           // "AAC"
        let trackControl: String
        let sampleRate: Int         // RTP clock rate == AAC sample rate
        let channels: Int
        let config: [UInt8]?        // AudioSpecificConfig bytes (fmtp `config=`)
        let sizeLength: Int         // AU-size field width, bits  (AAC-hbr: 13)
        let indexLength: Int        // first AU-Index width, bits (AAC-hbr: 3)
        let indexDeltaLength: Int   // subsequent AU-Index-delta width, bits
    }

    /// Parse the SDP for an AAC (MPEG4-GENERIC) audio track. A stream may carry
    /// several `m=audio` sections (e.g. AAC plus Opus); each is parsed in
    /// isolation and only the MPEG4-GENERIC one is returned, so a co-advertised
    /// Opus track can't bleed its rtpmap/control into the AAC result.
    static func parseAudioTrack(sdp: String) -> SDPAudioInfo? {
        let lines = sdp.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Split into media sections, each beginning at an `m=` line.
        var sections: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.hasPrefix("m=") {
                if !current.isEmpty { sections.append(current) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current) }

        for section in sections where section.first?.hasPrefix("m=audio") == true {
            if let info = parseAudioSection(section) { return info }
        }
        return nil
    }

    /// Parse a single `m=audio` section, returning AAC info only if its rtpmap is
    /// MPEG4-GENERIC. Returns nil for any other codec (Opus, PCMU, …).
    private static func parseAudioSection(_ lines: [String]) -> SDPAudioInfo? {
        var isAAC = false
        var trackControl = ""
        var sampleRate = 0
        var channels = 1
        var config: [UInt8]?
        var sizeLength = 13
        var indexLength = 3
        var indexDeltaLength = 3

        for line in lines {
            if line.hasPrefix("a=rtpmap:") {
                // a=rtpmap:97 MPEG4-GENERIC/48000/1
                let value = line.components(separatedBy: " ").dropFirst().first ?? ""
                let parts = value.components(separatedBy: "/")
                let name = parts.first?.uppercased() ?? ""
                if name == "MPEG4-GENERIC" { isAAC = true }
                if parts.count >= 2 { sampleRate = Int(parts[1]) ?? 0 }
                if parts.count >= 3 { channels = Int(parts[2]) ?? 1 }
            }
            if line.hasPrefix("a=control:") {
                let ctrl = String(line.dropFirst("a=control:".count))
                if ctrl != "*" && !ctrl.isEmpty { trackControl = ctrl }
            }
            if line.hasPrefix("a=fmtp:") {
                for param in line.components(separatedBy: ";") {
                    let kv = param.components(separatedBy: "=")
                    guard kv.count >= 2 else { continue }
                    let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                    let val = kv[1].trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "config":           config = hexToBytes(val)
                    case "sizelength":       sizeLength = Int(val) ?? sizeLength
                    case "indexlength":      indexLength = Int(val) ?? indexLength
                    case "indexdeltalength": indexDeltaLength = Int(val) ?? indexDeltaLength
                    default: break
                    }
                }
            }
        }

        guard isAAC, sampleRate > 0 else { return nil }
        return SDPAudioInfo(codec: "AAC", trackControl: trackControl, sampleRate: sampleRate,
                            channels: channels, config: config, sizeLength: sizeLength,
                            indexLength: indexLength, indexDeltaLength: indexDeltaLength)
    }

    /// Decode an even-length hex string to bytes. Returns nil on malformed input.
    static func hexToBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo)); i += 2
        }
        return bytes
    }

    // MARK: - AudioSpecificConfig parsing (ISO/IEC 14496-3)

    struct AudioSpecificConfig: Equatable {
        let objectType: Int     // 2 = AAC-LC, 5 = HE-AAC (SBR)
        let sampleRate: Int
        let channels: Int
    }

    private static let aacSampleRates =
        [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// Parse the first bytes of an AudioSpecificConfig: object type, sample rate, channel config.
    static func parseAudioSpecificConfig(_ bytes: [UInt8]) -> AudioSpecificConfig? {
        var reader = BitReader(bytes)
        guard var objectType = reader.read(5) else { return nil }
        if objectType == 31 {
            guard let ext = reader.read(6) else { return nil }
            objectType = 32 + ext
        }
        guard let freqIndex = reader.read(4) else { return nil }
        let sampleRate: Int
        if freqIndex == 15 {
            guard let explicit = reader.read(24) else { return nil }
            sampleRate = explicit
        } else {
            guard freqIndex < aacSampleRates.count else { return nil }
            sampleRate = aacSampleRates[freqIndex]
        }
        guard let channelConfig = reader.read(4) else { return nil }
        return AudioSpecificConfig(objectType: objectType, sampleRate: sampleRate, channels: channelConfig)
    }

    // MARK: - AAC RTP depacketization (RFC 3640, AAC-hbr)

    /// Read the AU-header section and return each AU's declared size (bytes) plus the
    /// offset where AU payload data begins. Returns nil if the headers don't fit.
    static func aacAUSizes(_ payload: [UInt8], sizeLength: Int, indexLength: Int,
                           indexDeltaLength: Int) -> (sizes: [Int], dataOffset: Int)? {
        guard payload.count >= 2, sizeLength > 0 else { return nil }
        let headerBits = Int(payload[0]) << 8 | Int(payload[1])
        let headerBytes = (headerBits + 7) / 8
        let dataOffset = 2 + headerBytes
        guard dataOffset <= payload.count else { return nil }

        var reader = BitReader(Array(payload[2..<dataOffset]))
        var sizes: [Int] = []
        var consumed = 0
        var first = true
        while consumed + sizeLength <= headerBits {
            guard let size = reader.read(sizeLength) else { break }
            let idxWidth = first ? indexLength : indexDeltaLength
            if idxWidth > 0 { _ = reader.read(idxWidth) }
            consumed += sizeLength + idxWidth
            sizes.append(size)
            first = false
        }
        return (sizes, dataOffset)
    }

    /// Split an AAC-hbr RTP payload into its constituent AAC access units.
    /// Trailing access units whose declared size overruns the packet are dropped
    /// (those indicate cross-packet fragmentation, handled statefully by the caller).
    static func depacketizeAAC(_ payload: [UInt8], sizeLength: Int, indexLength: Int,
                               indexDeltaLength: Int) -> [[UInt8]] {
        guard let (sizes, dataOffset) = aacAUSizes(payload, sizeLength: sizeLength,
                                                   indexLength: indexLength,
                                                   indexDeltaLength: indexDeltaLength) else { return [] }
        var aus: [[UInt8]] = []
        var pos = dataOffset
        for size in sizes {
            guard size > 0, pos + size <= payload.count else { break }
            aus.append(Array(payload[pos..<(pos + size)])); pos += size
        }
        return aus
    }

    /// Stateful AAC-hbr depacketizer that reassembles access units fragmented
    /// across several RTP packets (RFC 3640 §3.3.6). A fragmented AU is signalled
    /// by a single AU-header whose declared size exceeds the packet's data; the
    /// RTP marker bit closes the final fragment. Non-fragmented packets pass
    /// straight through. Feed one packet at a time in arrival order.
    struct AACDepacketizer {
        let sizeLength: Int
        let indexLength: Int
        let indexDeltaLength: Int
        /// Guard against a runaway/hostile fragment that never sees its marker.
        private let maxFragmentBytes = 64 * 1024
        private var fragment: [UInt8]?

        init(sizeLength: Int, indexLength: Int, indexDeltaLength: Int) {
            self.sizeLength = sizeLength
            self.indexLength = indexLength
            self.indexDeltaLength = indexDeltaLength
        }

        /// Feed one RTP payload (bytes after the RTP header) with its marker bit.
        /// Returns the complete AAC access units this packet produced (often one,
        /// sometimes several, or none mid-fragment).
        mutating func receive(_ payload: [UInt8], marker: Bool) -> [[UInt8]] {
            guard let (sizes, dataOffset) = RTPParser.aacAUSizes(
                payload, sizeLength: sizeLength, indexLength: indexLength,
                indexDeltaLength: indexDeltaLength) else { return [] }
            let data = dataOffset < payload.count ? Array(payload[dataOffset...]) : []

            // Continuation of an AU already in progress.
            if fragment != nil {
                fragment!.append(contentsOf: data)
                if fragment!.count > maxFragmentBytes { fragment = nil; return [] }
                guard marker else { return [] }
                let complete = fragment!; fragment = nil
                return [complete]
            }

            // First fragment: a lone AU whose declared size overruns this packet.
            if sizes.count == 1, sizes[0] > data.count, !marker {
                fragment = data
                return []
            }

            // One or more complete AUs carried whole in this packet.
            var aus: [[UInt8]] = []
            var pos = 0
            for size in sizes {
                guard size > 0, pos + size <= data.count else { break }
                aus.append(Array(data[pos ..< (pos + size)])); pos += size
            }
            return aus
        }
    }

    /// Minimal MSB-first bit reader over a byte array.
    struct BitReader {
        private let bytes: [UInt8]
        private var bitPos = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        /// Read `count` bits (0...32) as an unsigned value, or nil if out of range.
        mutating func read(_ count: Int) -> Int? {
            guard count >= 0, count <= 32 else { return nil }
            guard bitPos + count <= bytes.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                let byte = bytes[bitPos >> 3]
                let bit = (Int(byte) >> (7 - (bitPos & 7))) & 1
                value = value << 1 | bit
                bitPos += 1
            }
            return value
        }
    }

    // MARK: - Version comparison

    /// Compare semantic version strings. Returns true if remote > local.
    static func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}

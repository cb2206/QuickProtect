import Foundation
import Network
import AVFoundation
import CoreMedia

/// RTSP/RTP client using NWConnection.
/// All data processing runs on a dedicated serial queue to keep the main thread free.
/// Only @Published property updates are dispatched to the main thread for SwiftUI.
/// AVSampleBufferDisplayLayer.enqueue() is thread-safe and called from the processing queue.
final class RTSPClient: ObservableObject {

    // MARK: - Published (main-thread only)

    @Published var displayLayer = AVSampleBufferDisplayLayer()
    @Published var isConnected  = false
    @Published var error: String?
    @Published var videoDimensions: CGSize = .zero

    // MARK: - Dedicated processing queue
    // All mutable state below is accessed exclusively on this queue.
    // NWConnection callbacks also fire on this queue.

    private let queue = DispatchQueue(label: "com.quickprotect.rtsp", qos: .userInitiated)

    // MARK: - State (queue-only)

    private var connection:  NWConnection?
    private var currentURL:  URL?
    private var buffer       = [UInt8]()
    private var bufferOffset = 0          // read cursor; compact when > 64 KB
    private var inRTPMode    = false
    private var cSeq         = 0
    private var sessionId    = ""
    private var trackControl = ""

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

    // MARK: - Public API (called from main thread)

    func connect(to url: URL) {
        queue.async { [self] in
            disconnectOnQueue()
            currentURL       = url
            inRTPMode        = false
            buffer           = []
            bufferOffset     = 0
            cSeq             = 0
            sessionId        = ""
            trackControl     = ""
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

            guard let host = url.host,
                  let rawPort = url.port,
                  let port = NWEndpoint.Port(rawValue: UInt16(rawPort))
            else {
                DispatchQueue.main.async { self.error = "Invalid RTSP URL: \(url)" }
                return
            }

            let tlsOpts = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(
                tlsOpts.securityProtocolOptions,
                { _, _, complete in complete(true) },
                DispatchQueue.global()
            )

            let params = NWParameters(tls: tlsOpts)
            let conn   = NWConnection(host: NWEndpoint.Host(host), port: port, using: params)
            connection = conn

            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    guard conn === self.connection else { return }
                    switch state {
                    case .ready:
                        self.sendOptions()
                    case .failed(let e):
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

    // MARK: - Internal disconnect (must be called on queue)

    private func disconnectOnQueue() {
        // Send TEARDOWN to free server-side resources before closing the connection
        if let conn = connection, let url = currentURL, !sessionId.isEmpty {
            let seq = nextCSeq()
            let msg = "TEARDOWN \(url.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\nSession: \(sessionId)\r\n\r\n"
            conn.send(content: Data(msg.utf8), completion: .idempotent)
        }
        connection?.cancel()
        connection = nil
        displayLayer.flush()
        DispatchQueue.main.async { [self] in
            isConnected = false
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
                self.processBuffer()
            }
            if let e = err {
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

    // MARK: - RTSP response parser

    private func processRTSPResponses() {
        guard let headerEnd = findHeaderEnd() else { return }

        let headerText = String(bytes: buffer[bufferOffset..<headerEnd], encoding: .utf8) ?? ""
        let lines = headerText.components(separatedBy: "\r\n")

        var contentLength = 0
        var newSession    = ""
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "content-length": contentLength = Int(parts[1]) ?? 0
            case "session":        newSession = parts[1].components(separatedBy: ";").first ?? parts[1]
            default: break
            }
        }
        if !newSession.isEmpty { sessionId = newSession }

        let total = headerEnd + contentLength
        guard buffer.count >= total else { return }

        let body: String? = contentLength > 0
            ? String(bytes: buffer[headerEnd..<total], encoding: .utf8)
            : nil

        consumeBytes(total - bufferOffset)

        let statusLine = lines.first ?? ""
        let statusCode = Int(statusLine.components(separatedBy: " ").dropFirst().first ?? "0") ?? 0

        guard (200...299).contains(statusCode) else {
            DispatchQueue.main.async { self.error = "RTSP \(statusCode)" }
            return
        }

        switch cSeq {
        case 1: sendDescribe()
        case 2:
            if let sdp = body { parseSDP(sdp) }
            sendSetup()
        case 3: sendPlay()
        case 4:
            inRTPMode = true
            DispatchQueue.main.async { self.isConnected = true }
            if !buffer.isEmpty { processRTP() }
        default: break
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
        let seq = nextCSeq()
        send("OPTIONS \(currentURL!.absoluteString) RTSP/1.0\r\nCSeq: \(seq)\r\n\r\n")
    }

    private func sendDescribe() {
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

    private func sendSetup() {
        let seq = nextCSeq()
        let base = currentURL!.absoluteString
        let trackURL: String
        if trackControl.hasPrefix("rtsps://") || trackControl.hasPrefix("rtsp://") {
            trackURL = trackControl
        } else {
            trackURL = base + (trackControl.hasPrefix("/") ? trackControl : "/\(trackControl)")
        }
        send("SETUP \(trackURL) RTSP/1.0\r\nCSeq: \(seq)\r\nTransport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n\r\n")
    }

    private func sendPlay() {
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
            if channel == 0 {
                handleRTP(pos + 4, length: length)
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
            let isStart = (fuHdr & 0x80) != 0
            let isEnd   = (fuHdr & 0x40) != 0
            let origType = fuHdr & 0x1F
            if isStart {
                fuBuffer = [(fuInd & 0xE0) | origType]
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
            let isStart = (fuHdr & 0x80) != 0
            let isEnd   = (fuHdr & 0x40) != 0
            let fuNalType = fuHdr & 0x3F
            let hdr0: UInt8 = (buffer[off] & 0x81) | (fuNalType << 1)
            let hdr1: UInt8 = buffer[off + 1]
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
            let nalType = (nal[0] >> 1) & 0x3F
            switch nalType {
            case 32: hevcVPS = nal
            case 33: hevcSPS = nal
            case 34: hevcPPS = nal
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
            if nalType == 32 || nalType == 33 || nalType == 34 { return }
        } else {
            let nalType = nal[0] & 0x1F
            switch nalType {
            case 7: h264SPS = nal
            case 8: h264PPS = nal
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
            if nalType == 7 || nalType == 8 || nalType == 9 { return }
        }

        guard formatDescription != nil else { return }
        pendingNALs.append(nal)
    }

    // MARK: - AVCC/HVCC → CMSampleBuffer → display layer

    private func enqueueAccessUnit(_ nals: [[UInt8]], formatDescription: CMVideoFormatDescription) {
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
                let firstNAL = nals[0]
                let isKeyframe: Bool
                if codec == "H265", firstNAL.count >= 2 {
                    let t = (firstNAL[0] >> 1) & 0x3F
                    isKeyframe = (t >= 16 && t <= 21)
                } else {
                    isKeyframe = (firstNAL[0] & 0x1F) == 5
                }
                for dict in attachments {
                    dict[kCMSampleAttachmentKey_DependsOnOthers] = !isKeyframe
                    dict[kCMSampleAttachmentKey_DisplayImmediately] = true
                }
            }
            if displayLayer.status == .failed { displayLayer.flush() }
            displayLayer.enqueue(sb)
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

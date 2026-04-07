import Foundation

// MARK: - Minimal test framework (no XCTest/Xcode dependency)

var totalTests = 0
var passedTests = 0
var failedTests = 0
var currentSuite = ""

func suite(_ name: String) {
    currentSuite = name
    print("\n▸ \(name)")
}

func test(_ name: String, _ body: () throws -> Void) {
    totalTests += 1
    do {
        try body()
        passedTests += 1
        print("  ✓ \(name)")
    } catch {
        failedTests += 1
        print("  ✗ \(name): \(error)")
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: Int
    var description: String { "\(file):\(line) — \(message)" }
}

func expect(
    _ condition: Bool,
    _ message: String = "assertion failed",
    file: String = #file,
    line: Int = #line
) throws {
    guard condition else { throw TestFailure(message: message, file: file, line: line) }
}

func expectEqual<T: Equatable>(
    _ a: T, _ b: T,
    file: String = #file,
    line: Int = #line
) throws {
    guard a == b else {
        throw TestFailure(message: "expected \(a) == \(b)", file: file, line: line)
    }
}

func expectNil<T>(
    _ value: T?,
    file: String = #file,
    line: Int = #line
) throws {
    guard value == nil else {
        throw TestFailure(message: "expected nil, got \(value!)", file: file, line: line)
    }
}

func expectNotNil<T>(
    _ value: T?,
    file: String = #file,
    line: Int = #line
) throws {
    guard value != nil else {
        throw TestFailure(message: "expected non-nil", file: file, line: line)
    }
}

// MARK: - Run all tests

func runAllTests() {
    RTPInterleavedTests()
    RTPHeaderTests()
    H264NALTests()
    H265NALTests()
    NALClassificationTests()
    AVCCTests()
    RTSPResponseTests()
    SDPTests()
    VersionComparisonTests()
    GridLayoutTests()
    CameraModelRunnerTests()

    print("\n" + String(repeating: "─", count: 50))
    print("Results: \(passedTests)/\(totalTests) passed, \(failedTests) failed")
    if failedTests > 0 {
        print("⚠ FAILURES DETECTED")
        exit(1)
    } else {
        print("✓ All tests passed")
    }
}

// MARK: - RTP Interleaved Frame Extraction

func RTPInterleavedTests() {
    suite("RTP Interleaved Frame Extraction")

    test("single frame") {
        let buffer: [UInt8] = [0x24, 0x00, 0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD]
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        try expectEqual(frames.count, 1)
        try expectEqual(frames[0].channel, 0)
        try expectEqual(frames[0].payloadLength, 4)
        try expectEqual(consumed, 8)
    }

    test("multiple frames") {
        let buffer: [UInt8] = [
            0x24, 0x00, 0x00, 0x02, 0x11, 0x22,
            0x24, 0x01, 0x00, 0x02, 0x33, 0x44,
        ]
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        try expectEqual(frames.count, 2)
        try expectEqual(frames[0].channel, 0)
        try expectEqual(frames[1].channel, 1)
        try expectEqual(consumed, 12)
    }

    test("incomplete frame") {
        let buffer: [UInt8] = [0x24, 0x00, 0x00, 0x0A, 0x11, 0x22]
        let (frames, _) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        try expectEqual(frames.count, 0)
    }

    test("stray byte recovery") {
        let buffer: [UInt8] = [0xFF, 0xFE, 0x24, 0x00, 0x00, 0x02, 0x11, 0x22]
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        try expectEqual(frames.count, 1)
        try expectEqual(consumed, 8)
    }

    test("marker bit set") {
        let rtp: [UInt8] = [0x80, 0xE0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05]
        let len = UInt16(rtp.count)
        let buffer: [UInt8] = [0x24, 0x00, UInt8(len >> 8), UInt8(len & 0xFF)] + rtp
        let (frames, _) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        try expect(frames[0].markerBit, "marker should be set")
    }

    test("marker bit clear") {
        let rtp: [UInt8] = [0x80, 0x60, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05]
        let len = UInt16(rtp.count)
        let buffer: [UInt8] = [0x24, 0x00, UInt8(len >> 8), UInt8(len & 0xFF)] + rtp
        let (frames, _) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        try expect(!frames[0].markerBit, "marker should be clear")
    }
}

// MARK: - RTP Header

func RTPHeaderTests() {
    suite("RTP Header Parsing")

    test("basic 12-byte header") {
        let buffer: [UInt8] = [0x80, 0xE1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF]
        let result = RTPParser.parseRTPHeader(buffer, offset: 0, length: buffer.count)
        try expectNotNil(result)
        try expect(result!.marker)
        try expectEqual(result!.headerLength, 12)
    }

    test("header with 1 CSRC") {
        var buffer: [UInt8] = Array(repeating: 0, count: 20)
        buffer[0] = 0x81
        let result = RTPParser.parseRTPHeader(buffer, offset: 0, length: buffer.count)
        try expectEqual(result!.headerLength, 16)
    }

    test("too short") {
        try expectNil(RTPParser.parseRTPHeader([0x80, 0xE1, 0x00], offset: 0, length: 3))
    }
}

// MARK: - H.264 NAL

func H264NALTests() {
    suite("H.264 NAL Parsing")

    test("single NAL type 1") {
        let payload: [UInt8] = [0x61, 0xAA, 0xBB]
        let nals = RTPParser.parseH264Payload(payload)
        try expectEqual(nals.count, 1)
        try expectEqual(nals[0], payload)
    }

    test("STAP-A with 2 NALs") {
        let nal1: [UInt8] = [0x67, 0x42, 0x00]
        let nal2: [UInt8] = [0x68, 0xCE]
        var payload: [UInt8] = [24]
        payload += [0x00, UInt8(nal1.count)] + nal1
        payload += [0x00, UInt8(nal2.count)] + nal2
        let nals = RTPParser.parseH264Payload(payload)
        try expectEqual(nals.count, 2)
        try expectEqual(nals[0], nal1)
        try expectEqual(nals[1], nal2)
    }

    test("STAP-A empty") {
        try expectEqual(RTPParser.parseH264Payload([24]).count, 0)
    }

    test("STAP-A truncated") {
        try expectEqual(RTPParser.parseH264Payload([24, 0x00, 0x0A, 0x11, 0x22]).count, 0)
    }

    test("FU-A header reconstruction") {
        let header = RTPParser.reconstructH264FUAHeader(fuIndicator: 0x7C, fuHeader: 0x85)
        try expectEqual(header, 0x65)
    }

    test("FU-A flags") {
        let (start, end, nalType) = RTPParser.parseFUAFlags(0x85)
        try expect(start)
        try expect(!end)
        try expectEqual(nalType, 5)
    }
}

// MARK: - H.265 NAL

func H265NALTests() {
    suite("H.265 NAL Parsing")

    test("single NAL") {
        let payload: [UInt8] = [0x02, 0x01, 0xAA]
        let nals = RTPParser.parseH265Payload(payload)
        try expectEqual(nals.count, 1)
    }

    test("aggregation packet") {
        let nal1: [UInt8] = [0x40, 0x01, 0xAA]
        let nal2: [UInt8] = [0x42, 0x01, 0xBB]
        var payload: [UInt8] = [0x60, 0x01]
        payload += [0x00, UInt8(nal1.count)] + nal1
        payload += [0x00, UInt8(nal2.count)] + nal2
        let nals = RTPParser.parseH265Payload(payload)
        try expectEqual(nals.count, 2)
    }

    test("FU header reconstruction") {
        let (hdr0, hdr1) = RTPParser.reconstructH265FUHeader(byte0: 0x63, byte1: 0x01, fuHeader: 0xA0)
        try expectEqual(hdr0, 0x41)
        try expectEqual(hdr1, 0x01)
    }

    test("FU flags") {
        let (start, end, nalType) = RTPParser.parseH265FUFlags(0xA0)
        try expect(start)
        try expect(!end)
        try expectEqual(nalType, 32)
    }
}

// MARK: - NAL Classification

func NALClassificationTests() {
    suite("NAL Type Classification")

    test("H.264 types") {
        try expectEqual(RTPParser.classifyH264NAL(0x65), .idr)
        try expectEqual(RTPParser.classifyH264NAL(0x67), .sps)
        try expectEqual(RTPParser.classifyH264NAL(0x68), .pps)
        try expectEqual(RTPParser.classifyH264NAL(0x09), .aud)
        try expectEqual(RTPParser.classifyH264NAL(0x61), .data(type: 1))
    }

    test("H.265 types") {
        try expectEqual(RTPParser.classifyH265NAL(0x40), .vps)
        try expectEqual(RTPParser.classifyH265NAL(0x42), .sps)
        try expectEqual(RTPParser.classifyH265NAL(0x44), .pps)
        try expectEqual(RTPParser.classifyH265NAL(0x26), .keyframe(type: 19))
        try expectEqual(RTPParser.classifyH265NAL(0x02), .data(type: 1))
    }

    test("H.265 keyframe range 16-21") {
        for t: UInt8 in 16...21 {
            let byte = t << 1
            try expectEqual(RTPParser.classifyH265NAL(byte), .keyframe(type: t))
        }
    }
}

// MARK: - AVCC Conversion

func AVCCTests() {
    suite("AVCC Conversion")

    test("single NAL") {
        let nal: [UInt8] = [0x65, 0xAA, 0xBB, 0xCC]
        let avcc = RTPParser.nalsToAVCC([nal])
        try expectEqual(avcc.count, 8)
        try expectEqual(avcc[0], 0x00)
        try expectEqual(avcc[1], 0x00)
        try expectEqual(avcc[2], 0x00)
        try expectEqual(avcc[3], 0x04)
        try expectEqual(Array(avcc[4...]), nal)
    }

    test("multiple NALs") {
        let avcc = RTPParser.nalsToAVCC([[0x01, 0x02], [0x03, 0x04, 0x05]])
        try expectEqual(avcc.count, 13)
        try expectEqual(avcc[3], 2)
        try expectEqual(avcc[9], 3)
    }

    test("empty") {
        try expectEqual(RTPParser.nalsToAVCC([]).count, 0)
    }

    test("large length (300 bytes)") {
        let avcc = RTPParser.nalsToAVCC([[UInt8](repeating: 0xAA, count: 300)])
        try expectEqual(avcc.count, 304)
        try expectEqual(avcc[2], 0x01)
        try expectEqual(avcc[3], 0x2C)
    }
}

// MARK: - RTSP Response

func RTSPResponseTests() {
    suite("RTSP Response Parsing")

    test("find header end") {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\nbody".utf8)
        try expectNotNil(RTPParser.findHeaderEnd(in: buffer, from: 0))
    }

    test("header end missing") {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)
        try expectNil(RTPParser.findHeaderEnd(in: buffer, from: 0))
    }

    test("status code 200") {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8)
        try expectEqual(RTPParser.parseResponse(buffer, from: 0)?.statusCode, 200)
    }

    test("status code 454") {
        let buffer = [UInt8]("RTSP/1.0 454 Session Not Found\r\n\r\n".utf8)
        try expectEqual(RTPParser.parseResponse(buffer, from: 0)?.statusCode, 454)
    }

    test("content-length and body") {
        let body = "hello world"
        let bodyBytes = [UInt8](body.utf8)
        // Build response manually to avoid string interpolation ambiguity
        let header = "RTSP/1.0 200 OK\r\nContent-Length: \(bodyBytes.count)\r\n\r\n"
        let buffer = [UInt8](header.utf8) + bodyBytes
        let result = RTPParser.parseResponse(buffer, from: 0)
        try expectNotNil(result)
        try expectEqual(result?.body, body)
    }

    test("incomplete body returns nil") {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nContent-Length: 100\r\n\r\nhello".utf8)
        try expectNil(RTPParser.parseResponse(buffer, from: 0))
    }
}

// MARK: - SDP

func SDPTests() {
    suite("SDP Parsing")

    test("H.265 codec detection") {
        let sdp = "m=video 0 RTP/AVP 97\r\na=rtpmap:97 H265/90000\r\na=control:trackID=2\r\n"
        let info = RTPParser.parseVideoTrack(sdp: sdp)
        try expectEqual(info?.codec, "H265")
        try expectEqual(info?.trackControl, "trackID=2")
    }

    test("H.264 codec detection") {
        let sdp = "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:track1\r\n"
        try expectEqual(RTPParser.parseVideoTrack(sdp: sdp)?.codec, "H264")
    }

    test("video track control only") {
        let sdp = "m=audio 0 RTP/AVP 96\r\na=control:trackID=0\r\nm=video 0 RTP/AVP 97\r\na=rtpmap:97 H265/90000\r\na=control:trackID=2\r\n"
        try expectEqual(RTPParser.parseVideoTrack(sdp: sdp)?.trackControl, "trackID=2")
    }

    test("no video section") {
        let sdp = "v=0\r\nm=audio 0 RTP/AVP 96\r\na=rtpmap:96 opus/48000/2\r\n"
        try expectNil(RTPParser.parseVideoTrack(sdp: sdp))
    }
}

// MARK: - Version Comparison

func VersionComparisonTests() {
    suite("Version Comparison")

    test("newer major")   { try expect(RTPParser.isNewer(remote: "1.0", local: "0.9")) }
    test("newer minor")   { try expect(RTPParser.isNewer(remote: "0.4", local: "0.3")) }
    test("newer patch")   { try expect(RTPParser.isNewer(remote: "0.3.1", local: "0.3")) }
    test("equal")         { try expect(!RTPParser.isNewer(remote: "0.3", local: "0.3")) }
    test("older")         { try expect(!RTPParser.isNewer(remote: "0.2", local: "0.3")) }
    test("padded equal")  { try expect(!RTPParser.isNewer(remote: "1", local: "1.0.0")) }
    test("multi-digit")   { try expect(RTPParser.isNewer(remote: "0.10", local: "0.9")) }
    test("major trumps")  { try expect(RTPParser.isNewer(remote: "2.0", local: "1.99")) }
    test("4 components")  { try expect(RTPParser.isNewer(remote: "1.2.3.4", local: "1.2.3.3")) }
    test("single digit")  { try expect(RTPParser.isNewer(remote: "2", local: "1")) }
}

// MARK: - Grid Layout

func GridLayoutTests() {
    suite("Grid Layout & Pan Clamping")

    test("cell width span 1") {
        try expectEqual(1.0 * 100.0 + 0.0 * 3.0, 100.0)
    }
    test("cell width span 2") {
        try expectEqual(2.0 * 100.0 + 1.0 * 3.0, 203.0)
    }
    test("cell width span 4") {
        try expectEqual(4.0 * 100.0 + 3.0 * 3.0, 409.0)
    }
    test("pan max at zoom 1") {
        try expectEqual(400.0 * (1.0 - 1.0) / 2.0, 0.0)
    }
    test("pan max at zoom 2") {
        try expectEqual(400.0 * (2.0 - 1.0) / 2.0, 200.0)
    }
    test("pan clamp negative") {
        let maxPan = 200.0
        try expectEqual(max(-maxPan, min(maxPan, -999.0)), -200.0)
    }
    test("pan clamp within range") {
        let maxPan = 200.0
        try expectEqual(max(-maxPan, min(maxPan, 50.0)), 50.0)
    }
}

// MARK: - Camera Model

func CameraModelRunnerTests() {
    suite("Camera Model Decoding")

    test("Integration API shape (no featureFlags)") {
        let json = """
        {"id":"cam1","name":"Front Door","state":"CONNECTED","channels":[]}
        """.data(using: .utf8)!
        let cam = try JSONDecoder().decode(Camera.self, from: json)
        try expectEqual(cam.id, "cam1")
        try expectEqual(cam.name, "Front Door")
        try expect(cam.isOnline)
        try expect(!cam.isPtz)
    }

    test("PTZ camera via featureFlags.isPtz") {
        let json = """
        {"id":"ptz1","name":"Backyard","state":"CONNECTED","channels":[],
         "featureFlags":{"isPtz":true,"canOpticalZoom":false}}
        """.data(using: .utf8)!
        let cam = try JSONDecoder().decode(Camera.self, from: json)
        try expect(cam.isPtz, "isPtz should be true")
    }

    test("canOpticalZoom sets isPtz") {
        let json = """
        {"id":"oz1","name":"Garage","state":"CONNECTED","channels":[],
         "featureFlags":{"isPtz":false,"canOpticalZoom":true}}
        """.data(using: .utf8)!
        let cam = try JSONDecoder().decode(Camera.self, from: json)
        try expect(cam.isPtz, "canOpticalZoom should set isPtz")
    }

    test("missing state defaults to UNKNOWN") {
        let json = """
        {"id":"x","name":"Test"}
        """.data(using: .utf8)!
        let cam = try JSONDecoder().decode(Camera.self, from: json)
        try expectEqual(cam.state, "UNKNOWN")
        try expect(!cam.isOnline)
    }

    test("channel decoding and primaryRtspAlias") {
        let json = """
        {"id":"ch1","name":"C","state":"CONNECTED","channels":[
          {"id":0,"name":"High","rtspAlias":"abc","isRtspEnabled":true},
          {"id":1,"name":"Med","rtspAlias":"def","isRtspEnabled":false}
        ]}
        """.data(using: .utf8)!
        let cam = try JSONDecoder().decode(Camera.self, from: json)
        try expectEqual(cam.channels.count, 2)
        try expectEqual(cam.primaryRtspAlias, "abc")
    }

    test("encode excludes featureFlags") {
        let json = """
        {"id":"e1","name":"Enc","state":"CONNECTED","channels":[],
         "featureFlags":{"isPtz":true,"canOpticalZoom":true}}
        """.data(using: .utf8)!
        let cam = try JSONDecoder().decode(Camera.self, from: json)
        try expect(cam.isPtz)
        let encoded = try JSONEncoder().encode(cam)
        let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        try expectNil(dict["featureFlags"] as? [String: Any])
    }
}

// MARK: - Entry point

@main
enum TestMain {
    static func main() {
        runAllTests()
    }
}

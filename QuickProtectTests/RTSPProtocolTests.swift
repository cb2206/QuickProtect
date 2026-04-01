import XCTest

final class RTSPResponseTests: XCTestCase {

    func testFindHeaderEnd() {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\nbody".utf8)
        let end = RTPParser.findHeaderEnd(in: buffer, from: 0)
        XCTAssertNotNil(end)
    }

    func testFindHeaderEndMissing() {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8)
        XCTAssertNil(RTPParser.findHeaderEnd(in: buffer, from: 0))
    }

    func testParseStatusCode200() {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nCSeq: 1\r\n\r\n".utf8)
        XCTAssertEqual(RTPParser.parseResponse(buffer, from: 0)?.statusCode, 200)
    }

    func testParseStatusCode454() {
        let buffer = [UInt8]("RTSP/1.0 454 Session Not Found\r\n\r\n".utf8)
        XCTAssertEqual(RTPParser.parseResponse(buffer, from: 0)?.statusCode, 454)
    }

    func testParseSessionHeader() {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nSession: ABC123;timeout=60\r\n\r\n".utf8)
        let result = RTPParser.parseResponse(buffer, from: 0)
        XCTAssertEqual(result?.headers["session"], "ABC123;timeout=60")
    }

    func testParseContentLengthAndBody() {
        let body = "hello world"
        let bodyBytes = [UInt8](body.utf8)
        let header = "RTSP/1.0 200 OK\r\nContent-Length: \(bodyBytes.count)\r\n\r\n"
        let buffer = [UInt8](header.utf8) + bodyBytes
        let result = RTPParser.parseResponse(buffer, from: 0)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.body, body)
    }

    func testParseIncompleteBody() {
        let buffer = [UInt8]("RTSP/1.0 200 OK\r\nContent-Length: 100\r\n\r\nhello".utf8)
        XCTAssertNil(RTPParser.parseResponse(buffer, from: 0))
    }
}

final class SDPParsingTests: XCTestCase {

    func testVideoCodecH265() {
        let sdp = "m=video 0 RTP/AVP 97\r\na=rtpmap:97 H265/90000\r\na=control:trackID=2\r\n"
        let info = RTPParser.parseVideoTrack(sdp: sdp)
        XCTAssertEqual(info?.codec, "H265")
        XCTAssertEqual(info?.trackControl, "trackID=2")
    }

    func testVideoCodecH264() {
        let sdp = "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:track1\r\n"
        XCTAssertEqual(RTPParser.parseVideoTrack(sdp: sdp)?.codec, "H264")
    }

    func testTrackControlVideoOnly() {
        let sdp = "m=audio 0 RTP/AVP 96\r\na=control:trackID=0\r\nm=video 0 RTP/AVP 97\r\na=rtpmap:97 H265/90000\r\na=control:trackID=2\r\n"
        XCTAssertEqual(RTPParser.parseVideoTrack(sdp: sdp)?.trackControl, "trackID=2")
    }

    func testNoVideoSection() {
        let sdp = "v=0\r\nm=audio 0 RTP/AVP 96\r\na=rtpmap:96 opus/48000/2\r\n"
        XCTAssertNil(RTPParser.parseVideoTrack(sdp: sdp))
    }
}

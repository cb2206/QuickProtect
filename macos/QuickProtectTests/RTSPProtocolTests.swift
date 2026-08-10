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

final class SDPAudioParsingTests: XCTestCase {

    private let aacSDP = """
    m=video 0 RTP/AVP 96\r
    a=rtpmap:96 H264/90000\r
    a=control:trackID=0\r
    m=audio 0 RTP/AVP 97\r
    a=rtpmap:97 MPEG4-GENERIC/16000/1\r
    a=fmtp:97 streamtype=5; profile-level-id=15; mode=AAC-hbr; config=1408; \
    sizeLength=13; indexLength=3; indexDeltaLength=3\r
    a=control:trackID=1\r
    """

    func testParsesAACTrack() {
        let info = RTPParser.parseAudioTrack(sdp: aacSDP)
        XCTAssertEqual(info?.codec, "AAC")
        XCTAssertEqual(info?.sampleRate, 16000)
        XCTAssertEqual(info?.channels, 1)
        XCTAssertEqual(info?.trackControl, "trackID=1")
    }

    func testParsesFmtpParams() {
        let info = RTPParser.parseAudioTrack(sdp: aacSDP)
        XCTAssertEqual(info?.sizeLength, 13)
        XCTAssertEqual(info?.indexLength, 3)
        XCTAssertEqual(info?.indexDeltaLength, 3)
        XCTAssertEqual(info?.config, [0x14, 0x08])
    }

    func testNoAudioSection() {
        let sdp = "m=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=control:trackID=0\r\n"
        XCTAssertNil(RTPParser.parseAudioTrack(sdp: sdp))
    }

    func testNonAACAudioIgnored() {
        let sdp = "m=audio 0 RTP/AVP 96\r\na=rtpmap:96 PCMU/8000\r\na=control:trackID=1\r\n"
        XCTAssertNil(RTPParser.parseAudioTrack(sdp: sdp))
    }

    // UniFi Protect advertises both an AAC and an Opus audio track. The Opus
    // section must not bleed its rtpmap/control into the AAC result.
    private let aacPlusOpusSDP = """
    m=video 0 RTP/AVP 96\r
    a=rtpmap:96 H265/90000\r
    a=control:trackID=2\r
    m=audio 0 RTP/AVP 97\r
    a=rtpmap:97 MPEG4-GENERIC/48000/1\r
    a=fmtp:97 mode=AAC-hbr; config=1188; sizeLength=13; indexLength=3; indexDeltaLength=3\r
    a=control:trackID=0\r
    m=audio 0 RTP/AVP 98\r
    a=rtpmap:98 opus/48000/2\r
    a=control:trackID=1\r
    """

    func testPicksAACOverOpus() {
        let info = RTPParser.parseAudioTrack(sdp: aacPlusOpusSDP)
        XCTAssertEqual(info?.codec, "AAC")
        XCTAssertEqual(info?.sampleRate, 48000)
        XCTAssertEqual(info?.channels, 1)          // AAC mono, not Opus's 2ch
        XCTAssertEqual(info?.trackControl, "trackID=0")  // AAC track, not Opus's trackID=1
        XCTAssertEqual(info?.config, [0x11, 0x88])
    }

    func testPicksAACWhenOpusListedFirst() {
        let sdp = """
        m=audio 0 RTP/AVP 98\r
        a=rtpmap:98 opus/48000/2\r
        a=control:trackID=1\r
        m=audio 0 RTP/AVP 97\r
        a=rtpmap:97 MPEG4-GENERIC/48000/1\r
        a=fmtp:97 mode=AAC-hbr; config=1188\r
        a=control:trackID=0\r
        """
        let info = RTPParser.parseAudioTrack(sdp: sdp)
        XCTAssertEqual(info?.channels, 1)
        XCTAssertEqual(info?.trackControl, "trackID=0")
    }

    func testHexToBytes() {
        XCTAssertEqual(RTPParser.hexToBytes("1408"), [0x14, 0x08])
        XCTAssertNil(RTPParser.hexToBytes("140"))   // odd length
        XCTAssertNil(RTPParser.hexToBytes("14ZZ"))  // non-hex
    }
}

final class TransportHeaderTests: XCTestCase {

    func testInterleavedAudioChannel() {
        let t = "RTP/AVP/TCP;unicast;interleaved=2-3;ssrc=1A2B3C4D"
        XCTAssertEqual(RTPParser.interleavedRTPChannel(t), 2)
    }

    func testInterleavedVideoChannel() {
        XCTAssertEqual(RTPParser.interleavedRTPChannel("RTP/AVP/TCP;unicast;interleaved=0-1"), 0)
    }

    func testServerRenumberedChannel() {
        XCTAssertEqual(RTPParser.interleavedRTPChannel("RTP/AVP/TCP;interleaved=4-5"), 4)
    }

    func testNoInterleaved() {
        XCTAssertNil(RTPParser.interleavedRTPChannel("RTP/AVP/TCP;unicast;client_port=5000-5001"))
    }
}

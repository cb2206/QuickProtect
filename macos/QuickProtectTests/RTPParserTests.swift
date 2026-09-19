import XCTest

final class InterleavedFrameTests: XCTestCase {

    func testExtractSingleFrame() {
        let buffer: [UInt8] = [0x24, 0x00, 0x00, 0x04, 0xAA, 0xBB, 0xCC, 0xDD]
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].channel, 0)
        XCTAssertEqual(frames[0].payloadLength, 4)
        XCTAssertEqual(consumed, 8)
    }

    func testExtractMultipleFrames() {
        let buffer: [UInt8] = [
            0x24, 0x00, 0x00, 0x02, 0x11, 0x22,
            0x24, 0x01, 0x00, 0x02, 0x33, 0x44,
        ]
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].channel, 0)
        XCTAssertEqual(frames[1].channel, 1)
        XCTAssertEqual(consumed, 12)
    }

    func testExtractIncompleteFrame() {
        let buffer: [UInt8] = [0x24, 0x00, 0x00, 0x0A, 0x11, 0x22]
        let (frames, _) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        XCTAssertEqual(frames.count, 0)
    }

    func testStrayByteRecovery() {
        let buffer: [UInt8] = [0xFF, 0xFE, 0x24, 0x00, 0x00, 0x02, 0x11, 0x22]
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(consumed, 8)
    }

    func testMarkerBitSet() {
        let rtp: [UInt8] = [0x80, 0xE0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05]
        let len = UInt16(rtp.count)
        let buffer: [UInt8] = [0x24, 0x00, UInt8(len >> 8), UInt8(len & 0xFF)] + rtp
        let (frames, _) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        XCTAssertTrue(frames[0].markerBit)
    }

    func testMarkerBitClear() {
        let rtp: [UInt8] = [0x80, 0x60, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05]
        let len = UInt16(rtp.count)
        let buffer: [UInt8] = [0x24, 0x00, UInt8(len >> 8), UInt8(len & 0xFF)] + rtp
        let (frames, _) = RTPParser.extractInterleavedFrames(from: buffer, offset: 0)
        XCTAssertFalse(frames[0].markerBit)
    }
}

final class RTPHeaderTests: XCTestCase {

    func testBasicHeader() {
        let buffer: [UInt8] = [0x80, 0xE1, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF]
        let result = RTPParser.parseRTPHeader(buffer, offset: 0, length: buffer.count)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.marker)
        XCTAssertEqual(result!.headerLength, 12)
    }

    func testHeaderWithCSRC() {
        var buffer: [UInt8] = Array(repeating: 0, count: 20)
        buffer[0] = 0x81
        let result = RTPParser.parseRTPHeader(buffer, offset: 0, length: buffer.count)
        XCTAssertEqual(result!.headerLength, 16)
    }

    func testHeaderTooShort() {
        XCTAssertNil(RTPParser.parseRTPHeader([0x80, 0xE1, 0x00], offset: 0, length: 3))
    }
}

final class H264NALTests: XCTestCase {

    func testSingleNAL() {
        let payload: [UInt8] = [0x61, 0xAA, 0xBB]
        let nals = RTPParser.parseH264Payload(payload)
        XCTAssertEqual(nals.count, 1)
        XCTAssertEqual(nals[0], payload)
    }

    func testSTAPA() {
        let nal1: [UInt8] = [0x67, 0x42, 0x00]
        let nal2: [UInt8] = [0x68, 0xCE]
        var payload: [UInt8] = [24]
        payload += [0x00, UInt8(nal1.count)] + nal1
        payload += [0x00, UInt8(nal2.count)] + nal2
        let nals = RTPParser.parseH264Payload(payload)
        XCTAssertEqual(nals.count, 2)
        XCTAssertEqual(nals[0], nal1)
        XCTAssertEqual(nals[1], nal2)
    }

    func testSTAPAEmpty() {
        XCTAssertEqual(RTPParser.parseH264Payload([24]).count, 0)
    }

    func testSTAPATruncated() {
        XCTAssertEqual(RTPParser.parseH264Payload([24, 0x00, 0x0A, 0x11, 0x22]).count, 0)
    }

    func testFUAHeaderReconstruction() {
        let header = RTPParser.reconstructH264FUAHeader(fuIndicator: 0x7C, fuHeader: 0x85)
        XCTAssertEqual(header, 0x65)
    }

    func testFUAFlags() {
        let (start, end, nalType) = RTPParser.parseFUAFlags(0x85)
        XCTAssertTrue(start)
        XCTAssertFalse(end)
        XCTAssertEqual(nalType, 5)
    }
}

final class H265NALTests: XCTestCase {

    func testSingleNAL() {
        let payload: [UInt8] = [0x02, 0x01, 0xAA]
        let nals = RTPParser.parseH265Payload(payload)
        XCTAssertEqual(nals.count, 1)
    }

    func testAggregationPacket() {
        let nal1: [UInt8] = [0x40, 0x01, 0xAA]
        let nal2: [UInt8] = [0x42, 0x01, 0xBB]
        var payload: [UInt8] = [0x60, 0x01]
        payload += [0x00, UInt8(nal1.count)] + nal1
        payload += [0x00, UInt8(nal2.count)] + nal2
        let nals = RTPParser.parseH265Payload(payload)
        XCTAssertEqual(nals.count, 2)
    }

    func testFUHeaderReconstruction() {
        let (hdr0, hdr1) = RTPParser.reconstructH265FUHeader(byte0: 0x63, byte1: 0x01, fuHeader: 0xA0)
        XCTAssertEqual(hdr0, 0x41)
        XCTAssertEqual(hdr1, 0x01)
    }

    func testFUFlags() {
        let (start, end, nalType) = RTPParser.parseH265FUFlags(0xA0)
        XCTAssertTrue(start)
        XCTAssertFalse(end)
        XCTAssertEqual(nalType, 32)
    }
}

final class NALClassificationTests: XCTestCase {

    func testH264Types() {
        XCTAssertEqual(RTPParser.classifyH264NAL(0x65), .idr)
        XCTAssertEqual(RTPParser.classifyH264NAL(0x67), .sps)
        XCTAssertEqual(RTPParser.classifyH264NAL(0x68), .pps)
        XCTAssertEqual(RTPParser.classifyH264NAL(0x09), .aud)
        XCTAssertEqual(RTPParser.classifyH264NAL(0x61), .data(type: 1))
    }

    func testH265Types() {
        XCTAssertEqual(RTPParser.classifyH265NAL(0x40), .vps)
        XCTAssertEqual(RTPParser.classifyH265NAL(0x42), .sps)
        XCTAssertEqual(RTPParser.classifyH265NAL(0x44), .pps)
        XCTAssertEqual(RTPParser.classifyH265NAL(0x26), .keyframe(type: 19))
        XCTAssertEqual(RTPParser.classifyH265NAL(0x02), .data(type: 1))
    }

    func testH265KeyframeRange() {
        for t: UInt8 in 16...21 {
            XCTAssertEqual(RTPParser.classifyH265NAL(t << 1), .keyframe(type: t), "Type \(t)")
        }
    }
}

final class AVCCTests: XCTestCase {

    func testSingleNAL() {
        let nal: [UInt8] = [0x65, 0xAA, 0xBB, 0xCC]
        let avcc = RTPParser.nalsToAVCC([nal])
        XCTAssertEqual(avcc.count, 8)
        XCTAssertEqual(Array(avcc[0...3]), [0x00, 0x00, 0x00, 0x04])
        XCTAssertEqual(Array(avcc[4...]), nal)
    }

    func testMultipleNALs() {
        let avcc = RTPParser.nalsToAVCC([[0x01, 0x02], [0x03, 0x04, 0x05]])
        XCTAssertEqual(avcc.count, 13)
        XCTAssertEqual(avcc[3], 2)
        XCTAssertEqual(avcc[9], 3)
    }

    func testEmpty() {
        XCTAssertEqual(RTPParser.nalsToAVCC([]).count, 0)
    }

    func testLargeLength() {
        let avcc = RTPParser.nalsToAVCC([[UInt8](repeating: 0xAA, count: 300)])
        XCTAssertEqual(avcc.count, 304)
        XCTAssertEqual(avcc[2], 0x01)
        XCTAssertEqual(avcc[3], 0x2C)
    }
}

final class BitReaderTests: XCTestCase {

    func testReadAcrossByteBoundary() {
        var reader = RTPParser.BitReader([0b1010_1100, 0b1111_0000])
        XCTAssertEqual(reader.read(3), 0b101)
        XCTAssertEqual(reader.read(5), 0b01100)
        XCTAssertEqual(reader.read(4), 0b1111)
    }

    func testReadPastEndReturnsNil() {
        var reader = RTPParser.BitReader([0xFF])
        XCTAssertEqual(reader.read(8), 0xFF)
        XCTAssertNil(reader.read(1))
    }
}

final class AudioSpecificConfigTests: XCTestCase {

    func testAACLC16kMono() {
        // 0x1408: objectType=2 (AAC-LC), freqIndex=8 (16000), channels=1
        let asc = RTPParser.parseAudioSpecificConfig([0x14, 0x08])
        XCTAssertEqual(asc?.objectType, 2)
        XCTAssertEqual(asc?.sampleRate, 16000)
        XCTAssertEqual(asc?.channels, 1)
    }

    func testAACLC48kStereo() {
        // 0x1190: objectType=2, freqIndex=3 (48000), channels=2
        let asc = RTPParser.parseAudioSpecificConfig([0x11, 0x90])
        XCTAssertEqual(asc?.objectType, 2)
        XCTAssertEqual(asc?.sampleRate, 48000)
        XCTAssertEqual(asc?.channels, 2)
    }

    func testTruncatedReturnsNil() {
        XCTAssertNil(RTPParser.parseAudioSpecificConfig([0x14]))
    }
}

final class AACDepacketizeTests: XCTestCase {

    func testSingleAU() {
        // AU-headers-length = 16 bits; one AU-header (size=3<<3=... ) → size 3, index 0
        // size field 13 bits = 3, index 3 bits = 0 → 0b0000000000011_000 = 0x00 0x18
        let payload: [UInt8] = [0x00, 0x10, 0x00, 0x18, 0xAA, 0xBB, 0xCC]
        let aus = RTPParser.depacketizeAAC(payload, sizeLength: 13, indexLength: 3, indexDeltaLength: 3)
        XCTAssertEqual(aus.count, 1)
        XCTAssertEqual(aus[0], [0xAA, 0xBB, 0xCC])
    }

    func testTwoAUs() {
        // Two AU-headers (32 bits): AU0 size=2 idx=0, AU1 size=1 idxDelta=1
        // header0: 0000000000010_000 = 0x00 0x10 ; header1: 0000000000001_001 = 0x00 0x09
        let payload: [UInt8] = [0x00, 0x20, 0x00, 0x10, 0x00, 0x09, 0xAA, 0xBB, 0xCC]
        let aus = RTPParser.depacketizeAAC(payload, sizeLength: 13, indexLength: 3, indexDeltaLength: 3)
        XCTAssertEqual(aus.count, 2)
        XCTAssertEqual(aus[0], [0xAA, 0xBB])
        XCTAssertEqual(aus[1], [0xCC])
    }

    func testFragmentedAUDropped() {
        // One AU-header declares size 10 but only 3 data bytes present → dropped.
        let payload: [UInt8] = [0x00, 0x10, 0x00, 0x50, 0xAA, 0xBB, 0xCC]
        let aus = RTPParser.depacketizeAAC(payload, sizeLength: 13, indexLength: 3, indexDeltaLength: 3)
        XCTAssertEqual(aus.count, 0)
    }

    func testAUSizesReported() {
        let payload: [UInt8] = [0x00, 0x10, 0x00, 0x50, 0xAA, 0xBB, 0xCC]
        let info = RTPParser.aacAUSizes(payload, sizeLength: 13, indexLength: 3, indexDeltaLength: 3)
        XCTAssertEqual(info?.sizes, [10])
        XCTAssertEqual(info?.dataOffset, 4)
    }
}

final class AACDepacketizerTests: XCTestCase {

    private func makeDepacketizer() -> RTPParser.AACDepacketizer {
        RTPParser.AACDepacketizer(sizeLength: 13, indexLength: 3, indexDeltaLength: 3)
    }

    // AU-header for a declared size: 13-bit size + 3-bit index(0). 16-bit headers-length.
    private func packet(declaredSize: Int, data: [UInt8]) -> [UInt8] {
        let header = UInt16(declaredSize) << 3   // size in top 13 bits, index 0 in low 3
        return [0x00, 0x10, UInt8(header >> 8), UInt8(header & 0xFF)] + data
    }

    func testCompleteSingleAU() {
        var dep = makeDepacketizer()
        let aus = dep.receive(packet(declaredSize: 3, data: [0xAA, 0xBB, 0xCC]), marker: true)
        XCTAssertEqual(aus, [[0xAA, 0xBB, 0xCC]])
    }

    func testTwoPacketFragment() {
        var dep = makeDepacketizer()
        // Declared AU size 10, delivered as 6 + 4 bytes across two packets.
        let first  = dep.receive(packet(declaredSize: 10, data: [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5]), marker: false)
        XCTAssertEqual(first, [])   // mid-fragment, nothing yet
        let second = dep.receive(packet(declaredSize: 10, data: [0xB0, 0xB1, 0xB2, 0xB3]), marker: true)
        XCTAssertEqual(second, [[0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xB0, 0xB1, 0xB2, 0xB3]])
    }

    func testThreePacketFragment() {
        var dep = makeDepacketizer()
        XCTAssertEqual(dep.receive(packet(declaredSize: 9, data: [1, 2, 3]), marker: false), [])
        XCTAssertEqual(dep.receive(packet(declaredSize: 9, data: [4, 5, 6]), marker: false), [])
        XCTAssertEqual(dep.receive(packet(declaredSize: 9, data: [7, 8, 9]), marker: true),
                       [[1, 2, 3, 4, 5, 6, 7, 8, 9]])
    }

    func testCompleteAUAfterFragment() {
        var dep = makeDepacketizer()
        _ = dep.receive(packet(declaredSize: 6, data: [1, 2, 3]), marker: false)
        _ = dep.receive(packet(declaredSize: 6, data: [4, 5, 6]), marker: true)
        // Reassembler is clean again: a normal complete AU passes straight through.
        let aus = dep.receive(packet(declaredSize: 2, data: [0xEE, 0xFF]), marker: true)
        XCTAssertEqual(aus, [[0xEE, 0xFF]])
    }
}

final class AccessUnitKeyframeTests: XCTestCase {

    // NAL header bytes: H.264 type is the low 5 bits; HEVC type is bits 1–6.
    private let h264SEI: [UInt8] = [0x06, 0x05, 0x00]
    private let h264AUD: [UInt8] = [0x09, 0xF0]
    private let h264IDR: [UInt8] = [0x65, 0x88, 0x84]
    private let h264P: [UInt8]   = [0x41, 0x9A, 0x00]
    private let hevcSEI: [UInt8] = [0x4E, 0x01, 0x05]   // type 39 (prefix SEI)
    private let hevcIDR: [UInt8] = [0x26, 0x01, 0xAF]   // type 19 (IDR_W_RADL)
    private let hevcP: [UInt8]   = [0x02, 0x01, 0xD0]   // type 1 (TRAIL_R)

    func testH264IdrFirst() {
        XCTAssertTrue(RTPParser.accessUnitContainsKeyframe([h264IDR, h264P], hevc: false))
    }

    func testH264SeiBeforeIdrStillCountsAsKeyframe() {
        XCTAssertTrue(RTPParser.accessUnitContainsKeyframe([h264SEI, h264IDR], hevc: false))
        XCTAssertTrue(RTPParser.accessUnitContainsKeyframe([h264AUD, h264SEI, h264IDR], hevc: false))
    }

    func testH264PFrameOnlyIsNotKeyframe() {
        XCTAssertFalse(RTPParser.accessUnitContainsKeyframe([h264SEI, h264P], hevc: false))
        XCTAssertFalse(RTPParser.accessUnitContainsKeyframe([], hevc: false))
        XCTAssertFalse(RTPParser.accessUnitContainsKeyframe([[]], hevc: false))
    }

    func testHevcIrapAnywhere() {
        XCTAssertTrue(RTPParser.accessUnitContainsKeyframe([hevcIDR], hevc: true))
        XCTAssertTrue(RTPParser.accessUnitContainsKeyframe([hevcSEI, hevcIDR], hevc: true))
        XCTAssertFalse(RTPParser.accessUnitContainsKeyframe([hevcSEI, hevcP], hevc: true))
    }

    func testCodecFlagMatters() {
        // An H.264 IDR byte (0x65) parsed as HEVC is type 50, not an IRAP.
        XCTAssertFalse(RTPParser.accessUnitContainsKeyframe([h264IDR], hevc: true))
    }
}

final class RTPPayloadRangeTests: XCTestCase {

    /// 12-byte fixed header with the given flags byte and marker, followed by payload.
    private func packet(flags: UInt8, marker: Bool = false, payload: [UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 12)
        p[0] = flags
        p[1] = marker ? 0x80 | 96 : 96
        return p + payload
    }

    func testPlainPacket() {
        let p = packet(flags: 0x80, marker: true, payload: [1, 2, 3])
        let r = RTPParser.rtpPayloadRange(p, offset: 0, length: p.count)
        XCTAssertEqual(r?.marker, true)
        XCTAssertEqual(r?.start, 12)
        XCTAssertEqual(r?.end, 15)
    }

    func testCsrcListSkipped() {
        // CC = 2 → two 4-byte CSRC entries after the fixed header.
        let p = packet(flags: 0x82, payload: [0, 0, 0, 0, 0, 0, 0, 0, 9, 9])
        let r = RTPParser.rtpPayloadRange(p, offset: 0, length: p.count)
        XCTAssertEqual(r?.start, 20)
        XCTAssertEqual(r?.end, 22)
    }

    func testPaddingStripped() {
        // P bit set; payload [7, 7, pad, pad, pad=3] → last byte says 3 padding bytes.
        let p = packet(flags: 0xA0, payload: [7, 7, 0, 0, 3])
        let r = RTPParser.rtpPayloadRange(p, offset: 0, length: p.count)
        XCTAssertEqual(r?.start, 12)
        XCTAssertEqual(r?.end, 14)
    }

    func testExtensionSkipped() {
        // X bit set; extension header: profile (2 bytes) + length=1 word → 4 more bytes.
        let p = packet(flags: 0x90, payload: [0xBE, 0xDE, 0x00, 0x01, 0xAA, 0xAA, 0xAA, 0xAA, 5, 6])
        let r = RTPParser.rtpPayloadRange(p, offset: 0, length: p.count)
        XCTAssertEqual(r?.start, 20)
        XCTAssertEqual(r?.end, 22)
    }

    func testMalformedReturnsNil() {
        XCTAssertNil(RTPParser.rtpPayloadRange([UInt8](repeating: 0, count: 12), offset: 0, length: 12))
        // Padding count larger than the payload.
        let p = packet(flags: 0xA0, payload: [1, 2, 9])
        XCTAssertNil(RTPParser.rtpPayloadRange(p, offset: 0, length: p.count))
        // Extension claims more words than present.
        let e = packet(flags: 0x90, payload: [0, 0, 0x10, 0x00, 1])
        XCTAssertNil(RTPParser.rtpPayloadRange(e, offset: 0, length: e.count))
    }

    func testOffsetInsideLargerBuffer() {
        let p = [0xFF, 0xFF] + packet(flags: 0x80, payload: [4, 4])
        let r = RTPParser.rtpPayloadRange(p, offset: 2, length: p.count - 2)
        XCTAssertEqual(r?.start, 14)
        XCTAssertEqual(r?.end, 16)
    }
}

final class RTSPResponseHeaderTests: XCTestCase {

    func testHeaderParsedBeforeBodyArrives() {
        let text = "RTSP/1.0 200 OK\r\nCSeq: 2\r\nContent-Length: 10\r\nSession: 12345;timeout=60\r\n\r\nabc"
        let buf = Array(text.utf8)
        let head = RTPParser.parseResponseHeader(buf, from: 0)
        XCTAssertEqual(head?.statusCode, 200)
        XCTAssertEqual(head?.contentLength, 10)
        XCTAssertEqual(head?.headers["session"], "12345;timeout=60")
        // Body incomplete → the full parse still waits.
        XCTAssertNil(RTPParser.parseResponse(buf, from: 0))
    }

    func testNegativeContentLengthReadsAsZero() {
        let text = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nContent-Length: -5\r\n\r\n"
        let buf = Array(text.utf8)
        XCTAssertEqual(RTPParser.parseResponseHeader(buf, from: 0)?.contentLength, 0)
        let r = RTPParser.parseResponse(buf, from: 0)
        XCTAssertEqual(r?.totalLength, buf.count)
        XCTAssertNil(r?.body)
    }

    func testNoTerminatorYet() {
        XCTAssertNil(RTPParser.parseResponseHeader(Array("RTSP/1.0 200 OK\r\nCSeq: 1\r\n".utf8), from: 0))
    }
}

final class InterleavedConsumptionTests: XCTestCase {

    func testStrayBytesWithoutDollarConsumeWholeBuffer() {
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: [1, 2, 3, 4, 5], offset: 0)
        XCTAssertTrue(frames.isEmpty)
        XCTAssertEqual(consumed, 5)
    }

    func testResyncsAtNextDollar() {
        let buf: [UInt8] = [0xAA, 0xBB, 0x24, 0x00, 0x00, 0x02, 0x11, 0x22]
        let (frames, consumed) = RTPParser.extractInterleavedFrames(from: buf, offset: 0)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payloadOffset, 6)
        XCTAssertEqual(consumed, 8)
    }
}

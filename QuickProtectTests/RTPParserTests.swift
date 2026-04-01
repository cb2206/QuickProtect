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

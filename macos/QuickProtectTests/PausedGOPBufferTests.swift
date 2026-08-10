import XCTest

/// Tests for the render-pause GOP buffer: the pure policy deciding which
/// compressed access units survive a pause so resume can burst-decode a valid
/// GOP (see RTSPClient.setRenderPaused).
final class PausedGOPBufferTests: XCTestCase {

    /// One access unit of `size` bytes as a single NAL.
    private func au(_ size: Int, fill: UInt8 = 0) -> [[UInt8]] {
        [[UInt8](repeating: fill, count: size)]
    }

    func testStartsEmptyAndIgnoresMidGOPFrames() {
        var buf = PausedGOPBuffer()
        XCTAssertTrue(buf.isEmpty)
        buf.add(au(100), isKeyframe: false)
        XCTAssertTrue(buf.isEmpty, "frames with no anchoring keyframe are undecodable")
    }

    func testBuffersFromKeyframe() {
        var buf = PausedGOPBuffer()
        buf.add(au(100), isKeyframe: true)
        buf.add(au(50), isKeyframe: false)
        XCTAssertEqual(buf.accessUnits.count, 2)
    }

    func testNewKeyframeRestartsBuffer() {
        var buf = PausedGOPBuffer()
        buf.add(au(100, fill: 1), isKeyframe: true)
        buf.add(au(50, fill: 2), isKeyframe: false)
        buf.add(au(100, fill: 3), isKeyframe: true)
        buf.add(au(50, fill: 4), isKeyframe: false)
        XCTAssertEqual(buf.accessUnits.count, 2, "only the latest GOP is kept")
        XCTAssertEqual(buf.accessUnits.first?.first?.first, 3)
    }

    func testOverflowDropsGOPUntilNextKeyframe() {
        var buf = PausedGOPBuffer(byteLimit: 200)
        buf.add(au(150), isKeyframe: true)
        buf.add(au(100), isKeyframe: false)   // 250 > 200 → dropped
        XCTAssertTrue(buf.isEmpty)
        buf.add(au(50), isKeyframe: false)    // still dropped — no keyframe yet
        XCTAssertTrue(buf.isEmpty)
        buf.add(au(50), isKeyframe: true)     // fresh keyframe restarts buffering
        buf.add(au(50), isKeyframe: false)
        XCTAssertEqual(buf.accessUnits.count, 2)
    }

    func testDrainReturnsInOrderAndResets() {
        var buf = PausedGOPBuffer()
        buf.add(au(10, fill: 1), isKeyframe: true)
        buf.add(au(10, fill: 2), isKeyframe: false)
        let gop = buf.drain()
        XCTAssertEqual(gop.count, 2)
        XCTAssertEqual(gop[0][0][0], 1)
        XCTAssertEqual(gop[1][0][0], 2)
        XCTAssertTrue(buf.isEmpty)
        // The drained buffer accepts a fresh GOP again.
        buf.add(au(10), isKeyframe: true)
        XCTAssertEqual(buf.accessUnits.count, 1)
    }

    func testDrainAfterOverflowIsEmptyButReusable() {
        var buf = PausedGOPBuffer(byteLimit: 100)
        buf.add(au(150), isKeyframe: true)    // immediately over the limit
        XCTAssertTrue(buf.drain().isEmpty)
        buf.add(au(50), isKeyframe: true)
        XCTAssertEqual(buf.accessUnits.count, 1, "drain clears the dropped state")
    }
}

import XCTest

final class BitrateMeterTests: XCTestCase {
    func testFirstSampleHasNoRateThenRatesFollowTheByteDelta() {
        var meter = BitrateMeter()
        XCTAssertNil(meter.sample(totalBytes: 1_000, at: 10))
        // 500 kB in 2 s = 2 Mbit/s.
        XCTAssertEqual(meter.sample(totalBytes: 501_000, at: 12), 2_000_000)
    }

    func testStalledClockOrShrinkingTotalGivesNoRate() {
        var meter = BitrateMeter()
        _ = meter.sample(totalBytes: 1_000, at: 1)
        XCTAssertNil(meter.sample(totalBytes: 2_000, at: 1))
        XCTAssertNil(meter.sample(totalBytes: 10, at: 2))
        XCTAssertNotNil(meter.sample(totalBytes: 20, at: 3))
    }

    func testFormatSwitchesUnitsAndUsesTheLocaleDecimalSeparator() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(BitrateMeter.format(bitsPerSecond: 0, locale: en), "0 kbps")
        XCTAssertEqual(BitrateMeter.format(bitsPerSecond: 850_400, locale: en), "850 kbps")
        XCTAssertEqual(BitrateMeter.format(bitsPerSecond: 999_499, locale: en), "999 kbps")
        XCTAssertEqual(BitrateMeter.format(bitsPerSecond: 999_500, locale: en), "1.0 Mbps")
        XCTAssertEqual(BitrateMeter.format(bitsPerSecond: 4_240_000, locale: en), "4.2 Mbps")
        XCTAssertEqual(BitrateMeter.format(bitsPerSecond: 4_240_000, locale: Locale(identifier: "de_DE")), "4,2 Mbps")
        XCTAssertEqual(BitrateMeter.format(bitsPerSecond: 12_000_000, locale: Locale(identifier: "fr_FR")), "12,0 Mbps")
    }

    func testStreamTrafficAccumulates() {
        let before = StreamTraffic.shared.totalBytes
        StreamTraffic.shared.add(1234)
        XCTAssertGreaterThanOrEqual(StreamTraffic.shared.totalBytes - before, 1234)
    }
}

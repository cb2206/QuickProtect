import XCTest

/// Tests for the pinned window's stream-recovery pacing.
final class StreamRecoveryBackoffTests: XCTestCase {

    func testDelaysDoubleFromFiveSecondsToSixtySecondCap() {
        var backoff = StreamRecoveryBackoff()
        let delays = (0..<7).compactMap { _ in backoff.failed() }
        XCTAssertEqual(delays, [5, 10, 20, 40, 60, 60, 60])
    }

    func testRecoveryResetsToInitialDelay() {
        var backoff = StreamRecoveryBackoff()
        _ = backoff.failed()
        _ = backoff.failed()
        _ = backoff.failed()
        backoff.recovered()
        XCTAssertEqual(backoff.failed(), 5)
        XCTAssertEqual(backoff.failed(), 10)
    }

    func testStopEndsRetries() {
        var backoff = StreamRecoveryBackoff()
        XCTAssertEqual(backoff.failed(), 5)
        backoff.stop()
        XCTAssertTrue(backoff.isStopped)
        XCTAssertNil(backoff.failed())
    }

    func testStopSurvivesALateRecovery() {
        // A frame that was already on its way when the window closed must not
        // re-arm retries.
        var backoff = StreamRecoveryBackoff()
        backoff.stop()
        backoff.recovered()
        XCTAssertNil(backoff.failed())
    }
}

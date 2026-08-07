import XCTest

/// Tests for the pure controller request-policy rules (fetch throttling, PTZ
/// enrichment throttling, quality-ladder abort) and the stream keep-alive
/// clamping. All UserDefaults- and network-free.
final class ControllerRequestPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Fetch throttle

    func testFirstFetchIsNeverSkipped() {
        XCTAssertFalse(ControllerRequestPolicy.shouldSkipFetch(lastSuccess: nil, now: now))
    }

    func testFreshFetchIsSkipped() {
        let last = now.addingTimeInterval(-1)
        XCTAssertTrue(ControllerRequestPolicy.shouldSkipFetch(lastSuccess: last, now: now))
    }

    func testStaleFetchIsNotSkipped() {
        let last = now.addingTimeInterval(-ControllerRequestPolicy.fetchInterval)
        XCTAssertFalse(ControllerRequestPolicy.shouldSkipFetch(lastSuccess: last, now: now))
    }

    // MARK: - PTZ enrichment throttle

    private func record(agoSeconds: TimeInterval, username: String = "u",
                        password: String = "p") -> ControllerRequestPolicy.PtzEnrichRecord {
        ControllerRequestPolicy.PtzEnrichRecord(
            at: now.addingTimeInterval(-agoSeconds), username: username, password: password)
    }

    func testPtzEnrichRunsWhenNeverEnriched() {
        XCTAssertFalse(ControllerRequestPolicy.shouldSkipPtzEnrich(
            last: nil, username: "u", password: "p", now: now))
    }

    func testPtzEnrichSkippedWhenRecentWithSameCredentials() {
        XCTAssertTrue(ControllerRequestPolicy.shouldSkipPtzEnrich(
            last: record(agoSeconds: 10), username: "u", password: "p", now: now))
    }

    func testPtzEnrichRunsWhenCredentialsChanged() {
        XCTAssertFalse(ControllerRequestPolicy.shouldSkipPtzEnrich(
            last: record(agoSeconds: 10, password: "old"),
            username: "u", password: "new", now: now))
    }

    func testPtzEnrichRunsAgainAfterInterval() {
        XCTAssertFalse(ControllerRequestPolicy.shouldSkipPtzEnrich(
            last: record(agoSeconds: ControllerRequestPolicy.ptzEnrichInterval),
            username: "u", password: "p", now: now))
    }

    // MARK: - Quality-ladder abort

    func testRateLimitAndServerErrorsAbortLadder() {
        XCTAssertTrue(ControllerRequestPolicy.abortsQualityLadder(httpStatus: 429))
        XCTAssertTrue(ControllerRequestPolicy.abortsQualityLadder(httpStatus: 500))
        XCTAssertTrue(ControllerRequestPolicy.abortsQualityLadder(httpStatus: 503))
    }

    func testQualityErrorsContinueLadder() {
        XCTAssertFalse(ControllerRequestPolicy.abortsQualityLadder(httpStatus: 400))
        XCTAssertFalse(ControllerRequestPolicy.abortsQualityLadder(httpStatus: 404))
    }

    // MARK: - Keep-alive clamping

    func testKeepAliveClampsToRange() {
        XCTAssertEqual(AppSettings.clampStreamKeepAlive(-5), 0)
        XCTAssertEqual(AppSettings.clampStreamKeepAlive(0), 0)
        XCTAssertEqual(AppSettings.clampStreamKeepAlive(10), 10)
        XCTAssertEqual(AppSettings.clampStreamKeepAlive(600), 60)
    }

    func testKeepAliveDefaultIsInRange() {
        XCTAssertTrue(AppSettings.streamKeepAliveRange.contains(AppSettings.streamKeepAliveDefault))
    }
}

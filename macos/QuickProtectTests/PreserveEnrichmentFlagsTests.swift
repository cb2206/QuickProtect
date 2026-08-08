import XCTest

/// `Camera.preservingEnrichmentFlags` carries PTZ capability flags forward
/// across Integration-API refreshes (whose payloads never include them), so a
/// panel reopen inside the enrichment throttle window doesn't wipe PTZ chips,
/// overlay, and movement. Mirrors the .NET PreserveEnrichmentFlagsTests.
final class PreserveEnrichmentFlagsTests: XCTestCase {

    private func camera(_ id: String, isPtz: Bool = false, canZoom: Bool = false) -> Camera {
        Camera(id: id, name: id, state: "CONNECTED", channels: [],
               isPtz: isPtz, canZoom: canZoom, secondaryLens: nil)
    }

    func testCarriesPtzFlagForwardById() {
        let previous = [camera("a", isPtz: true), camera("b")]
        let fresh = [camera("a"), camera("b")]

        let merged = Camera.preservingEnrichmentFlags(from: previous, into: fresh)
        XCTAssertTrue(merged[0].isPtz, "enriched flag must survive an unenriched refresh")
        XCTAssertFalse(merged[1].isPtz)
    }

    func testCarriesZoomFlagIndependentlyOfPtz() {
        // A zoom-only camera (optical lens, no pan/tilt motor) keeps just canZoom.
        let previous = [camera("z", canZoom: true)]
        let fresh = [camera("z")]

        let merged = Camera.preservingEnrichmentFlags(from: previous, into: fresh)
        XCTAssertTrue(merged[0].canZoom)
        XCTAssertFalse(merged[0].isPtz)
    }

    func testDoesNotFlagPreviouslyUnflaggedCameras() {
        let previous = [camera("a", isPtz: true, canZoom: true), camera("b")]
        let fresh = [camera("b")]

        let merged = Camera.preservingEnrichmentFlags(from: previous, into: fresh)
        XCTAssertFalse(merged[0].isPtz)
        XCTAssertFalse(merged[0].canZoom)
    }

    func testRemovedCameraIsNotResurrected() {
        let previous = [camera("gone", isPtz: true), camera("kept", isPtz: true)]
        let fresh = [camera("kept")]

        let merged = Camera.preservingEnrichmentFlags(from: previous, into: fresh)
        XCTAssertEqual(merged.map(\.id), ["kept"])
        XCTAssertTrue(merged[0].isPtz)
    }

    func testNewCameraStaysUnflagged() {
        let previous = [camera("a", isPtz: true)]
        let fresh = [camera("a"), camera("new")]

        let merged = Camera.preservingEnrichmentFlags(from: previous, into: fresh)
        XCTAssertTrue(merged[0].isPtz)
        XCTAssertFalse(merged[1].isPtz)
        XCTAssertFalse(merged[1].canZoom)
    }

    func testOnlyEverSetsFlagsTrue() {
        // A fresh camera already flagged true (e.g. from a cached list) must not
        // be cleared by a previous list where it was false — the merge only
        // sets flags, it never clears; clearing is the enrichment's job.
        let previous = [camera("a", isPtz: false, canZoom: false), camera("b", isPtz: true)]
        let fresh = [camera("a", isPtz: true, canZoom: true), camera("b")]

        let merged = Camera.preservingEnrichmentFlags(from: previous, into: fresh)
        XCTAssertTrue(merged[0].isPtz)
        XCTAssertTrue(merged[0].canZoom)
        XCTAssertTrue(merged[1].isPtz)
    }

    func testEmptyPreviousListLeavesFreshUntouched() {
        let fresh = [camera("a"), camera("b")]

        let merged = Camera.preservingEnrichmentFlags(from: [], into: fresh)
        XCTAssertEqual(merged.map(\.id), ["a", "b"])
        XCTAssertFalse(merged.contains { $0.isPtz || $0.canZoom })
    }

    func testEmptyFreshListStaysEmpty() {
        let previous = [camera("a", isPtz: true)]

        let merged = Camera.preservingEnrichmentFlags(from: previous, into: [])
        XCTAssertTrue(merged.isEmpty)
    }
}

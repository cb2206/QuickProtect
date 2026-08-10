import XCTest
import AppKit

/// Tests for the pinned floating-window value types: the persisted
/// `PinnedCameraState` round-trip and the pure `PinnedWindowGeometry` sizing
/// math. Both are UserDefaults-free, so they're verified in isolation.
final class PinnedCameraTests: XCTestCase {

    // MARK: - PinnedCameraState round-trip

    func testFrameRoundTrips() {
        let frame = NSRect(x: 120, y: 340, width: 480, height: 270)
        let dict = PinnedCameraState(cameraId: "cam1", frame: frame).dictionary
        let restored = PinnedCameraState(cameraId: "cam1", dictionary: dict)
        XCTAssertEqual(restored.cameraId, "cam1")
        XCTAssertEqual(restored.frame, frame)
    }

    func testNilFrameProducesEmptyDictionary() {
        let dict = PinnedCameraState(cameraId: "cam1", frame: nil).dictionary
        XCTAssertTrue(dict.isEmpty)
        // An empty dict still reads back as "pinned but unpositioned".
        XCTAssertNil(PinnedCameraState(cameraId: "cam1", dictionary: dict).frame)
    }

    func testZeroSizeIsTreatedAsUnpositioned() {
        let bad = ["x": 10.0, "y": 10.0, "w": 0.0, "h": 0.0]
        XCTAssertNil(PinnedCameraState(cameraId: "cam1", dictionary: bad).frame)
    }

    func testPartialDictionaryIsRejected() {
        let partial = ["x": 10.0, "y": 10.0]   // missing w/h
        XCTAssertNil(PinnedCameraState(cameraId: "cam1", dictionary: partial).frame)
    }

    // MARK: - PinnedWindowGeometry.defaultSize

    func testDefaultSizeMatchesAspectRatio() {
        let size = PinnedWindowGeometry.defaultSize(aspectRatio: 16.0 / 9.0, targetWidth: 360)
        XCTAssertEqual(size.width, 360)
        XCTAssertEqual(size.height, (360.0 / (16.0 / 9.0)).rounded())
    }

    func testDefaultSizeFourThree() {
        let size = PinnedWindowGeometry.defaultSize(aspectRatio: 4.0 / 3.0, targetWidth: 360)
        XCTAssertEqual(size.width, 360)
        XCTAssertEqual(size.height, 270)
    }

    func testDefaultSizeClampsWidth() {
        let tooWide = PinnedWindowGeometry.defaultSize(aspectRatio: 16.0 / 9.0, targetWidth: 5000)
        XCTAssertEqual(tooWide.width, PinnedWindowGeometry.maxWidth)
        let tooNarrow = PinnedWindowGeometry.defaultSize(aspectRatio: 16.0 / 9.0, targetWidth: 10)
        XCTAssertEqual(tooNarrow.width, PinnedWindowGeometry.minWidth)
    }

    func testDefaultSizeFallsBackOnNonPositiveAspect() {
        let size = PinnedWindowGeometry.defaultSize(aspectRatio: 0, targetWidth: 320)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, (320.0 / PinnedWindowGeometry.fallbackAspect).rounded())
    }

    // MARK: - PinnedWindowGeometry.constrain

    func testConstrainDrivesHeightFromWidth() {
        // A free-form drag to 600×600 must snap height to the 16:9 ratio.
        let constrained = PinnedWindowGeometry.constrain(
            NSSize(width: 600, height: 600), toAspectRatio: 16.0 / 9.0)
        XCTAssertEqual(constrained.width, 600)
        XCTAssertEqual(constrained.height, (600.0 / (16.0 / 9.0)).rounded())
    }

    func testConstrainClampsWidthToRange() {
        let clamped = PinnedWindowGeometry.constrain(
            NSSize(width: 9999, height: 100), toAspectRatio: 16.0 / 9.0)
        XCTAssertEqual(clamped.width, PinnedWindowGeometry.maxWidth)
    }
}

import XCTest
import AppKit

final class PanelPlacementTests: XCTestCase {
    private let main = NSRect(x: 0, y: 0, width: 1440, height: 875)
    private let right = NSRect(x: 1440, y: -200, width: 1920, height: 1055)
    private let size = NSSize(width: 640, height: 400)

    func testLevelFollowsKeepOpen() {
        XCTAssertEqual(PanelPlacement.level(keepOpen: false), .popUpMenu)
        XCTAssertEqual(PanelPlacement.level(keepOpen: true), .floating)
    }

    func testOriginOnScreenIsKept() {
        let saved = NSPoint(x: 100, y: 200)
        XCTAssertEqual(PanelPlacement.restoredOrigin(saved: saved, size: size, visibleFrames: [main, right]), saved)
    }

    func testOriginOnSecondScreenIsKept() {
        let saved = NSPoint(x: 2000, y: 100)
        XCTAssertEqual(PanelPlacement.restoredOrigin(saved: saved, size: size, visibleFrames: [main, right]), saved)
    }

    func testPanelHangingOffTheEdgeIsPulledBack() {
        // Center still on the main screen, right and top edges past it.
        let saved = NSPoint(x: 1000, y: 600)
        let restored = PanelPlacement.restoredOrigin(saved: saved, size: size, visibleFrames: [main])
        XCTAssertEqual(restored, NSPoint(x: main.maxX - size.width, y: main.maxY - size.height))
    }

    func testGoneDisplayGivesNil() {
        // Saved on the right-hand display, which is no longer attached.
        XCTAssertNil(PanelPlacement.restoredOrigin(saved: NSPoint(x: 2000, y: 100), size: size, visibleFrames: [main]))
    }

    func testPanelLargerThanScreenPinsToItsOrigin() {
        let small = NSRect(x: 0, y: 0, width: 500, height: 300)
        let restored = PanelPlacement.restoredOrigin(saved: NSPoint(x: -50, y: -20), size: size, visibleFrames: [small])
        XCTAssertEqual(restored, NSPoint(x: 0, y: 0))
    }
}

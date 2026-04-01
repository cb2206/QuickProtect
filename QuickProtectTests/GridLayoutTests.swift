import XCTest

final class GridLayoutTests: XCTestCase {

    private func cellWidth(span: Int, colWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        CGFloat(span) * colWidth + CGFloat(span - 1) * spacing
    }

    private func panMax(cellSize: CGFloat, zoomScale: CGFloat) -> CGFloat {
        cellSize * (zoomScale - 1) / 2
    }

    func testCellWidthSpan1() { XCTAssertEqual(cellWidth(span: 1, colWidth: 100, spacing: 3), 100) }
    func testCellWidthSpan2() { XCTAssertEqual(cellWidth(span: 2, colWidth: 100, spacing: 3), 203) }
    func testCellWidthSpan4() { XCTAssertEqual(cellWidth(span: 4, colWidth: 100, spacing: 3), 409) }

    func testPanClampAtZoom1() { XCTAssertEqual(panMax(cellSize: 400, zoomScale: 1.0), 0) }
    func testPanClampAtZoom2() { XCTAssertEqual(panMax(cellSize: 400, zoomScale: 2.0), 200) }
    func testPanClampAtZoom4() { XCTAssertEqual(panMax(cellSize: 300, zoomScale: 4.0), 450) }

    func testPanClampSymmetric() {
        let maxPan = panMax(cellSize: 200, zoomScale: 3.0)
        XCTAssertEqual(max(-maxPan, min(maxPan, -999)), -maxPan)
        XCTAssertEqual(max(-maxPan, min(maxPan, 999)), maxPan)
    }

    func testPanWithinRange() {
        let maxPan = panMax(cellSize: 200, zoomScale: 3.0)
        XCTAssertEqual(max(-maxPan, min(maxPan, 50)), 50)
    }
}

import XCTest
import SwiftUI
import AppKit

/// Tests for the Aurora appearance layer added in 0.6: the `Color(hex:)` accent
/// parser, the appearance enum's color-scheme mapping, and the accent swatches.
final class AppearanceTests: XCTestCase {

    // MARK: - Color(hex:)

    /// Resolve a parsed `Color` to its sRGB components for assertion.
    private func rgb(_ hex: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let ns = NSColor(Color(hex: hex)).usingColorSpace(.sRGB)!
        return (ns.redComponent, ns.greenComponent, ns.blueComponent)
    }

    func testParsesDefaultAccentBlue() {
        let c = rgb("0a84ff")
        XCTAssertEqual(c.r, 0x0a / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.g, 0x84 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.b, 0xff / 255.0, accuracy: 0.001)
    }

    func testParsesWhiteAndBlack() {
        let white = rgb("ffffff")
        XCTAssertEqual(white.r, 1, accuracy: 0.001)
        XCTAssertEqual(white.g, 1, accuracy: 0.001)
        XCTAssertEqual(white.b, 1, accuracy: 0.001)

        let black = rgb("000000")
        XCTAssertEqual(black.r, 0, accuracy: 0.001)
        XCTAssertEqual(black.g, 0, accuracy: 0.001)
        XCTAssertEqual(black.b, 0, accuracy: 0.001)
    }

    func testStripsLeadingHash() {
        let withHash = rgb("#30d158")
        let without  = rgb("30d158")
        XCTAssertEqual(withHash.r, without.r, accuracy: 0.001)
        XCTAssertEqual(withHash.g, without.g, accuracy: 0.001)
        XCTAssertEqual(withHash.b, without.b, accuracy: 0.001)
        XCTAssertEqual(withHash.g, 0xd1 / 255.0, accuracy: 0.001)
    }

    /// Documented contract: invalid input yields black rather than crashing.
    func testInvalidInputYieldsBlack() {
        for bad in ["", "nothex", "zzzzzz"] {
            let c = rgb(bad)
            XCTAssertEqual(c.r, 0, accuracy: 0.001, "\(bad) should parse to black")
            XCTAssertEqual(c.g, 0, accuracy: 0.001, "\(bad) should parse to black")
            XCTAssertEqual(c.b, 0, accuracy: 0.001, "\(bad) should parse to black")
        }
    }

    // MARK: - Appearance enum

    func testAppearanceRawValues() {
        XCTAssertEqual(AppSettings.Appearance.auto.rawValue, 0)
        XCTAssertEqual(AppSettings.Appearance.light.rawValue, 1)
        XCTAssertEqual(AppSettings.Appearance.dark.rawValue, 2)
        XCTAssertEqual(AppSettings.Appearance.allCases.count, 3)
    }

    func testPreferredColorScheme() {
        XCTAssertNil(AppSettings.Appearance.auto.preferredColorScheme)
        XCTAssertEqual(AppSettings.Appearance.light.preferredColorScheme, .light)
        XCTAssertEqual(AppSettings.Appearance.dark.preferredColorScheme, .dark)
    }

    // MARK: - Accent swatches

    func testAccentSwatchesIncludeDefault() {
        XCTAssertEqual(AuroraAccent.swatches.count, 6)
        XCTAssertEqual(AuroraAccent.swatches.first, "0a84ff")
        // All swatches must be valid 6-char hex so the picker never renders black.
        for hex in AuroraAccent.swatches {
            XCTAssertEqual(hex.count, 6, "\(hex) is not 6 hex chars")
            XCTAssertNotNil(UInt64(hex, radix: 16), "\(hex) is not valid hex")
        }
    }
}

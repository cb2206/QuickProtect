import XCTest
import Carbon

final class HotkeyManagerTests: XCTestCase {

    func testCarbonModifiersCommand() {
        XCTAssertEqual(HotkeyManager.carbonModifiers(from: .command), UInt32(cmdKey))
    }

    func testCarbonModifiersCombined() {
        let mods = HotkeyManager.carbonModifiers(from: [.command, .shift])
        XCTAssertEqual(mods, UInt32(cmdKey) | UInt32(shiftKey))
    }

    func testCarbonModifiersAll() {
        let mods = HotkeyManager.carbonModifiers(from: [.command, .shift, .option, .control])
        XCTAssertEqual(mods, UInt32(cmdKey) | UInt32(shiftKey) | UInt32(optionKey) | UInt32(controlKey))
    }

    func testKeyNameKnown() {
        XCTAssertEqual(HotkeyManager.keyName(for: 0), "A")
        XCTAssertEqual(HotkeyManager.keyName(for: 49), "Space")
        XCTAssertEqual(HotkeyManager.keyName(for: 36), "↩")
        XCTAssertEqual(HotkeyManager.keyName(for: 53), "⎋")
    }

    func testKeyNameUnknown() {
        XCTAssertEqual(HotkeyManager.keyName(for: 999), "Key999")
    }

    func testDisplayString() {
        let s = HotkeyManager.displayString(keyCode: 0, carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey))
        XCTAssertTrue(s.contains("⌘"))
        XCTAssertTrue(s.contains("⇧"))
        XCTAssertTrue(s.contains("A"))
    }
}

import XCTest

final class ControllerAddressTests: XCTestCase {

    func testBareIP() {
        let a = ControllerAddress.parse("192.168.1.1")
        XCTAssertEqual(a?.host, "192.168.1.1")
        XCTAssertNil(a?.port)
        XCTAssertEqual(a?.authority, "192.168.1.1")
        XCTAssertEqual(a?.httpsBase, "https://192.168.1.1")
        XCTAssertEqual(a?.pinKey, "192.168.1.1")
    }

    func testSchemeTrailingSlashAndWhitespaceAreDropped() {
        XCTAssertEqual(ControllerAddress.parse("  https://192.168.1.1/  ")?.authority, "192.168.1.1")
        XCTAssertEqual(ControllerAddress.parse("http://udm.local/protect")?.authority, "udm.local")
    }

    func testHostnameIsLowercased() {
        XCTAssertEqual(ControllerAddress.parse("UDM.Local")?.pinKey, "udm.local")
    }

    func testExplicitPortKeptExceptDefault() {
        XCTAssertEqual(ControllerAddress.parse("10.0.0.1:8443")?.port, 8443)
        XCTAssertEqual(ControllerAddress.parse("10.0.0.1:8443")?.authority, "10.0.0.1:8443")
        XCTAssertEqual(ControllerAddress.parse("10.0.0.1:8443")?.pinKey, "10.0.0.1")
        XCTAssertNil(ControllerAddress.parse("10.0.0.1:443")?.port)
        XCTAssertEqual(ControllerAddress.parse("10.0.0.1:443")?.authority, "10.0.0.1")
    }

    func testIPv6() {
        let a = ControllerAddress.parse("[fd00::1]:7443")
        XCTAssertEqual(a?.host, "fd00::1")
        XCTAssertEqual(a?.authority, "[fd00::1]:7443")
        XCTAssertEqual(ControllerAddress.parse("https://[fd00::1]/")?.authority, "[fd00::1]")
    }

    func testUserinfoIsDropped() {
        XCTAssertEqual(ControllerAddress.parse("admin:pw@10.0.0.1")?.authority, "10.0.0.1")
    }

    func testEmptyAndGarbage() {
        XCTAssertNil(ControllerAddress.parse(""))
        XCTAssertNil(ControllerAddress.parse("   "))
        XCTAssertNil(ControllerAddress.parse("https://"))
    }
}

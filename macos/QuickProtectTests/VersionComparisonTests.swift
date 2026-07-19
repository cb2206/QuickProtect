import XCTest

final class VersionComparisonTests: XCTestCase {

    func testNewerMajor()      { XCTAssertTrue(RTPParser.isNewer(remote: "1.0", local: "0.9")) }
    func testNewerMinor()      { XCTAssertTrue(RTPParser.isNewer(remote: "0.4", local: "0.3")) }
    func testNewerPatch()      { XCTAssertTrue(RTPParser.isNewer(remote: "0.3.1", local: "0.3")) }
    func testEqual()           { XCTAssertFalse(RTPParser.isNewer(remote: "0.3", local: "0.3")) }
    func testOlder()           { XCTAssertFalse(RTPParser.isNewer(remote: "0.2", local: "0.3")) }
    func testPaddedEqual()     { XCTAssertFalse(RTPParser.isNewer(remote: "1", local: "1.0.0")) }
    func testMultiDigit()      { XCTAssertTrue(RTPParser.isNewer(remote: "0.10", local: "0.9")) }
    func testMajorTrumps()     { XCTAssertTrue(RTPParser.isNewer(remote: "2.0", local: "1.99")) }
    func testFourComponents()  { XCTAssertTrue(RTPParser.isNewer(remote: "1.2.3.4", local: "1.2.3.3")) }
    func testSingleComponent() { XCTAssertTrue(RTPParser.isNewer(remote: "2", local: "1")) }
}

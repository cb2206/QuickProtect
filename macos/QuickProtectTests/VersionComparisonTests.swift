import XCTest

final class VersionComparisonTests: XCTestCase {

    func testNewerMajor()      { XCTAssertTrue(VersionCompare.isNewer(remote: "1.0", local: "0.9")) }
    func testNewerMinor()      { XCTAssertTrue(VersionCompare.isNewer(remote: "0.4", local: "0.3")) }
    func testNewerPatch()      { XCTAssertTrue(VersionCompare.isNewer(remote: "0.3.1", local: "0.3")) }
    func testEqual()           { XCTAssertFalse(VersionCompare.isNewer(remote: "0.3", local: "0.3")) }
    func testOlder()           { XCTAssertFalse(VersionCompare.isNewer(remote: "0.2", local: "0.3")) }
    func testPaddedEqual()     { XCTAssertFalse(VersionCompare.isNewer(remote: "1", local: "1.0.0")) }
    func testMultiDigit()      { XCTAssertTrue(VersionCompare.isNewer(remote: "0.10", local: "0.9")) }
    func testMajorTrumps()     { XCTAssertTrue(VersionCompare.isNewer(remote: "2.0", local: "1.99")) }
    func testFourComponents()  { XCTAssertTrue(VersionCompare.isNewer(remote: "1.2.3.4", local: "1.2.3.3")) }
    func testSingleComponent() { XCTAssertTrue(VersionCompare.isNewer(remote: "2", local: "1")) }

    // Pre-release handling: a beta of the next version is newer than the
    // current release, but never newer than its own final release.
    func testPrereleaseIsNewerThanPreviousRelease() {
        XCTAssertTrue(VersionCompare.isNewer(remote: "1.4.0-beta", local: "1.3.1"))
    }
    func testPrereleaseIsOlderThanItsRelease() {
        XCTAssertFalse(VersionCompare.isNewer(remote: "1.4.0-beta", local: "1.4.0"))
        XCTAssertTrue(VersionCompare.isNewer(remote: "1.4.0", local: "1.4.0-beta"))
    }
    func testPrereleasesCompareBySuffix() {
        XCTAssertTrue(VersionCompare.isNewer(remote: "1.4.0-beta.2", local: "1.4.0-beta.1"))
        XCTAssertTrue(VersionCompare.isNewer(remote: "1.4.0-beta.10", local: "1.4.0-beta.9"))
        XCTAssertFalse(VersionCompare.isNewer(remote: "1.4.0-beta.1", local: "1.4.0-beta.1"))
    }
    func testBuildMetadataIgnored() {
        XCTAssertFalse(VersionCompare.isNewer(remote: "1.4.0+build.7", local: "1.4.0"))
    }
}

import XCTest

final class UpdateAssetsTests: XCTestCase {

    func testDmgMatches() {
        XCTAssertTrue(UpdateAssets.containsMacAsset(["QuickProtect-1.2.1.dmg"]))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(UpdateAssets.containsMacAsset(["QuickProtect-1.2.1.DMG"]))
    }

    func testExplicitMacosTag() {
        XCTAssertTrue(UpdateAssets.containsMacAsset(["QuickProtect-1.3.0-macos.zip"]))
    }

    func testMixedPlatformRelease() {
        XCTAssertTrue(UpdateAssets.containsMacAsset([
            "QuickProtect-1.3.0-win-x64.exe",
            "QuickProtect-1.3.0-linux-x64.tar.gz",
            "QuickProtect-1.3.0.dmg"
        ]))
    }

    func testWindowsOnlyRelease() {
        XCTAssertFalse(UpdateAssets.containsMacAsset(["QuickProtect-1.3.0-win-x64.exe"]))
    }

    func testLinuxOnlyRelease() {
        XCTAssertFalse(UpdateAssets.containsMacAsset(["QuickProtect-1.3.0-linux-x64.tar.gz"]))
    }

    func testEmptyAssetList() {
        XCTAssertFalse(UpdateAssets.containsMacAsset([]))
    }
}

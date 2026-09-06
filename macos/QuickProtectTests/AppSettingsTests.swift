import XCTest
import AppKit

/// `AppSettings` against a private UserDefaults suite and an in-memory secret
/// store: persistence, the layout-profile model, per-camera preferences, and
/// the one-time migrations, without touching the real preferences or Keychain.
@MainActor
final class AppSettingsTests: XCTestCase {

    private final class InMemorySecretStore: SecretStoring {
        var values: [String: String] = [:]
        var failWrites = false
        func get(_ account: String) -> String? { values[account] }
        func set(_ value: String, account: String) -> Bool {
            if failWrites { return false }
            values[account] = value
            return true
        }
        func remove(_ account: String) -> Bool { values.removeValue(forKey: account) != nil }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var secrets: InMemorySecretStore!

    override func setUp() async throws {
        try await super.setUp()
        try await MainActor.run {
            suiteName = "com.cb.quickprotect.tests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            secrets = InMemorySecretStore()
        }
    }

    override func tearDown() async throws {
        await MainActor.run { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, secrets: secrets)
    }

    // MARK: - Persistence and secrets

    func testConnectionSettingsRoundTrip() {
        let s = makeSettings()
        s.ipAddress = "192.168.1.10:8443"
        s.apiKey = "key-1"
        s.username = "user"
        s.password = "pw"

        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.ipAddress), "192.168.1.10:8443")
        XCTAssertNil(defaults.string(forKey: AppSettings.Keys.apiKey), "secrets never land in UserDefaults")
        XCTAssertEqual(secrets.values[AppSettings.Keys.apiKey], "key-1")
        XCTAssertEqual(secrets.values[AppSettings.Keys.username], "user")
        XCTAssertEqual(secrets.values[AppSettings.Keys.password], "pw")

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.ipAddress, "192.168.1.10:8443")
        XCTAssertEqual(reloaded.apiKey, "key-1")
        XCTAssertEqual(reloaded.password, "pw")
    }

    func testLegacyPlaintextSecretMigratesIntoTheSecretStore() {
        defaults.set("legacy-key", forKey: AppSettings.Keys.apiKey)
        let s = makeSettings()
        XCTAssertEqual(s.apiKey, "legacy-key")
        XCTAssertEqual(secrets.values[AppSettings.Keys.apiKey], "legacy-key")
        XCTAssertNil(defaults.string(forKey: AppSettings.Keys.apiKey), "plaintext copy is removed after a successful write")
    }

    func testLegacySecretIsKeptWhenTheSecretStoreRejectsIt() {
        defaults.set("legacy-key", forKey: AppSettings.Keys.apiKey)
        secrets.failWrites = true
        let s = makeSettings()
        XCTAssertEqual(s.apiKey, "legacy-key")
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.apiKey), "legacy-key",
                       "the only copy must survive a failed Keychain write")
    }

    func testStoredKeepAliveIsClampedOnLoad() {
        defaults.set(999, forKey: AppSettings.Keys.streamKeepAliveSeconds)
        XCTAssertEqual(makeSettings().streamKeepAliveSeconds, AppSettings.streamKeepAliveRange.upperBound)
        defaults.set(-5, forKey: AppSettings.Keys.streamKeepAliveSeconds)
        XCTAssertEqual(makeSettings().streamKeepAliveSeconds, 0)
    }

    func testDefaultsWhenNothingIsStored() {
        let s = makeSettings()
        XCTAssertEqual(s.streamKeepAliveSeconds, AppSettings.streamKeepAliveDefault)
        XCTAssertTrue(s.pauseDecodeWhileClosed)
        XCTAssertTrue(s.showFocusOverlayControls)
        XCTAssertFalse(s.speakerEnabled)
        XCTAssertEqual(s.defaultStreamQuality, .auto)
        XCTAssertEqual(s.snapshotDestination, .clipboard)
        XCTAssertEqual(s.activeProfileID, AppSettings.defaultProfileID)
    }

    // MARK: - Layout profiles

    func testDefaultProfileIsSynthesised() {
        let s = makeSettings()
        XCTAssertEqual(s.profiles().map(\.id), [AppSettings.defaultProfileID])
        XCTAssertEqual(s.activeProfile.id, AppSettings.defaultProfileID)
    }

    func testCreateProfileSnapshotsTheActiveLayoutAndSwitches() {
        let s = makeSettings()
        s.setCameraOrder(["b", "a"])
        s.setHidden(true, for: "c")
        s.setCameraSize(.large, for: "a")

        let id = s.createProfile(named: "Night")
        XCTAssertEqual(s.activeProfileID, id)
        XCTAssertEqual(s.profiles().map(\.name), ["Default", "Night"])
        XCTAssertEqual(s.cameraOrder(), ["b", "a"])
        XCTAssertTrue(s.isHidden("c"))
        XCTAssertEqual(s.cameraSize(for: "a"), .large)
    }

    func testProfilesKeepIndependentLayouts() {
        let s = makeSettings()
        let night = s.createProfile(named: "Night")
        s.setHidden(true, for: "x")
        s.setCameraOrder(["x", "y"])

        s.switchProfile(to: AppSettings.defaultProfileID)
        XCTAssertFalse(s.isHidden("x"))
        XCTAssertEqual(s.cameraOrder(), [])

        s.switchProfile(to: night)
        XCTAssertTrue(s.isHidden("x"))
        XCTAssertEqual(s.cameraOrder(), ["x", "y"])
    }

    func testRenameAndDeleteProfile() {
        let s = makeSettings()
        let night = s.createProfile(named: "Night")
        s.renameProfile(night, to: "Evening")
        XCTAssertEqual(s.profiles().last?.name, "Evening")

        s.deleteProfile(night)
        XCTAssertEqual(s.profiles().map(\.id), [AppSettings.defaultProfileID])
        XCTAssertEqual(s.activeProfileID, AppSettings.defaultProfileID, "deleting the active profile falls back")

        s.deleteProfile(AppSettings.defaultProfileID)
        XCTAssertEqual(s.profiles().count, 1, "the last profile cannot be deleted")
    }

    func testSwitchToUnknownProfileIsIgnored() {
        let s = makeSettings()
        s.switchProfile(to: "nope")
        XCTAssertEqual(s.activeProfileID, AppSettings.defaultProfileID)
    }

    func testPanelSizeIsPerProfileAndDisplay() {
        let s = makeSettings()
        s.setPanelSize(NSSize(width: 800, height: 600), display: "1")
        s.setPanelSize(NSSize(width: 400, height: 300), display: "2")
        XCTAssertEqual(s.panelSize(display: "1"), NSSize(width: 800, height: 600))
        XCTAssertEqual(s.panelSize(display: "2"), NSSize(width: 400, height: 300))

        s.createProfile(named: "Other")
        XCTAssertNil(s.panelSize(display: "1"), "geometry is not copied into a new profile")
    }

    func testLayoutPersistsAcrossInstances() {
        let s = makeSettings()
        s.setCameraOrder(["z", "y"])
        s.setHidden(true, for: "h")
        s.setCameraSize(.small, for: "z")

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.cameraOrder(), ["z", "y"])
        XCTAssertTrue(reloaded.isHidden("h"))
        XCTAssertEqual(reloaded.cameraSize(for: "z"), .small)
    }

    // MARK: - Migration of the pre-profiles layout

    func testLegacyLayoutMigratesIntoTheDefaultProfile() {
        defaults.set(["old-hidden"], forKey: AppSettings.Keys.hiddenCameras)
        defaults.set([AppSettings.displayKey(): ["order": ["c2", "c1"], "sizes": ["c1": 4]]],
                     forKey: AppSettings.Keys.perDisplay)

        let s = makeSettings()
        XCTAssertEqual(s.profiles().map(\.id), [AppSettings.defaultProfileID])
        XCTAssertEqual(s.cameraOrder(), ["c2", "c1"])
        XCTAssertEqual(s.cameraSize(for: "c1"), .large)
        XCTAssertTrue(s.isHidden("old-hidden"))
        XCTAssertNil(defaults.array(forKey: AppSettings.Keys.hiddenCameras), "the global hidden set is retired")

        // Runs once: a second instance must not re-migrate over later edits.
        s.setHidden(false, for: "old-hidden")
        XCTAssertFalse(makeSettings().isHidden("old-hidden"))
    }

    // MARK: - Per-camera preferences

    func testStreamQualityOverrideFallsBackToTheGlobalDefault() {
        let s = makeSettings()
        s.defaultStreamQuality = .low
        XCTAssertNil(s.streamQuality(for: "cam"))
        XCTAssertEqual(s.effectiveStreamQuality(for: "cam"), .low)

        s.setStreamQuality(.high, for: "cam")
        XCTAssertEqual(s.streamQuality(for: "cam"), .high)
        XCTAssertEqual(s.effectiveStreamQuality(for: "cam"), .high)

        s.setStreamQuality(nil, for: "cam")
        XCTAssertEqual(s.effectiveStreamQuality(for: "cam"), .low)
    }

    func testPinnedCameraStateRoundTrip() {
        let s = makeSettings()
        s.setPinned("cam")
        XCTAssertTrue(s.isPinned("cam"))
        XCTAssertNil(s.pinnedCameras().first?.frame)

        let frame = NSRect(x: 10, y: 20, width: 300, height: 200)
        s.setPinnedFrame(frame, for: "cam")
        XCTAssertEqual(makeSettings().pinnedCameras().first?.frame, frame)

        s.removePinned("cam")
        XCTAssertFalse(s.isPinned("cam"))
        XCTAssertTrue(s.pinnedCameras().isEmpty)
    }

    func testCachedVideoDimensionsGiveAnAspectRatio() {
        let s = makeSettings()
        XCTAssertNil(s.cachedAspectRatio(for: "cam"))
        s.cacheVideoDimensions(CGSize(width: 1920, height: 1080), for: "cam")
        XCTAssertEqual(try XCTUnwrap(s.cachedAspectRatio(for: "cam")), 16.0 / 9.0, accuracy: 0.001)
    }
}

import Combine
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

    // No super calls: XCTest's async setUp/tearDown defaults are empty, and
    // Swift 6.1 (CI's Xcode 16.4) rejects sending the non-Sendable test case
    // to them from a main-actor class.
    override func setUp() async throws {
        try await MainActor.run {
            suiteName = "com.cb.quickprotect.tests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            secrets = InMemorySecretStore()
        }
    }

    override func tearDown() async throws {
        await MainActor.run { defaults.removePersistentDomain(forName: suiteName) }
    }

    private func makeSettings() -> AppSettings {
        AppSettings(defaults: defaults, secrets: secrets)
    }

    // MARK: - Connection change notifications

    /// AppDelegate tears streams down from a site's connection publisher and
    /// relies on the old address and key still being stored then, so the
    /// DELETEs release the allocations on the controller that holds them.
    func testConnectionPublishersFireBeforeTheNewValueIsStored() {
        let site = makeSettings().sites[0]
        site.ipAddress = "10.0.0.1"
        site.apiKey = "old-key"
        var seen: [String] = []
        let address = site.$ipAddress.dropFirst().sink { _ in seen.append(site.ipAddress) }
        let key = site.$apiKey.dropFirst().sink { _ in seen.append(site.apiKey) }
        var changes = 0
        let combined = site.connectionChanges.sink { changes += 1 }
        site.ipAddress = "10.0.0.2"
        site.apiKey = "new-key"
        site.name = "Renamed"   // not a connection change
        address.cancel()
        key.cancel()
        combined.cancel()
        XCTAssertEqual(seen, ["10.0.0.1", "old-key"])
        XCTAssertEqual(changes, 2)
    }

    // MARK: - Persistence and secrets

    func testConnectionSettingsRoundTrip() throws {
        let s = makeSettings()
        let site = s.sites[0]
        XCTAssertEqual(site.id, ControllerSite.legacyID)
        site.ipAddress = "192.168.1.10:8443"
        site.apiKey = "key-1"
        site.username = "user"
        site.password = "pw"

        // The first site keeps the pre-multi-site storage, so a downgrade
        // still finds its controller.
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.ipAddress), "192.168.1.10:8443")
        XCTAssertNil(defaults.string(forKey: AppSettings.Keys.apiKey), "secrets never land in UserDefaults")
        XCTAssertEqual(secrets.values[AppSettings.Keys.apiKey], "key-1")
        XCTAssertEqual(secrets.values[AppSettings.Keys.username], "user")
        XCTAssertEqual(secrets.values[AppSettings.Keys.password], "pw")

        let reloaded = try XCTUnwrap(makeSettings().sites.first)
        XCTAssertEqual(reloaded.ipAddress, "192.168.1.10:8443")
        XCTAssertEqual(reloaded.apiKey, "key-1")
        XCTAssertEqual(reloaded.password, "pw")
    }

    func testLegacyPlaintextSecretMigratesIntoTheSecretStore() {
        defaults.set("legacy-key", forKey: AppSettings.Keys.apiKey)
        let s = makeSettings()
        XCTAssertEqual(s.sites[0].apiKey, "legacy-key")
        XCTAssertEqual(secrets.values[AppSettings.Keys.apiKey], "legacy-key")
        XCTAssertNil(defaults.string(forKey: AppSettings.Keys.apiKey), "plaintext copy is removed after a successful write")
    }

    func testLegacySecretIsKeptWhenTheSecretStoreRejectsIt() {
        defaults.set("legacy-key", forKey: AppSettings.Keys.apiKey)
        secrets.failWrites = true
        let s = makeSettings()
        XCTAssertEqual(s.sites[0].apiKey, "legacy-key")
        XCTAssertEqual(defaults.string(forKey: AppSettings.Keys.apiKey), "legacy-key",
                       "the only copy must survive a failed Keychain write")
    }

    // MARK: - Sites

    /// Upgrading from a single-controller install: the configured controller
    /// becomes the first site, already seeded into every profile.
    func testSingleControllerConfigurationMigratesIntoTheFirstSite() {
        defaults.set("10.0.1.1", forKey: AppSettings.Keys.ipAddress)
        secrets.values[AppSettings.Keys.apiKey] = "key"
        secrets.values[AppSettings.Keys.username] = "admin"

        let s = makeSettings()
        XCTAssertEqual(s.sites.count, 1)
        let site = s.sites[0]
        XCTAssertEqual(site.id, ControllerSite.legacyID)
        XCTAssertEqual(site.ipAddress, "10.0.1.1")
        XCTAssertEqual(site.apiKey, "key")
        XCTAssertEqual(site.username, "admin")
        XCTAssertTrue(site.isConfigured)
        XCTAssertFalse(s.hasMultipleSites)
        XCTAssertTrue(s.seededSiteIDs.contains(ControllerSite.legacyID))
        XCTAssertEqual((defaults.array(forKey: AppSettings.Keys.sites) as? [[String: String]])?.first?["address"],
                       "10.0.1.1")
    }

    func testAddedSiteStoresItsSecretsUnderItsOwnAccounts() throws {
        let s = makeSettings()
        s.sites[0].apiKey = "inca-key"
        let added = s.addSite(name: "BC285")
        added.ipAddress = "10.2.0.1"
        added.apiKey = "bc-key"
        added.password = "bc-pw"

        XCTAssertTrue(s.hasMultipleSites)
        XCTAssertEqual(secrets.values["\(AppSettings.Keys.apiKey).\(added.id)"], "bc-key")
        XCTAssertEqual(secrets.values["\(AppSettings.Keys.password).\(added.id)"], "bc-pw")
        XCTAssertEqual(secrets.values[AppSettings.Keys.apiKey], "inca-key", "the first site's key is untouched")
        XCTAssertFalse(s.seededSiteIDs.contains(added.id))

        let reloaded = makeSettings()
        XCTAssertEqual(reloaded.sites.map(\.id), [ControllerSite.legacyID, added.id])
        let again = try XCTUnwrap(reloaded.site(id: added.id))
        XCTAssertEqual(again.name, "BC285")
        XCTAssertEqual(again.displayName, "BC285")
        XCTAssertEqual(again.ipAddress, "10.2.0.1")
        XCTAssertEqual(again.apiKey, "bc-key")
    }

    func testRemovingASiteDeletesItsSecretsButNeverTheLastSite() {
        let s = makeSettings()
        let added = s.addSite()
        added.apiKey = "bc-key"
        s.removeSite(id: added.id)
        XCTAssertEqual(s.sites.map(\.id), [ControllerSite.legacyID])
        XCTAssertNil(secrets.values["\(AppSettings.Keys.apiKey).\(added.id)"])
        XCTAssertEqual(makeSettings().sites.count, 1)

        s.removeSite(id: ControllerSite.legacyID)
        XCTAssertEqual(s.sites.count, 1, "the last site stays")
    }

    func testDisplayNameFallsBackToTheAddress() {
        let site = makeSettings().sites[0]
        site.ipAddress = "10.0.1.1"
        XCTAssertEqual(site.displayName, "10.0.1.1")
        site.name = "  Inca "
        XCTAssertEqual(site.displayName, "Inca")
    }

    /// A newly added site's cameras stay visible in the active profile only;
    /// a second delivery (or a seeded site) leaves the profiles alone.
    func testNewSiteCamerasAreHiddenOutsideTheActiveProfile() {
        let s = makeSettings()
        let other = s.createProfile(named: "Driveway only")   // switches to it
        s.switchProfile(to: AppSettings.defaultProfileID)
        let added = s.addSite(name: "BC285")

        XCTAssertTrue(s.seedSiteCamerasIfNeeded(siteID: added.id, cameraIDs: ["bc1", "bc2"]))
        XCTAssertFalse(s.isHidden("bc1"), "visible in the active profile")
        s.switchProfile(to: other)
        XCTAssertTrue(s.isHidden("bc1"))
        XCTAssertTrue(s.isHidden("bc2"))

        XCTAssertFalse(s.seedSiteCamerasIfNeeded(siteID: added.id, cameraIDs: ["bc3"]))
        XCTAssertFalse(s.isHidden("bc3"), "later cameras behave like any new camera")
        XCTAssertFalse(s.seedSiteCamerasIfNeeded(siteID: ControllerSite.legacyID, cameraIDs: ["inca1"]))
        XCTAssertFalse(s.isHidden("inca1"))
    }

    func testSeedingWaitsForTheFirstNonEmptyCameraList() {
        let s = makeSettings()
        let added = s.addSite()
        XCTAssertFalse(s.seedSiteCamerasIfNeeded(siteID: added.id, cameraIDs: []))
        XCTAssertFalse(s.seededSiteIDs.contains(added.id))
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

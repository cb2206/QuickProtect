import Foundation
import AppKit
import Combine
import ServiceManagement
import Security

extension Notification.Name {
    /// Posted when the active layout profile changes, so the open panel can
    /// restore that profile's saved window size for the current display.
    static let layoutProfileChanged = Notification.Name("layoutProfileChanged")
}

/// Main-actor isolated: SwiftUI reads and writes it there, and the few
/// off-main consumers (RTSP TLS pinning, stream teardown) take value
/// snapshots on the main actor instead of reaching in.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var ipAddress: String {
        didSet { defaults.set(ipAddress, forKey: Keys.ipAddress) }
    }

    /// Integration API key. Sensitive — stored in the Keychain, not UserDefaults.
    @Published var apiKey: String {
        didSet { secrets.set(apiKey, account: Keys.apiKey) }
    }

    /// Username for classic API auth (required for PTZ control).
    /// Sensitive — stored in the Keychain, not UserDefaults.
    @Published var username: String {
        didSet { secrets.set(username, account: Keys.username) }
    }

    /// Password for classic API auth (required for PTZ control).
    /// Sensitive — stored in the Keychain, not UserDefaults.
    @Published var password: String {
        didSet { secrets.set(password, account: Keys.password) }
    }

    /// Where a captured snapshot goes: the clipboard, or a user-picked folder.
    enum SnapshotDestination: Int { case clipboard = 0, folder = 1 }

    /// Snapshot destination. Defaults to the clipboard; `.folder` additionally
    /// requires `snapshotFolderBookmark` to be set.
    @Published var snapshotDestination: SnapshotDestination {
        didSet { defaults.set(snapshotDestination.rawValue, forKey: Keys.snapshotDestination) }
    }

    /// Global fallback stream quality, used for any camera without a per-camera
    /// override (see `streamQuality(for:)`). Defaults to `.auto`.
    @Published var defaultStreamQuality: StreamQuality {
        didSet { defaults.set(defaultStreamQuality.rawValue, forKey: Keys.defaultStreamQuality) }
    }

    /// Bounds and default (seconds) for `streamKeepAliveSeconds`.
    nonisolated static let streamKeepAliveRange = 0...60
    nonisolated static let streamKeepAliveDefault = 10

    /// Clamps a stored keep-alive value into the supported range. Pure, so the
    /// bounds are unit-testable without touching UserDefaults.
    nonisolated static func clampStreamKeepAlive(_ value: Int) -> Int {
        min(max(value, streamKeepAliveRange.lowerBound), streamKeepAliveRange.upperBound)
    }

    /// How long (seconds) camera streams stay connected after the panel closes,
    /// so a quick reopen shows video instantly instead of re-fetching and
    /// re-creating every stream. 0 disconnects immediately on close.
    @Published var streamKeepAliveSeconds: Int {
        didSet { defaults.set(streamKeepAliveSeconds, forKey: Keys.streamKeepAliveSeconds) }
    }

    /// Whether video decoding is paused while the panel is closed during the
    /// keep-alive grace: streams stay connected (instant reopen) but the CPU
    /// drops to network-only. Only consulted when `streamKeepAliveSeconds > 0`.
    /// Defaults to on.
    @Published var pauseDecodeWhileClosed: Bool {
        didSet { defaults.set(pauseDecodeWhileClosed, forKey: Keys.pauseDecodeWhileClosed) }
    }

    /// Security-scoped bookmark to the folder where snapshots are saved.
    /// Used when `snapshotDestination` is `.folder`. The sandbox requires a
    /// bookmark to regain write access to a user-chosen folder across launches.
    @Published var snapshotFolderBookmark: Data? {
        didSet {
            if let data = snapshotFolderBookmark {
                defaults.set(data, forKey: Keys.snapshotFolderBookmark)
            } else {
                defaults.removeObject(forKey: Keys.snapshotFolderBookmark)
            }
            cachedSnapshotFolderPath = nil
        }
    }

    /// Display path memoised per bookmark, so Settings doesn't resolve the
    /// security-scoped bookmark on every render pass.
    var cachedSnapshotFolderPath: String?

    // MARK: - Stores

    /// Preference and secret backends. The app uses defaults and
    /// the Keychain; tests pass a private suite and an in-memory secret store.
    let defaults: UserDefaults
    let secrets: any SecretStoring

    // MARK: - Layout profile state (methods in AppSettings+LayoutProfiles)

    /// The currently selected profile's id. Drives all order/size/visibility
    /// reads below; publishing it re-renders the grid and header on switch.
    @Published var activeProfileID: String {
        didSet {
            guard activeProfileID != oldValue else { return }
            defaults.set(activeProfileID, forKey: Keys.activeProfileID)
        }
    }

    /// In-memory copy of the stored profile layouts. The grid consults
    /// order/size/visibility once per camera per body evaluation (and again per
    /// cell), which used to decode the whole UserDefaults dictionary every
    /// time — hundreds of decodes per render with a dozen cameras. All writes
    /// go through `writeProfileLayouts`, which keeps this in sync.
    var profileLayoutsCache: [String: [String: Any]]?

    // MARK: - Launch at login

    /// Set while reconciling the published value with the real registration state,
    /// to stop `didSet` from recursing back into `updateLoginItem()`.
    var isSyncingLoginItem = false

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLoginItem else { return }
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    // MARK: - Appearance (Aurora UI)

    enum Appearance: Int, CaseIterable { case auto = 0, light = 1, dark = 2 }

    @Published var appearance: Appearance {
        didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Hex string (without '#') for the user's chosen accent color.
    /// Defaults to system blue (0a84ff).
    @Published var accentColorHex: String {
        didSet { defaults.set(accentColorHex, forKey: Keys.accentColorHex) }
    }

    /// Whether the first-run onboarding has been completed / skipped.
    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    /// Whether the focus-view overlay help (keyboard-shortcut hints) and the
    /// on-screen PTZ d-pad are shown. Defaults to on.
    @Published var showFocusOverlayControls: Bool {
        didSet { defaults.set(showFocusOverlayControls, forKey: Keys.showFocusOverlayControls) }
    }

    /// Global speaker preference: whether focused streams play audio. Off (muted)
    /// by default so opening a camera never blasts sound unexpectedly.
    @Published var speakerEnabled: Bool {
        didSet { defaults.set(speakerEnabled, forKey: Keys.speakerEnabled) }
    }

    // MARK: - Keys

    enum Keys {
        static let ipAddress      = "unifi.ipAddress"
        static let apiKey         = "unifi.apiKey"
        // "unifi.usePlainRtsp" retired: the Integration API's stream tokens are
        // only valid on rtsps://:7441, so a plain-RTSP mode can't exist for
        // these on-demand streams (see ProtectService.toPlayableURL). Old
        // preference files may still carry the key; it's ignored.
        static let perDisplay     = "unifi.perDisplay"
        static let hiddenCameras  = "unifi.hiddenCameras"
        static let profiles       = "unifi.profiles"
        static let profileLayout  = "unifi.profileLayout"
        static let activeProfileID = "unifi.activeProfileID"
        static let videoDimensions = "unifi.videoDimensions"
        static let cameraFillModes = "unifi.cameraFillModes"
        static let secondaryLensPip = "unifi.secondaryLensPip"
        static let secondaryLensPipGrid = "unifi.secondaryLensPipGrid"
        static let hotkeyCode     = "unifi.hotkeyCode"
        static let hotkeyMods     = "unifi.hotkeyMods"
        static let username       = "unifi.username"
        static let password       = "unifi.password"
        static let launchAtLogin  = "unifi.launchAtLogin"
        static let autoStartPromptShown = "unifi.autoStartPromptShown"
        static let appearance     = "unifi.appearance"
        static let accentColorHex = "unifi.accentColorHex"
        static let hasCompletedOnboarding = "unifi.hasCompletedOnboarding"
        static let showFocusOverlayControls = "unifi.showFocusOverlayControls"
        static let speakerEnabled = "unifi.speakerEnabled"
        static let snapshotDestination = "unifi.snapshotDestination"
        static let snapshotFolderBookmark = "unifi.snapshotFolderBookmark"
        static let defaultStreamQuality = "unifi.defaultStreamQuality"
        static let cameraStreamQualities = "unifi.cameraStreamQualities"
        static let pinnedCameras  = "unifi.pinnedCameras"
        static let appStorePromoShown = "unifi.appStorePromoShown"
        static let streamKeepAliveSeconds = "unifi.streamKeepAliveSeconds"
        static let pauseDecodeWhileClosed = "unifi.pauseDecodeWhileClosed"
        static let lastPromotedUpdateVersion = "unifi.lastPromotedUpdateVersion"
    }

    /// Loads a sensitive value from the Keychain. On first run after upgrading,
    /// migrates any plaintext value still living in UserDefaults into the Keychain
    /// and clears the old copy.
    static func loadSecret(_ account: String, defaults: UserDefaults, secrets: any SecretStoring) -> String {
        if let value = secrets.get(account) { return value }
        if let legacy = defaults.string(forKey: account), !legacy.isEmpty {
            // Only drop the plaintext copy once the Keychain write succeeded;
            // otherwise the credential would be lost on this launch.
            if secrets.set(legacy, account: account) {
                defaults.removeObject(forKey: account)
            }
            return legacy
        }
        return ""
    }

    /// `shared` uses the real stores; tests inject a throwaway UserDefaults
    /// suite and an in-memory secret store so nothing touches the Keychain.
    init(defaults: UserDefaults = .standard, secrets: any SecretStoring = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        ipAddress    = defaults.string(forKey: Keys.ipAddress) ?? ""
        apiKey       = Self.loadSecret(Keys.apiKey, defaults: defaults, secrets: secrets)
        username     = Self.loadSecret(Keys.username, defaults: defaults, secrets: secrets)
        password     = Self.loadSecret(Keys.password, defaults: defaults, secrets: secrets)
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        let raw = defaults.object(forKey: Keys.appearance) as? Int
        appearance = Appearance(rawValue: raw ?? 0) ?? .auto
        accentColorHex = defaults.string(forKey: Keys.accentColorHex) ?? "0a84ff"
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        let showControls = defaults.object(forKey: Keys.showFocusOverlayControls)
        showFocusOverlayControls = showControls != nil
            ? defaults.bool(forKey: Keys.showFocusOverlayControls)
            : true
        speakerEnabled = defaults.bool(forKey: Keys.speakerEnabled)
        snapshotDestination = SnapshotDestination(
            rawValue: defaults.integer(forKey: Keys.snapshotDestination)) ?? .clipboard
        defaultStreamQuality = StreamQuality(
            rawValue: defaults.string(forKey: Keys.defaultStreamQuality) ?? "") ?? .auto
        snapshotFolderBookmark = defaults.data(forKey: Keys.snapshotFolderBookmark)
        let keepAlive = defaults.object(forKey: Keys.streamKeepAliveSeconds) as? Int
        streamKeepAliveSeconds = Self.clampStreamKeepAlive(keepAlive ?? Self.streamKeepAliveDefault)
        let pauseDecode = defaults.object(forKey: Keys.pauseDecodeWhileClosed)
        pauseDecodeWhileClosed = pauseDecode != nil
            ? defaults.bool(forKey: Keys.pauseDecodeWhileClosed)
            : true
        activeProfileID = defaults.string(forKey: Keys.activeProfileID) ?? Self.defaultProfileID
        migrateLayoutProfilesIfNeeded()
    }

    /// One-time migration of the pre-profiles layout into a built-in "Default"
    /// profile: the global hidden set plus the main display's order/sizes become
    /// the Default profile's content. Panel sizes stay per-display, untouched.
    private func migrateLayoutProfilesIfNeeded() {
        let d = defaults
        guard d.array(forKey: Keys.profiles) == nil else { return }

        var content: [String: Any] = [:]
        if let hidden = d.stringArray(forKey: Keys.hiddenCameras), !hidden.isEmpty {
            content["hidden"] = hidden
        }
        if let all = d.dictionary(forKey: Keys.perDisplay) as? [String: [String: Any]] {
            let entry = all[Self.displayKey()]
                ?? all.values.first { $0["order"] != nil || $0["sizes"] != nil }
            if let order = entry?["order"] as? [String] { content["order"] = order }
            if let sizes = entry?["sizes"] as? [String: Int] { content["sizes"] = sizes }
        }

        var layouts = (d.dictionary(forKey: Keys.profileLayout) as? [String: [String: Any]]) ?? [:]
        layouts[Self.defaultProfileID] = content
        d.set(layouts, forKey: Keys.profileLayout)
        d.set([["id": Self.defaultProfileID, "name": defaultProfileName]], forKey: Keys.profiles)
        d.set(Self.defaultProfileID, forKey: Keys.activeProfileID)
        // Retire the global hidden set — visibility now lives in the profile.
        d.removeObject(forKey: Keys.hiddenCameras)
    }
}

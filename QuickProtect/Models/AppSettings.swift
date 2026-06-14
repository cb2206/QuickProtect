import Foundation
import AppKit
import Combine
import ServiceManagement
import Security

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var ipAddress: String {
        didSet { UserDefaults.standard.set(ipAddress, forKey: Keys.ipAddress) }
    }

    /// Integration API key. Sensitive — stored in the Keychain, not UserDefaults.
    @Published var apiKey: String {
        didSet { KeychainStore.set(apiKey, account: Keys.apiKey) }
    }

    @Published var usePlainRtsp: Bool {
        didSet { UserDefaults.standard.set(usePlainRtsp, forKey: Keys.usePlainRtsp) }
    }

    /// Username for classic API auth (required for PTZ control).
    /// Sensitive — stored in the Keychain, not UserDefaults.
    @Published var username: String {
        didSet { KeychainStore.set(username, account: Keys.username) }
    }

    /// Password for classic API auth (required for PTZ control).
    /// Sensitive — stored in the Keychain, not UserDefaults.
    @Published var password: String {
        didSet { KeychainStore.set(password, account: Keys.password) }
    }

    /// Where a captured snapshot goes: the clipboard, or a user-picked folder.
    enum SnapshotDestination: Int { case clipboard = 0, folder = 1 }

    /// Snapshot destination. Defaults to the clipboard; `.folder` additionally
    /// requires `snapshotFolderBookmark` to be set.
    @Published var snapshotDestination: SnapshotDestination {
        didSet { UserDefaults.standard.set(snapshotDestination.rawValue, forKey: Keys.snapshotDestination) }
    }

    /// Global fallback stream quality, used for any camera without a per-camera
    /// override (see `streamQuality(for:)`). Defaults to `.auto`.
    @Published var defaultStreamQuality: StreamQuality {
        didSet { UserDefaults.standard.set(defaultStreamQuality.rawValue, forKey: Keys.defaultStreamQuality) }
    }

    /// Security-scoped bookmark to the folder where snapshots are saved.
    /// Used when `snapshotDestination` is `.folder`. The sandbox requires a
    /// bookmark to regain write access to a user-chosen folder across launches.
    @Published var snapshotFolderBookmark: Data? {
        didSet {
            if let data = snapshotFolderBookmark {
                UserDefaults.standard.set(data, forKey: Keys.snapshotFolderBookmark)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.snapshotFolderBookmark)
            }
        }
    }

    // MARK: - Snapshot folder

    /// Resolves the saved bookmark to a folder URL, refreshing it if stale.
    /// Returns nil when no folder is configured or the bookmark can't be resolved.
    func resolveSnapshotFolder() -> URL? {
        guard let data = snapshotFolderBookmark else { return nil }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: [.withSecurityScope],
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            if isStale { setSnapshotFolder(url) }
            return url
        } catch {
            NSLog("[Snapshot] bookmark resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Stores a user-picked folder as a security-scoped bookmark, or clears it when nil.
    func setSnapshotFolder(_ url: URL?) {
        guard let url else { snapshotFolderBookmark = nil; return }
        do {
            snapshotFolderBookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        } catch {
            NSLog("[Snapshot] bookmark create failed: \(error.localizedDescription)")
        }
    }

    /// Human-readable path of the configured folder, or "" when none is set.
    var snapshotFolderDisplayPath: String {
        resolveSnapshotFolder()?.path ?? ""
    }

    // MARK: - Display identification

    /// Stable display key derived from CGDirectDisplayID.
    static func displayKey(for screen: NSScreen? = NSScreen.main) -> String {
        guard let screen else { return "default" }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return String(id)
    }

    // MARK: - Per-display helpers

    private func displayDict(_ rootKey: String, display: String) -> [String: Any]? {
        let all = UserDefaults.standard.dictionary(forKey: rootKey) as? [String: [String: Any]]
        return all?[display]
    }

    private func setDisplayValue(_ rootKey: String, display: String, subKey: String, value: Any?) {
        var all = (UserDefaults.standard.dictionary(forKey: rootKey) as? [String: [String: Any]]) ?? [:]
        var sub = all[display] ?? [:]
        if let value { sub[subKey] = value } else { sub.removeValue(forKey: subKey) }
        all[display] = sub
        UserDefaults.standard.set(all, forKey: rootKey)
    }

    // MARK: - Camera order (per-display)

    func cameraOrder(display: String? = nil) -> [String] {
        let dk = display ?? Self.displayKey()
        return (displayDict(Keys.perDisplay, display: dk)?["order"] as? [String]) ?? []
    }

    func setCameraOrder(_ ids: [String], display: String? = nil) {
        setDisplayValue(Keys.perDisplay, display: display ?? Self.displayKey(), subKey: "order", value: ids)
    }

    func orderedCameras(_ cameras: [Camera], display: String? = nil) -> [Camera] {
        let order = cameraOrder(display: display)
        guard !order.isEmpty else { return cameras }
        let indexMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return cameras.sorted { (indexMap[$0.id] ?? Int.max) < (indexMap[$1.id] ?? Int.max) }
    }

    // MARK: - Camera sizes (per-display)

    enum CameraSize: Int, CaseIterable { case small = 1, medium = 2, large = 4 }

    func cameraSize(for id: String, display: String? = nil) -> CameraSize? {
        let dk = display ?? Self.displayKey()
        guard let sizes = displayDict(Keys.perDisplay, display: dk)?["sizes"] as? [String: Int],
              let raw = sizes[id] else { return nil }
        return CameraSize(rawValue: raw)
    }

    func setCameraSize(_ size: CameraSize?, for id: String, display: String? = nil) {
        let dk = display ?? Self.displayKey()
        var all = (UserDefaults.standard.dictionary(forKey: Keys.perDisplay) as? [String: [String: Any]]) ?? [:]
        var sub = all[dk] ?? [:]
        var sizes = (sub["sizes"] as? [String: Int]) ?? [:]
        if let size { sizes[id] = size.rawValue } else { sizes.removeValue(forKey: id) }
        sub["sizes"] = sizes
        all[dk] = sub
        UserDefaults.standard.set(all, forKey: Keys.perDisplay)
    }

    // MARK: - Panel size (per-display)

    func panelSize(display: String? = nil) -> NSSize? {
        let dk = display ?? Self.displayKey()
        guard let d = displayDict(Keys.perDisplay, display: dk),
              let w = d["panelW"] as? Double,
              let h = d["panelH"] as? Double else { return nil }
        return NSSize(width: w, height: h)
    }

    func setPanelSize(_ size: NSSize, display: String? = nil) {
        let dk = display ?? Self.displayKey()
        var all = (UserDefaults.standard.dictionary(forKey: Keys.perDisplay) as? [String: [String: Any]]) ?? [:]
        var sub = all[dk] ?? [:]
        sub["panelW"] = Double(size.width)
        sub["panelH"] = Double(size.height)
        all[dk] = sub
        UserDefaults.standard.set(all, forKey: Keys.perDisplay)
    }

    // MARK: - Hidden cameras (global — same across displays)

    func isHidden(_ cameraId: String) -> Bool {
        let set = UserDefaults.standard.stringArray(forKey: Keys.hiddenCameras) ?? []
        return set.contains(cameraId)
    }

    func setHidden(_ hidden: Bool, for cameraId: String) {
        var set = UserDefaults.standard.stringArray(forKey: Keys.hiddenCameras) ?? []
        if hidden { if !set.contains(cameraId) { set.append(cameraId) } }
        else { set.removeAll { $0 == cameraId } }
        UserDefaults.standard.set(set, forKey: Keys.hiddenCameras)
        objectWillChange.send()
    }

    func visibleCameras(_ cameras: [Camera]) -> [Camera] {
        cameras.filter { !isHidden($0.id) }
    }

    // MARK: - Per-camera fill mode (fit vs. fill the focus frame)

    /// User's fit/fill choice for a focused camera. `true` = fill (crop to frame),
    /// `false` = fit (whole image). `nil` = never set → caller defaults to fit.
    func cameraFillMode(for id: String) -> Bool? {
        let dict = UserDefaults.standard.dictionary(forKey: Keys.cameraFillModes) as? [String: Bool]
        return dict?[id]
    }

    func setCameraFillMode(_ fill: Bool, for id: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: Keys.cameraFillModes) as? [String: Bool]) ?? [:]
        dict[id] = fill
        UserDefaults.standard.set(dict, forKey: Keys.cameraFillModes)
    }

    // MARK: - Per-camera stream quality

    /// This camera's explicit stream-quality override, or `nil` when it should
    /// follow `defaultStreamQuality`. The dict only holds cameras the user has
    /// explicitly set.
    func streamQuality(for id: String) -> StreamQuality? {
        let dict = UserDefaults.standard.dictionary(forKey: Keys.cameraStreamQualities) as? [String: String]
        return dict?[id].flatMap(StreamQuality.init(rawValue:))
    }

    /// Set (or, with `nil`, clear) this camera's quality override.
    func setStreamQuality(_ quality: StreamQuality?, for id: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: Keys.cameraStreamQualities) as? [String: String]) ?? [:]
        if let quality {
            dict[id] = quality.rawValue
        } else {
            dict.removeValue(forKey: id)
        }
        UserDefaults.standard.set(dict, forKey: Keys.cameraStreamQualities)
    }

    /// The quality a camera actually streams at: its override if set, else the
    /// global default. Still `.auto` when that's the effective choice — callers
    /// resolve to a concrete substream with `StreamQuality.resolve(focused:)`.
    func effectiveStreamQuality(for id: String) -> StreamQuality {
        streamQuality(for: id) ?? defaultStreamQuality
    }

    // MARK: - Per-camera secondary-lens picture-in-picture

    /// Whether the secondary-lens PiP (e.g. doorbell package camera) is shown
    /// when this camera is focused. Defaults to `true` — the dict only holds
    /// entries the user has explicitly turned off.
    func showsSecondaryLensPip(for id: String) -> Bool {
        let dict = UserDefaults.standard.dictionary(forKey: Keys.secondaryLensPip) as? [String: Bool]
        return dict?[id] ?? true
    }

    func setShowsSecondaryLensPip(_ on: Bool, for id: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: Keys.secondaryLensPip) as? [String: Bool]) ?? [:]
        dict[id] = on
        UserDefaults.standard.set(dict, forKey: Keys.secondaryLensPip)
    }

    /// Whether the secondary-lens PiP is also shown on the camera's grid tile
    /// (not just the focus/fullscreen view). Defaults to `false`: a grid PiP is
    /// tiny and keeps a second stream running whenever the grid is visible.
    func showsSecondaryLensPipInGrid(for id: String) -> Bool {
        let dict = UserDefaults.standard.dictionary(forKey: Keys.secondaryLensPipGrid) as? [String: Bool]
        return dict?[id] ?? false
    }

    func setShowsSecondaryLensPipInGrid(_ on: Bool, for id: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: Keys.secondaryLensPipGrid) as? [String: Bool]) ?? [:]
        dict[id] = on
        UserDefaults.standard.set(dict, forKey: Keys.secondaryLensPipGrid)
    }

    // MARK: - Cached video dimensions (for stable initial layout)

    func cachedAspectRatio(for cameraId: String) -> CGFloat? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Keys.videoDimensions) as? [String: [String: Double]],
              let dims = dict[cameraId],
              let w = dims["w"], let h = dims["h"], w > 0, h > 0 else { return nil }
        return CGFloat(w / h)
    }

    func cacheVideoDimensions(_ size: CGSize, for cameraId: String) {
        guard size.width > 0, size.height > 0 else { return }
        var dict = (UserDefaults.standard.dictionary(forKey: Keys.videoDimensions) as? [String: [String: Double]]) ?? [:]
        dict[cameraId] = ["w": Double(size.width), "h": Double(size.height)]
        UserDefaults.standard.set(dict, forKey: Keys.videoDimensions)
    }

    // MARK: - Global hotkey

    func globalHotkey() -> (keyCode: UInt32, carbonModifiers: UInt32)? {
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.hotkeyCode) != nil else { return nil }
        return (UInt32(d.integer(forKey: Keys.hotkeyCode)),
                UInt32(d.integer(forKey: Keys.hotkeyMods)))
    }

    func setGlobalHotkey(keyCode: UInt32, carbonModifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: Keys.hotkeyCode)
        UserDefaults.standard.set(Int(carbonModifiers), forKey: Keys.hotkeyMods)
        objectWillChange.send()
    }

    func clearGlobalHotkey() {
        UserDefaults.standard.removeObject(forKey: Keys.hotkeyCode)
        UserDefaults.standard.removeObject(forKey: Keys.hotkeyMods)
        objectWillChange.send()
    }

    var hotkeyDisplayString: String {
        guard let (kc, mods) = globalHotkey() else { return "Not set" }
        return HotkeyManager.displayString(keyCode: kc, carbonModifiers: mods)
    }

    // MARK: - Launch at login

    /// Set while reconciling the published value with the real registration state,
    /// to stop `didSet` from recursing back into `updateLoginItem()`.
    private var isSyncingLoginItem = false

    @Published var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLoginItem else { return }
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    // MARK: - Appearance (Aurora UI)

    enum Appearance: Int, CaseIterable { case auto = 0, light = 1, dark = 2 }

    @Published var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Keys.appearance) }
    }

    /// Hex string (without '#') for the user's chosen accent color.
    /// Defaults to system blue (0a84ff).
    @Published var accentColorHex: String {
        didSet { UserDefaults.standard.set(accentColorHex, forKey: Keys.accentColorHex) }
    }

    /// Whether the first-run onboarding has been completed / skipped.
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    /// Whether the focus-view overlay help (keyboard-shortcut hints) and the
    /// on-screen PTZ d-pad are shown. Defaults to on.
    @Published var showFocusOverlayControls: Bool {
        didSet { UserDefaults.standard.set(showFocusOverlayControls, forKey: Keys.showFocusOverlayControls) }
    }

    /// Global speaker preference: whether focused streams play audio. Off (muted)
    /// by default so opening a camera never blasts sound unexpectedly.
    @Published var speakerEnabled: Bool {
        didSet { UserDefaults.standard.set(speakerEnabled, forKey: Keys.speakerEnabled) }
    }

    /// Whether the first-launch autostart prompt has been shown.
    var hasShownAutoStartPrompt: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.autoStartPromptShown) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.autoStartPromptShown) }
    }

    func updateLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if launchAtLogin {
                try svc.register()
            } else {
                try svc.unregister()
            }
        } catch {
            // Registration failed — reconcile the toggle with reality so the UI
            // doesn't show "on" while the system rejected it.
            let actuallyEnabled = (svc.status == .enabled)
            if actuallyEnabled != launchAtLogin {
                isSyncingLoginItem = true
                launchAtLogin = actuallyEnabled
                isSyncingLoginItem = false
                UserDefaults.standard.set(actuallyEnabled, forKey: Keys.launchAtLogin)
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let ipAddress      = "unifi.ipAddress"
        static let apiKey         = "unifi.apiKey"
        static let usePlainRtsp   = "unifi.usePlainRtsp"
        static let perDisplay     = "unifi.perDisplay"
        static let hiddenCameras  = "unifi.hiddenCameras"
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
    }

    /// Loads a sensitive value from the Keychain. On first run after upgrading,
    /// migrates any plaintext value still living in UserDefaults into the Keychain
    /// and clears the old copy.
    private static func loadSecret(_ account: String) -> String {
        if let value = KeychainStore.get(account) { return value }
        if let legacy = UserDefaults.standard.string(forKey: account), !legacy.isEmpty {
            KeychainStore.set(legacy, account: account)
            UserDefaults.standard.removeObject(forKey: account)
            return legacy
        }
        return ""
    }

    private init() {
        ipAddress    = UserDefaults.standard.string(forKey: Keys.ipAddress) ?? ""
        apiKey       = Self.loadSecret(Keys.apiKey)
        let stored = UserDefaults.standard.object(forKey: Keys.usePlainRtsp)
        usePlainRtsp = stored != nil ? UserDefaults.standard.bool(forKey: Keys.usePlainRtsp) : true
        username     = Self.loadSecret(Keys.username)
        password     = Self.loadSecret(Keys.password)
        launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
        let raw = UserDefaults.standard.object(forKey: Keys.appearance) as? Int
        appearance = Appearance(rawValue: raw ?? 0) ?? .auto
        accentColorHex = UserDefaults.standard.string(forKey: Keys.accentColorHex) ?? "0a84ff"
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Keys.hasCompletedOnboarding)
        let showControls = UserDefaults.standard.object(forKey: Keys.showFocusOverlayControls)
        showFocusOverlayControls = showControls != nil
            ? UserDefaults.standard.bool(forKey: Keys.showFocusOverlayControls)
            : true
        speakerEnabled = UserDefaults.standard.bool(forKey: Keys.speakerEnabled)
        snapshotDestination = SnapshotDestination(
            rawValue: UserDefaults.standard.integer(forKey: Keys.snapshotDestination)) ?? .clipboard
        defaultStreamQuality = StreamQuality(
            rawValue: UserDefaults.standard.string(forKey: Keys.defaultStreamQuality) ?? "") ?? .auto
        snapshotFolderBookmark = UserDefaults.standard.data(forKey: Keys.snapshotFolderBookmark)
    }
}

// MARK: - Keychain

/// Thin wrapper over the macOS Keychain for storing sensitive strings
/// (Integration API key, classic-API username/password) as generic password
/// items, so credentials are no longer kept in plaintext UserDefaults.
enum KeychainStore {
    private static let service = "com.cb.quickprotect"

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// Stores `value` for `account`. An empty string removes the item entirely.
    static func set(_ value: String, account: String) {
        guard !value.isEmpty else { remove(account); return }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // AfterFirstUnlock so credentials are available when the app relaunches
            // at login; ThisDeviceOnly so they never sync or migrate via backups.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery(account)
            insert.merge(attributes) { _, new in new }
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}

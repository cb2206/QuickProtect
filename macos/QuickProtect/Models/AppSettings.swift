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

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var ipAddress: String {
        didSet { UserDefaults.standard.set(ipAddress, forKey: Keys.ipAddress) }
    }

    /// Integration API key. Sensitive — stored in the Keychain, not UserDefaults.
    @Published var apiKey: String {
        didSet { KeychainStore.set(apiKey, account: Keys.apiKey) }
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

    /// Bounds and default (seconds) for `streamKeepAliveSeconds`.
    static let streamKeepAliveRange = 0...60
    static let streamKeepAliveDefault = 10

    /// Clamps a stored keep-alive value into the supported range. Pure, so the
    /// bounds are unit-testable without touching UserDefaults.
    static func clampStreamKeepAlive(_ value: Int) -> Int {
        min(max(value, streamKeepAliveRange.lowerBound), streamKeepAliveRange.upperBound)
    }

    /// How long (seconds) camera streams stay connected after the panel closes,
    /// so a quick reopen shows video instantly instead of re-fetching and
    /// re-creating every stream. 0 disconnects immediately on close.
    @Published var streamKeepAliveSeconds: Int {
        didSet { UserDefaults.standard.set(streamKeepAliveSeconds, forKey: Keys.streamKeepAliveSeconds) }
    }

    /// Whether video decoding is paused while the panel is closed during the
    /// keep-alive grace: streams stay connected (instant reopen) but the CPU
    /// drops to network-only. Only consulted when `streamKeepAliveSeconds > 0`.
    /// Defaults to on.
    @Published var pauseDecodeWhileClosed: Bool {
        didSet { UserDefaults.standard.set(pauseDecodeWhileClosed, forKey: Keys.pauseDecodeWhileClosed) }
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

    // MARK: - Per-display helpers (panel geometry)

    private func displayDict(_ rootKey: String, display: String) -> [String: Any]? {
        let all = UserDefaults.standard.dictionary(forKey: rootKey) as? [String: [String: Any]]
        return all?[display]
    }

    // MARK: - Layout profiles (content layer)

    /// A named layout: which cameras are visible, their order, and their sizes.
    /// Shared across displays — panel/window geometry stays per-display.
    struct LayoutProfile: Identifiable, Equatable {
        let id: String
        var name: String
    }

    /// Stable id of the built-in profile that pre-profiles layouts migrate into.
    static let defaultProfileID = "default"

    private var defaultProfileName: String { String(localized: "Default") }

    /// The currently selected profile's id. Drives all order/size/visibility
    /// reads below; publishing it re-renders the grid and header on switch.
    @Published var activeProfileID: String {
        didSet {
            guard activeProfileID != oldValue else { return }
            UserDefaults.standard.set(activeProfileID, forKey: Keys.activeProfileID)
        }
    }

    /// All profiles, in menu order. Always non-empty (synthesizes a Default if
    /// nothing is stored yet).
    func profiles() -> [LayoutProfile] {
        let raw = UserDefaults.standard.array(forKey: Keys.profiles) as? [[String: String]] ?? []
        let list = raw.compactMap { dict -> LayoutProfile? in
            guard let id = dict["id"], let name = dict["name"] else { return nil }
            return LayoutProfile(id: id, name: name)
        }
        return list.isEmpty ? [LayoutProfile(id: Self.defaultProfileID, name: defaultProfileName)] : list
    }

    /// The active profile, falling back to the first if the stored id is stale.
    var activeProfile: LayoutProfile {
        let all = profiles()
        return all.first { $0.id == activeProfileID } ?? all[0]
    }

    private func saveProfiles(_ list: [LayoutProfile]) {
        UserDefaults.standard.set(list.map { ["id": $0.id, "name": $0.name] }, forKey: Keys.profiles)
        objectWillChange.send()
    }

    /// Stored content for a profile: `order`, `sizes`, `hidden`.
    private func profileLayout(_ id: String) -> [String: Any] {
        let all = UserDefaults.standard.dictionary(forKey: Keys.profileLayout) as? [String: [String: Any]]
        return all?[id] ?? [:]
    }

    private func setProfileLayoutValue(_ id: String, subKey: String, value: Any?) {
        var all = (UserDefaults.standard.dictionary(forKey: Keys.profileLayout) as? [String: [String: Any]]) ?? [:]
        var sub = all[id] ?? [:]
        if let value { sub[subKey] = value } else { sub.removeValue(forKey: subKey) }
        all[id] = sub
        UserDefaults.standard.set(all, forKey: Keys.profileLayout)
    }

    func switchProfile(to id: String) {
        guard profiles().contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        // Let the panel restore this profile's saved window size for the display.
        NotificationCenter.default.post(name: .layoutProfileChanged, object: nil)
    }

    /// Creates a new profile by snapshotting the active profile's current layout,
    /// then switches to it. Returns the new profile's id.
    @discardableResult
    func createProfile(named name: String) -> String {
        let newID = UUID().uuidString
        var all = (UserDefaults.standard.dictionary(forKey: Keys.profileLayout) as? [String: [String: Any]]) ?? [:]
        all[newID] = profileLayout(activeProfileID)
        UserDefaults.standard.set(all, forKey: Keys.profileLayout)
        saveProfiles(profiles() + [LayoutProfile(id: newID, name: name)])
        switchProfile(to: newID)
        return newID
    }

    func renameProfile(_ id: String, to name: String) {
        var list = profiles()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].name = name
        saveProfiles(list)
    }

    /// Deletes a profile and its stored layout. No-op when it's the last one.
    /// If the active profile is deleted, falls back to the first remaining.
    func deleteProfile(_ id: String) {
        var list = profiles()
        guard list.count > 1, let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list.remove(at: idx)
        var all = (UserDefaults.standard.dictionary(forKey: Keys.profileLayout) as? [String: [String: Any]]) ?? [:]
        all.removeValue(forKey: id)
        UserDefaults.standard.set(all, forKey: Keys.profileLayout)
        saveProfiles(list)
        if activeProfileID == id { switchProfile(to: list[0].id) }
    }

    // MARK: - Camera order (per-profile)

    func cameraOrder() -> [String] {
        (profileLayout(activeProfileID)["order"] as? [String]) ?? []
    }

    func setCameraOrder(_ ids: [String]) {
        setProfileLayoutValue(activeProfileID, subKey: "order", value: ids)
    }

    func orderedCameras(_ cameras: [Camera]) -> [Camera] {
        let order = cameraOrder()
        guard !order.isEmpty else { return cameras }
        let indexMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return cameras.sorted { (indexMap[$0.id] ?? Int.max) < (indexMap[$1.id] ?? Int.max) }
    }

    /// Unhides `id` and appends it to the end of the active profile's grid.
    /// `visibleOrder` is the current on-screen order of visible camera ids, so
    /// the camera lands last regardless of any stale position in stored order.
    func addHiddenCamera(_ id: String, visibleOrder: [String]) {
        setHidden(false, for: id)
        var order = visibleOrder.filter { $0 != id }
        order.append(id)
        setCameraOrder(order)
    }

    // MARK: - Camera sizes (per-profile)

    enum CameraSize: Int, CaseIterable { case small = 1, medium = 2, large = 4 }

    func cameraSize(for id: String) -> CameraSize? {
        guard let sizes = profileLayout(activeProfileID)["sizes"] as? [String: Int],
              let raw = sizes[id] else { return nil }
        return CameraSize(rawValue: raw)
    }

    func setCameraSize(_ size: CameraSize?, for id: String) {
        var sizes = (profileLayout(activeProfileID)["sizes"] as? [String: Int]) ?? [:]
        if let size { sizes[id] = size.rawValue } else { sizes.removeValue(forKey: id) }
        setProfileLayoutValue(activeProfileID, subKey: "sizes", value: sizes)
    }

    // MARK: - Panel size (per-profile, per-display)

    /// Storage key combining the active profile and a display. Profile ids are
    /// UUIDs / "default" (no "@"); display keys are numeric, so the two never
    /// collide with a bare legacy display key.
    private func panelKey(display: String) -> String { "\(activeProfileID)@\(display)" }

    func panelSize(display: String? = nil) -> NSSize? {
        let dk = display ?? Self.displayKey()
        // Prefer the profile-scoped size; fall back to a legacy per-display size
        // (written before panel sizes became per-profile) so existing windows
        // keep their dimensions on first switch.
        let d = displayDict(Keys.perDisplay, display: panelKey(display: dk))
            ?? displayDict(Keys.perDisplay, display: dk)
        guard let d, let w = d["panelW"] as? Double, let h = d["panelH"] as? Double else { return nil }
        return NSSize(width: w, height: h)
    }

    func setPanelSize(_ size: NSSize, display: String? = nil) {
        let dk = display ?? Self.displayKey()
        let key = panelKey(display: dk)
        var all = (UserDefaults.standard.dictionary(forKey: Keys.perDisplay) as? [String: [String: Any]]) ?? [:]
        var sub = all[key] ?? [:]
        sub["panelW"] = Double(size.width)
        sub["panelH"] = Double(size.height)
        all[key] = sub
        UserDefaults.standard.set(all, forKey: Keys.perDisplay)
    }

    // MARK: - Hidden cameras (per-profile)

    func isHidden(_ cameraId: String) -> Bool {
        let set = (profileLayout(activeProfileID)["hidden"] as? [String]) ?? []
        return set.contains(cameraId)
    }

    func setHidden(_ hidden: Bool, for cameraId: String) {
        var set = (profileLayout(activeProfileID)["hidden"] as? [String]) ?? []
        if hidden { if !set.contains(cameraId) { set.append(cameraId) } }
        else { set.removeAll { $0 == cameraId } }
        setProfileLayoutValue(activeProfileID, subKey: "hidden", value: set)
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

    // MARK: - Pinned floating windows (global, not per-profile)

    /// All currently pinned cameras with their saved frames. Order is
    /// unspecified (dictionary-backed); callers reconcile against the live
    /// camera list. Global on purpose — a pinned window is a standalone
    /// always-on-top thing, independent of the active layout profile.
    func pinnedCameras() -> [PinnedCameraState] {
        let dict = (UserDefaults.standard.dictionary(forKey: Keys.pinnedCameras) as? [String: [String: Double]]) ?? [:]
        return dict.map { PinnedCameraState(cameraId: $0.key, dictionary: $0.value) }
    }

    func isPinned(_ cameraId: String) -> Bool {
        let dict = (UserDefaults.standard.dictionary(forKey: Keys.pinnedCameras) as? [String: [String: Double]]) ?? [:]
        return dict[cameraId] != nil
    }

    /// Pin a camera, optionally recording its window frame. A `nil` frame marks
    /// the camera as pinned but not yet positioned (the controller computes a
    /// default and writes it back on first layout).
    func setPinned(_ cameraId: String, frame: NSRect? = nil) {
        var dict = (UserDefaults.standard.dictionary(forKey: Keys.pinnedCameras) as? [String: [String: Double]]) ?? [:]
        dict[cameraId] = PinnedCameraState(cameraId: cameraId, frame: frame).dictionary
        UserDefaults.standard.set(dict, forKey: Keys.pinnedCameras)
        objectWillChange.send()
    }

    /// Persist a moved/resized pinned window's frame. No-op if not pinned, so a
    /// late delegate callback during teardown can't resurrect an unpinned entry.
    func setPinnedFrame(_ frame: NSRect, for cameraId: String) {
        guard isPinned(cameraId) else { return }
        setPinned(cameraId, frame: frame)
    }

    func removePinned(_ cameraId: String) {
        var dict = (UserDefaults.standard.dictionary(forKey: Keys.pinnedCameras) as? [String: [String: Double]]) ?? [:]
        guard dict.removeValue(forKey: cameraId) != nil else { return }
        UserDefaults.standard.set(dict, forKey: Keys.pinnedCameras)
        objectWillChange.send()
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

    /// Whether the one-time "QuickProtect is on the App Store" nudge has been
    /// shown at launch. Non-App-Store builds only — see `AppDistribution`.
    var hasShownAppStorePromo: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.appStorePromoShown) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.appStorePromoShown) }
    }

    /// The newest GitHub release the user has already been nudged about, so the
    /// App Store suggestion appears at most once per new version.
    var lastPromotedUpdateVersion: String {
        get { UserDefaults.standard.string(forKey: Keys.lastPromotedUpdateVersion) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastPromotedUpdateVersion) }
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
    private static func loadSecret(_ account: String) -> String {
        if let value = KeychainStore.get(account) { return value }
        if let legacy = UserDefaults.standard.string(forKey: account), !legacy.isEmpty {
            // Only drop the plaintext copy once the Keychain write succeeded;
            // otherwise the credential would be lost on this launch.
            if KeychainStore.set(legacy, account: account) {
                UserDefaults.standard.removeObject(forKey: account)
            }
            return legacy
        }
        return ""
    }

    private init() {
        ipAddress    = UserDefaults.standard.string(forKey: Keys.ipAddress) ?? ""
        apiKey       = Self.loadSecret(Keys.apiKey)
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
        let keepAlive = UserDefaults.standard.object(forKey: Keys.streamKeepAliveSeconds) as? Int
        streamKeepAliveSeconds = Self.clampStreamKeepAlive(keepAlive ?? Self.streamKeepAliveDefault)
        let pauseDecode = UserDefaults.standard.object(forKey: Keys.pauseDecodeWhileClosed)
        pauseDecodeWhileClosed = pauseDecode != nil
            ? UserDefaults.standard.bool(forKey: Keys.pauseDecodeWhileClosed)
            : true
        activeProfileID = UserDefaults.standard.string(forKey: Keys.activeProfileID) ?? Self.defaultProfileID
        migrateLayoutProfilesIfNeeded()
    }

    /// One-time migration of the pre-profiles layout into a built-in "Default"
    /// profile: the global hidden set plus the main display's order/sizes become
    /// the Default profile's content. Panel sizes stay per-display, untouched.
    private func migrateLayoutProfilesIfNeeded() {
        let d = UserDefaults.standard
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

// MARK: - Pinned floating-window state

/// Persisted state for one pinned floating window. The frame is in screen
/// coordinates; a `nil` frame means "pinned but not yet positioned" so the
/// window controller can compute a default on first show and write it back.
///
/// The dictionary conversion is pure (touches no UserDefaults), so the
/// round-trip is unit-testable in isolation.
struct PinnedCameraState: Equatable {
    let cameraId: String
    var frame: NSRect?

    init(cameraId: String, frame: NSRect? = nil) {
        self.cameraId = cameraId
        self.frame = frame
    }

    init(cameraId: String, dictionary: [String: Double]) {
        self.cameraId = cameraId
        if let x = dictionary["x"], let y = dictionary["y"],
           let w = dictionary["w"], let h = dictionary["h"], w > 0, h > 0 {
            frame = NSRect(x: x, y: y, width: w, height: h)
        } else {
            frame = nil
        }
    }

    /// UserDefaults storage form. An unpositioned entry stores an empty dict,
    /// which still reads back as "pinned" (the key is present).
    var dictionary: [String: Double] {
        guard let f = frame else { return [:] }
        return ["x": f.origin.x, "y": f.origin.y, "w": f.size.width, "h": f.size.height]
    }
}

/// Pure geometry helpers for the pinned floating window. Kept free of AppKit
/// window state so the sizing math can be unit-tested directly.
enum PinnedWindowGeometry {
    static let minWidth: CGFloat = 200
    static let maxWidth: CGFloat = 1600
    static let fallbackAspect: CGFloat = 16.0 / 9.0

    /// Default content size for a freshly pinned window: `targetWidth` scaled to
    /// the camera's aspect ratio (width ÷ height), clamped to a sane range.
    static func defaultSize(aspectRatio: CGFloat, targetWidth: CGFloat = 360) -> NSSize {
        let ar = aspectRatio > 0 ? aspectRatio : fallbackAspect
        let w = min(maxWidth, max(minWidth, targetWidth)).rounded()
        return NSSize(width: w, height: (w / ar).rounded())
    }

    /// Constrain a proposed size to `aspectRatio`, driving from width so a
    /// corner drag keeps the camera's proportions. Width is clamped to range.
    static func constrain(_ proposed: NSSize, toAspectRatio aspectRatio: CGFloat) -> NSSize {
        let ar = aspectRatio > 0 ? aspectRatio : fallbackAspect
        let w = min(maxWidth, max(minWidth, proposed.width)).rounded()
        return NSSize(width: w, height: (w / ar).rounded())
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
    /// Returns false when the Keychain refused the write (the status is logged).
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return remove(account) }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // AfterFirstUnlock so credentials are available when the app relaunches
            // at login; ThisDeviceOnly so they never sync or migrate via backups.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        var status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = baseQuery(account)
            insert.merge(attributes) { _, new in new }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        return check(status, "store", account)
    }

    /// Removes the item. Returns true when it is gone (including "was never there").
    @discardableResult
    static func remove(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecItemNotFound || check(status, "remove", account)
    }

    private static func check(_ status: OSStatus, _ op: String, _ account: String) -> Bool {
        guard status != errSecSuccess else { return true }
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        NSLog("[Keychain] %@ %@ failed: %@", op, account, reason)
        return false
    }
}

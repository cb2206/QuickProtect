import Foundation
import AppKit
import Combine
import ServiceManagement

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var ipAddress: String {
        didSet { UserDefaults.standard.set(ipAddress, forKey: Keys.ipAddress) }
    }

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: Keys.apiKey) }
    }

    @Published var usePlainRtsp: Bool {
        didSet { UserDefaults.standard.set(usePlainRtsp, forKey: Keys.usePlainRtsp) }
    }

    /// Username for classic API auth (required for PTZ control).
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: Keys.username) }
    }

    /// Password for classic API auth (required for PTZ control).
    @Published var password: String {
        didSet { UserDefaults.standard.set(password, forKey: Keys.password) }
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

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
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
            // Silently ignore — user can toggle again
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
        static let hotkeyCode     = "unifi.hotkeyCode"
        static let hotkeyMods     = "unifi.hotkeyMods"
        static let username       = "unifi.username"
        static let password       = "unifi.password"
        static let launchAtLogin  = "unifi.launchAtLogin"
        static let autoStartPromptShown = "unifi.autoStartPromptShown"
    }

    private init() {
        ipAddress    = UserDefaults.standard.string(forKey: Keys.ipAddress) ?? ""
        apiKey       = UserDefaults.standard.string(forKey: Keys.apiKey) ?? ""
        let stored = UserDefaults.standard.object(forKey: Keys.usePlainRtsp)
        usePlainRtsp = stored != nil ? UserDefaults.standard.bool(forKey: Keys.usePlainRtsp) : true
        username     = UserDefaults.standard.string(forKey: Keys.username) ?? ""
        password     = UserDefaults.standard.string(forKey: Keys.password) ?? ""
        launchAtLogin = UserDefaults.standard.bool(forKey: Keys.launchAtLogin)
    }
}

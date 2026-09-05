import AppKit

// MARK: - Layout profiles: which cameras are visible, their order and
// sizes (shared across displays), plus per-display panel geometry.

extension AppSettings {

    // MARK: - Display identification

    /// Stable display key derived from CGDirectDisplayID.
    static func displayKey(for screen: NSScreen? = NSScreen.main) -> String {
        guard let screen else { return "default" }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        return String(id)
    }

    // MARK: - Per-display helpers (panel geometry)

    func displayDict(_ rootKey: String, display: String) -> [String: Any]? {
        let all = defaults.dictionary(forKey: rootKey) as? [String: [String: Any]]
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

    var defaultProfileName: String { String(localized: "Default") }

    /// All profiles, in menu order. Always non-empty (synthesizes a Default if
    /// nothing is stored yet).
    func profiles() -> [LayoutProfile] {
        let raw = defaults.array(forKey: Keys.profiles) as? [[String: String]] ?? []
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

    func saveProfiles(_ list: [LayoutProfile]) {
        defaults.set(list.map { ["id": $0.id, "name": $0.name] }, forKey: Keys.profiles)
        objectWillChange.send()
    }

    func allProfileLayouts() -> [String: [String: Any]] {
        if let cached = profileLayoutsCache { return cached }
        let loaded = (defaults.dictionary(forKey: Keys.profileLayout) as? [String: [String: Any]]) ?? [:]
        profileLayoutsCache = loaded
        return loaded
    }

    func writeProfileLayouts(_ all: [String: [String: Any]]) {
        profileLayoutsCache = all
        defaults.set(all, forKey: Keys.profileLayout)
    }

    /// Stored content for a profile: `order`, `sizes`, `hidden`.
    func profileLayout(_ id: String) -> [String: Any] {
        allProfileLayouts()[id] ?? [:]
    }

    func setProfileLayoutValue(_ id: String, subKey: String, value: Any?) {
        var all = allProfileLayouts()
        var sub = all[id] ?? [:]
        if let value { sub[subKey] = value } else { sub.removeValue(forKey: subKey) }
        all[id] = sub
        writeProfileLayouts(all)
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
        var all = allProfileLayouts()
        all[newID] = profileLayout(activeProfileID)
        writeProfileLayouts(all)
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
        var all = allProfileLayouts()
        all.removeValue(forKey: id)
        writeProfileLayouts(all)
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
    func panelKey(display: String) -> String { "\(activeProfileID)@\(display)" }

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
        var all = (defaults.dictionary(forKey: Keys.perDisplay) as? [String: [String: Any]]) ?? [:]
        var sub = all[key] ?? [:]
        sub["panelW"] = Double(size.width)
        sub["panelH"] = Double(size.height)
        all[key] = sub
        defaults.set(all, forKey: Keys.perDisplay)
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
}

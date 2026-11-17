import Foundation

// MARK: - Sites: the UniFi consoles QuickProtect streams from.

extension AppSettings {

    /// Loads the stored site list, migrating the single-controller
    /// configuration into a first site on the first launch after upgrading.
    /// Always returns at least one site.
    func loadSites() -> [ControllerSite] {
        let stored = defaults.array(forKey: Keys.sites) as? [[String: String]]
        var list = (stored ?? []).compactMap { entry -> ControllerSite? in
            guard let id = entry["id"] else { return nil }
            return makeSite(id: id, name: entry["name"] ?? "", address: entry["address"] ?? "")
        }
        if list.isEmpty {
            // Pre-multi-site install (or a fresh one): the original controller
            // becomes the legacy site, which keeps its Keychain accounts. Its
            // cameras already sit in every profile, so it counts as seeded.
            let address = defaults.string(forKey: Keys.ipAddress) ?? ""
            list = [makeSite(id: ControllerSite.legacyID, name: "", address: address)]
            markSiteSeeded(ControllerSite.legacyID)
            persistSites(list)
        }
        return list
    }

    private func makeSite(id: String, name: String, address: String) -> ControllerSite {
        let site: ControllerSite
        if id == ControllerSite.legacyID {
            // Through loadSecret so a plaintext secret from very old builds
            // still migrates into the Keychain.
            site = ControllerSite(
                id: id, name: name, ipAddress: address, secrets: secrets,
                apiKey: Self.loadSecret(Keys.apiKey, defaults: defaults, secrets: secrets),
                username: Self.loadSecret(Keys.username, defaults: defaults, secrets: secrets),
                password: Self.loadSecret(Keys.password, defaults: defaults, secrets: secrets))
        } else {
            site = ControllerSite(id: id, name: name, ipAddress: address, secrets: secrets)
        }
        site.onListChange = { [weak self] in
            guard let self else { return }
            self.persistSites(self.sites)
        }
        return site
    }

    /// Writes the site list (no secrets). The legacy site's address is also
    /// mirrored to the pre-multi-site key, so a downgrade keeps that console.
    func persistSites(_ list: [ControllerSite]) {
        defaults.set(list.map(\.listEntry), forKey: Keys.sites)
        if let legacy = list.first(where: { $0.id == ControllerSite.legacyID }) {
            defaults.set(legacy.ipAddress, forKey: Keys.ipAddress)
        }
    }

    func site(id: String) -> ControllerSite? {
        sites.first { $0.id == id }
    }

    /// More than one console is configured, so the UI labels cameras by site.
    var hasMultipleSites: Bool { sites.count > 1 }

    /// Adds an empty site at the end of the list and returns it. Its cameras
    /// are distributed over the layout profiles on its first successful fetch.
    @discardableResult
    func addSite(name: String = "") -> ControllerSite {
        let site = makeSite(id: UUID().uuidString, name: name, address: "")
        sites.append(site)
        persistSites(sites)
        return site
    }

    /// Removes a site and its Keychain secrets. The last site can't be removed.
    func removeSite(id: String) {
        guard sites.count > 1, let idx = sites.firstIndex(where: { $0.id == id }) else { return }
        let site = sites.remove(at: idx)
        site.onListChange = nil
        site.removeSecrets()
        persistSites(sites)
        var seeded = seededSiteIDs
        seeded.remove(id)
        defaults.set(Array(seeded).sorted(), forKey: Keys.seededSites)
    }

    // MARK: - Profile seeding for a newly added site

    var seededSiteIDs: Set<String> {
        Set(defaults.stringArray(forKey: Keys.seededSites) ?? [])
    }

    func markSiteSeeded(_ id: String) {
        var seeded = seededSiteIDs
        guard seeded.insert(id).inserted else { return }
        defaults.set(Array(seeded).sorted(), forKey: Keys.seededSites)
    }

    /// The first time a newly added site's cameras arrive, they stay visible in
    /// the active profile only: every other profile gets them hidden, so a
    /// curated layout doesn't suddenly grow by a whole site. Cameras the site
    /// gains later behave like any new camera (visible everywhere).
    /// Returns true when it seeded (the caller refreshes the grid).
    @discardableResult
    func seedSiteCamerasIfNeeded(siteID: String, cameraIDs: [String]) -> Bool {
        guard !seededSiteIDs.contains(siteID), !cameraIDs.isEmpty else { return false }
        var all = allProfileLayouts()
        for profile in profiles() where profile.id != activeProfile.id {
            var sub = all[profile.id] ?? [:]
            var hidden = (sub["hidden"] as? [String]) ?? []
            for id in cameraIDs where !hidden.contains(id) { hidden.append(id) }
            sub["hidden"] = hidden
            all[profile.id] = sub
        }
        writeProfileLayouts(all)
        markSiteSeeded(siteID)
        objectWillChange.send()
        return true
    }
}

import AppKit
import ServiceManagement

// MARK: - Global hotkey, login item, one-shot prompts.

extension AppSettings {

    // MARK: - Global hotkey

    func globalHotkey() -> (keyCode: UInt32, carbonModifiers: UInt32)? {
        let d = defaults
        guard d.object(forKey: Keys.hotkeyCode) != nil else { return nil }
        return (UInt32(d.integer(forKey: Keys.hotkeyCode)),
                UInt32(d.integer(forKey: Keys.hotkeyMods)))
    }

    func setGlobalHotkey(keyCode: UInt32, carbonModifiers: UInt32) {
        defaults.set(Int(keyCode), forKey: Keys.hotkeyCode)
        defaults.set(Int(carbonModifiers), forKey: Keys.hotkeyMods)
        objectWillChange.send()
    }

    func clearGlobalHotkey() {
        defaults.removeObject(forKey: Keys.hotkeyCode)
        defaults.removeObject(forKey: Keys.hotkeyMods)
        objectWillChange.send()
    }

    var hotkeyDisplayString: String {
        guard let (kc, mods) = globalHotkey() else { return "Not set" }
        return HotkeyManager.displayString(keyCode: kc, carbonModifiers: mods)
    }

    /// Whether the first-launch autostart prompt has been shown.
    var hasShownAutoStartPrompt: Bool {
        get { defaults.bool(forKey: Keys.autoStartPromptShown) }
        set { defaults.set(newValue, forKey: Keys.autoStartPromptShown) }
    }

    /// Whether the one-time "QuickProtect is on the App Store" nudge has been
    /// shown at launch. Non-App-Store builds only — see `AppDistribution`.
    var hasShownAppStorePromo: Bool {
        get { defaults.bool(forKey: Keys.appStorePromoShown) }
        set { defaults.set(newValue, forKey: Keys.appStorePromoShown) }
    }

    /// The newest GitHub release the user has already been nudged about, so the
    /// App Store suggestion appears at most once per new version.
    var lastPromotedUpdateVersion: String {
        get { defaults.string(forKey: Keys.lastPromotedUpdateVersion) ?? "" }
        set { defaults.set(newValue, forKey: Keys.lastPromotedUpdateVersion) }
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
                defaults.set(actuallyEnabled, forKey: Keys.launchAtLogin)
            }
        }
    }
}

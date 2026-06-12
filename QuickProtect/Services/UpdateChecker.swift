import Foundation
import AppKit

/// Identifies how this build was distributed.
///
/// The GitHub build is distributed **unsigned** (a deliberate hurdle that steers
/// users toward the paid Mac App Store version). Because an unsigned build can't
/// be safely auto-installed — downloading and executing an unsigned DMG would be
/// a supply-chain risk — the updater only *notifies* and links to the release
/// page; it never installs. Mac App Store builds are updated by the App Store
/// itself, and Apple forbids in-app update mechanisms there (Guideline 2.4.5 /
/// 3.2.2), so the updater stays idle when a `_MASReceipt/receipt` is present.
enum AppDistribution {
    static var isAppStore: Bool {
        // Demo override: force App Store presentation (hides the update tab and
        // disables update checks) without a real receipt — used for App Store
        // review screen recordings. Can only force the value TRUE, never disable
        // genuine App Store detection, so it is safe to ship.
        //   Enable:  defaults write com.cb.quickprotect QPForceAppStore -bool YES
        //   Disable: defaults delete com.cb.quickprotect QPForceAppStore
        if UserDefaults.standard.bool(forKey: "QPForceAppStore") { return true }
        if ProcessInfo.processInfo.environment["QUICKPROTECT_FORCE_APPSTORE"] == "1" { return true }

        guard let receiptURL = Bundle.main.appStoreReceiptURL else { return false }
        return FileManager.default.fileExists(atPath: receiptURL.path)
    }
}

/// Checks GitHub for a newer release and surfaces it in Settings. Notify-only:
/// it does not download or install anything. The user opens the release page and
/// updates manually (the GitHub build is intentionally unsigned, so auto-install
/// is neither possible nor safe — see `AppDistribution`).
final class UpdateChecker: NSObject, ObservableObject {

    // MARK: - Published state

    @Published var updateAvailable = false
    @Published var latestVersion   = ""
    @Published var releaseURL: URL?
    @Published var isChecking      = false

    // MARK: - Config

    private let repoOwner = "cb2206"
    private let repoName  = "QuickProtect"
    private var timer: Timer?

    /// Releases page to fall back to if a specific release URL wasn't captured.
    private var releasesPageURL: URL? {
        URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/latest")
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    // MARK: - Periodic checks

    func startPeriodicChecks() {
        // App Store builds are updated by the App Store; never self-check.
        guard !AppDistribution.isAppStore else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.checkForUpdate()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
    }

    // MARK: - Check for update

    func checkForUpdate() {
        guard !isChecking else { return }
        isChecking = true

        let urlString = "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest"
        guard let url = URL(string: urlString) else { isChecking = false; return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChecking = false

                guard error == nil,
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String,
                      let htmlURL = json["html_url"] as? String else { return }

                let remote = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                self.latestVersion = remote
                self.releaseURL = URL(string: htmlURL)
                self.updateAvailable = self.isNewer(remote: remote, local: self.currentVersion)
            }
        }.resume()
    }

    // MARK: - Open the release for manual download

    /// Opens the latest release page in the browser. The user downloads and
    /// installs manually — this build is unsigned by design, so there is no
    /// in-app installer.
    func openReleasePage() {
        if let url = releaseURL ?? releasesPageURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Version comparison

    /// Delegates to the single, unit-tested implementation in RTPParser so the
    /// shipping comparison and the tested one can't drift apart.
    private func isNewer(remote: String, local: String) -> Bool {
        RTPParser.isNewer(remote: remote, local: local)
    }
}

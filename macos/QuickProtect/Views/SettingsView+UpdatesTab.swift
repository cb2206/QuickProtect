import SwiftUI
import Carbon

// MARK: - Updates tab: GitHub release check (non-App-Store builds).

extension SettingsView {

    // MARK: Updates

    var updatesTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraSettingsSection(String(localized: "Mac App Store")) {
                AuroraSettingsRow(
                    String(localized: "Get the App Store edition"),
                    hint: String(localized: "Automatic updates, an Apple-signed install with no security warnings, and it supports development."),
                    isLast: true,
                    labelExpands: true
                ) {
                    AuroraPrimaryButton(title: String(localized: "View on the App Store")) {
                        AppStorePromo.open()
                    }
                }
            }

            AuroraSettingsSection(String(localized: "Version")) {
                AuroraSettingsRow(String(localized: "Installed")) {
                    HStack(spacing: 8) {
                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.system(size: 12))
                            .foregroundColor(palette.text)
                        if updateChecker.updateAvailable {
                            Text("v\(updateChecker.latestVersion) available")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(AuroraTokens.statusOrange)
                        }
                    }
                }
                AuroraSettingsRow(isLast: true) {
                    updateActions
                }
            }

            AuroraSettingsSection(String(localized: "Source")) {
                AuroraSettingsRow(
                    String(localized: "GitHub"),
                    hint: String(localized: "View the project source and releases."),
                    isLast: true,
                    labelExpands: true
                ) {
                    AuroraSecondaryButton(title: String(localized: "View on GitHub")) {
                        if let url = URL(string: "https://github.com/cb2206/QuickProtect") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    var updateActions: some View {
        HStack(spacing: 10) {
            // Notify-only: the GitHub build is not code-signed, so there is no
            // in-app installer — point the user at the release page to update.
            if updateChecker.updateAvailable {
                AuroraPrimaryButton(title: String(localized: "Get update")) {
                    updateChecker.openReleasePage()
                }
            }
            AuroraSecondaryButton(
                title: updateChecker.isChecking ? String(localized: "Checking…") : String(localized: "Check for Updates")
            ) {
                updateChecker.checkForUpdate()
            }
            if updateChecker.isChecking {
                ProgressView().scaleEffect(0.6)
            }
        }
    }
}

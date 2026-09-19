import SwiftUI
import Carbon

// MARK: - About tab.

extension SettingsView {

    // MARK: About

    var aboutTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AuroraBrandMark(size: 44, color: Color(hex: settings.accentColorHex))
                VStack(alignment: .leading, spacing: 4) {
                    Text("QuickProtect")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundColor(palette.text)
                    Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundColor(palette.subtext)
                }
            }
            Text("Menu-bar status app for UniFi Protect. Live camera feeds, one click away.")
                .font(.system(size: 12))
                .foregroundColor(palette.subtext)
                .frame(maxWidth: 420, alignment: .leading)

            AuroraSettingsSection(String(localized: "Legal")) {
                AuroraSettingsRow(
                    String(localized: "License"),
                    hint: String(localized: "© 2026 Christian Bartels · Released under the MIT License."),
                    isLast: true,
                    labelExpands: true
                ) {
                    HStack(spacing: 10) {
                        AuroraSecondaryButton(title: String(localized: "View License")) {
                            if let url = URL(string: "https://github.com/cb2206/QuickProtect/blob/main/LICENSE") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        AuroraSecondaryButton(title: String(localized: "View on GitHub")) {
                            if let url = URL(string: "https://github.com/cb2206/QuickProtect") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
    }
}

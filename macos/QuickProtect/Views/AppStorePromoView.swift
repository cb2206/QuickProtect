import SwiftUI

/// Promotes the Mac App Store edition of QuickProtect. Shown only in
/// non-App-Store builds (see `AppDistribution`): once at launch, when a GitHub
/// update is found, and as a section in Settings → Updates.
///
/// The App Store version updates automatically, installs without security
/// warnings, and supports continued development.
struct AppStorePromoView: View {
    /// When set, the newer GitHub version that triggered this prompt — the copy
    /// then leads with the update and offers a manual GitHub download alongside.
    var updateVersion: String?
    var onAppStore: () -> Void
    var onGitHub: (() -> Void)?
    var onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }
    private var accent: Color { Color(hex: AppSettings.shared.accentColorHex) }

    private let advantages: [(icon: String, text: String)] = [
        ("arrow.triangle.2.circlepath",
         String(localized: "Automatic updates — always on the latest version, no manual downloads.")),
        ("checkmark.seal",
         String(localized: "Signed and notarized by Apple — installs cleanly, with no security warnings.")),
        ("lock.shield",
         String(localized: "Sandboxed for extra security.")),
        ("heart",
         String(localized: "Supports development and helps keep QuickProtect improving."))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            advantagesList
            buttons
        }
        .padding(26)
        .frame(width: 460)
        .background(palette.popoverBg)
        .accentColor(accent)
        .preferredColorScheme(AppSettings.shared.appearance.preferredColorScheme)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AuroraBrandMark(size: 40, color: accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(palette.text)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundColor(palette.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var advantagesList: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(advantages, id: \.text) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(accent)
                        .frame(width: 18)
                    Text(item.text)
                        .font(.system(size: 12.5))
                        .foregroundColor(palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            AuroraPrimaryButton(title: String(localized: "View on the App Store")) {
                onAppStore()
            }
            if let onGitHub {
                AuroraSecondaryButton(title: String(localized: "Download from GitHub")) {
                    onGitHub()
                }
            }
            Spacer()
            AuroraSecondaryButton(
                title: updateVersion == nil ? String(localized: "Not now") : String(localized: "Later")
            ) {
                onDismiss()
            }
        }
    }

    private var title: String {
        updateVersion == nil
            ? String(localized: "QuickProtect is on the App Store")
            : String(localized: "A new version is available")
    }

    private var subtitle: String {
        if let updateVersion {
            return String(localized:
                "QuickProtect \(updateVersion) is out. The easiest way to stay up to date — and get a signed, hassle-free install — is the Mac App Store.")
        }
        return String(localized:
            "Prefer automatic updates and an Apple-signed, hassle-free install? Get QuickProtect from the Mac App Store.")
    }
}

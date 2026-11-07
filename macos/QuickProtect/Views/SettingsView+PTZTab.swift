import SwiftUI
import Carbon

// MARK: - PTZ tab: classic-API credentials for pan/tilt/zoom.

extension SettingsView {

    // MARK: PTZ

    var ptzTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            if settings.hasMultipleSites {
                // Each console has its own local account.
                AuroraSettingsSection {
                    AuroraSettingsRow(String(localized: "Site"), isLast: true) {
                        AuroraSegmented(options: settings.sites.map { ($0.displayName, $0.id) },
                                        selection: selectedSiteBinding)
                    }
                }
            }
            SitePTZSection(site: selectedSite, settings: settings, hub: service)
                .id(selectedSite.id)
            Text("PTZ control uses the classic Protect API, which requires a local account. The Integration API (API Key) only exposes preset and patrol endpoints, not free-form movement.")
                .font(.system(size: 11))
                .foregroundColor(palette.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

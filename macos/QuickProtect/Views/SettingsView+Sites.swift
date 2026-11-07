import SwiftUI
import AppKit

// MARK: - Sites: list, per-site connection fields, per-site PTZ login.

/// Selectable list of configured sites with Add / Remove. The selection is
/// shared by the Connection and PTZ tabs, which edit the selected site.
struct SiteListSection: View {
    @ObservedObject var settings: AppSettings
    let hub: ProtectHub
    @Binding var selectedSiteID: String

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        AuroraSettingsSection(String(localized: "Sites")) {
            ForEach(settings.sites) { site in
                SiteListRow(site: site, service: hub.service(forSite: site.id),
                            selected: site.id == selectedSiteID) {
                    selectedSiteID = site.id
                }
                AuroraHairline(color: palette.divider)
            }
            AuroraSettingsRow(isLast: true) {
                HStack(spacing: 8) {
                    AuroraSecondaryButton(title: String(localized: "Add Site")) {
                        selectedSiteID = settings.addSite().id
                    }
                    if settings.sites.count > 1 {
                        AuroraSecondaryButton(title: String(localized: "Remove Site…")) {
                            confirmRemove()
                        }
                    }
                    Spacer()
                    Text("Cameras from all sites share the grid and layout profiles.")
                        .font(.system(size: 11))
                        .foregroundColor(palette.subtext)
                }
            }
        }
    }

    private func confirmRemove() {
        guard let site = settings.site(id: selectedSiteID) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Remove “\(site.displayName)”?")
        alert.informativeText = String(localized: "Its cameras disappear from every profile and its API key and login are deleted from the Keychain.")
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Remove"))
        guard alert.runModalAboveFloatingWindows() == .alertSecondButtonReturn else { return }
        settings.removeSite(id: site.id)
        selectedSiteID = settings.sites.first?.id ?? ""
    }
}

private struct SiteListRow: View {
    @ObservedObject var site: ControllerSite
    let service: ProtectService?
    let selected: Bool
    let onSelect: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 12))
                .foregroundColor(selected ? .accentColor : palette.subtext)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(palette.text)
                if !site.ipAddress.isEmpty, site.displayName != site.ipAddress {
                    Text(site.ipAddress)
                        .font(.system(size: 11))
                        .foregroundColor(palette.subtext)
                }
            }
            Spacer()
            if let service {
                SiteStatusBadge(service: service, site: site, mode: .connection)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Connection status pill for one site: Integration API on most tabs, the
/// classic-API login on the PTZ tab. Observes the site's own service, which
/// the hub doesn't republish field by field.
struct SiteStatusBadge: View {
    enum Mode { case connection, ptz }

    @ObservedObject var service: ProtectService
    @ObservedObject var site: ControllerSite
    let mode: Mode

    var body: some View {
        switch mode {
        case .ptz:
            let configured = !site.username.isEmpty && !site.password.isEmpty
            AuroraStatusBadge(
                connected: service.isClassicLoggedIn,
                text: service.isClassicLoggedIn
                    ? String(localized: "Connected")
                    : (configured ? String(localized: "Not verified") : String(localized: "Not configured"))
            )
        case .connection:
            let ok = service.errorMessage == nil && service.certificateChange == nil && !service.cameras.isEmpty
            AuroraStatusBadge(
                connected: ok,
                text: !site.isConfigured
                    ? String(localized: "Not configured")
                    : (service.errorMessage == nil && service.certificateChange == nil
                       ? String(localized: "Connected") : String(localized: "Disconnected"))
            )
        }
    }
}

/// Name, address and API key of one site, plus its Test Connection.
struct SiteConnectionSection: View {
    @ObservedObject var site: ControllerSite
    @ObservedObject var settings: AppSettings
    let hub: ProtectHub

    @State private var showApiKey = false
    @State private var isTesting = false
    @State private var testResult: SettingsView.TestResult?

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        AuroraSettingsSection(settings.hasMultipleSites ? site.displayName : String(localized: "Controller")) {
            AuroraSettingsRow(String(localized: "Site Name"),
                              hint: String(localized: "Shown on camera tiles when you have more than one site")) {
                PastableTextField(text: $site.name, placeholder: "")
                    .frame(width: 260)
            }
            AuroraSettingsRow(String(localized: "IP Address"), hint: String(localized: "Local IP of your UniFi Protect controller")) {
                PastableTextField(text: $site.ipAddress, placeholder: "10.0.1.1")
                    .frame(width: 260)
            }
            AuroraSettingsRow(String(localized: "API Key"), hint: String(localized: "Integration API key from controller settings")) {
                HStack(spacing: 6) {
                    Group {
                        if showApiKey {
                            PastableTextField(text: $site.apiKey, placeholder: "")
                        } else {
                            PastableSecureField(text: $site.apiKey, placeholder: "")
                        }
                    }
                    .frame(width: 234)
                    Button {
                        showApiKey.toggle()
                    } label: {
                        Image(systemName: showApiKey ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundColor(palette.subtext)
                    }
                    .buttonStyle(.plain)
                    .help(showApiKey ? "Hide API key" : "Show API key")
                }
            }
            AuroraSettingsRow(isLast: true) {
                HStack(spacing: 10) {
                    AuroraPrimaryButton(
                        title: String(localized: "Test Connection"),
                        disabled: isTesting || site.ipAddress.isEmpty || site.apiKey.isEmpty,
                        action: runTest
                    )
                    if isTesting {
                        ProgressView().scaleEffect(0.6)
                    }
                    if let result = testResult {
                        HStack(spacing: 5) {
                            Image(systemName: result.icon)
                            Text(result.message)
                                .font(.system(size: 12))
                        }
                        .foregroundColor(result.color)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    /// Another site already points at the same console (its cameras would
    /// collide with this one's and be shown once).
    private var duplicateSite: ControllerSite? {
        guard let mine = ControllerAddress.parse(site.ipAddress) else { return nil }
        return settings.sites.first { other in
            other.id != site.id && ControllerAddress.parse(other.ipAddress)?.authority == mine.authority
        }
    }

    private func runTest() {
        testResult = nil
        // Store the address in its canonical form (scheme, path and whitespace
        // dropped) so what the user sees is exactly what gets pinned and dialled.
        if let address = ControllerAddress.parse(site.ipAddress), address.authority != site.ipAddress {
            site.ipAddress = address.authority
        }
        if let duplicate = duplicateSite {
            testResult = SettingsView.TestResult(
                message: String(localized: "This console is already added as “\(duplicate.displayName)”."),
                icon: "xmark.circle.fill", color: .red)
            return
        }
        isTesting = true
        Task {
            let service = hub.service(forSite: site.id)
            await service?.fetchCameras(forced: true)
            hub.recompute()
            isTesting = false
            if let err = service?.errorMessage {
                testResult = SettingsView.TestResult(message: err, icon: "xmark.circle.fill", color: .red)
            } else {
                let n = service?.cameras.count ?? 0
                testResult = SettingsView.TestResult(
                    message: String(localized: "Connected · \(n) cameras found"),
                    icon: "checkmark.circle.fill",
                    color: AuroraTokens.statusGreenDark
                )
            }
        }
    }
}

/// Classic-API login (PTZ) of one site, plus its Test Connection.
struct SitePTZSection: View {
    @ObservedObject var site: ControllerSite
    @ObservedObject var settings: AppSettings
    let hub: ProtectHub

    @State private var showPassword = false
    @State private var isTesting = false
    @State private var testResult: SettingsView.TestResult?

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        AuroraSettingsSection(settings.hasMultipleSites
                              ? String(localized: "Classic API credentials · \(site.displayName)")
                              : String(localized: "Classic API credentials")) {
            AuroraSettingsRow(
                String(localized: "Username"),
                hint: String(localized: "Local admin account on the Protect controller.")
            ) {
                PastableTextField(text: $site.username, placeholder: "")
                    .frame(width: 260)
            }
            AuroraSettingsRow(String(localized: "Password")) {
                HStack(spacing: 6) {
                    Group {
                        if showPassword {
                            PastableTextField(text: $site.password, placeholder: "")
                        } else {
                            PastableSecureField(text: $site.password, placeholder: "")
                        }
                    }
                    .frame(width: 234)
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.system(size: 13))
                            .foregroundColor(palette.subtext)
                    }
                    .buttonStyle(.plain)
                    .help(showPassword ? "Hide password" : "Show password")
                }
            }
            AuroraSettingsRow(isLast: true) {
                HStack(spacing: 10) {
                    AuroraPrimaryButton(
                        title: String(localized: "Test Connection"),
                        disabled: isTesting || site.ipAddress.isEmpty
                            || site.username.isEmpty || site.password.isEmpty,
                        action: runTest
                    )
                    if isTesting {
                        ProgressView().scaleEffect(0.6)
                    }
                    if let result = testResult {
                        HStack(spacing: 5) {
                            Image(systemName: result.icon)
                            Text(result.message)
                                .font(.system(size: 12))
                        }
                        .foregroundColor(result.color)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let ok = await hub.service(forSite: site.id)?.classicLogin() ?? false
            isTesting = false
            if ok {
                testResult = SettingsView.TestResult(
                    message: String(localized: "Signed in · PTZ control ready"),
                    icon: "checkmark.circle.fill",
                    color: AuroraTokens.statusGreenDark
                )
            } else {
                testResult = SettingsView.TestResult(
                    message: String(localized: "Login failed — check the username and password"),
                    icon: "xmark.circle.fill",
                    color: .red
                )
            }
        }
    }
}

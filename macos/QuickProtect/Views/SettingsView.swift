import SwiftUI
import Carbon

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case general    = "General"
    case connection = "Connection"
    case ptz        = "PTZ"
    case cameras    = "Cameras"
    case shortcuts  = "Shortcuts"
    case updates    = "Updates"
    case about      = "About"

    var id: String { rawValue }

    /// Tabs shown in the sidebar. The self-update tab is omitted from App
    /// Store builds, which are updated by the App Store itself.
    static var visibleCases: [SettingsTab] {
        allCases.filter { !($0 == .updates && AppDistribution.isAppStore) }
    }

    var systemImage: String {
        switch self {
        case .general:    return "gearshape"
        case .connection: return "link"
        case .ptz:        return "scope"
        case .cameras:    return "square.grid.2x2"
        case .shortcuts:  return "keyboard"
        case .updates:    return "arrow.down.circle"
        case .about:      return "info.circle"
        }
    }

    /// Localized title shown in the sidebar and detail-pane header. The raw value
    /// remains the stable identifier; this is the user-facing, translatable label.
    var title: String {
        switch self {
        case .general:    return String(localized: "General")
        case .connection: return String(localized: "Connection")
        case .ptz:        return String(localized: "PTZ")
        case .cameras:    return String(localized: "Cameras")
        case .shortcuts:  return String(localized: "Shortcuts")
        case .updates:    return String(localized: "Updates")
        case .about:      return String(localized: "About")
        }
    }
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var service: ProtectService
    @ObservedObject var updateChecker: UpdateChecker

    /// Last tab the user viewed, remembered for the lifetime of the app process.
    /// Resets to General on relaunch (it is not persisted), so the first open
    /// after starting the app lands on General while later opens within the same
    /// session restore the previous selection.
    static var sessionTab: SettingsTab = .general

    @State private var tab: SettingsTab = SettingsView.sessionTab
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var isTestingPtz = false
    @State private var ptzTestResult: TestResult?
    @State private var isRecordingHotkey = false
    @State private var showApiKey = false
    @State private var showPassword = false
    /// Toggled to force `pendingCertFingerprint` to re-read after the user re-pins.
    @State private var certRefresh = false
    @State private var hotkeyRegistrationFailed = false

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detailPane
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 600)
        .onChange(of: tab) { SettingsView.sessionTab = $0 }
        .background(palette.popoverBg)
        .accentColor(Color(hex: settings.accentColorHex))
        .preferredColorScheme(settings.appearance.preferredColorScheme)
        .background(hotkeyRecorderOverlay)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                AuroraBrandMark(size: 16, color: Color(hex: settings.accentColorHex))
                Text("QuickProtect")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(palette.text)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(SettingsTab.visibleCases) { t in
                AuroraSidebarItem(
                    systemImage: t.systemImage,
                    title: t.title,
                    selected: tab == t,
                    action: { tab = t }
                )
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 14)
        .frame(width: 200)
        .background(
            ZStack {
                VisualEffectBackground(material: .sidebar, blending: .behindWindow)
                palette.chrome.opacity(0.4)
            }
        )
        .overlay(AuroraHairline(color: palette.divider).frame(maxHeight: .infinity), alignment: .trailing)
    }

    // MARK: - Detail pane

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(tab.title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(palette.text)
                Spacer()
                headerStatusBadge
            }
            .padding(.horizontal, 22).frame(height: 52)
            AuroraHairline(color: palette.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .general:    generalTab
                    case .connection: connectionTab
                    case .ptz:        ptzTab
                    case .cameras:    camerasTab
                    case .shortcuts:  shortcutsTab
                    case .updates:    updatesTab
                    case .about:      aboutTab
                    }
                }
                .padding(22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Header pill. On the PTZ tab it reflects the classic-API login state;
    /// everywhere else it reflects the Integration API connection.
    @ViewBuilder
    private var headerStatusBadge: some View {
        if tab == .ptz {
            let configured = !settings.username.isEmpty && !settings.password.isEmpty
            AuroraStatusBadge(
                connected: service.isClassicLoggedIn,
                text: service.isClassicLoggedIn
                    ? String(localized: "Connected")
                    : (configured ? String(localized: "Not verified") : String(localized: "Not configured"))
            )
        } else {
            AuroraStatusBadge(
                connected: service.errorMessage == nil && !service.cameras.isEmpty,
                text: service.errorMessage == nil ? String(localized: "Connected") : String(localized: "Disconnected")
            )
        }
    }

    // MARK: - Tabs

    private var connectionTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraSettingsSection(String(localized: "Controller")) {
                AuroraSettingsRow(String(localized: "IP Address"), hint: String(localized: "Local IP of your UniFi Protect controller")) {
                    PastableTextField(text: $settings.ipAddress, placeholder: "10.0.1.1")
                        .frame(width: 260)
                }
                AuroraSettingsRow(String(localized: "API Key"), hint: String(localized: "Integration API key from controller settings")) {
                    HStack(spacing: 6) {
                        Group {
                            if showApiKey {
                                PastableTextField(text: $settings.apiKey, placeholder: "")
                            } else {
                                PastableSecureField(text: $settings.apiKey, placeholder: "")
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
                AuroraSettingsRow(
                    String(localized: "Keep streams alive"),
                    hint: String(localized: "Streams stay connected for this long after closing, so a quick reopen shows video instantly")
                ) {
                    AuroraSegmented(
                        options: [
                            (String(localized: "Off"), 0),
                            ("5 s", 5),
                            ("10 s", 10),
                            ("30 s", 30),
                            ("60 s", 60)
                        ],
                        selection: $settings.streamKeepAliveSeconds
                    )
                }
                if settings.streamKeepAliveSeconds > 0 {
                    AuroraSettingsRow(
                        String(localized: "Pause decoding while closed"),
                        hint: String(localized: "Kept-alive streams stay connected but skip video decoding while the panel is closed, cutting CPU use to nearly nothing. The picture catches up instantly on reopen."),
                        labelExpands: true
                    ) {
                        Toggle("", isOn: $settings.pauseDecodeWhileClosed)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }
                AuroraSettingsRow(isLast: true) {
                    HStack(spacing: 10) {
                        AuroraPrimaryButton(
                            title: String(localized: "Test Connection"),
                            disabled: isTesting || settings.ipAddress.isEmpty || settings.apiKey.isEmpty,
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

            let pending = pendingCertificates
            if !pending.isEmpty {
                AuroraSettingsSection(String(localized: "Certificate")) {
                    ForEach(Array(pending.enumerated()), id: \.element.host) { index, entry in
                        AuroraSettingsRow(
                            String(localized: "Certificate changed"),
                            hint: String(localized: "The controller is presenting a new certificate. This is expected if you reinstalled or replaced the controller — but if you didn't, it may indicate someone intercepting the connection. Compare the new key with the certificate your controller shows before trusting it."),
                            isLast: index == pending.count - 1,
                            labelExpands: true
                        ) {
                            VStack(alignment: .trailing, spacing: 8) {
                                certificateFingerprints(for: entry)
                                AuroraPrimaryButton(
                                    title: String(localized: "Trust new certificate"),
                                    disabled: false
                                ) {
                                    CertificateTrust.Store().trustPending(host: entry.host)
                                    certRefresh.toggle()
                                    runTest()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Full SHA-256 SubjectPublicKeyInfo fingerprints of the trusted and the
    /// new key, so the change can be verified against the controller.
    private func certificateFingerprints(for entry: (host: String, fingerprint: String)) -> some View {
        let pinned = CertificateTrust.Store().pinned(host: entry.host)
        return VStack(alignment: .leading, spacing: 4) {
            Text(entry.host)
                .font(.system(size: 11, weight: .semibold))
            if let pinned {
                Text(String(localized: "Trusted key"))
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Text(CertificateTrust.displayFingerprint(pinned))
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text(String(localized: "New key"))
                .font(.system(size: 10)).foregroundColor(.secondary)
            Text(CertificateTrust.displayFingerprint(entry.fingerprint))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    /// Every changed controller certificate awaiting the user's decision.
    /// Listed for all hosts rather than one guessed key, so a pin left under an
    /// older key format can still be reviewed. Reads through `certRefresh` so
    /// re-pinning updates the UI.
    private var pendingCertificates: [(host: String, fingerprint: String)] {
        _ = certRefresh
        return CertificateTrust.Store().allPending()
    }

    // MARK: General

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraSettingsSection(String(localized: "Startup")) {
                AuroraSettingsRow(
                    String(localized: "Launch at login"),
                    hint: String(localized: "Automatically start QuickProtect when you log in."),
                    isLast: true,
                    labelExpands: true
                ) {
                    Toggle("", isOn: $settings.launchAtLogin)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            AuroraSettingsSection(String(localized: "Streaming")) {
                AuroraSettingsRow(
                    String(localized: "Default stream quality"),
                    hint: String(localized: "Auto streams low quality in the grid and high quality when a camera is enlarged — saving CPU and bandwidth. Override per camera by right-clicking its tile."),
                    isLast: true,
                    labelExpands: true
                ) {
                    AuroraSegmented(
                        options: StreamQuality.allCases.map { ($0.displayName, $0) },
                        selection: $settings.defaultStreamQuality
                    )
                }
            }

            AuroraSettingsSection(String(localized: "Focus view")) {
                AuroraSettingsRow(
                    String(localized: "Show overlay controls"),
                    hint: String(localized: "Display the keyboard-shortcut hints and the on-screen PTZ pad when a camera is in focus."),
                    isLast: true,
                    labelExpands: true
                ) {
                    Toggle("", isOn: $settings.showFocusOverlayControls)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            AuroraSettingsSection(String(localized: "Snapshots")) {
                AuroraSettingsRow(
                    String(localized: "Destination"),
                    hint: String(localized: "Press S on a focused camera to capture a snapshot."),
                    isLast: settings.snapshotDestination == .clipboard
                ) {
                    AuroraSegmented(
                        options: [
                            (String(localized: "Clipboard"), AppSettings.SnapshotDestination.clipboard),
                            (String(localized: "Folder"), AppSettings.SnapshotDestination.folder)
                        ],
                        selection: Binding(
                            get: { settings.snapshotDestination },
                            set: { newValue in
                                settings.snapshotDestination = newValue
                                // Folder mode requires a picked folder — prompt
                                // immediately and revert to clipboard if cancelled.
                                if newValue == .folder, settings.resolveSnapshotFolder() == nil {
                                    chooseSnapshotFolder(revertToClipboardIfCancelled: true)
                                }
                            }
                        )
                    )
                }
                if settings.snapshotDestination == .folder {
                    AuroraSettingsRow(
                        String(localized: "Save folder"),
                        hint: String(localized: "Snapshots are saved here as PNG files."),
                        isLast: true,
                        labelExpands: true
                    ) {
                        HStack(spacing: 8) {
                            if !settings.snapshotFolderDisplayPath.isEmpty {
                                Text((settings.snapshotFolderDisplayPath as NSString).lastPathComponent)
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            AuroraSecondaryButton(title: String(localized: "Choose…")) {
                                chooseSnapshotFolder(revertToClipboardIfCancelled: false)
                            }
                        }
                    }
                }
            }

            AuroraSettingsSection(String(localized: "Appearance")) {
                AuroraSettingsRow(String(localized: "Theme")) {
                    AuroraSegmented(
                        options: [
                            (String(localized: "Auto"),  AppSettings.Appearance.auto),
                            (String(localized: "Light"), AppSettings.Appearance.light),
                            (String(localized: "Dark"),  AppSettings.Appearance.dark)
                        ],
                        selection: $settings.appearance
                    )
                }
                AuroraSettingsRow(String(localized: "Accent"), isLast: true) {
                    HStack(spacing: 8) {
                        ForEach(AuroraAccent.swatches, id: \.self) { hex in
                            AccentSwatch(hex: hex, selected: settings.accentColorHex == hex) {
                                settings.accentColorHex = hex
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: PTZ

    private var ptzTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraSettingsSection(String(localized: "Classic API credentials")) {
                AuroraSettingsRow(
                    String(localized: "Username"),
                    hint: String(localized: "Local admin account on the Protect controller.")
                ) {
                    PastableTextField(text: $settings.username, placeholder: "")
                        .frame(width: 260)
                }
                AuroraSettingsRow(String(localized: "Password")) {
                    HStack(spacing: 6) {
                        Group {
                            if showPassword {
                                PastableTextField(text: $settings.password, placeholder: "")
                            } else {
                                PastableSecureField(text: $settings.password, placeholder: "")
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
                            disabled: isTestingPtz || settings.ipAddress.isEmpty
                                || settings.username.isEmpty || settings.password.isEmpty,
                            action: runPtzTest
                        )
                        if isTestingPtz {
                            ProgressView().scaleEffect(0.6)
                        }
                        if let result = ptzTestResult {
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
            Text("PTZ control uses the classic Protect API, which requires a local account. The Integration API (API Key) only exposes preset and patrol endpoints, not free-form movement.")
                .font(.system(size: 11))
                .foregroundColor(palette.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cameras

    private var camerasTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if settings.profiles().count > 1 {
                Text("Visibility, size, and order apply to the “\(settings.activeProfile.name)” profile. Switch profiles from the popover header.")
                    .font(.system(size: 11))
                    .foregroundColor(palette.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            cameraListSection
        }
    }

    private var cameraListSection: some View {
        AuroraSettingsSection {
            if service.cameras.isEmpty {
                AuroraSettingsRow(isLast: true) {
                    Text("No cameras discovered yet. Run Test Connection on the Connection tab.")
                        .font(.system(size: 12))
                        .foregroundColor(palette.subtext)
                }
            } else {
                let cams = settings.orderedCameras(service.cameras)
                ForEach(Array(cams.enumerated()), id: \.element.id) { idx, cam in
                    CameraRow(
                        camera: cam,
                        size: settings.cameraSize(for: cam.id),
                        hidden: settings.isHidden(cam.id),
                        showsPip: settings.showsSecondaryLensPip(for: cam.id),
                        showsGridPip: settings.showsSecondaryLensPipInGrid(for: cam.id),
                        isLast: idx == cams.count - 1,
                        onSize: { s in
                            settings.setCameraSize(s, for: cam.id)
                            service.objectWillChange.send()
                        },
                        onHide: { h in
                            settings.setHidden(h, for: cam.id)
                            service.objectWillChange.send()
                        },
                        onTogglePip: { on in
                            settings.setShowsSecondaryLensPip(on, for: cam.id)
                            service.objectWillChange.send()
                        },
                        onToggleGridPip: { on in
                            settings.setShowsSecondaryLensPipInGrid(on, for: cam.id)
                            service.objectWillChange.send()
                        }
                    )
                }
            }
        }
    }

    // MARK: Shortcuts

    private var shortcutsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraSettingsSection(String(localized: "Global")) {
                AuroraSettingsRow(
                    String(localized: "Toggle QuickProtect"),
                    hint: String(localized: "Show or hide the camera grid from anywhere."),
                    isLast: true
                ) {
                    HStack(spacing: 10) {
                        Text(isRecordingHotkey ? String(localized: "Press shortcut…") : settings.hotkeyDisplayString)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(isRecordingHotkey ? Color.accentColor : Color.accentColor)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(colorScheme == .dark ? Color.black.opacity(0.3) : .white)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.accentColor.opacity(isRecordingHotkey ? 1 : 0.4),
                                            lineWidth: 0.5)
                            )
                        AuroraSecondaryButton(title: isRecordingHotkey ? String(localized: "Cancel") : String(localized: "Change")) {
                            isRecordingHotkey.toggle()
                        }
                        if settings.globalHotkey() != nil {
                            AuroraSecondaryButton(title: String(localized: "Clear")) {
                                settings.clearGlobalHotkey()
                                HotkeyManager.shared.unregister()
                                hotkeyRegistrationFailed = false
                            }
                        }
                    }
                }
                if hotkeyRegistrationFailed {
                    AuroraSettingsRow(
                        String(localized: "Couldn't register this shortcut — it may be in use by another app."),
                        isLast: true,
                        labelExpands: true
                    ) { EmptyView() }
                }
            }
            AuroraSettingsSection(String(localized: "Within QuickProtect")) {
                let rows: [(String, String)] = [
                    (String(localized: "Focus camera"),       String(localized: "Click")),
                    (String(localized: "Display fullscreen"), String(localized: "F  ·  Space")),
                    (String(localized: "Exit / back"),        String(localized: "Esc")),
                    (String(localized: "Pan & tilt (PTZ)"),   "← → ↑ ↓"),
                    (String(localized: "Zoom (PTZ)"),         "I  ·  O"),
                    (String(localized: "Open in Protect"),    String(localized: "Double-click")),
                    (String(localized: "Digital zoom"),       String(localized: "⌘+scroll")),
                ]
                ForEach(Array(rows.enumerated()), id: \.offset) { idx, r in
                    AuroraSettingsRow(isLast: idx == rows.count - 1) {
                        HStack {
                            Text(r.0)
                                .font(.system(size: 12.5))
                                .foregroundColor(palette.text)
                            Spacer()
                            Text(r.1)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundColor(palette.subtext)
                        }
                    }
                }
            }
        }
    }

    // MARK: Updates

    private var updatesTab: some View {
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
    private var updateActions: some View {
        HStack(spacing: 10) {
            // Notify-only: the GitHub build is unsigned, so there is no
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

    // MARK: About

    private var aboutTab: some View {
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

    // MARK: - Hotkey recorder overlay (invisible key-capture)

    @ViewBuilder
    private var hotkeyRecorderOverlay: some View {
        if isRecordingHotkey {
            HotkeyRecorderView { keyCode, modifiers in
                let carbonMods = HotkeyManager.carbonModifiers(from: modifiers)
                settings.setGlobalHotkey(keyCode: UInt32(keyCode), carbonModifiers: carbonMods)
                hotkeyRegistrationFailed = !HotkeyManager.shared.register(keyCode: UInt32(keyCode), carbonModifiers: carbonMods)
                isRecordingHotkey = false
            } onCancel: {
                isRecordingHotkey = false
            }
        }
    }

    // MARK: - Snapshot folder

    private func chooseSnapshotFolder(revertToClipboardIfCancelled: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        panel.message = String(localized: "Choose a folder for saved snapshots")
        if panel.runModal() == .OK, let url = panel.url {
            settings.setSnapshotFolder(url)
        } else if revertToClipboardIfCancelled, settings.resolveSnapshotFolder() == nil {
            // Folder mode needs a folder; with none picked, fall back to clipboard.
            settings.snapshotDestination = .clipboard
        }
    }

    // MARK: - Test connection

    private func runTest() {
        isTesting = true
        testResult = nil
        // Store the address in its canonical form (scheme, path and whitespace
        // dropped) so what the user sees is exactly what gets pinned and dialled.
        if let address = ControllerAddress.parse(settings.ipAddress), address.authority != settings.ipAddress {
            settings.ipAddress = address.authority
        }
        Task {
            await service.fetchCameras(forced: true)
            isTesting = false
            if let err = service.errorMessage {
                testResult = TestResult(message: err, icon: "xmark.circle.fill", color: .red)
            } else {
                let n = service.cameras.count
                testResult = TestResult(
                    message: String(localized: "Connected · \(n) cameras found"),
                    icon: "checkmark.circle.fill",
                    color: AuroraTokens.statusGreenDark
                )
            }
        }
    }

    private func runPtzTest() {
        isTestingPtz = true
        ptzTestResult = nil
        Task {
            let ok = await service.classicLogin()
            isTestingPtz = false
            if ok {
                ptzTestResult = TestResult(
                    message: String(localized: "Signed in · PTZ control ready"),
                    icon: "checkmark.circle.fill",
                    color: AuroraTokens.statusGreenDark
                )
            } else {
                ptzTestResult = TestResult(
                    message: String(localized: "Login failed — check the username and password"),
                    icon: "xmark.circle.fill",
                    color: .red
                )
            }
        }
    }

    private struct TestResult: Equatable {
        let message: String
        let icon: String
        let color: Color
    }
}

// MARK: - Accent swatch

private struct AccentSwatch: View {
    let hex: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 18, height: 18)
                .overlay(
                    Circle()
                        .stroke(Color(hex: hex),
                                lineWidth: selected ? 1.5 : 0)
                        .padding(-3.5)
                )
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pastable text fields (NSTextField-backed for proper Cmd+V support)

/// Routes the standard editing key equivalents (⌘X/⌘C/⌘V/⌘A/⌘Z) to the field
/// editor. A menu-bar (`.accessory`) app has no Edit menu, so these shortcuts
/// would otherwise be dropped and only the context-menu items would work.
private func handleEditingKeyEquivalent(_ event: NSEvent, from sender: NSControl) -> Bool {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
          let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
    let action: Selector
    switch key {
    case "x": action = #selector(NSText.cut(_:))
    case "c": action = #selector(NSText.copy(_:))
    case "v": action = #selector(NSText.paste(_:))
    case "a": action = #selector(NSText.selectAll(_:))
    case "z": action = Selector(("undo:"))
    default:  return false
    }
    // Dispatch through the responder chain to the first responder (field editor).
    return NSApp.sendAction(action, to: nil, from: sender)
}

final class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditingKeyEquivalent(event, from: self) || super.performKeyEquivalent(with: event)
    }
}

final class EditableSecureTextField: NSSecureTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleEditingKeyEquivalent(event, from: self) || super.performKeyEquivalent(with: event)
    }
}

/// Regular text field that supports copy/paste in panels/popovers.
struct PastableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSTextField {
        let field = EditableTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

/// Secure text field that supports copy/paste in panels/popovers.
struct PastableSecureField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = EditableSecureTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField { text.wrappedValue = field.stringValue }
        }
    }
}

// MARK: - NSView-based hotkey recorder (captures key events)

struct HotkeyRecorderView: NSViewRepresentable {
    let onRecord: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyCapture {
        let v = HotkeyCapture()
        v.onRecord = onRecord
        v.onCancel = onCancel
        // Become first responder to receive key events
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: HotkeyCapture, context: Context) {}

    final class HotkeyCapture: NSView {
        var onRecord: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            // Escape cancels
            if event.keyCode == 53 { onCancel?(); return }
            // Require at least one modifier (cmd, ctrl, option, or shift)
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard !mods.isEmpty else { return }
            onRecord?(event.keyCode, mods)
        }
    }
}

// MARK: - Cameras tab row

private struct CameraRow: View {
    let camera: Camera
    let size: AppSettings.CameraSize?
    let hidden: Bool
    let showsPip: Bool
    let showsGridPip: Bool
    let isLast: Bool
    let onSize: (AppSettings.CameraSize?) -> Void
    let onHide: (Bool) -> Void
    let onTogglePip: (Bool) -> Void
    let onToggleGridPip: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(camera.isOnline ? AuroraTokens.statusGreenDark : AuroraTokens.statusOrange)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(camera.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(palette.text)
                            .lineLimit(1)
                        if camera.isPtz {
                            Text("PTZ")
                                .font(.system(size: 9.5, weight: .semibold))
                                .tracking(0.3)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .foregroundColor(Color.accentColor)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                    Text(camera.isOnline ? String(localized: "Connected") : String(localized: "Offline"))
                        .font(.system(size: 11))
                        .foregroundColor(palette.subtext)
                }
                Spacer()
                AuroraSegmented(
                    options: [
                        (String(localized: "Auto"), nil as AppSettings.CameraSize?),
                        ("S",    .small),
                        ("M",    .medium),
                        ("L",    .large)
                    ],
                    selection: Binding(get: { size }, set: onSize)
                )
                Toggle("", isOn: Binding(get: { !hidden }, set: { onHide(!$0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(hidden ? "Show in grid" : "Hide from grid")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            if let lens = camera.secondaryLens {
                secondaryLensRow(lens)
            }
            if !isLast { AuroraHairline(color: palette.divider) }
        }
    }

    /// Indented sub-rows, shown only for cameras with a second lens: one toggle
    /// for the focus/fullscreen PiP and one for showing it on the grid tile too.
    @ViewBuilder
    private func secondaryLensRow(_ lens: Camera.SecondaryLens) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "pip")
                    .font(.system(size: 11))
                    .foregroundColor(palette.subtext)
                Text(lens.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(palette.text)
                Spacer()
            }
            pipToggle(title: String(localized: "Picture-in-picture when focused"),
                      isOn: showsPip, set: onTogglePip)
            pipToggle(title: String(localized: "Also show on the grid tile"),
                      isOn: showsGridPip, set: onToggleGridPip)
        }
        .padding(.leading, 31).padding(.trailing, 14)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private func pipToggle(title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundColor(palette.subtext)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .padding(.leading, 21)
    }
}

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
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var service: ProtectService
    @ObservedObject var updateChecker: UpdateChecker

    /// Last tab the user viewed, remembered for the lifetime of the app process.
    /// Resets to General on relaunch (it is not persisted), so the first open
    /// after starting the app lands on General while later opens within the same
    /// session restore the previous selection.
    static var sessionTab: SettingsTab = .general

    @State var tab: SettingsTab = SettingsView.sessionTab
    @State var isTesting = false
    @State var testResult: TestResult?
    @State var isTestingPtz = false
    @State var ptzTestResult: TestResult?
    @State var isRecordingHotkey = false
    @State var showApiKey = false
    @State var showPassword = false
    /// Toggled to force `pendingCertFingerprint` to re-read after the user re-pins.
    @State var certRefresh = false
    @State var hotkeyRegistrationFailed = false

    @Environment(\.colorScheme) var colorScheme
    var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

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

    var sidebar: some View {
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

    var detailPane: some View {
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
    var headerStatusBadge: some View {
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

    // MARK: - Hotkey recorder overlay (invisible key-capture)

    @ViewBuilder
    var hotkeyRecorderOverlay: some View {
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

    func chooseSnapshotFolder(revertToClipboardIfCancelled: Bool) {
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

    func runTest() {
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

    func runPtzTest() {
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

    struct TestResult: Equatable {
        let message: String
        let icon: String
        let color: Color
    }
}

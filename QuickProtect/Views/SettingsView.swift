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
}

// MARK: - Root

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var service: ProtectService
    @ObservedObject var updateChecker: UpdateChecker

    @State private var tab: SettingsTab = .connection
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var isRecordingHotkey = false
    @State private var showApiKey = false
    @State private var showPassword = false

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detailPane
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 600)
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

            ForEach(SettingsTab.allCases) { t in
                AuroraSidebarItem(
                    systemImage: t.systemImage,
                    title: t.rawValue,
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
                Text(tab.rawValue)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(palette.text)
                Spacer()
                AuroraStatusBadge(
                    connected: service.errorMessage == nil && !service.cameras.isEmpty,
                    text: service.errorMessage == nil ? "Connected" : "Disconnected"
                )
            }
            .padding(.horizontal, 22).frame(height: 52)
            AuroraHairline(color: palette.divider)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case .connection: connectionTab
                    default:          placeholderTab
                    }
                }
                .padding(22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Tabs

    private var connectionTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            AuroraSettingsSection("Controller") {
                AuroraSettingsRow("IP Address", hint: "Local IP of your UniFi Protect controller") {
                    PastableTextField(text: $settings.ipAddress, placeholder: "10.0.1.1")
                        .frame(width: 260)
                }
                AuroraSettingsRow("API Key", hint: "Integration API key from controller settings") {
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
                AuroraSettingsRow("Stream protocol") {
                    AuroraSegmented(
                        options: [("RTSPS (TLS)", false), ("RTSP (7447)", true)],
                        selection: $settings.usePlainRtsp
                    )
                }
                AuroraSettingsRow(isLast: true) {
                    HStack(spacing: 10) {
                        AuroraPrimaryButton(
                            title: "Test Connection",
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

            AuroraSettingsSection("Appearance") {
                AuroraSettingsRow("Theme") {
                    AuroraSegmented(
                        options: [
                            ("Auto",  AppSettings.Appearance.auto),
                            ("Light", AppSettings.Appearance.light),
                            ("Dark",  AppSettings.Appearance.dark)
                        ],
                        selection: $settings.appearance
                    )
                }
                AuroraSettingsRow("Accent", isLast: true) {
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

    private var placeholderTab: some View {
        Text("Coming soon.")
            .font(.system(size: 12))
            .foregroundColor(palette.subtext)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Hotkey recorder overlay (invisible key-capture)

    @ViewBuilder
    private var hotkeyRecorderOverlay: some View {
        if isRecordingHotkey {
            HotkeyRecorderView { keyCode, modifiers in
                let carbonMods = HotkeyManager.carbonModifiers(from: modifiers)
                settings.setGlobalHotkey(keyCode: UInt32(keyCode), carbonModifiers: carbonMods)
                HotkeyManager.shared.register(keyCode: UInt32(keyCode), carbonModifiers: carbonMods)
                isRecordingHotkey = false
            } onCancel: {
                isRecordingHotkey = false
            }
        }
    }

    // MARK: - Test connection

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            await service.fetchCameras()
            isTesting = false
            if let err = service.errorMessage {
                testResult = TestResult(message: err, icon: "xmark.circle.fill", color: .red)
            } else {
                let n = service.cameras.count
                testResult = TestResult(
                    message: "Connected · \(n) camera\(n == 1 ? "" : "s") found",
                    icon: "checkmark.circle.fill",
                    color: AuroraTokens.statusGreenDark
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

/// Regular text field that supports copy/paste in panels/popovers.
struct PastableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
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
        let field = NSSecureTextField()
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

import SwiftUI
import Carbon

// MARK: - Shortcuts tab: global hotkey and the in-panel key reference.

extension SettingsView {

    // MARK: Shortcuts

    var shortcutsTab: some View {
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
}

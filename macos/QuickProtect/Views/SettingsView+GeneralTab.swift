import SwiftUI
import Carbon

// MARK: - General tab: appearance, streams, snapshots, login item.

extension SettingsView {

    // MARK: General

    var generalTab: some View {
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

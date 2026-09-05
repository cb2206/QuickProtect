import SwiftUI
import Carbon

// MARK: - Cameras tab: per-camera size, visibility and picture-in-picture.

extension SettingsView {

    // MARK: Cameras

    var camerasTab: some View {
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

    var cameraListSection: some View {
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

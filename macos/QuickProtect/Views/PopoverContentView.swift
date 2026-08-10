import SwiftUI

/// Root view shown inside the status-bar popover.
struct PopoverContentView: View {
    @ObservedObject var service: ProtectService
    let clientManager: RTSPClientManager
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchQuery: String = ""
    let openSettings: () -> Void

    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            // When a camera is focused, its own top bar replaces this grid header.
            if !service.isFocusMode {
                header
                AuroraHairline(color: palette.chromeBorder)
            }
            CameraGridView(service: service, clientManager: clientManager,
                           searchQuery: searchQuery, onOpenSettings: openSettings)
        }
        .background(palette.popoverBg)
        .accentColor(Color(hex: settings.accentColorHex))
        .preferredColorScheme(settings.appearance.preferredColorScheme)
    }

    // MARK: - Header bar

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                AuroraBrandMark(size: 15, color: Color(hex: settings.accentColorHex))
                Text("QuickProtect")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(palette.text)
                    .tracking(-0.1)
            }

            statusPill
                .padding(.leading, 2)

            profileMenu

            Spacer(minLength: 8)

            if service.isLoading {
                ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
            }

            searchField

            HeaderIconButton(systemName: "arrow.clockwise", help: String(localized: "Refresh cameras")) {
                Task { await service.fetchCameras(forced: true) }
            }
            .disabled(service.isLoading)

            HeaderIconButton(systemName: "gearshape", help: String(localized: "Settings"), action: openSettings)

            HeaderIconButton(systemName: "power", help: String(localized: "Quit QuickProtect")) {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                palette.chrome
            }
        )
    }

    private var visibleCount: Int {
        let visible = settings.visibleCameras(service.cameras).filter { $0.isOnline }
        return visible.count
    }

    private var statusPill: some View {
        let isDark = colorScheme == .dark
        let green = isDark ? AuroraTokens.statusGreenDark : AuroraTokens.statusGreenLight
        let bg = isDark
            ? AuroraTokens.statusGreenDark.opacity(0.14)
            : AuroraTokens.statusGreenDark.opacity(0.18)
        return HStack(spacing: 6) {
            Circle().fill(AuroraTokens.statusGreenDark)
                .frame(width: 5, height: 5)
            // TODO: expose bitrate from ProtectService; design shows "· 4.2 Mbps" too
            Text("\(visibleCount) streams")
                .font(.system(size: 11))
                .monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundColor(green)
        .background(Capsule().fill(bg))
    }

    // MARK: - Layout profile switcher

    private var profileMenu: some View {
        Menu {
            ForEach(settings.profiles()) { profile in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.switchProfile(to: profile.id)
                    }
                    service.objectWillChange.send()
                } label: {
                    if profile.id == settings.activeProfileID {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }

            Divider()

            Button(String(localized: "Save Current View as New Profile…")) {
                promptForName(
                    title: String(localized: "Save Current View as New Profile"),
                    initial: "",
                    confirm: String(localized: "Save")
                ) {
                    settings.createProfile(named: $0)
                    service.objectWillChange.send()
                }
            }

            Button(String(localized: "Rename Profile…")) {
                let current = settings.activeProfile
                promptForName(
                    title: String(localized: "Rename Profile"),
                    initial: current.name,
                    confirm: String(localized: "Rename")
                ) { settings.renameProfile(current.id, to: $0) }
            }

            Button(String(localized: "Delete Profile"), role: .destructive) {
                settings.deleteProfile(settings.activeProfileID)
                service.objectWillChange.send()
            }
            .disabled(settings.profiles().count <= 1)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 10, weight: .medium))
                Text(settings.activeProfile.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundColor(palette.subtext)
            .background(
                Capsule().fill(colorScheme == .dark
                               ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
            )
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Switch layout profile"))
    }

    /// Prompts for a profile name with a modal alert. The popover stays open —
    /// its dismiss-on-outside-click monitor only fires for events outside the app.
    private func promptForName(title: String, initial: String, confirm: String,
                               onConfirm: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = initial
        field.placeholderString = String(localized: "Profile name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        // The popover panel sits at `.popUpMenu` level, which draws above the
        // modal alert. Temporarily drop it (and any other elevated app windows)
        // to normal level so the name field is reachable, then restore.
        let elevated = NSApp.windows.filter { $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue }
        let savedLevels = elevated.map(\.level)
        elevated.forEach { $0.level = .normal }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        zip(elevated, savedLevels).forEach { $0.level = $1 }
        guard response == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onConfirm(name) }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
            AuroraSearchField(text: $searchQuery, placeholder: String(localized: "Search cameras"))
                .frame(width: 100)
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(palette.subtext)
                .help("Clear search")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: searchQuery.isEmpty)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundColor(palette.subtext)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.04))
        )
    }
}

// MARK: - Header icon button

private struct HeaderIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 24, height: 24)
                .foregroundColor(hover ? AuroraTokens.palette(for: colorScheme).text
                                       : AuroraTokens.palette(for: colorScheme).subtext)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hover
                              ? (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))
                              : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Plain text field for header search (no border, inherits color)

private struct AuroraSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: 11.5)
        f.focusRingType = .none
        f.delegate = context.coordinator
        f.stringValue = text
        return f
    }

    func updateNSView(_ v: NSTextField, context: Context) {
        if v.stringValue != text { v.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { text.wrappedValue = f.stringValue }
        }
    }
}

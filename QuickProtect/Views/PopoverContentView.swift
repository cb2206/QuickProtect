import SwiftUI

/// Root view shown inside the status-bar popover.
struct PopoverContentView: View {
    @ObservedObject var service: ProtectService
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchQuery: String = ""
    let openSettings: () -> Void

    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            AuroraHairline(color: palette.chromeBorder)
            CameraGridView(service: service, searchQuery: searchQuery, onOpenSettings: openSettings)
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

            Spacer(minLength: 8)

            if service.isLoading {
                ProgressView().scaleEffect(0.55).frame(width: 16, height: 16)
            }

            searchField

            HeaderIconButton(systemName: "arrow.clockwise", help: "Refresh cameras") {
                Task { await service.fetchCameras() }
            }
            .disabled(service.isLoading)

            HeaderIconButton(systemName: "gearshape", help: "Settings", action: openSettings)

            HeaderIconButton(systemName: "power", help: "Quit QuickProtect") {
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
            Text("\(visibleCount) stream\(visibleCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundColor(green)
        .background(Capsule().fill(bg))
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
            AuroraSearchField(text: $searchQuery, placeholder: "Search cameras")
                .frame(width: 100)
        }
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

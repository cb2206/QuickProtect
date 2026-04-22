import SwiftUI

// MARK: - Section container

struct AuroraSettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundColor(palette.subtext)
            }
            VStack(spacing: 0) { content() }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(palette.sectionBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.divider, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Row

struct AuroraSettingsRow<Content: View>: View {
    let label: String?
    let hint: String?
    let isLast: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    init(_ label: String? = nil, hint: String? = nil, isLast: Bool = false,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.hint = hint
        self.isLast = isLast
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                if let label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(palette.text)
                        if let hint {
                            Text(hint)
                                .font(.system(size: 11))
                                .foregroundColor(palette.subtext)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(width: 150, alignment: .leading)
                }
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if !isLast { AuroraHairline(color: palette.divider) }
        }
    }
}

// MARK: - Sidebar item

struct AuroraSidebarItem: View {
    let systemImage: String
    let title: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .foregroundColor(selected ? Color.accentColor : AuroraTokens.palette(for: colorScheme).text)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected
                          ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
                          : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Segmented picker styled to match Aurora

struct AuroraSegmented<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = AuroraTokens.palette(for: colorScheme)
        HStack(spacing: 1) {
            ForEach(options.indices, id: \.self) { i in
                let (label, value) = options[i]
                let active = value == selection
                Text(label)
                    .font(.system(size: 11.5, weight: active ? .medium : .regular))
                    .foregroundColor(palette.text)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(active
                                  ? (colorScheme == .dark ? Color.white.opacity(0.12) : Color.white)
                                  : Color.clear)
                            .shadow(color: active ? .black.opacity(0.1) : .clear, radius: 1.5, y: 0.5)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selection = value }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.divider, lineWidth: 0.5)
        )
        .fixedSize()
    }
}

// MARK: - Status badge ("Connected")

struct AuroraStatusBadge: View {
    let connected: Bool
    let text: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let green = colorScheme == .dark ? AuroraTokens.statusGreenDark : AuroraTokens.statusGreenLight
        let bg = AuroraTokens.statusGreenDark.opacity(colorScheme == .dark ? 0.14 : 0.18)
        HStack(spacing: 5) {
            Circle()
                .fill(connected ? AuroraTokens.statusGreenDark : AuroraTokens.statusRed)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 11))
                .monospacedDigit()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundColor(connected ? green : AuroraTokens.statusRed)
        .background(Capsule().fill(connected ? bg : AuroraTokens.statusRed.opacity(0.14)))
    }
}

// MARK: - Primary/secondary button

struct AuroraPrimaryButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

struct AuroraSecondaryButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AuroraTokens.palette(for: colorScheme).text)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }
}

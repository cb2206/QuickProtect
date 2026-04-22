import SwiftUI

// MARK: - State card shown in place of the grid

struct AuroraStateCard: View {
    enum Tone { case warning, neutral, error }

    let tone: Tone
    let systemImage: String
    let title: String
    let message: String
    let primary: (String, () -> Void)?
    let secondary: (String, () -> Void)?
    let footer: String?

    @Environment(\.colorScheme) private var colorScheme
    private var palette: AuroraTokens.Palette { AuroraTokens.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 10) {
            iconBubble
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(palette.text)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(palette.subtext)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .frame(maxWidth: 260)
            HStack(spacing: 8) {
                if let primary {
                    Button(primary.0, action: primary.1)
                        .buttonStyle(AuroraStatePillButtonStyle(primary: true))
                }
                if let secondary {
                    Button(secondary.0, action: secondary.1)
                        .buttonStyle(AuroraStatePillButtonStyle(primary: false))
                }
            }
            .padding(.top, 4)
            if let footer {
                Text(footer)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundColor(palette.subtext)
                    .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(palette.sectionBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(palette.divider, lineWidth: 0.5)
        )
    }

    private var toneColor: Color {
        switch tone {
        case .warning: return AuroraTokens.statusOrange
        case .neutral: return palette.subtext
        case .error:   return AuroraTokens.statusRed
        }
    }

    private var iconBubble: some View {
        ZStack {
            Circle()
                .fill(toneColor.opacity(tone == .neutral ? 0.08 : 0.16))
                .frame(width: 44, height: 44)
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundColor(toneColor)
        }
    }
}

// MARK: - Pill-shaped action button

struct AuroraStatePillButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let palette = AuroraTokens.palette(for: colorScheme)
        let bg: Color = primary
            ? Color.accentColor
            : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05))
        let fg: Color = primary ? .white : palette.text
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(fg)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(bg))
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

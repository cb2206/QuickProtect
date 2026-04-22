import SwiftUI

// MARK: - Top floating bar

struct AuroraFocusTopBar: View {
    let cameraName: String
    let isPtz: Bool
    @Binding var fillMode: Bool
    let now: Date
    let onBack: () -> Void
    let onToggleFullscreen: () -> Void

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy·MM·dd  HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Grid")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Back to grid (Esc)")

            AuroraFocusBarDivider()

            AuroraRecDot(size: 6)

            Text(cameraName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .tracking(-0.1)

            if isPtz {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("PTZ · ARROW KEYS")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.4)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.10)))
            }

            Spacer(minLength: 6)

            Text(Self.timestampFormatter.string(from: now))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))

            AuroraFocusIconButton(systemName: fillMode ? "rectangle.inset.filled" : "rectangle",
                                   help: fillMode ? "Fit to frame" : "Fill frame") {
                fillMode.toggle()
            }
            AuroraFocusIconButton(systemName: "arrow.up.left.and.arrow.down.right",
                                   help: "Fullscreen (F)",
                                   action: onToggleFullscreen)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                Color(red: 20/255, green: 20/255, blue: 22/255).opacity(0.6)
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct AuroraFocusBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 0.5, height: 14)
    }
}

struct AuroraFocusIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 24, height: 24)
                .foregroundStyle(.white.opacity(hover ? 1.0 : 0.75))
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hover ? Color.white.opacity(0.08) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - PTZ d-pad

struct AuroraPtzDpad: View {
    let onPress: (Direction) -> Void
    let onRelease: () -> Void

    enum Direction { case up, down, left, right }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 20/255, green: 20/255, blue: 22/255).opacity(0.45))
                .overlay(
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
                .background(
                    VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                        .clipShape(Circle())
                )

            // Center dot
            Circle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 6, height: 6)

            // Grid of 3x3 positions; corners stay blank
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear
                    DpadButton(systemName: "chevron.up", onPress: { onPress(.up) }, onRelease: onRelease)
                    Color.clear
                }
                HStack(spacing: 0) {
                    DpadButton(systemName: "chevron.left", onPress: { onPress(.left) }, onRelease: onRelease)
                    Color.clear
                    DpadButton(systemName: "chevron.right", onPress: { onPress(.right) }, onRelease: onRelease)
                }
                HStack(spacing: 0) {
                    Color.clear
                    DpadButton(systemName: "chevron.down", onPress: { onPress(.down) }, onRelease: onRelease)
                    Color.clear
                }
            }
            .padding(8)
        }
        .frame(width: 110, height: 110)
    }
}

private struct DpadButton: View {
    let systemName: String
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isPressed ? 1.0 : 0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            onPress()
                        }
                    }
                    .onEnded { _ in
                        if isPressed {
                            isPressed = false
                            onRelease()
                        }
                    }
            )
    }
}

// MARK: - True-fullscreen HUD

struct AuroraFullscreenHUD: View {
    let cameraName: String
    let isPtz: Bool
    let now: Date
    let visible: Bool

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ZStack(alignment: .topLeading) {
            livePill
                .padding(24)
            VStack {
                Spacer()
                bottomPill
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: visible)
    }

    private var livePill: some View {
        HStack(spacing: 7) {
            AuroraRecDot(size: 6)
            Text("LIVE")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.3)
                .foregroundStyle(.white)
            Text(Self.clockFormatter.string(from: now))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                Color(red: 18/255, green: 18/255, blue: 20/255).opacity(0.65)
            }
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .clipShape(Capsule())
    }

    private var bottomPill: some View {
        HStack(spacing: 10) {
            AuroraRecDot(size: 6)
            Text(cameraName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            if isPtz {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("PTZ")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                }
                .foregroundStyle(Color(red: 96/255, green: 165/255, blue: 250/255))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color(red: 10/255, green: 132/255, blue: 255/255).opacity(0.22)))
            }
            Rectangle().fill(Color.white.opacity(0.15)).frame(width: 0.5, height: 14)
            KbdKey("F"); Text("exit fullscreen").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.7))
            KbdKey("⎋"); Text("back to popover").font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.7))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                Color(red: 18/255, green: 18/255, blue: 20/255).opacity(0.7)
            }
        )
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .clipShape(Capsule())
    }

    private struct KbdKey: View {
        let label: String
        init(_ label: String) { self.label = label }
        var body: some View {
            Text(label)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.white)
                .frame(minWidth: 14)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                )
        }
    }
}

// MARK: - Shortcut hints

struct AuroraFocusHints: View {
    let showPtzHint: Bool

    var body: some View {
        HStack(spacing: 14) {
            Hint(keys: ["F"], label: "Fullscreen")
            Hint(keys: ["␣"], label: "Fullscreen")
            Hint(keys: ["⎋"], label: "Back")
            if showPtzHint {
                Hint(keys: ["←", "→", "↑", "↓"], label: "Pan / tilt")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(Color.white.opacity(0.65))
    }

    private struct Hint: View {
        let keys: [String]
        let label: String
        var body: some View {
            HStack(spacing: 5) {
                HStack(spacing: 2) {
                    ForEach(keys, id: \.self) { k in
                        Text(k)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(minWidth: 14)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.white.opacity(0.12))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                                    )
                            )
                    }
                }
                Text(label)
            }
        }
    }
}

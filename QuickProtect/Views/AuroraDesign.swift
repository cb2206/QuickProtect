import SwiftUI
import AppKit

// MARK: - Tokens

/// Aurora design tokens. Values mirror `design_handoff_ui_overhaul/designs/direction-a-aurora.jsx`.
enum AuroraTokens {
    struct Palette {
        let chrome: Color
        let chromeBorder: Color
        let popoverBg: Color
        let gridBg: Color
        let chip: Color
        let chipBorder: Color
        let text: Color
        let subtext: Color
        let divider: Color
        let fieldBg: Color
        let sectionBg: Color
        let subtleSurface: Color
    }

    static let statusGreenDark  = Color(red: 0x30/255, green: 0xd1/255, blue: 0x58/255)
    static let statusGreenLight = Color(red: 0x24/255, green: 0x8a/255, blue: 0x3d/255)
    static let statusOrange     = Color(red: 0xff/255, green: 0x9f/255, blue: 0x0a/255)
    static let statusRed        = Color(red: 0xff/255, green: 0x45/255, blue: 0x3a/255)

    static func palette(for scheme: ColorScheme) -> Palette {
        scheme == .dark ? dark : light
    }

    static let dark = Palette(
        chrome:       Color(red: 28/255, green: 28/255, blue: 30/255).opacity(0.78),
        chromeBorder: Color.white.opacity(0.08),
        popoverBg:    Color(red: 0x0a/255, green: 0x0a/255, blue: 0x0b/255),
        gridBg:       Color(red: 0x05/255, green: 0x05/255, blue: 0x06/255),
        chip:         Color.black.opacity(0.55),
        chipBorder:   Color.white.opacity(0.10),
        text:         Color(red: 0xf5/255, green: 0xf5/255, blue: 0xf7/255),
        subtext:      Color(red: 0xeb/255, green: 0xeb/255, blue: 0xf5/255).opacity(0.6),
        divider:      Color.white.opacity(0.08),
        fieldBg:      Color.black.opacity(0.3),
        sectionBg:    Color.white.opacity(0.04),
        subtleSurface: Color.white.opacity(0.06)
    )

    static let light = Palette(
        chrome:       Color(red: 246/255, green: 246/255, blue: 247/255).opacity(0.82),
        chromeBorder: Color.black.opacity(0.08),
        popoverBg:    Color.white,
        gridBg:       Color(red: 0xef/255, green: 0xef/255, blue: 0xf2/255),
        chip:         Color.white.opacity(0.82),
        chipBorder:   Color.black.opacity(0.08),
        text:         Color(red: 0x1d/255, green: 0x1d/255, blue: 0x1f/255),
        subtext:      Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.6),
        divider:      Color.black.opacity(0.08),
        fieldBg:      Color.white,
        sectionBg:    Color.black.opacity(0.025),
        subtleSurface: Color.black.opacity(0.05)
    )
}

// MARK: - Brand mark

/// Aperture-style brand mark matching `BrandMark` in `designs/shared.jsx`:
/// outer ring + solid inner lens + quick-shutter top arc.
struct AuroraBrandMark: View {
    var size: CGFloat = 15
    var color: Color = .accentColor

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            // viewBox is 16x16 with stroke 1.4
            let scale = s / 16
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

            // Outer ring (r = 6.2)
            let ringRadius = 6.2 * scale
            let ringRect = CGRect(
                x: center.x - ringRadius, y: center.y - ringRadius,
                width: ringRadius * 2, height: ringRadius * 2
            )
            ctx.stroke(
                Path(ellipseIn: ringRect),
                with: .color(color),
                lineWidth: 1.4 * scale
            )

            // Inner filled lens (r = 2.4)
            let lensRadius = 2.4 * scale
            let lensRect = CGRect(
                x: center.x - lensRadius, y: center.y - lensRadius,
                width: lensRadius * 2, height: lensRadius * 2
            )
            ctx.fill(Path(ellipseIn: lensRect), with: .color(color))

            // Top-right shutter arc: from (8,1.8) sweeping to (14.2,8)
            var arc = Path()
            let startAngle = Angle(degrees: -90)
            let endAngle = Angle(degrees: 0)
            arc.addArc(
                center: center,
                radius: ringRadius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: false
            )
            ctx.stroke(
                arc,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.4 * scale, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Rec dot (pulsing)

struct AuroraRecDot: View {
    var size: CGFloat = 6
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(AuroraTokens.statusRed)
            .frame(width: size, height: size)
            .shadow(color: AuroraTokens.statusRed.opacity(0.6), radius: size * 0.5)
            .opacity(pulse ? 0.35 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - NSVisualEffectView bridge

/// SwiftUI wrapper around NSVisualEffectView. Used for Aurora's translucent
/// header and sidebar ("saturate(180%) blur(24px)" in the JSX).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = state
        v.isEmphasized = emphasized
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.state = state
        v.isEmphasized = emphasized
    }
}

// MARK: - Hex color helper

extension Color {
    /// Init from a 6-character hex string (no leading '#'). Invalid input yields black.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xff) / 255.0
        let g = Double((value >>  8) & 0xff) / 255.0
        let b = Double( value        & 0xff) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

/// The six accent swatches offered by the Appearance settings row.
enum AuroraAccent {
    static let swatches: [String] = [
        "0a84ff", "30d158", "ff9f0a", "ff375f", "bf5af2", "ff453a"
    ]
}

// MARK: - Preferred color scheme from settings

extension AppSettings.Appearance {
    /// Returns nil for `.auto` so SwiftUI uses the system setting.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .auto:  return nil
        case .light: return .light
        case .dark:  return .dark
        }
    }
}

// MARK: - Hairline divider

struct AuroraHairline: View {
    var color: Color
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width:  axis == .vertical   ? 0.5 : nil,
                height: axis == .horizontal ? 0.5 : nil
            )
    }
}

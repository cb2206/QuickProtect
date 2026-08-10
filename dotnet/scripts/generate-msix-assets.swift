#!/usr/bin/env swift
//
//  generate-msix-assets.swift
//  Generates the MSIX visual assets (tile/app-list logos) for the Windows
//  Store package from the same Aurora design as the macOS .icns, so both
//  platforms show an identical mark.
//
//  Geometry is copied verbatim from macos/tools/generate_appicon.swift — if
//  the icon design changes, update both. The macOS Big Sur margin is dropped
//  here (Windows tiles have no equivalent grid); `kMarginRatio` instead keeps
//  a small breathing space so the rounded body isn't clipped at tile edges.
//
//  Runs on the macOS dev machine; its PNG output is committed under
//  dotnet/installer/msix/Assets/ so the Windows packaging script never needs
//  to regenerate it.
//
//  Usage:  swift dotnet/scripts/generate-msix-assets.swift [outputDir]
//
import AppKit

// MARK: - Geometry (matches the SVG viewBox, y-down)

let kMarginRatio: CGFloat = 0.04              // small margin; Windows tiles are square
let kViewBox:     CGFloat = 128.0             // SVG coordinate space

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

/// Draws the icon into `ctx` as a `side`×`side` square whose lower-left corner
/// is at (`originX`, `originY`) — the offset lets wide tiles centre the mark.
func drawIcon(into ctx: CGContext, side: CGFloat, originX: CGFloat = 0, originY: CGFloat = 0) {
    let off  = side * kMarginRatio
    let body = side * (1 - 2 * kMarginRatio)
    let s    = body / kViewBox
    ctx.saveGState()
    ctx.translateBy(x: originX + off, y: originY + off)
    ctx.scaleBy(x: s, y: s)

    // CoreGraphics is y-up; the SVG is y-down. Convert each y via Y().
    func Y(_ v: CGFloat) -> CGFloat { kViewBox - v }
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: Y(y)) }

    // Rounded-rect body path: rect(4,4,120,120) rx 27 in SVG space.
    let bodyRect = CGRect(x: 4, y: 4, width: 120, height: 120)
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 27, cornerHeight: 27, transform: nil)

    // --- Fill: blue gradient (top-left #4ea9ff → bottom-right #0a84ff) ---
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    guard let bg = CGGradient(colorsSpace: space,
                              colors: [rgba(0x4e, 0xa9, 0xff).cgColor,
                                       rgba(0x0a, 0x84, 0xff).cgColor] as CFArray,
                              locations: [0, 1]) else {
        fail("could not build the body gradient")
    }
    ctx.drawLinearGradient(bg, start: pt(0, 0), end: pt(128, 128), options: [])

    // --- Gloss: vertical white sheen, top 30% → fades out by 55% ---
    guard let gloss = CGGradient(colorsSpace: space,
                                 colors: [NSColor(white: 1, alpha: 0.30).cgColor,
                                          NSColor(white: 1, alpha: 0.0).cgColor] as CFArray,
                                 locations: [0, 1]) else {
        fail("could not build the gloss gradient")
    }
    ctx.drawLinearGradient(gloss, start: pt(64, 0), end: pt(64, 70.4), options: [])
    ctx.restoreGState()

    // --- Aperture ring: circle r34, white stroke width 3, opacity 0.95 ---
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.95).cgColor)
    ctx.setLineWidth(3)
    ctx.addEllipse(in: CGRect(x: 64 - 34, y: Y(64) - 34, width: 68, height: 68))
    ctx.strokePath()

    // --- Inner lens: white r14, blue r10, highlight r3.5 ---
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addEllipse(in: CGRect(x: 64 - 14, y: Y(64) - 14, width: 28, height: 28))
    ctx.fillPath()
    ctx.setFillColor(rgba(0x0a, 0x84, 0xff).cgColor)
    ctx.addEllipse(in: CGRect(x: 64 - 10, y: Y(64) - 10, width: 20, height: 20))
    ctx.fillPath()
    ctx.setFillColor(NSColor(white: 1, alpha: 0.75).cgColor)
    let hl = pt(60, 60)
    ctx.addEllipse(in: CGRect(x: hl.x - 3.5, y: hl.y - 3.5, width: 7, height: 7))
    ctx.fillPath()

    // --- Quick-shutter arc: "M64 26 A34 34 0 0 1 94 48", stroke 6, round cap ---
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    let center = pt(64, 64)
    let startAngle = atan2(Y(26) - center.y, 64 - center.x)   // +90° in CG
    let endAngle   = atan2(Y(48) - center.y, 94 - center.x)
    ctx.addArc(center: center, radius: 34,
               startAngle: startAngle, endAngle: endAngle, clockwise: true)
    ctx.strokePath()

    // --- Subtle inner edge to define the body against light backgrounds ---
    ctx.addPath(bodyPath)
    ctx.setStrokeColor(NSColor(white: 0, alpha: 0.15).cgColor)
    ctx.setLineWidth(1)
    ctx.strokePath()

    ctx.restoreGState()
}

/// Aborts with a message — these are unrecoverable setup failures in a
/// build-time tool, so there is nothing to fall back to.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

/// Renders a `w`×`h` PNG with the square mark centred on a transparent canvas.
func renderPNG(w: Int, h: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not create a \(w)×\(h) bitmap context")
    }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))

    // Wide tiles keep the mark square and centred rather than stretching it.
    let side = CGFloat(min(w, h))
    drawIcon(into: ctx,
             side: side,
             originX: (CGFloat(w) - side) / 2,
             originY: (CGFloat(h) - side) / 2)

    guard let cg = ctx.makeImage() else { fail("could not render the \(w)×\(h) image") }
    guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
        fail("could not encode the \(w)×\(h) image as PNG")
    }
    return png
}

// MARK: - Emit the MSIX asset set

let args = CommandLine.arguments
let outDir = args.count > 1
    ? args[1]
    : FileManager.default.currentDirectoryPath + "/dotnet/installer/msix/Assets"

let fm = FileManager.default
do {
    try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
} catch {
    fail("could not create \(outDir): \(error.localizedDescription)")
}

struct Asset {
    let name: String
    let w: Int
    let h: Int
    init(_ name: String, _ w: Int, _ h: Int) {
        self.name = name
        self.w = w
        self.h = h
    }
}

// Names are fixed by the AppxManifest / Store certification requirements.
// `targetsize-*` variants are what Windows uses for the taskbar and app list;
// `altform-unplated` drops the accent-coloured plate behind the icon.
let assets: [Asset] = [
    Asset("StoreLogo", 50, 50),
    Asset("Square44x44Logo", 44, 44),
    Asset("Square44x44Logo.targetsize-16", 16, 16),
    Asset("Square44x44Logo.targetsize-24", 24, 24),
    Asset("Square44x44Logo.targetsize-32", 32, 32),
    Asset("Square44x44Logo.targetsize-48", 48, 48),
    Asset("Square44x44Logo.targetsize-256", 256, 256),
    Asset("Square44x44Logo.altform-unplated_targetsize-16", 16, 16),
    Asset("Square44x44Logo.altform-unplated_targetsize-24", 24, 24),
    Asset("Square44x44Logo.altform-unplated_targetsize-32", 32, 32),
    Asset("Square44x44Logo.altform-unplated_targetsize-48", 48, 48),
    Asset("Square44x44Logo.altform-unplated_targetsize-256", 256, 256),
    Asset("Square71x71Logo", 71, 71),
    Asset("Square150x150Logo", 150, 150),
    Asset("Square310x310Logo", 310, 310),
    Asset("Wide310x150Logo", 310, 150),
    // Scale-200 variants keep the icons crisp on high-DPI displays.
    Asset("Square44x44Logo.scale-200", 88, 88),
    Asset("Square71x71Logo.scale-200", 142, 142),
    Asset("Square150x150Logo.scale-200", 300, 300),
    Asset("Square310x310Logo.scale-200", 620, 620),
    Asset("Wide310x150Logo.scale-200", 620, 300),
    Asset("StoreLogo.scale-200", 100, 100)
]

for asset in assets {
    let data = renderPNG(w: asset.w, h: asset.h)
    let path = outDir + "/" + asset.name + ".png"
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("could not write \(path): \(error.localizedDescription)")
    }
    print("  \(asset.name).png  (\(asset.w)×\(asset.h))")
}

print("Wrote \(assets.count) MSIX assets to \(outDir)")

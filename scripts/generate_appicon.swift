#!/usr/bin/env swift
//
//  generate_appicon.swift
//  Generates QuickProtect's app icon (the .icns) from the Aurora design.
//
//  Faithfully redraws `AuroraAppIcon` from the design handoff
//  (designs/direction-a-details.jsx): a blue-gradient rounded square with a
//  white aperture ring, an inner lens, and a "quick-shutter" top arc.
//
//  All geometry is expressed in the SVG's original 128×128 viewBox and mapped
//  into the macOS Big Sur icon grid (≈824/1024 content with a transparent
//  margin) so it sits correctly next to first-party Dock icons.
//
//  Usage:  swift scripts/generate_appicon.swift QuickProtect/QuickProtect.icns
//
import AppKit

// MARK: - Geometry (matches the SVG viewBox, y-down)

// macOS icon grid: content body inset within the 1024 tile.
let kMarginRatio: CGFloat = 80.0 / 1024.0     // transparent margin
let kBodyRatio:   CGFloat = 864.0 / 1024.0    // body occupies this fraction
let kViewBox:     CGFloat = 128.0             // SVG coordinate space

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}

/// Draws the icon into `ctx`, sized to a `px`×`px` device-pixel canvas.
func drawIcon(into ctx: CGContext, px: CGFloat) {
    ctx.clear(CGRect(x: 0, y: 0, width: px, height: px))

    // Map the 128-unit SVG space into the centered body region.
    let off  = px * kMarginRatio
    let body = px * kBodyRatio
    let s    = body / kViewBox
    ctx.saveGState()
    ctx.translateBy(x: off, y: off)
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
    let bg = CGGradient(colorsSpace: space,
                        colors: [rgba(0x4e, 0xa9, 0xff).cgColor,
                                 rgba(0x0a, 0x84, 0xff).cgColor] as CFArray,
                        locations: [0, 1])!
    // top-left (0,128 in CG) → bottom-right (128,0 in CG)
    ctx.drawLinearGradient(bg, start: pt(0, 0), end: pt(128, 128), options: [])

    // --- Gloss: vertical white sheen, top 30% → fades out by 55% ---
    let gloss = CGGradient(colorsSpace: space,
                           colors: [NSColor(white: 1, alpha: 0.30).cgColor,
                                    NSColor(white: 1, alpha: 0.0).cgColor] as CFArray,
                           locations: [0, 1])!
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
    // Arc on the r34 circle: from top (12 o'clock) clockwise to (94,48).
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    let center = pt(64, 64)
    // SVG start (64,26) is straight up; end (94,48) is up-and-right.
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

func renderPNG(px: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                        bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(into: ctx, px: CGFloat(px))
    let cg = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: cg)
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Build the .iconset and pack it with iconutil

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "QuickProtect.icns"

let fm = FileManager.default
let work = NSTemporaryDirectory() + "QuickProtect-\(ProcessInfo.processInfo.processIdentifier).iconset"
try? fm.removeItem(atPath: work)
try! fm.createDirectory(atPath: work, withIntermediateDirectories: true)

// Standard macOS iconset sizes (1x and 2x).
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16",      16),  ("icon_16x16@2x",      32),
    ("icon_32x32",      32),  ("icon_32x32@2x",      64),
    ("icon_128x128",   128),  ("icon_128x128@2x",   256),
    ("icon_256x256",   256),  ("icon_256x256@2x",   512),
    ("icon_512x512",   512),  ("icon_512x512@2x",  1024),
]
for entry in sizes {
    let data = renderPNG(px: entry.px)
    try! data.write(to: URL(fileURLWithPath: "\(work)/\(entry.name).png"))
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", work, "-o", outPath]
try! proc.run()
proc.waitUntilExit()
try? fm.removeItem(atPath: work)

if proc.terminationStatus == 0 {
    print("Wrote \(outPath)")
} else {
    FileHandle.standardError.write("iconutil failed (\(proc.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}

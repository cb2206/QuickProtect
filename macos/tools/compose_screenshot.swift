#!/usr/bin/env swift
// Compose an App Store-ready macOS screenshot.
// Usage: swift compose_screenshot.swift <input.png> <output.png> [width] [height]
// Places the input window image, centered with a shadow, on a gradient canvas
// of the given pixel size (default 2880x1800 — the highest macOS Retina tier).

import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: compose_screenshot.swift <in.png> <out.png> [w] [h]\n".data(using: .utf8)!)
    exit(1)
}
let inPath = args[1]
let outPath = args[2]
let W = args.count > 3 ? Int(args[3])! : 2880
let H = args.count > 4 ? Int(args[4])! : 1800

guard let input = NSImage(contentsOfFile: inPath),
      let inRep = NSBitmapImageRep(data: input.tiffRepresentation!) else {
    FileHandle.standardError.write("cannot load input image\n".data(using: .utf8)!)
    exit(1)
}
// Size off real pixels, not points — input DPI (72 vs 144) must not matter.
let inW = CGFloat(inRep.pixelsWide)
let inH = CGFloat(inRep.pixelsHigh)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let canvas = NSRect(x: 0, y: 0, width: W, height: H)

// 1. Vertical gradient backdrop (top -> bottom), matching the dark app theme.
let top = NSColor(srgbRed: 0.11, green: 0.14, blue: 0.20, alpha: 1)   // #1C2433
let bot = NSColor(srgbRed: 0.05, green: 0.07, blue: 0.10, alpha: 1)   // #0D121A
NSGradient(colors: [top, bot])!.draw(in: canvas, angle: -90)

// 2. Soft teal glow behind the window for depth.
let glowInner = NSColor(srgbRed: 0.20, green: 0.55, blue: 0.65, alpha: 0.28)
let glowOuter = NSColor(srgbRed: 0.20, green: 0.55, blue: 0.65, alpha: 0.0)
let center = NSPoint(x: CGFloat(W) * 0.5, y: CGFloat(H) * 0.58)
NSGradient(colors: [glowInner, glowOuter])!.draw(fromCenter: center, radius: 0,
                                                  toCenter: center, radius: CGFloat(W) * 0.42,
                                                  options: [])

// 3. Scale the window image to fit inside a margin box, preserving aspect.
let maxW = CGFloat(W) * 0.80
let maxH = CGFloat(H) * 0.84
let s = min(maxW / inW, maxH / inH)
let dw = inW * s
let dh = inH * s
let dest = NSRect(x: (CGFloat(W) - dw) / 2, y: (CGFloat(H) - dh) / 2, width: dw, height: dh)

// 4. Drop shadow to ground the window on the canvas.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -24),
              blur: 60,
              color: NSColor(white: 0, alpha: 0.55).cgColor)
input.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1.0)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png encode failed\n".data(using: .utf8)!)
    exit(1)
}
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(W)x\(H))")

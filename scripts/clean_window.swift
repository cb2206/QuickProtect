#!/usr/bin/env swift
// Strip the flat grey border from a window capture and round the corners to
// transparency, so the window composites cleanly onto any background.
// Detects the border by scanning inward along the centre lines (avoids the
// rounded-corner arcs), crops to the window, then applies a rounded-rect mask.
// Usage: swift clean_window.swift <in.png> <out.png> [cornerRadius]

import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let img = NSImage(contentsOfFile: args[1]),
      let rep = NSBitmapImageRep(data: img.tiffRepresentation!) else {
    FileHandle.standardError.write("usage: clean_window.swift <in.png> <out.png> [radius]\n".data(using: .utf8)!)
    exit(1)
}
let radius: CGFloat = args.count > 3 ? CGFloat(Double(args[3])!) : 26
let w = rep.pixelsWide, h = rep.pixelsHigh

// A pixel is "border grey" if it is near-neutral and mid-tone (~0.30..0.46).
func isBorder(_ x: Int, _ y: Int) -> Bool {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
    let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
    let spread = max(r, max(g, b)) - min(r, min(g, b))
    return spread < 0.05 && r > 0.30 && r < 0.46
}

let cx = w / 2, cy = h / 2
var top = 0;            while top < h, isBorder(cx, top) { top += 1 }
var bottom = h - 1;     while bottom > 0, isBorder(cx, bottom) { bottom -= 1 }
var left = 0;           while left < w, isBorder(left, cy) { left += 1 }
var right = w - 1;      while right > 0, isBorder(right, cy) { right -= 1 }
let cw = right - left + 1, ch = bottom - top + 1
print("insets  T\(top) B\(h-1-bottom) L\(left) R\(w-1-right)  ->  \(cw)x\(ch)")

// Crop in pixel-native CGImage space (top-left origin) to dodge point/pixel DPI mismatch.
guard let cg = rep.cgImage?.cropping(to: CGRect(x: left, y: top, width: cw, height: ch)) else {
    FileHandle.standardError.write("crop failed\n".data(using: .utf8)!)
    exit(1)
}
let cropped = NSImage(cgImage: cg, size: NSSize(width: cw, height: ch))

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
// Rounded-rect clip so the grey corners become transparent.
let dst = NSRect(x: 0, y: 0, width: cw, height: ch)
NSBezierPath(roundedRect: dst, xRadius: radius, yRadius: radius).addClip()
cropped.draw(in: dst, from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (\(cw)x\(ch))")

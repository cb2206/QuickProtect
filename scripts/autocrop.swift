#!/usr/bin/env swift
// Trim transparent / soft-shadow margins from a window capture.
// Finds the tight bounding box of pixels with alpha >= threshold and crops to it.
// Usage: swift autocrop.swift <in.png> <out.png> [alphaThreshold 0..1]

import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: autocrop.swift <in.png> <out.png> [alpha]\n".data(using: .utf8)!)
    exit(1)
}
let alphaThresh = args.count > 3 ? Double(args[3])! : 0.6

guard let img = NSImage(contentsOfFile: args[1]),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    FileHandle.standardError.write("cannot load input\n".data(using: .utf8)!)
    exit(1)
}
let w = rep.pixelsWide, h = rep.pixelsHigh
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w {
        guard let c = rep.colorAt(x: x, y: y) else { continue }
        if Double(c.alphaComponent) >= alphaThresh {
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
guard maxX >= minX, maxY >= minY else {
    FileHandle.standardError.write("no opaque pixels found above threshold\n".data(using: .utf8)!)
    exit(1)
}
let cw = maxX - minX + 1, ch = maxY - minY + 1
print("content bbox: x\(minX) y\(minY) \(cw)x\(ch)  (orig \(w)x\(h))")

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cw, pixelsHigh: ch,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
// Draw cropped region. rep origin is top-left; NSImage draw is bottom-left.
let srcRect = NSRect(x: minX, y: h - maxY - 1, width: cw, height: ch)
rep.draw(in: NSRect(x: 0, y: 0, width: cw, height: ch), from: srcRect,
         operation: .copy, fraction: 1.0, respectFlipped: false, hints: nil)
NSGraphicsContext.restoreGraphicsState()

try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) (\(cw)x\(ch))")

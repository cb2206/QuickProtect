#!/usr/bin/env swift
// Gaussian-blur the video/stream area of a window capture while keeping sharp:
//   (a) the top/bottom UI toolbar bands, and
//   (b) the app's overlay labels (white text on dark pills — camera names,
//       timestamps, PTZ chips), which are auto-detected and excluded from blur.
// Preserves transparent rounded corners. Pixel-native (DPI-agnostic).
// Usage: swift blur_streams.swift <in.png> <out.png> [radius] [topSharpPx] [bottomSharpPx] [--debug]

import AppKit
import CoreImage

let a = CommandLine.arguments
let debug = a.contains("--debug")
guard a.count >= 3, let src = NSImage(contentsOfFile: a[1]),
      let probe = NSBitmapImageRep(data: src.tiffRepresentation!) else {
    FileHandle.standardError.write("usage: blur_streams.swift <in.png> <out.png> [radius] [topSharp] [bottomSharp] [--debug]\n".data(using: .utf8)!)
    exit(1)
}
let radius   = a.count > 3 && !a[3].hasPrefix("--") ? Double(a[3])! : 13
let topSharp = a.count > 4 && !a[4].hasPrefix("--") ? Int(Double(a[4])!) : 75
let botSharp = a.count > 5 && !a[5].hasPrefix("--") ? Int(Double(a[5])!) : 0
let W = probe.pixelsWide, H = probe.pixelsHigh

// Explicit keep-sharp rectangles (top-left origin px): --box x,y,w,h  (repeatable)
struct Box { let x0: Int, y0: Int, x1: Int, y1: Int }
var boxes: [Box] = []
for (i, t) in a.enumerated() where t == "--box" && i + 1 < a.count {
    let v = a[i + 1].split(separator: ",").map { Int($0)! }
    boxes.append(Box(x0: v[0], y0: v[1], x1: v[0] + v[2], y1: v[1] + v[3]))
}
@inline(__always) func inBox(_ x: Int, _ y: Int) -> Bool {
    for b in boxes where x >= b.x0 && x < b.x1 && y >= b.y0 && y < b.y1 { return true }
    return false
}

// --- Read input as tightly-packed RGBA8 (top-left origin) ---
let rgba = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                            isPlanar: false, colorSpaceName: .deviceRGB,
                            bytesPerRow: W * 4, bitsPerPixel: 32)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rgba)
src.draw(in: NSRect(x: 0, y: 0, width: W, height: H))
NSGraphicsContext.restoreGraphicsState()
let px = rgba.bitmapData!
@inline(__always) func lum(_ x: Int, _ y: Int) -> Double {
    let i = y * W * 4 + x * 4
    return (Double(px[i]) + Double(px[i+1]) + Double(px[i+2])) / 3.0
}
@inline(__always) func alpha(_ x: Int, _ y: Int) -> Double { Double(px[y * W * 4 + x * 4 + 3]) }

// --- Integral image of luminance for fast local-mean ---
var integ = [Double](repeating: 0, count: (W + 1) * (H + 1))
for y in 0..<H {
    var rowSum = 0.0
    for x in 0..<W {
        rowSum += lum(x, y)
        integ[(y + 1) * (W + 1) + (x + 1)] = integ[y * (W + 1) + (x + 1)] + rowSum
    }
}
@inline(__always) func boxMean(_ cx: Int, _ cy: Int, _ r: Int) -> Double {
    let x0 = max(0, cx - r), y0 = max(0, cy - r)
    let x1 = min(W, cx + r + 1), y1 = min(H, cy + r + 1)
    let s = integ[y1 * (W + 1) + x1] - integ[y0 * (W + 1) + x1]
          - integ[y1 * (W + 1) + x0] + integ[y0 * (W + 1) + x0]
    return s / Double((x1 - x0) * (y1 - y0))
}

// --- Detect label pixels: bright text sitting on a locally-dark pill ---
let win = 16          // local-mean window radius
var mark = [UInt8](repeating: 0, count: W * H)
for y in 0..<H {
    for x in 0..<W {
        if alpha(x, y) > 40 && lum(x, y) > 220 && boxMean(x, y, win) < 95 {
            mark[y * W + x] = 1
        }
    }
}
// Integral of marks.
var mInt = [Int](repeating: 0, count: (W + 1) * (H + 1))
for y in 0..<H {
    var rs = 0
    for x in 0..<W {
        rs += Int(mark[y * W + x])
        mInt[(y + 1) * (W + 1) + (x + 1)] = mInt[y * (W + 1) + (x + 1)] + rs
    }
}
@inline(__always) func markCount(_ cx: Int, _ cy: Int, _ r: Int) -> Int {
    let x0 = max(0, cx - r), y0 = max(0, cy - r)
    let x1 = min(W, cx + r + 1), y1 = min(H, cy + r + 1)
    return mInt[y1 * (W + 1) + x1] - mInt[y0 * (W + 1) + x1]
         - mInt[y1 * (W + 1) + x0] + mInt[y0 * (W + 1) + x0]
}
// Keep only DENSE, SIZEABLE clusters (real pills); reject bright video specks
// and small compact reflections. A real label is dense at small scale AND large
// at a bigger scale; a stray highlight is dense only in a tiny neighbourhood.
var core = [UInt8](repeating: 0, count: W * H)
for y in 0..<H { for x in 0..<W
    where markCount(x, y, 16) >= 60 && markCount(x, y, 40) >= 230 { core[y * W + x] = 1 } }
var cInt = [Int](repeating: 0, count: (W + 1) * (H + 1))
for y in 0..<H {
    var rs = 0
    for x in 0..<W {
        rs += Int(core[y * W + x])
        cInt[(y + 1) * (W + 1) + (x + 1)] = cInt[y * (W + 1) + (x + 1)] + rs
    }
}
let D = 18   // dilate the dense core to cover the whole pill
@inline(__always) func nearLabel(_ cx: Int, _ cy: Int) -> Bool {
    let x0 = max(0, cx - D), y0 = max(0, cy - D)
    let x1 = min(W, cx + D + 1), y1 = min(H, cy + D + 1)
    let s = cInt[y1 * (W + 1) + x1] - cInt[y0 * (W + 1) + x1]
          - cInt[y1 * (W + 1) + x0] + cInt[y0 * (W + 1) + x0]
    return s > 0
}

// --- Build mask (top-left origin): white = blur, black = keep sharp ---
let mrep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false,
                            isPlanar: false, colorSpaceName: .deviceWhite,
                            bytesPerRow: W, bitsPerPixel: 8)!
let mp = mrep.bitmapData!
for y in 0..<H {
    let inBand = (y >= topSharp) && (y < H - botSharp)   // video region
    for x in 0..<W {
        let sharp = !inBand || nearLabel(x, y) || inBox(x, y)
        mp[y * W + x] = sharp ? 0 : 255
    }
}

if debug {
    // Tint kept-sharp label pixels red over the original for inspection.
    for y in 0..<H { for x in 0..<W where (y >= topSharp && y < H - botSharp && (nearLabel(x, y) || inBox(x, y))) {
        let i = y * W * 4 + x * 4; px[i] = 255; px[i+1] = 0; px[i+2] = 0
    } }
    try! rgba.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
    print("wrote DEBUG \(a[2])"); exit(0)
}

// --- CoreImage: blur, blend via mask, restore corner transparency ---
let ci = CIImage(contentsOf: URL(fileURLWithPath: a[1]))!
let ext = ci.extent
let blurred = ci.clampedToExtent()
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
    .cropped(to: ext)
// Feather the mask so sharp<->blur transitions are soft gradients, not hard
// rectangles (no cut-out look around labels / kept-sharp boxes).
let feather = 11.0
let maskCI = CIImage(cgImage: mrep.cgImage!).clampedToExtent()
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather])
    .cropped(to: ext)
let mixed = blurred.applyingFilter("CIBlendWithMask", parameters: [
    kCIInputBackgroundImageKey: ci, kCIInputMaskImageKey: maskCI])
let clear = CIImage(color: CIColor.clear).cropped(to: ext)
let final = mixed.applyingFilter("CIBlendWithAlphaMask", parameters: [
    kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: ci])
let cgCtx = CIContext(options: [.workingColorSpace: NSNull()])
let outCG = cgCtx.createCGImage(final, from: ext)!
try! NSBitmapImageRep(cgImage: outCG).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: a[2]))
print("wrote \(a[2]) (\(W)x\(H))  radius \(radius) top \(topSharp) bot \(botSharp)")

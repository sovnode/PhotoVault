// Builds PhotoVault's app icon from the supplied artwork.
//
// Usage: swift Scripts/make-icon.swift
//   reads  Resources/Icon/AppIcon-source.jpg
//   writes Resources/Icon/AppIcon.png  (1024 × 1024, transparent outside the icon shape)
//          Resources/Icon/AppIcon.icns (every size macOS asks for)
//          build/icon-preview.png      (light and dark backgrounds, 256 → 16 px)
//
// Why it isn't a simple resize. The artwork arrives as a rounded tile with a
// silver rim, sitting on a light grey background with a soft drop shadow. Since
// macOS 26, an app icon that doesn't exactly fill Apple's rounded-square shape —
// anything protruding past it, or not covering it (round icons, say) — is shrunk
// onto a grey tile. So the tile is cut out by its own edge, scaled just enough
// that it covers the whole of Apple's shape, and masked to that shape. The
// script refuses to write anything if the result doesn't fill the shape exactly.

import Foundation
import ImageIO
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Resources/Icon/AppIcon-source.jpg")
let outPNG = root.appendingPathComponent("Resources/Icon/AppIcon.png")
let outICNS = root.appendingPathComponent("Resources/Icon/AppIcon.icns")
let previewURL = root.appendingPathComponent("build/icon-preview.png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("make-icon: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Load the artwork

guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("can't read \(source.path)") }
let W = art.width, H = art.height
var pixels = [UInt8](repeating: 0, count: W * H * 4)
CGContext(data: &pixels, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    .draw(art, in: CGRect(x: 0, y: 0, width: W, height: H))
/// Luminance, with y counted from the top, as the artwork is viewed.
func lum(_ x: Int, _ y: Int) -> Int {
    let i = (y * W + x) * 4
    return (Int(pixels[i]) * 3 + Int(pixels[i + 1]) * 6 + Int(pixels[i + 2])) / 10
}

// MARK: - Find the tile: flood the background and shadow in from the corners

// The background and its drop shadow change brightness smoothly; the tile's rim
// starts with a sharp edge. Flooding inward from the four corners through
// smoothly-changing pixels marks everything outside the tile and stops at the rim.
var outside = [Bool](repeating: false, count: W * H)
var stack: [(Int, Int)] = [(0, 0), (W - 1, 0), (0, H - 1), (W - 1, H - 1)]
for (x, y) in stack { outside[y * W + x] = true }
while let (x, y) = stack.popLast() {
    let here = lum(x, y)
    for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] {
        guard nx >= 0, ny >= 0, nx < W, ny < H, !outside[ny * W + nx] else { continue }
        let there = lum(nx, ny)
        // Down to 60: the shadow right under the rim is darker than the
        // background, and the flood has to reach the rim's outline through it.
        if there >= 60, abs(there - here) <= 6 {
            outside[ny * W + nx] = true
            stack.append((nx, ny))
        }
    }
}
var minX = W, maxX = 0, minY = H, maxY = 0, area = 0
for y in 0..<H { for x in 0..<W where !outside[y * W + x] {
    area += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
let tileW = maxX - minX + 1, tileH = maxY - minY + 1
print("tile found: x \(minX)…\(maxX), y \(minY)…\(maxY) (\(tileW) × \(tileH)), fills \(Int(Double(area) / Double(tileW * tileH) * 100))% of its box")
guard tileW > W / 2, tileH > H / 2, abs(tileW - tileH) < tileW / 20,
      Double(area) / Double(tileW * tileH) > 0.9 else {
    fail("the tile edge wasn't found cleanly (the flood leaked or stopped early) — refusing to guess")
}
func isTile(_ x: Double, _ y: Double) -> Bool {
    let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
    guard ix >= 0, iy >= 0, ix < W, iy < H else { return false }
    return !outside[iy * W + ix]
}

// MARK: - Apple's icon shape

// macOS app icon grid: a 1024-point canvas, the rounded square 824 across with
// 100 points of margin, continuous ("squircle") corners of radius 185.4 — the
// same curve SwiftUI draws for `.continuous`. Inset half a point so the
// anti-aliased edge never strays outside the shape.
let canvas: CGFloat = 1024
let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824).insetBy(dx: 0.5, dy: 0.5)
let shape = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: shapeRect).cgPath

// Where the artwork lands: the tile's box, centred on the shape and enlarged by
// `grow` points on every side until the tile covers every point of the shape.
let center = CGPoint(x: Double(minX + maxX + 1) / 2, y: Double(minY + maxY + 1) / 2)
func artRect(_ grow: CGFloat) -> CGRect { CGRect(x: 100, y: 100, width: 824, height: 824).insetBy(dx: -grow, dy: -grow) }
/// Canvas point (origin bottom-left, as CGContext draws) → artwork pixel
/// (origin top-left). The artwork is drawn upright, so y flips.
func toSource(_ p: CGPoint, _ rect: CGRect) -> (Double, Double) {
    let side = Double(max(tileW, tileH))
    let sx = (Double(p.x - rect.minX) / Double(rect.width) - 0.5) * side + Double(center.x)
    let sy = (0.5 - Double(p.y - rect.minY) / Double(rect.height)) * side + Double(center.y)
    return (sx, sy)
}
// Points just inside the shape's edge are the ones that matter.
var edge: [CGPoint] = []
for i in 0..<4000 {
    let t = Double(i) / 4000 * 2 * Double.pi
    let dir = CGPoint(x: cos(t), y: sin(t))
    var r: CGFloat = 0, step: CGFloat = 1
    while shape.contains(CGPoint(x: 512 + dir.x * (r + step), y: 512 + dir.y * (r + step))) { r += step }
    edge.append(CGPoint(x: 512 + dir.x * (r - 1), y: 512 + dir.y * (r - 1)))
}
var grow: CGFloat = 0
while !edge.allSatisfy({ let (x, y) = toSource($0, artRect(grow)); return isTile(x, y) }) {
    grow += 0.5
    if grow > 60 { fail("the artwork can't be scaled to cover the icon shape") }
}
print("artwork scaled to cover the icon shape: grown \(grow) pt per side (\(Int(824 + grow * 2)) pt across)")

// MARK: - Draw

func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let k = CGFloat(size) / canvas
    ctx.scaleBy(x: k, y: k)
    // CGContext's origin is bottom-left; the shape is symmetric, so only the
    // artwork needs flipping into place.
    ctx.addPath(shape)
    ctx.clip()
    let side = CGFloat(max(tileW, tileH))
    let crop = art.cropping(to: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))!
    ctx.draw(crop, in: artRect(grow))
    return ctx.makeImage()!
}

let icon = render(1024)

// Check before writing: fully transparent outside the shape, fully opaque inside it.
let data = icon.dataProvider!.data! as Data
let bpr = icon.bytesPerRow
var leaks = 0, holes = 0
let inner = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: shapeRect.insetBy(dx: 2, dy: 2)).cgPath
let outer = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: shapeRect.insetBy(dx: -2, dy: -2)).cgPath
for y in 0..<1024 { for x in 0..<1024 {
    let a = data[y * bpr + x * 4 + 3]
    let p = CGPoint(x: Double(x) + 0.5, y: Double(1023 - y) + 0.5)
    if !outer.contains(p) && a != 0 { leaks += 1 }
    if inner.contains(p) && a != 255 { holes += 1 }
} }
guard leaks == 0, holes == 0 else { fail("result doesn't match the icon shape: \(leaks) pixels outside it, \(holes) gaps inside it") }
print("checked: nothing outside Apple's icon shape, no gaps inside it")

// MARK: - Write the PNG, the .icns and the preview

func writePNG(_ image: CGImage, _ url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fail("couldn't write \(url.path)") }
}
writePNG(icon, outPNG)

// Intermediate files stay in the project's git-ignored build folder.
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for points in [16, 32, 128, 256, 512] {
    writePNG(render(points), iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(points * 2), iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outICNS.path]
try iconutil.run(); iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

let sizes = [256, 128, 64, 32, 16]
let pw = 40 + sizes.reduce(0) { $0 + $1 + 40 }, ph = 2 * (256 + 80)
let preview = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for (band, colour) in [(0, CGColor(gray: 0.12, alpha: 1)), (1, CGColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1))] {
    preview.setFillColor(colour)
    preview.fill(CGRect(x: 0, y: band * (256 + 80), width: pw, height: 256 + 80))
    var x = 40
    for s in sizes {
        preview.draw(render(s), in: CGRect(x: x, y: band * (256 + 80) + 40 + (256 - s) / 2, width: s, height: s))
        x += s + 40
    }
}
writePNG(preview.makeImage()!, previewURL)
print("wrote \(outPNG.path.replacingOccurrences(of: root.path + "/", with: "")), \(outICNS.path.replacingOccurrences(of: root.path + "/", with: "")) and \(previewURL.path.replacingOccurrences(of: root.path + "/", with: ""))")

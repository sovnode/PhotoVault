// Draws PhotoVault Installer's icon: a generic installer — an open box with an
// arrow going into it — rather than PhotoVault's own icon, since the installer
// isn't PhotoVault. Drawn here, so it's reproducible and holds no third-party
// artwork (SF Symbols' licence doesn't allow them in app icons).
//
// Usage: swift Scripts/make-installer-icon.swift
//   writes Resources/Icon/InstallerIcon.png  (1024 × 1024)
//          Resources/Icon/InstallerIcon.icns (every size macOS asks for)
//
// Like the app icon, it fills Apple's rounded-square shape exactly (see
// make-icon.swift), so macOS shows it as drawn rather than shrunk onto a tile.

import Foundation
import ImageIO
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let outPNG = root.appendingPathComponent("Resources/Icon/InstallerIcon.png")
let outICNS = root.appendingPathComponent("Resources/Icon/InstallerIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The icon at `size` pixels, drawn on Apple's 1024-point grid.
func render(_ size: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    ctx.setShouldAntialias(true)

    // The tile: Apple's rounded square, a cool slate-blue gradient.
    let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: tileRect).cgPath
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [color(0x5C7FB8), color(0x2E4673)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // CoreGraphics counts y from the bottom.
    let white = color(0xFFFFFF), shade = color(0xDCE5F2), inside = color(0x1E2F4F, 0.55)

    // The box's open top, seen a little from above: the dark inside.
    let opening = CGMutablePath()
    opening.move(to: CGPoint(x: 300, y: 520))
    opening.addLine(to: CGPoint(x: 724, y: 520))
    opening.addLine(to: CGPoint(x: 690, y: 566))
    opening.addLine(to: CGPoint(x: 334, y: 566))
    opening.closeSubpath()
    ctx.addPath(opening)
    ctx.setFillColor(inside)
    ctx.fillPath()

    // The arrow, going down into the box.
    let arrow = CGMutablePath()
    arrow.move(to: CGPoint(x: 466, y: 840))
    arrow.addLine(to: CGPoint(x: 558, y: 840))
    arrow.addLine(to: CGPoint(x: 558, y: 666))
    arrow.addLine(to: CGPoint(x: 630, y: 666))
    arrow.addLine(to: CGPoint(x: 512, y: 548))
    arrow.addLine(to: CGPoint(x: 394, y: 666))
    arrow.addLine(to: CGPoint(x: 466, y: 666))
    arrow.closeSubpath()
    ctx.addPath(arrow)
    ctx.setFillColor(white)
    ctx.fillPath()

    // The box's front.
    let body = RoundedRectangle(cornerRadius: 22, style: .continuous)
        .path(in: CGRect(x: 300, y: 230, width: 424, height: 300)).cgPath
    ctx.addPath(body)
    ctx.setFillColor(white)
    ctx.fillPath()
    // A seam across it, so it reads as a box rather than a card.
    ctx.setFillColor(shade)
    ctx.fill(CGRect(x: 300, y: 400, width: 424, height: 16))

    // The flaps, hinged on the opening's sides and folded out.
    for side in [CGFloat(-1), 1] {
        func x(_ offset: CGFloat) -> CGFloat { 512 + side * offset }
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: x(212), y: 520))
        flap.addLine(to: CGPoint(x: x(178), y: 566))
        flap.addLine(to: CGPoint(x: x(268), y: 640))
        flap.addLine(to: CGPoint(x: x(318), y: 590))
        flap.closeSubpath()
        ctx.addPath(flap)
        ctx.setFillColor(shade)
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("make-installer-icon: can't write \(url.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

writePNG(render(1024), outPNG)

let iconset = root.appendingPathComponent("build/InstallerIcon.iconset")
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
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(1) }
print("wrote \(outPNG.path) and \(outICNS.path)")

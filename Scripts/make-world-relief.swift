// Builds Resources/World Relief.pvrelief, the terrain shading on PhotoVault's
// map, from Natural Earth's shaded relief (SR_HR, public domain,
// naturalearthdata.com). Run once when the shading should change; the app
// only ever reads the result, and never downloads anything.
//
// Usage: swift Scripts/make-world-relief.swift <SR_HR.tif> [output] [quality] [heic|jpeg]
//
// The source is the whole world at a sixtieth of a degree a pixel (about
// 1.9 km), one grey value each, lit from the north-west: 206 where the ground
// is flat and over the sea, darker on slopes in shadow, lighter on those in
// the sun. It's reprojected to Web Mercator as 256-pixel tiles down to zoom
// 6 (closer zooms stretch those), each level above made from the one below,
// and re-centred so flat is 128: the app blends it over the land in "soft
// light", which leaves 128 as it is. Tiles with nothing but flat ground or
// sea aren't stored. Each tile is a HEIC image at quality 0.5: 7.9 MB in all.
// JPEG at the same size showed its 8×8 blocks once the map stretched a tile
// close in; HEIC has none.

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift Scripts/make-world-relief.swift <SR_HR.tif> [output] [quality]\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: args.count > 2 ? args[2] : "Resources/World Relief.pvrelief")
let quality = args.count > 3 ? Double(args[3]) ?? 0.5 : 0.5
let maxZoom = 6
let side = 256
let flatSource = 206.0
/// How far from flat a value is moved, per step in the source: the darkest
/// shadow (about 56) comes out near 0.
let gain = 128.0 / 150.0

// MARK: - The source, in memory

let source: (w: Int, h: Int, pixels: [UInt8]) = {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("can't read \(args[1])") }
    let w = image.width, h = image.height
    var pixels = [UInt8](repeating: 0, count: w * h)
    pixels.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, pixels)
}()

/// The source at a longitude and latitude, between pixels.
func sample(lon: Double, lat: Double) -> Double {
    let u = (lon + 180) / 360 * Double(source.w) - 0.5
    let v = (90 - lat) / 180 * Double(source.h) - 0.5
    let x0 = Int(u.rounded(.down)), y0 = Int(v.rounded(.down))
    let fx = u - Double(x0), fy = v - Double(y0)
    func at(_ x: Int, _ y: Int) -> Double {
        let xx = (x % source.w + source.w) % source.w, yy = min(max(y, 0), source.h - 1)
        return Double(source.pixels[yy * source.w + xx])
    }
    let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
    let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
    return top * (1 - fy) + bottom * fy
}

func neutral(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (128 + (v - flatSource) * gain).rounded()))) }

/// True for a tile with no slope worth showing: all within a step or two of flat.
func isFlat(_ t: [UInt8]) -> Bool { t.allSatisfy { abs(Int($0) - 128) <= 2 } }

struct Key: Hashable, Comparable {
    let z, x, y: Int
    static func < (a: Key, b: Key) -> Bool { (a.z, a.x, a.y) < (b.z, b.x, b.y) }
}

// MARK: - Zoom 6, reprojected

var tiles: [Key: [UInt8]] = [:]
let n6 = 1 << maxZoom
for ty in 0..<n6 {
    // A row of tiles shares its latitudes.
    let lats = (0..<side).map { j -> Double in
        let wy = (Double(ty) + (Double(j) + 0.5) / Double(side)) / Double(n6)
        return atan(sinh(.pi * (1 - 2 * wy))) * 180 / .pi
    }
    for tx in 0..<n6 {
        var t = [UInt8](repeating: 128, count: side * side)
        for j in 0..<side {
            for i in 0..<side {
                let lon = (Double(tx) + (Double(i) + 0.5) / Double(side)) / Double(n6) * 360 - 180
                t[j * side + i] = neutral(sample(lon: lon, lat: lats[j]))
            }
        }
        if !isFlat(t) { tiles[Key(z: maxZoom, x: tx, y: ty)] = t }
    }
}

// MARK: - Each zoom out, from the four tiles beneath

for z in stride(from: maxZoom - 1, through: 0, by: -1) {
    let n = 1 << z
    for ty in 0..<n {
        for tx in 0..<n {
            let kids = (0..<4).map { tiles[Key(z: z + 1, x: tx * 2 + $0 % 2, y: ty * 2 + $0 / 2)] }
            guard kids.contains(where: { $0 != nil }) else { continue }
            var t = [UInt8](repeating: 128, count: side * side)
            for j in 0..<side {
                for i in 0..<side {
                    let quarter = (j >= side / 2 ? 2 : 0) + (i >= side / 2 ? 1 : 0)
                    guard let kid = kids[quarter] else { continue }
                    let ki = (i % (side / 2)) * 2, kj = (j % (side / 2)) * 2
                    let sum = Int(kid[kj * side + ki]) + Int(kid[kj * side + ki + 1])
                        + Int(kid[(kj + 1) * side + ki]) + Int(kid[(kj + 1) * side + ki + 1])
                    t[j * side + i] = UInt8((sum + 2) / 4)
                }
            }
            if !isFlat(t) { tiles[Key(z: z, x: tx, y: ty)] = t }
        }
    }
}

// MARK: - Writing

let format = args.count > 4 ? args[4] : "heic"
let formatType = format == "jpeg" ? UTType.jpeg : UTType.heic

func encode(_ t: [UInt8]) -> Data {
    let image: CGImage = t.withUnsafeBufferPointer { buf in
        let provider = CGDataProvider(data: Data(buffer: buf) as CFData)!
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    // HEIC takes colour only: the grey goes in as RGB, whose colour channels,
    // all flat, cost next to nothing.
    var encoded = image
    if formatType == .heic {
        let rgb = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        rgb.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        encoded = rgb.makeImage()!
    }
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, formatType.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, encoded, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest), out.length > 0 else { fatalError("couldn't encode a tile as \(format)") }
    return out as Data
}

var out = Data()
func u8(_ v: Int) { out.append(UInt8(v)) }
func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { out.append(contentsOf: $0) } }
func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }

let version = (try? String(contentsOf: URL(fileURLWithPath: args[1]).deletingPathExtension().appendingPathExtension("VERSION.txt"),
                           encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
let credit = Array("Natural Earth shaded relief \(version) (public domain), naturalearthdata.com".utf8)
let keys = tiles.keys.sorted()
let blobs = keys.map { encode(tiles[$0]!) }

out.append(contentsOf: Array("PVRELF01".utf8))
u16(credit.count); out.append(contentsOf: credit)
u8(maxZoom)
u32(keys.count)
var offset = 0
for (key, blob) in zip(keys, blobs) {
    u8(key.z); u16(key.x); u16(key.y); u32(offset); u32(blob.count)
    offset += blob.count
}
for blob in blobs { out.append(blob) }
try out.write(to: output)

for z in 0...maxZoom {
    let level = zip(keys, blobs).filter { $0.0.z == z }
    print("zoom \(z): \(level.count) tiles, \(level.reduce(0) { $0 + $1.1.count } / 1024) KB")
}
print("wrote \(output.path): \(out.count / 1024) KB, \(format) at quality \(quality)")

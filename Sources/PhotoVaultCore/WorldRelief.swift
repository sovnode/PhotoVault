import Foundation
import CoreGraphics
import ImageIO

/// Terrain shading for the map: Natural Earth's shaded relief (public
/// domain), made into `Resources/World Relief.pvrelief` by
/// `Scripts/make-world-relief.swift` — greyscale tiles down to zoom 6, 128
/// where the ground is flat, darker and lighter on slopes away from and
/// towards the light. Only tiles with some slope are kept. Comes with the
/// app; nothing is ever downloaded.
public final class WorldRelief: @unchecked Sendable {
    public let credit: String
    /// The most detailed zoom stored; closer in, its tiles are stretched.
    public let maxZoom: Int
    private let bytes: Data
    private let index: [Int64: Range<Int>]

    public static let bundled: WorldRelief? = {
        guard let url = Bundle.main.url(forResource: "World Relief", withExtension: "pvrelief") else { return nil }
        return try? WorldRelief(contentsOf: url)
    }()

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        let b = [UInt8](data)
        var o = 0
        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard o + n <= b.count else { throw VaultError.packCorrupt("terrain shading ends early") }
            defer { o += n }
            return b[o..<o + n]
        }
        func uint(_ n: Int) throws -> Int {
            let s = try take(n)
            return (0..<n).reduce(0) { $0 | Int(s[s.startIndex + $1]) << (8 * $1) }
        }
        guard b.count >= 8, String(decoding: b[0..<8], as: UTF8.self) == "PVRELF01" else {
            throw VaultError.packCorrupt("not PhotoVault terrain shading")
        }
        o = 8
        credit = String(decoding: try take(try uint(2)), as: UTF8.self)
        maxZoom = try uint(1)
        let count = try uint(4)
        var entries: [(Int64, Int, Int)] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let z = try uint(1), x = try uint(2), y = try uint(2), offset = try uint(4), length = try uint(4)
            entries.append((Self.key(z, x, y), offset, length))
        }
        let start = o
        var index: [Int64: Range<Int>] = [:]
        for (key, offset, length) in entries {
            guard start + offset + length <= b.count else { throw VaultError.packCorrupt("terrain shading ends early") }
            index[key] = (start + offset)..<(start + offset + length)
        }
        self.index = index
        bytes = data
    }

    private static func key(_ z: Int, _ x: Int, _ y: Int) -> Int64 { Int64(z) << 40 | Int64(x) << 20 | Int64(y) }

    public var tileCount: Int { index.count }

    /// A stored tile, decoded; nil where the ground is flat (or it isn't stored).
    public func image(z: Int, x: Int, y: Int) -> CGImage? {
        guard let range = index[Self.key(z, x, y)],
              let src = CGImageSourceCreateWithData(bytes.subdata(in: range) as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    public static let side = 256

    /// The last few tiles decoded, as grey bytes: neighbouring map tiles
    /// close in all stretch the same one.
    private var decoded: [(Int64, [UInt8])] = []
    private let lock = NSLock()

    /// `shading(z:x:y:)` as grey bytes, 256 a row, top row first.
    public func grayShading(z: Int, x: Int, y: Int) -> ([UInt8], CGRect)? {
        let up = max(0, z - maxZoom)
        let sz = z - up, sx = x >> up, sy = y >> up
        let key = Self.key(sz, sx, sy)
        let n = Double(1 << sz)
        let area = CGRect(x: Double(sx) / n, y: Double(sy) / n, width: 1 / n, height: 1 / n)
        if let hit = lock.withLock({ decoded.first { $0.0 == key }?.1 }) { return (hit, area) }
        guard let image = image(z: sz, x: sx, y: sy) else { return nil }
        let side = Self.side
        var bytes = [UInt8](repeating: 128, count: side * side)
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        lock.withLock {
            decoded.insert((key, bytes), at: 0)
            if decoded.count > 16 { decoded.removeLast() }
        }
        return (bytes, area)
    }

    /// The shading for map tile (z, x, y), and the part of the world it
    /// covers: the tile itself, or past `maxZoom` the stored tile above it,
    /// which covers more. Nil where the ground is flat.
    public func shading(z: Int, x: Int, y: Int) -> (CGImage, CGRect)? {
        let up = max(0, z - maxZoom)
        let sz = z - up, sx = x >> up, sy = y >> up
        guard let image = image(z: sz, x: sx, y: sy) else { return nil }
        let n = Double(1 << sz)
        return (image, CGRect(x: Double(sx) / n, y: Double(sy) / n, width: 1 / n, height: 1 / n))
    }
}

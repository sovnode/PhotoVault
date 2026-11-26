import Foundation
import CoreGraphics

/// The map's projection: Web Mercator, as a fraction of the world's width.
/// x runs from the antimeridian eastward, 0 to 1; y from the north edge
/// down, 0 to 1. At zoom z the world is 256 × 2^z points across.
public enum WebMercator {
    public static let maxLatitude = 85.05112878

    public static func project(_ p: GeoPoint) -> CGPoint {
        let phi = max(-maxLatitude, min(maxLatitude, p.latitude)) * .pi / 180
        let x = (p.longitude + 180) / 360
        let y = 0.5 - log(tan(.pi / 4 + phi / 2)) / (2 * .pi)
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    public static func unproject(_ w: CGPoint) -> GeoPoint {
        let lon = Double(w.x) * 360 - 180
        let lat = atan(sinh(.pi * (1 - 2 * Double(w.y)))) * 180 / .pi
        return GeoPoint(latitude: lat, longitude: lon)
    }

    /// Points across the whole world at `zoom`.
    public static func worldSize(atZoom zoom: Double) -> Double { 256 * pow(2, zoom) }
}

/// The world outline the map is drawn on: land, lakes, borders and place
/// names from Natural Earth (public domain), made into
/// `Resources/World Map.pvmap` by `Scripts/make-world-map.swift`. Comes
/// with the app; nothing is ever downloaded to draw a map.
public final class WorldMap: @unchecked Sendable {
    public enum Kind: UInt8, Sendable {
        case land = 1, lakes = 2, countryBorders = 3, stateBorders = 4
    }

    /// Part of a shape, in world coordinates, with its box.
    public struct Piece: @unchecked Sendable {
        public let bounds: CGRect
        public let path: CGPath
    }

    public struct Level: Sendable {
        public let fromZoom: Int
        public let pieces: [Piece]
    }

    public struct Layer: Sendable {
        public let kind: Kind
        public let minZoom: Int
        public let levels: [Level]

        /// The detail to draw at `zoom`; nil below the zoom the layer starts at.
        public func level(atZoom zoom: Int) -> Level? {
            guard zoom >= minZoom else { return nil }
            return levels.last { $0.fromZoom <= zoom } ?? levels.first
        }
    }

    public struct Place: Sendable {
        public let point: CGPoint
        /// The zoom its name is shown from.
        public let minZoom: Double
        public let rank: Int
        public let name: String
    }

    public let credit: String
    public let layers: [Layer]
    /// Most important first.
    public let places: [Place]

    public func layer(_ kind: Kind) -> Layer? { layers.first { $0.kind == kind } }

    /// The copy in the app.
    public static let bundled: WorldMap? = {
        guard let url = Bundle.main.url(forResource: "World Map", withExtension: "pvmap") else { return nil }
        return try? WorldMap(contentsOf: url)
    }()

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        var r = Reader(bytes: [UInt8](data))
        guard r.bytes.count >= 8, String(decoding: r.bytes[0..<8], as: UTF8.self) == "PVMAP002" else {
            throw VaultError.packCorrupt("not a PhotoVault world map")
        }
        r.offset = 8
        credit = try r.string()
        var layers: [Layer] = []
        for _ in 0..<(try r.u32()) {
            let kind = Kind(rawValue: try r.u8())
            let minZoom = Int(try r.u8())
            var levels: [Level] = []
            for _ in 0..<(try r.u8()) {
                let fromZoom = Int(try r.u8())
                var pieces: [Piece] = []
                let count = try r.u32()
                pieces.reserveCapacity(count)
                for _ in 0..<count {
                    let x0 = Double(try r.f32()), y0 = Double(try r.f32())
                    let x1 = Double(try r.f32()), y1 = Double(try r.f32())
                    let w = (x1 - x0) / 65535, h = (y1 - y0) / 65535
                    let path = CGMutablePath()
                    for _ in 0..<(try r.u32()) {
                        let n = try r.u32()
                        var points: [CGPoint] = []
                        points.reserveCapacity(n)
                        for _ in 0..<n {
                            points.append(CGPoint(x: x0 + Double(try r.u16()) * w, y: y0 + Double(try r.u16()) * h))
                        }
                        path.addLines(between: points)
                        if kind == .land || kind == .lakes { path.closeSubpath() }
                    }
                    pieces.append(Piece(bounds: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), path: path))
                }
                levels.append(Level(fromZoom: fromZoom, pieces: pieces))
            }
            if let kind { layers.append(Layer(kind: kind, minZoom: minZoom, levels: levels)) }
        }
        self.layers = layers
        var places: [Place] = []
        for _ in 0..<(try r.u32()) {
            let x = Double(try r.f32()), y = Double(try r.f32())
            let minZoom = Double(try r.f32())
            let rank = Int(try r.u8())
            places.append(Place(point: CGPoint(x: x, y: y), minZoom: minZoom, rank: rank, name: try r.string()))
        }
        self.places = places
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard offset + n <= bytes.count else { throw VaultError.packCorrupt("world map ends early") }
            defer { offset += n }
            return bytes[offset..<offset + n]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func u16() throws -> UInt16 {
            let b = try take(2)
            return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
        }
        mutating func u32() throws -> Int {
            let b = try take(4)
            return (0..<4).reduce(0) { $0 | Int(b[b.startIndex + $1]) << (8 * $1) }
        }
        mutating func f32() throws -> Float { Float(bitPattern: UInt32(try u32())) }
        mutating func string() throws -> String { String(decoding: try take(Int(try u16())), as: UTF8.self) }
    }
}

/// Draws the world outline as square tiles, for the map to lay side by
/// side. Pure Core Graphics, safe to run off the main thread.
public enum MapTileRenderer {
    public struct Style: Sendable, Hashable {
        public var water: CGColor
        public var land: CGColor
        public var countryBorder: CGColor
        public var stateBorder: CGColor
        /// How strongly the terrain shading shows, 0 to 1.
        public var relief: Double
        /// Shadows only, darkening the land — what shows on pale land; or
        /// soft light, shadows and sunlit slopes both — what shows on dark.
        public var reliefDarkens: Bool

        public init(water: CGColor, land: CGColor, countryBorder: CGColor, stateBorder: CGColor,
                    relief: Double = 0.5, reliefDarkens: Bool = true) {
            self.water = water
            self.land = land
            self.countryBorder = countryBorder
            self.stateBorder = stateBorder
            self.relief = relief
            self.reliefDarkens = reliefDarkens
        }

        public static let light = Style(water: CGColor(srgbRed: 0.80, green: 0.87, blue: 0.93, alpha: 1),
                                        land: CGColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1),
                                        countryBorder: CGColor(srgbRed: 0.55, green: 0.52, blue: 0.58, alpha: 1),
                                        stateBorder: CGColor(srgbRed: 0.72, green: 0.70, blue: 0.74, alpha: 1),
                                        relief: 0.42, reliefDarkens: true)
        public static let dark = Style(water: CGColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 1),
                                       land: CGColor(srgbRed: 0.20, green: 0.20, blue: 0.21, alpha: 1),
                                       countryBorder: CGColor(srgbRed: 0.50, green: 0.49, blue: 0.53, alpha: 1),
                                       stateBorder: CGColor(srgbRed: 0.35, green: 0.35, blue: 0.38, alpha: 1),
                                       relief: 0.8, reliefDarkens: false)
    }

    /// Tile (x, y) of the 2^z × 2^z grid at zoom z, `pixels` square.
    public static func tile(_ map: WorldMap, relief: WorldRelief? = nil, z: Int, x: Int, y: Int, pixels: Int,
                            style: Style) -> CGImage? {
        guard pixels > 0,
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(style.water)
        ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))

        let n = Double(1 << z)
        let tileRect = CGRect(x: Double(x) / n, y: Double(y) / n, width: 1 / n, height: 1 / n)
        let scale = Double(pixels) * n
        /// Drawing in world coordinates. World y runs down; the bitmap's runs up.
        func inWorld(_ draw: () -> Void) {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(pixels))
            ctx.scaleBy(x: scale, y: -scale)
            ctx.translateBy(x: -tileRect.minX, y: -tileRect.minY)
            draw()
            ctx.restoreGState()
        }
        // Pieces overlap their neighbours a little (see the script); a touch
        // more of the box keeps a line's width from being cut at the edge.
        let lookup = tileRect.insetBy(dx: -2 / scale, dy: -2 / scale)

        func fill(_ kind: WorldMap.Kind, _ color: CGColor) {
            guard let level = map.layer(kind)?.level(atZoom: z) else { return }
            ctx.setFillColor(color)
            for piece in level.pieces where piece.bounds.intersects(lookup) {
                ctx.addPath(piece.path)
                ctx.fillPath(using: .evenOdd)
            }
        }
        func stroke(_ kind: WorldMap.Kind, _ color: CGColor, width: Double, dash: [CGFloat] = []) {
            guard let level = map.layer(kind)?.level(atZoom: z) else { return }
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width / scale)
            ctx.setLineJoin(.round)
            ctx.setLineDash(phase: 0, lengths: dash.map { $0 / scale })
            for piece in level.pieces where piece.bounds.intersects(lookup) {
                ctx.addPath(piece.path)
            }
            ctx.strokePath()
        }
        // Widths in pixels, so twice as many on a Retina tile of twice the size.
        let px = Double(pixels) / 256
        inWorld { fill(.land, style.land) }
        // Terrain, over the land: soft light leaves flat ground (and the sea,
        // which is flat in the shading) as it was. Past the most detailed
        // shading, the tile above is stretched smoothly over this one.
        if let relief, style.relief > 0,
           let shade = shading(relief, z: z, x: x, y: y, tile: tileRect, pixels: pixels, darkens: style.reliefDarkens) {
            // Past zoom 9 the data has no more detail to give: it eases off,
            // a tone saying "in the hills" rather than a picture of them.
            let fade = z <= 9 ? 1 : max(0.45, 1 - Double(z - 9) * 0.15)
            ctx.saveGState()
            ctx.setBlendMode(style.reliefDarkens ? .multiply : .softLight)
            ctx.setAlpha(style.relief * fade)
            ctx.draw(shade, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            ctx.restoreGState()
        }
        inWorld {
            fill(.lakes, style.water)
            stroke(.stateBorders, style.stateBorder, width: 0.7 * px, dash: [3 * px, 2 * px])
            stroke(.countryBorders, style.countryBorder, width: 1.0 * px)
        }
        return ctx.makeImage()
    }

    /// The terrain for one tile, as a grey layer the tile's size: 128 where
    /// the ground is flat — or, for `darkens`, white, with only the shadows.
    /// Resampled here with a cubic curve rather than by Core Graphics, whose
    /// enlarging holds each old pixel flat for half its width: stretched over
    /// a close-in tile, that showed as soft squares.
    static func shading(_ relief: WorldRelief, z: Int, x: Int, y: Int, tile: CGRect, pixels: Int, darkens: Bool) -> CGImage? {
        guard let (source, area) = relief.grayShading(z: z, x: x, y: y) else { return nil }
        let side = WorldRelief.side
        // Where each tile pixel falls in the stored tile, in its pixels.
        let perPixel = Double(pixels) * area.width / (tile.width * Double(side))
        let u0 = (tile.minX - area.minX) / area.width * Double(side), v0 = (tile.minY - area.minY) / area.height * Double(side)
        // Interpolating when close to the stored detail; smoothing, which
        // never rings, when stretched far past it.
        let smooth = perPixel > 3
        func weights(_ t: Double) -> (Double, Double, Double, Double) {
            if smooth {   // cubic B-spline
                let t2 = t * t, t3 = t2 * t
                return ((1 - t) * (1 - t) * (1 - t) / 6, (3 * t3 - 6 * t2 + 4) / 6, (-3 * t3 + 3 * t2 + 3 * t + 1) / 6, t3 / 6)
            }
            // Catmull–Rom
            let t2 = t * t, t3 = t2 * t
            return ((-t3 + 2 * t2 - t) / 2, (3 * t3 - 5 * t2 + 2) / 2, (-3 * t3 + 4 * t2 + t) / 2, (t3 - t2) / 2)
        }
        func clamp(_ i: Int) -> Int { min(max(i, 0), side - 1) }
        // Horizontally first, for each stored row the tile needs...
        let firstRow = Int((v0 + 0.5 / perPixel - 0.5).rounded(.down)) - 1
        let lastRow = Int((v0 + (Double(pixels) - 0.5) / perPixel - 0.5).rounded(.down)) + 2
        let rows = lastRow - firstRow + 1
        var across = [Double](repeating: 128, count: rows * pixels)
        var columns: [(Int, (Double, Double, Double, Double))] = []
        columns.reserveCapacity(pixels)
        for i in 0..<pixels {
            let u = u0 + (Double(i) + 0.5) / perPixel - 0.5
            let base = Int(u.rounded(.down))
            columns.append((base, weights(u - Double(base))))
        }
        source.withUnsafeBufferPointer { src in
            for r in 0..<rows {
                let row = clamp(firstRow + r) * side
                for (i, (base, w)) in columns.enumerated() {
                    across[r * pixels + i] = w.0 * Double(src[row + clamp(base - 1)]) + w.1 * Double(src[row + clamp(base)])
                        + w.2 * Double(src[row + clamp(base + 1)]) + w.3 * Double(src[row + clamp(base + 2)])
                }
            }
        }
        // ...then down the columns.
        var out = [UInt8](repeating: 128, count: pixels * pixels)
        for j in 0..<pixels {
            let v = v0 + (Double(j) + 0.5) / perPixel - 0.5
            let base = Int(v.rounded(.down))
            let w = weights(v - Double(base))
            let r = base - 1 - firstRow
            for i in 0..<pixels {
                var value = w.0 * across[r * pixels + i] + w.1 * across[(r + 1) * pixels + i]
                    + w.2 * across[(r + 2) * pixels + i] + w.3 * across[(r + 3) * pixels + i]
                // Shadows only: flat (128) and the sunlit side become white.
                if darkens { value *= 2 }
                out[j * pixels + i] = UInt8(max(0, min(255, value.rounded())))
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: pixels,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Where the map is looking: its centre, in world coordinates, and its zoom
/// (the world is 256 × 2^zoom points across). Each view keeps its own.
public struct MapCamera: Sendable, Equatable {
    public static let maxZoom = 18.0

    public var center: CGPoint
    public var zoom: Double

    public init(center: CGPoint, zoom: Double) {
        self.center = center
        self.zoom = zoom
    }

    /// As kept in the catalog: "x y zoom".
    public var storageValue: String { "\(Double(center.x)) \(Double(center.y)) \(zoom)" }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: " ").compactMap { Double($0) }
        guard parts.count == 3, parts.allSatisfy(\.isFinite) else { return nil }
        self.init(center: CGPoint(x: parts[0], y: parts[1]), zoom: parts[2])
    }

    private var scale: Double { WebMercator.worldSize(atZoom: zoom) }

    /// The part of the world a view `size` points large shows.
    public func worldRect(in size: CGSize) -> CGRect {
        let w = Double(size.width) / scale, h = Double(size.height) / scale
        return CGRect(x: Double(center.x) - w / 2, y: Double(center.y) - h / 2, width: w, height: h)
    }

    /// From world coordinates to the view's, top-left origin.
    public func screenPoint(_ world: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: (Double(world.x) - Double(center.x)) * scale + Double(size.width) / 2,
                y: (Double(world.y) - Double(center.y)) * scale + Double(size.height) / 2)
    }

    public func worldPoint(_ screen: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: Double(center.x) + (Double(screen.x) - Double(size.width) / 2) / scale,
                y: Double(center.y) + (Double(screen.y) - Double(size.height) / 2) / scale)
    }

    /// The least zoom for a view `size` points large: the world as wide as it.
    public static func minZoom(for size: CGSize) -> Double {
        max(0, log2(max(1, Double(size.width)) / 256))
    }

    /// Zoomed in (or out, for a negative `delta`) by `delta` levels, keeping
    /// the world point under `anchor` where it is on screen.
    public func zoomed(by delta: Double, around anchor: CGPoint, in size: CGSize) -> MapCamera {
        let fixed = worldPoint(anchor, in: size)
        var c = self
        c.zoom = min(Self.maxZoom, max(Self.minZoom(for: size), zoom + delta))
        let moved = c.screenPoint(fixed, in: size)
        c.center.x += (moved.x - anchor.x) / c.scale
        c.center.y += (moved.y - anchor.y) / c.scale
        return c.clamped(in: size)
    }

    /// Moved so the picture follows a drag of `by` points.
    public func panned(by d: CGSize, in size: CGSize) -> MapCamera {
        var c = self
        c.center.x -= d.width / scale
        c.center.y -= d.height / scale
        return c.clamped(in: size)
    }

    /// Kept to the world: zoomed in at least enough to fill the view's width,
    /// and the edges of the world never pulled past the view's.
    public func clamped(in size: CGSize) -> MapCamera {
        var c = self
        c.zoom = min(Self.maxZoom, max(Self.minZoom(for: size), zoom))
        let r = c.worldRect(in: size)
        func fit(_ v: Double, _ half: Double) -> Double { half >= 0.5 ? 0.5 : min(max(v, half), 1 - half) }
        c.center = CGPoint(x: fit(Double(c.center.x), Double(r.width) / 2), y: fit(Double(c.center.y), Double(r.height) / 2))
        return c
    }

    /// A camera showing all of `rect` in a view `size` points large, with a
    /// margin, and no closer than `closest` — a single photo, or a few at one
    /// spot, is shown in its neighbourhood rather than at the closest zoom.
    public static func fitting(_ rect: CGRect, in size: CGSize, margin: Double = 60, closest: Double = 14) -> MapCamera {
        let w = max(1, Double(size.width) - 2 * margin), h = max(1, Double(size.height) - 2 * margin)
        let zx = rect.width > 0 ? log2(w / (Double(rect.width) * 256)) : closest
        let zy = rect.height > 0 ? log2(h / (Double(rect.height) * 256)) : closest
        return MapCamera(center: CGPoint(x: rect.midX, y: rect.midY), zoom: min(closest, zx, zy)).clamped(in: size)
    }
}

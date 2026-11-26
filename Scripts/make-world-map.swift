// Builds Resources/World Map.pvmap, the world outline PhotoVault's map is
// drawn on, from Natural Earth's shapefiles (public domain,
// naturalearthdata.com). Run once when the outline should change; the app
// only ever reads the result, and never downloads anything.
//
// Usage: swift Scripts/make-world-map.swift <folder> [output]
//
// <folder> holds the unzipped layers, each in a folder of its own name:
//   ne_50m_land, ne_10m_land, ne_50m_lakes,
//   ne_50m_admin_0_boundary_lines_land, ne_10m_admin_0_boundary_lines_land,
//   ne_50m_admin_1_states_provinces_lines, ne_10m_populated_places_simple
//
// Everything is projected to Web Mercator, as a fraction of the world's width
// (x from the antimeridian eastward, y from the north edge down), simplified
// for each range of zoom levels it's drawn at, and big shapes are cut into
// pieces of a few hundred points so a map tile only draws what it touches.
// The format is read by WorldMap in PhotoVaultCore.

import Foundation

typealias P = (x: Double, y: Double)

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift Scripts/make-world-map.swift <natural earth folder> [output]\n".data(using: .utf8)!)
    exit(2)
}
let source = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args.count > 2 ? args[2] : "Resources/World Map.pvmap")

// MARK: - Shapefiles

/// One record's parts in longitude/latitude; nil for a null shape.
func readShapes(_ name: String) throws -> [[[P]]?] {
    let data = try Data(contentsOf: source.appendingPathComponent(name).appendingPathComponent(name + ".shp"))
    func i32be(_ o: Int) -> Int { Int(Int32(bigEndian: data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })) }
    func i32(_ o: Int) -> Int { Int(Int32(littleEndian: data.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })) }
    func f64(_ o: Int) -> Double { Double(bitPattern: UInt64(littleEndian: data.subdata(in: o..<o + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })) }

    var out: [[[P]]?] = []
    var o = 100
    while o + 8 <= data.count {
        let length = i32be(o + 4) * 2
        let c = o + 8
        let type = i32(c)
        switch type {
        case 0:
            out.append(nil)
        case 1:
            out.append([[(f64(c + 4), f64(c + 12))]])
        case 3, 5:
            let parts = i32(c + 36), points = i32(c + 40)
            let starts = (0..<parts).map { i32(c + 44 + 4 * $0) } + [points]
            let base = c + 44 + 4 * parts
            out.append((0..<parts).map { p in
                (starts[p]..<starts[p + 1]).map { (f64(base + 16 * $0), f64(base + 16 * $0 + 8)) }
            })
        default:
            fatalError("\(name): shape type \(type) isn't handled")
        }
        o = c + length
    }
    return out
}

/// The attribute table: each record's fields, by lower-case field name.
func readTable(_ name: String) throws -> [[String: String]] {
    let data = try Data(contentsOf: source.appendingPathComponent(name).appendingPathComponent(name + ".dbf"))
    let bytes = [UInt8](data)
    func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
    let count = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
    let headerLength = u16(8), recordLength = u16(10)
    var fields: [(name: String, length: Int)] = []
    var f = 32
    while bytes[f] != 0x0D {
        let raw = bytes[f..<f + 11].prefix { $0 != 0 }
        fields.append((String(decoding: raw, as: UTF8.self).lowercased(), Int(bytes[f + 16])))
        f += 32
    }
    return (0..<count).map { r in
        var o = headerLength + r * recordLength + 1
        var row: [String: String] = [:]
        for field in fields {
            row[field.name] = String(decoding: bytes[o..<o + field.length], as: UTF8.self).trimmingCharacters(in: .whitespaces)
            o += field.length
        }
        return row
    }
}

// MARK: - Geometry

let maxLatitude = 85.05112878

func project(_ lon: Double, _ lat: Double) -> P {
    let phi = max(-maxLatitude, min(maxLatitude, lat)) * .pi / 180
    let x = (lon + 180) / 360
    let y = 0.5 - log(tan(.pi / 4 + phi / 2)) / (2 * .pi)
    return (min(max(x, 0), 1), min(max(y, 0), 1))
}

/// How far half a screen point is at `zoom`, as a fraction of the world.
func halfPoint(atZoom zoom: Int) -> Double { 0.5 / (256 * pow(2, Double(zoom))) }

func distance2(_ p: P, _ a: P, _ b: P) -> Double {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
    t = max(0, min(1, t))
    let ex = a.x + t * dx - p.x, ey = a.y + t * dy - p.y
    return ex * ex + ey * ey
}

/// Douglas–Peucker, without recursion.
func simplify(_ pts: [P], _ tolerance: Double) -> [P] {
    guard pts.count > 2 else { return pts }
    var keep = [Bool](repeating: false, count: pts.count)
    keep[0] = true
    keep[pts.count - 1] = true
    var stack = [(0, pts.count - 1)]
    let tol2 = tolerance * tolerance
    while let (a, b) = stack.popLast() {
        guard b > a + 1 else { continue }
        var worst = -1.0, index = -1
        for i in (a + 1)..<b {
            let d = distance2(pts[i], pts[a], pts[b])
            if d > worst { worst = d; index = i }
        }
        if worst > tol2 {
            keep[index] = true
            stack.append((a, index))
            stack.append((index, b))
        }
    }
    return pts.indices.filter { keep[$0] }.map { pts[$0] }
}

struct Rect {
    var x0, y0, x1, y1: Double
    func expanded(_ m: Double) -> Rect { Rect(x0: x0 - m, y0: y0 - m, x1: x1 + m, y1: y1 + m) }
}

func bounds(_ parts: [[P]]) -> Rect {
    var r = Rect(x0: .infinity, y0: .infinity, x1: -.infinity, y1: -.infinity)
    for part in parts { for p in part { r.x0 = min(r.x0, p.x); r.y0 = min(r.y0, p.y); r.x1 = max(r.x1, p.x); r.y1 = max(r.y1, p.y) } }
    return r
}

/// Sutherland–Hodgman: a ring (no repeated closing point) clipped to `r`.
/// Clipping each ring of a shape on its own is right for an even–odd fill.
func clip(_ ring: [P], to r: Rect) -> [P] {
    var pts = ring
    let edges: [(P) -> Bool] = [{ $0.x >= r.x0 }, { $0.x <= r.x1 }, { $0.y >= r.y0 }, { $0.y <= r.y1 }]
    let cuts: [(P, P) -> P] = [
        { a, b in (r.x0, a.y + (b.y - a.y) * (r.x0 - a.x) / (b.x - a.x)) },
        { a, b in (r.x1, a.y + (b.y - a.y) * (r.x1 - a.x) / (b.x - a.x)) },
        { a, b in (a.x + (b.x - a.x) * (r.y0 - a.y) / (b.y - a.y), r.y0) },
        { a, b in (a.x + (b.x - a.x) * (r.y1 - a.y) / (b.y - a.y), r.y1) },
    ]
    for e in 0..<4 {
        guard !pts.isEmpty else { break }
        var out: [P] = []
        out.reserveCapacity(pts.count + 4)
        var prev = pts[pts.count - 1]
        for cur in pts {
            let inCur = edges[e](cur), inPrev = edges[e](prev)
            if inCur {
                if !inPrev { out.append(cuts[e](prev, cur)) }
                out.append(cur)
            } else if inPrev {
                out.append(cuts[e](prev, cur))
            }
            prev = cur
        }
        pts = out
    }
    return pts.count >= 3 ? pts : []
}

/// A shape cut into quarters, and those into quarters, until each piece has
/// at most `limit` points. Each quarter is clipped a little larger than it
/// is (`margin`), so neighbouring pieces overlap: with anti-aliasing, pieces
/// that only met edge to edge would show a faint seam.
func cut(_ rings: [[P]], in r: Rect, limit: Int, margin: Double, into out: inout [[[P]]]) {
    let count = rings.reduce(0) { $0 + $1.count }
    guard count > 0 else { return }
    if count <= limit || r.x1 - r.x0 < margin * 8 {
        out.append(rings)
        return
    }
    let mx = (r.x0 + r.x1) / 2, my = (r.y0 + r.y1) / 2
    for q in [Rect(x0: r.x0, y0: r.y0, x1: mx, y1: my), Rect(x0: mx, y0: r.y0, x1: r.x1, y1: my),
              Rect(x0: r.x0, y0: my, x1: mx, y1: r.y1), Rect(x0: mx, y0: my, x1: r.x1, y1: r.y1)] {
        let pieces = rings.map { clip($0, to: q.expanded(margin)) }.filter { !$0.isEmpty }
        cut(pieces, in: q, limit: limit, margin: margin, into: &out)
    }
}

// MARK: - Layers

enum Kind: UInt8 { case land = 1, lakes = 2, countryBorders = 3, stateBorders = 4 }

struct Level {
    var fromZoom: Int
    var features: [[[P]]]   // pieces; each a list of rings or lines
}

/// Polygons, simplified for the most detailed zoom the level is drawn at,
/// with rings too small to see there left out, then cut into pieces.
func polygonLevel(_ shapes: [[[P]]?], from: Int, to: Int) -> Level {
    let tolerance = halfPoint(atZoom: to)
    let margin = 4 * halfPoint(atZoom: from)
    var features: [[[P]]] = []
    for case let parts? in shapes {
        var rings: [[P]] = []
        for part in parts {
            var ring = simplify(part.map { project($0.x, $0.y) }, tolerance)
            if ring.count > 1, ring.first! == ring.last! { ring.removeLast() }
            let b = bounds([ring])
            if ring.count >= 3, b.x1 - b.x0 > tolerance || b.y1 - b.y0 > tolerance { rings.append(ring) }
        }
        guard !rings.isEmpty else { continue }
        cut(rings, in: bounds(rings), limit: 600, margin: margin, into: &features)
    }
    return Level(fromZoom: from, features: features)
}

/// Lines, simplified, in runs of at most 256 points so each has a tight box.
func lineLevel(_ shapes: [[[P]]?], from: Int, to: Int) -> Level {
    let tolerance = halfPoint(atZoom: to)
    var features: [[[P]]] = []
    for case let parts? in shapes {
        for part in parts {
            let line = simplify(part.map { project($0.x, $0.y) }, tolerance)
            guard line.count >= 2 else { continue }
            var start = 0
            while start < line.count - 1 {
                let end = min(start + 256, line.count - 1)
                features.append([Array(line[start...end])])
                start = end
            }
        }
    }
    return Level(fromZoom: from, features: features)
}

let land50 = try readShapes("ne_50m_land")
let land10 = try readShapes("ne_10m_land")
let lakes50 = try readShapes("ne_50m_lakes")
let borders50 = try readShapes("ne_50m_admin_0_boundary_lines_land")
let borders10 = try readShapes("ne_10m_admin_0_boundary_lines_land")
let states50 = try readShapes("ne_50m_admin_1_states_provinces_lines")

// Each layer: the zoom it appears from, then its levels — the zoom each is
// used from, and the most detailed zoom it's simplified for.
let layers: [(Kind, Int, [Level])] = [
    // The 1:10 million data is only good to a kilometre or so: simplifying
    // it for zoom 9 keeps all it has to show, at any closer zoom too.
    (.land, 0, [polygonLevel(land50, from: 0, to: 2), polygonLevel(land50, from: 3, to: 5),
                polygonLevel(land10, from: 6, to: 9)]),
    (.lakes, 1, [polygonLevel(lakes50, from: 1, to: 4), polygonLevel(lakes50, from: 5, to: 8)]),
    (.countryBorders, 0, [lineLevel(borders50, from: 0, to: 5), lineLevel(borders10, from: 6, to: 9)]),
    (.stateBorders, 3, [lineLevel(states50, from: 3, to: 5), lineLevel(states50, from: 6, to: 9)]),
]

// Places: towns and cities, each with the zoom its name appears from.
let placeShapes = try readShapes("ne_10m_populated_places_simple")
let placeRows = try readTable("ne_10m_populated_places_simple")
precondition(placeShapes.count == placeRows.count, "shapes and table out of step")
var places: [(p: P, minZoom: Float, rank: UInt8, name: String)] = []
for (shape, row) in zip(placeShapes, placeRows) {
    guard let point = shape?.first?.first, let name = row["name"], !name.isEmpty,
          let minZoom = Float(row["min_zoom"] ?? "") else { continue }
    let rank = UInt8(max(0, min(255, Int(Double(row["scalerank"] ?? "") ?? 10))))
    places.append((project(point.x, point.y), minZoom, rank, name))
}
// Most important first, so a name that's crowded out is the lesser one.
places.sort { ($0.minZoom, $0.rank, $0.name) < ($1.minZoom, $1.rank, $1.name) }

let version = (try? String(contentsOf: source.appendingPathComponent("ne_10m_land/ne_10m_land.VERSION.txt"), encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"

// MARK: - Writing

var out = Data()
func u8(_ v: UInt8) { out.append(v) }
func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
func f32(_ v: Double) { withUnsafeBytes(of: Float(v).bitPattern.littleEndian) { out.append(contentsOf: $0) } }
func string(_ s: String) { let b = Array(s.utf8); u16(UInt16(b.count)); out.append(contentsOf: b) }

out.append(contentsOf: Array("PVMAP002".utf8))
string("Natural Earth \(version) (public domain), naturalearthdata.com")
u32(layers.count)
for (kind, minZoom, levels) in layers {
    u8(kind.rawValue)
    u8(UInt8(minZoom))
    u8(UInt8(levels.count))
    for level in levels {
        u8(UInt8(level.fromZoom))
        u32(level.features.count)
        var points = 0, largest = 0
        for feature in level.features {
            let b = bounds(feature)
            f32(b.x0); f32(b.y0); f32(b.x1); f32(b.y1)
            u32(feature.count)
            // Each point as two 16-bit fractions of the piece's own box:
            // half the size of 32-bit floats, and still far finer than the
            // data (a piece is small wherever detail matters).
            let w = b.x1 - b.x0, h = b.y1 - b.y0
            func q(_ v: Double, _ lo: Double, _ size: Double) -> UInt16 {
                size > 0 ? UInt16((max(0, min(1, (v - lo) / size)) * 65535).rounded()) : 0
            }
            var n = 0
            for part in feature {
                u32(part.count)
                for p in part { u16(q(p.x, b.x0, w)); u16(q(p.y, b.y0, h)) }
                n += part.count
            }
            points += n
            largest = max(largest, n)
        }
        print("\(kind) from zoom \(level.fromZoom): \(level.features.count) pieces, \(points) points, largest \(largest)")
    }
}
u32(places.count)
for place in places {
    f32(place.p.x); f32(place.p.y)
    withUnsafeBytes(of: place.minZoom.bitPattern.littleEndian) { out.append(contentsOf: $0) }
    u8(place.rank)
    string(place.name)
}
print("places: \(places.count)")
try out.write(to: output)
print("wrote \(output.path): \(out.count / 1024) KB")

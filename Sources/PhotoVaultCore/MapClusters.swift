import Foundation
import CoreGraphics

/// A circle on the map: one photo, or several close together at that zoom.
public struct MapCluster: Sendable, Hashable {
    /// Its place in its zoom level's list.
    public let index: Int
    /// Where it's drawn, in world coordinates: the middle of its photos.
    public let point: CGPoint
    public let count: Int
    /// The box around all its photos, in world coordinates. Zero-sized when
    /// every one was taken at the same spot, so no zoom will part them.
    public let bounds: CGRect
    /// A photo in it — the photo itself, for a cluster of one.
    public let photoID: Int64
    public let mediaType: MediaType

    public var isSingle: Bool { count == 1 }
}

/// Photos gathered into clusters for every zoom level, the way the
/// Supercluster library does it: starting close in, each photo or cluster
/// takes in its neighbours within `radius` points, and the zoom out from
/// there gathers those again. Built once for a set of photos — a second or
/// so for 100,000, so off the main thread — then each look-up is a scan of
/// one level.
public final class MapClusters: @unchecked Sendable {
    public static let maxZoom = 17
    public let radius: Double
    public let count: Int

    /// What a level holds, in parallel arrays: cheaper than 100,000 structs
    /// with arrays of their own.
    private struct Level {
        var x: [Double] = [], y: [Double] = []
        var count: [Int32] = []
        var minX: [Double] = [], minY: [Double] = [], maxX: [Double] = [], maxY: [Double] = []
        var photo: [Int32] = []           // a leaf's index in `points`
        /// Each cluster's members in the level below, as a run of `members`.
        var memberStart: [Int32] = [], memberCount: [Int32] = []
        var members: [Int32] = []

        var size: Int { x.count }

        mutating func reserve(_ n: Int) {
            for a in [\Level.x, \Level.y, \Level.minX, \Level.minY, \Level.maxX, \Level.maxY] as [WritableKeyPath<Level, [Double]>] {
                self[keyPath: a].reserveCapacity(n)
            }
            count.reserveCapacity(n)
            photo.reserveCapacity(n)
            memberStart.reserveCapacity(n)
            memberCount.reserveCapacity(n)
        }
    }

    private let points: [MapPoint]
    /// levels[z] for z in 0...maxZoom; levels[maxZoom + 1] is the photos.
    private var levels: [Level] = []

    public init(_ points: [MapPoint], radius: Double = 60) {
        self.points = points
        self.radius = radius
        self.count = points.count

        var leaves = Level()
        leaves.reserve(points.count)
        for (i, p) in points.enumerated() {
            let w = WebMercator.project(p.point)
            leaves.x.append(w.x); leaves.y.append(w.y)
            leaves.minX.append(w.x); leaves.minY.append(w.y); leaves.maxX.append(w.x); leaves.maxY.append(w.y)
            leaves.count.append(1)
            leaves.photo.append(Int32(i))
            leaves.memberStart.append(0)
            leaves.memberCount.append(0)
        }
        var built = [leaves]
        for z in stride(from: Self.maxZoom, through: 0, by: -1) {
            built.append(Self.gather(built.last!, radius: radius / WebMercator.worldSize(atZoom: Double(z))))
        }
        levels = built.reversed()
    }

    private static func gather(_ below: Level, radius r: Double) -> Level {
        var out = Level()
        out.reserve(below.size)
        // A grid of cells as wide as the radius: a neighbour is in this cell
        // or one of the eight around it. Members sorted by cell, each cell a
        // run of them.
        func cell(_ i: Int) -> (Int, Int) { (Int((below.x[i] / r).rounded(.down)), Int((below.y[i] / r).rounded(.down))) }
        func key(_ c: (Int, Int)) -> Int64 { Int64(c.0) << 32 | Int64(UInt32(truncatingIfNeeded: c.1)) }
        let keys = (0..<below.size).map { key(cell($0)) }
        let order = (0..<below.size).sorted { keys[$0] < keys[$1] }
        var runs: [Int64: Range<Int>] = [:]
        runs.reserveCapacity(below.size)
        var start = 0
        while start < order.count {
            var end = start + 1
            while end < order.count && keys[order[end]] == keys[order[start]] { end += 1 }
            runs[keys[order[start]]] = start..<end
            start = end
        }

        var taken = [Bool](repeating: false, count: below.size)
        let r2 = r * r
        var near: [Int] = []
        for i in 0..<below.size where !taken[i] {
            taken[i] = true
            near.removeAll(keepingCapacity: true)
            let (cx, cy) = cell(i)
            for dx in -1...1 {
                for dy in -1...1 {
                    guard let run = runs[key((cx + dx, cy + dy))] else { continue }
                    for k in run {
                        let j = order[k]
                        guard !taken[j] else { continue }
                        let ex = below.x[j] - below.x[i], ey = below.y[j] - below.y[i]
                        if ex * ex + ey * ey <= r2 { near.append(j) }
                    }
                }
            }
            for j in near { taken[j] = true }
            let group = [i] + near

            // Placed at the photos' average position.
            var n = 0, sx = 0.0, sy = 0.0
            var b = (below.minX[i], below.minY[i], below.maxX[i], below.maxY[i])
            for j in group {
                let c = Int(below.count[j])
                n += c
                sx += below.x[j] * Double(c)
                sy += below.y[j] * Double(c)
                b = (min(b.0, below.minX[j]), min(b.1, below.minY[j]), max(b.2, below.maxX[j]), max(b.3, below.maxY[j]))
            }
            out.x.append(sx / Double(n)); out.y.append(sy / Double(n))
            out.minX.append(b.0); out.minY.append(b.1); out.maxX.append(b.2); out.maxY.append(b.3)
            out.count.append(Int32(n))
            out.photo.append(below.photo[i])
            out.memberStart.append(Int32(out.members.count))
            out.memberCount.append(Int32(group.count))
            out.members.append(contentsOf: group.map(Int32.init))
        }
        return out
    }

    private static func level(forZoom zoom: Double) -> Int { max(0, min(maxZoom, Int(zoom.rounded(.down)))) }

    private func cluster(_ i: Int, in level: Level) -> MapCluster {
        let point = points[Int(level.photo[i])]
        return MapCluster(index: i, point: CGPoint(x: level.x[i], y: level.y[i]), count: Int(level.count[i]),
                          bounds: CGRect(x: level.minX[i], y: level.minY[i],
                                         width: level.maxX[i] - level.minX[i], height: level.maxY[i] - level.minY[i]),
                          photoID: point.id, mediaType: point.mediaType)
    }

    /// The clusters at `zoom` whose centre is in `rect` (world coordinates).
    public func clusters(atZoom zoom: Double, in rect: CGRect) -> [MapCluster] {
        guard !levels.isEmpty else { return [] }
        let level = levels[Self.level(forZoom: zoom)]
        var out: [MapCluster] = []
        for i in 0..<level.size where rect.contains(CGPoint(x: level.x[i], y: level.y[i])) {
            out.append(cluster(i, in: level))
        }
        return out
    }

    /// Every photo in a cluster from `clusters(atZoom:in:)` at the same zoom.
    public func photos(in cluster: MapCluster, atZoom zoom: Double) -> [MapPoint] {
        var z = Self.level(forZoom: zoom)
        var current = [cluster.index]
        while z <= Self.maxZoom {
            let level = levels[z]
            current = current.flatMap { i in
                let start = Int(level.memberStart[i])
                return level.members[start..<start + Int(level.memberCount[i])].map(Int.init)
            }
            z += 1
        }
        let leaves = levels[Self.maxZoom + 1]
        return current.map { points[Int(leaves.photo[$0])] }
    }

    /// The box around all the photos, in world coordinates; nil for none.
    public var bounds: CGRect? {
        guard let top = levels.first, top.size > 0 else { return nil }
        var r = CGRect.null
        for i in 0..<top.size {
            r = r.union(CGRect(x: top.minX[i], y: top.minY[i], width: top.maxX[i] - top.minX[i], height: top.maxY[i] - top.minY[i]))
        }
        return r
    }
}

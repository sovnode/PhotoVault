import Foundation
import CoreGraphics
import ImageIO

/// In-memory LRU in front of the pack.
///
/// Reading the whole ~300 MB pack into RAM at mount would eliminate the eject
/// problem entirely, but it puts 300 MB of decoded pixels within reach of swap
/// — which is the requirement this app exists to satisfy. A bounded cache over
/// `pread` keeps the resident set small enough that it doesn't matter.
final class ThumbnailCache {
    private var map: [Int64: CGImage] = [:]
    private var order: [Int64] = []
    private let limit: Int
    private let lock = NSLock()

    init(limit: Int = 2_000) { self.limit = limit }

    func image(for id: Int64) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        guard let img = map[id] else { return nil }
        if let i = order.firstIndex(of: id) {
            order.remove(at: i)
            order.append(id)
        }
        return img
    }

    func insert(_ image: CGImage, for id: Int64) {
        lock.lock(); defer { lock.unlock() }
        if map[id] == nil { order.append(id) }
        map[id] = image
        while order.count > limit, let evict = order.first {
            order.removeFirst()
            map.removeValue(forKey: evict)
        }
    }

    /// Drops one thumbnail — after a rotation, so the grid fetches the new one.
    func remove(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        map.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
        order.removeAll()
    }

    /// JPEG bytes straight to `CGImage`. Going via `NSImage` would add a
    /// redundant decode and a copy for every cell on screen.
    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

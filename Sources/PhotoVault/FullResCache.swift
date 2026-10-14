import Foundation
import CoreGraphics

/// Full-resolution decodes for the viewer: the photo on screen plus the
/// neighbours either side, decoded ahead so stepping lands on a sharp image.
///
/// Capped at three. Decoded full-size pixels are the one thing here that can be
/// paged to swap, outside the volume, so the design keeps as few in memory as
/// possible and drops them all whenever the app goes to the background.
@MainActor
final class FullResCache {
    private var images: [Int64: CGImage] = [:]
    private var order: [Int64] = []
    private var inFlight: [Int64: Task<CGImage?, Never>] = [:]
    private let capacity: Int

    init(capacity: Int = 3) { self.capacity = capacity }

    /// Read-only, so it's safe to call while a view is rendering.
    func image(for id: Int64) -> CGImage? { images[id] }

    /// Decodes once, however many callers ask at the same time.
    func load(_ id: Int64, url: URL?, priority: TaskPriority = .userInitiated) async -> CGImage? {
        if let ready = images[id] {
            touch(id)
            return ready
        }
        if let pending = inFlight[id] { return await pending.value }
        guard let url else { return nil }
        let task = Task.detached(priority: priority) { ViewerView.decodeFull(url: url) }
        inFlight[id] = task
        let image = await task.value
        inFlight[id] = nil
        if let image { insert(image, for: id) }
        return image
    }

    func remove(_ id: Int64) {
        images[id] = nil
        order.removeAll { $0 == id }
    }

    func removeAll() {
        images.removeAll()
        order.removeAll()
    }

    private func touch(_ id: Int64) {
        order.removeAll { $0 == id }
        order.append(id)
    }

    private func insert(_ image: CGImage, for id: Int64) {
        images[id] = image
        touch(id)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
    }
}

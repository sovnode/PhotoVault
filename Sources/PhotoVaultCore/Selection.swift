import Foundation

/// Finder's multi-select rules, kept as plain logic so they can be tested
/// without a running app.
///
/// The subtlety worth isolating is the anchor. A shift-click measures from the
/// last *plain or command* click, not from the previously shift-clicked cell —
/// which is what lets you shift-click repeatedly to grow and shrink one range
/// instead of dragging the anchor along behind the cursor.
public struct Selection: Equatable, Sendable {
    public private(set) var ids: Set<Int64> = []
    public private(set) var anchor: Int64?

    public init(ids: Set<Int64> = [], anchor: Int64? = nil) {
        self.ids = ids
        self.anchor = anchor
    }

    public enum Click: Sendable {
        case replace      // plain click
        case toggle       // command-click
        case extend       // shift-click
        case extendUnion  // command-shift-click
    }

    public var isEmpty: Bool { ids.isEmpty }
    public var count: Int { ids.count }
    public func contains(_ id: Int64) -> Bool { ids.contains(id) }

    public mutating func click(_ id: Int64, kind: Click, in order: [Int64]) {
        switch kind {
        case .replace:
            ids = [id]
            anchor = id

        case .toggle:
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id

        case .extend, .extendUnion:
            guard let anchor,
                  let from = order.firstIndex(of: anchor),
                  let to = order.firstIndex(of: id)
            else {
                // Nothing to measure from: the first shift-click in a fresh
                // grid behaves like a plain one.
                ids = [id]
                self.anchor = id
                return
            }
            let span = from <= to ? from...to : to...from
            let range = Set(order[span])
            ids = (kind == .extendUnion) ? ids.union(range) : range
            // The anchor stays where it was, deliberately.
        }
    }

    public mutating func selectAll(_ order: [Int64]) {
        ids = Set(order)
        anchor = order.first
    }

    public mutating func clear() {
        ids.removeAll()
        anchor = nil
    }

    /// Right-clicking inside an existing selection acts on the whole thing;
    /// right-clicking outside it selects that one item first.
    public mutating func prepareForContextMenu(on id: Int64) {
        guard !ids.contains(id) else { return }
        ids = [id]
        anchor = id
    }

    /// Drops ids that are no longer on screen — after a rescan, a filter
    /// change, or a file going missing.
    public mutating func intersect(with visible: [Int64]) {
        ids.formIntersection(visible)
        if let a = anchor, !visible.contains(a) { anchor = nil }
    }
}

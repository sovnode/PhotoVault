import Testing
@testable import PhotoVaultCore

/// Finder's multi-select rules. The anchor behaviour is the part that is easy
/// to get subtly wrong and impossible to notice from reading the code.
@Suite("Selection")
struct SelectionTests {
    let order: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8]

    private func selection(after clicks: [(Int64, Selection.Click)]) -> Selection {
        var s = Selection()
        for (id, kind) in clicks { s.click(id, kind: kind, in: order) }
        return s
    }

    @Test func plainClickReplaces() {
        let s = selection(after: [(3, .replace), (5, .replace)])
        #expect(s.ids == [5])
        #expect(s.anchor == 5)
    }

    @Test func commandClickAddsWithoutClearing() {
        let s = selection(after: [(2, .replace), (4, .toggle), (6, .toggle)])
        #expect(s.ids == [2, 4, 6])
    }

    @Test func commandClickOnASelectedItemRemovesIt() {
        let s = selection(after: [(2, .replace), (4, .toggle), (2, .toggle)])
        #expect(s.ids == [4], "command-click is a toggle, not an add")
    }

    @Test func shiftClickSelectsTheRange() {
        let s = selection(after: [(3, .replace), (6, .extend)])
        #expect(s.ids == [3, 4, 5, 6])
    }

    @Test func shiftClickWorksBackwards() {
        let s = selection(after: [(6, .replace), (3, .extend)])
        #expect(s.ids == [3, 4, 5, 6], "dragging the range upward must work too")
    }

    /// The one that separates a real implementation from a naive one: the
    /// anchor stays at the last plain click, so a second shift-click re-measures
    /// from there rather than from the previous shift-click.
    @Test func repeatedShiftClicksResizeOneRange() {
        var s = Selection()
        s.click(3, kind: .replace, in: order)
        s.click(6, kind: .extend, in: order)
        #expect(s.ids == [3, 4, 5, 6])

        s.click(8, kind: .extend, in: order)
        #expect(s.ids == [3, 4, 5, 6, 7, 8], "grew from the original anchor")

        s.click(4, kind: .extend, in: order)
        #expect(s.ids == [3, 4], "and shrank back toward it, not toward 8")
        #expect(s.anchor == 3)
    }

    @Test func shiftClickReplacesRatherThanAccumulating() {
        var s = Selection()
        s.click(1, kind: .replace, in: order)
        s.click(2, kind: .extend, in: order)
        s.click(7, kind: .replace, in: order)
        s.click(8, kind: .extend, in: order)
        #expect(s.ids == [7, 8], "the earlier range is gone")
    }

    @Test func commandShiftClickUnionsRanges() {
        var s = Selection()
        s.click(1, kind: .replace, in: order)
        s.click(2, kind: .extend, in: order)
        s.click(7, kind: .toggle, in: order)
        s.click(8, kind: .extendUnion, in: order)
        #expect(s.ids == [1, 2, 7, 8], "two disjoint ranges, both kept")
    }

    @Test func commandClickMovesTheAnchor() {
        var s = Selection()
        s.click(1, kind: .replace, in: order)
        s.click(5, kind: .toggle, in: order)
        s.click(7, kind: .extend, in: order)
        #expect(s.ids == [5, 6, 7], "the range measured from the command-click")
    }

    @Test func shiftClickWithNoAnchorActsLikeAPlainClick() {
        let s = selection(after: [(4, .extend)])
        #expect(s.ids == [4])
        #expect(s.anchor == 4)
    }

    @Test func shiftClickOnItselfSelectsJustIt() {
        let s = selection(after: [(4, .replace), (4, .extend)])
        #expect(s.ids == [4])
    }

    @Test func selectAllAndClear() {
        var s = Selection()
        s.selectAll(order)
        #expect(s.ids.count == 8)
        s.clear()
        #expect(s.isEmpty)
        #expect(s.anchor == nil)
    }

    @Test func contextMenuOutsideSelectionReplacesIt() {
        var s = Selection()
        s.click(1, kind: .replace, in: order)
        s.click(2, kind: .toggle, in: order)
        s.prepareForContextMenu(on: 7)
        #expect(s.ids == [7], "right-clicking elsewhere targets just that item")
    }

    @Test func contextMenuInsideSelectionKeepsIt() {
        var s = Selection()
        s.click(1, kind: .replace, in: order)
        s.click(2, kind: .toggle, in: order)
        s.prepareForContextMenu(on: 2)
        #expect(s.ids == [1, 2], "right-clicking a selected item acts on all of them")
    }

    /// After a rescan or a filter change, ids that are no longer on screen have
    /// to go — otherwise a later Add to Album silently includes invisible rows.
    @Test func intersectDropsVanishedItemsAndStaleAnchor() {
        var s = Selection()
        s.click(2, kind: .replace, in: order)
        s.click(7, kind: .toggle, in: order)
        s.intersect(with: [1, 2, 3])
        #expect(s.ids == [2])
        #expect(s.anchor == nil, "the anchor pointed at a row that is gone")
    }

    @Test func intersectKeepsALiveAnchor() {
        var s = Selection()
        s.click(2, kind: .replace, in: order)
        s.intersect(with: [1, 2, 3])
        #expect(s.anchor == 2)
    }
}

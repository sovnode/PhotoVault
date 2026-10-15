import Testing
@testable import PhotoVault

/// Dragging an album in the sidebar: where it lands.
@MainActor
@Suite("Album drag")
struct AlbumMoveTests {
    struct Row: Identifiable, Equatable { let id: Int64 }
    let rows = [1, 2, 3, 4].map { Row(id: $0) }

    private func ids(_ dragged: Int64, beside target: Int64, after: Bool) -> [Int64]? {
        LibraryModel.moving(dragged, beside: target, after: after, in: rows)?.map(\.id)
    }

    @Test func dropsJustAboveOrBelowTheRowUnderThePointer() {
        #expect(ids(4, beside: 1, after: false) == [4, 1, 2, 3], "to the top")
        #expect(ids(1, beside: 4, after: true) == [2, 3, 4, 1], "to the bottom")
        #expect(ids(1, beside: 3, after: false) == [2, 1, 3, 4], "down, above its target")
        #expect(ids(1, beside: 3, after: true) == [2, 3, 1, 4], "down, below its target")
        #expect(ids(4, beside: 2, after: true) == [1, 2, 4, 3], "up, below its target")
    }

    @Test func dropsThatChangeNothingAreRefused() {
        #expect(ids(2, beside: 2, after: true) == nil, "onto itself")
        #expect(ids(9, beside: 2, after: true) == nil, "not one of these")
        #expect(ids(2, beside: 9, after: true) == nil)
    }
}

@MainActor
@Suite("Deleting several albums")
struct DeleteAlbumsWordingTests {
    @Test func saysHowManyOfEach() {
        #expect(SidebarView.count(albums: 3, smart: 0) == "3 Albums")
        #expect(SidebarView.count(albums: 0, smart: 1) == "1 Smart Album")
        #expect(SidebarView.count(albums: 1, smart: 2) == "1 Album and 2 Smart Albums")
    }
}

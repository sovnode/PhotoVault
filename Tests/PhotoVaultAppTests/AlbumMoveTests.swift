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

@MainActor
@Suite("Keyboard shortcuts")
struct ShortcutTests {
    @Test func noTwoCommandsShareAKey() {
        // Plain keys may repeat across places that are never live together:
        // R is Repeat in the viewer, never a library command.
        let keys = Shortcut.allCases.map { "\($0.label) \($0.place == .viewer && $0.modifiers.isEmpty ? "viewer" : "")" }
        #expect(Set(keys).count == keys.count, "\(Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys)")
    }

    @Test func readAsTheMenusShowThem() {
        #expect(Shortcut.sortUp.label == "⌥⌘↑")
        #expect(Shortcut.fullRescan.label == "⌥⇧⌘R")
        #expect(Shortcut.favorite.label == ".")
        #expect(Shortcut.autoScroll.label == "Space")
        #expect(Shortcut.smallerThumbnails.label == "⌘−")
        #expect(Shortcut.trash.help("Move to Trash") == "Move to Trash (⌘⌫)")
    }

    @Test func everyShortcutIsListedSomewhere() {
        for place in Shortcut.Place.allCases {
            #expect(Shortcut.allCases.contains { $0.place == place })
        }
    }
}

@MainActor
@Suite("The grid's rows")
struct GridColumnsTests {
    @Test func countsPhotosToARowAsTheGridDoes() {
        // 8 points of padding each side, 8 between.
        #expect(GridView.columns(width: 16 + 160, cellSize: 160) == 1)
        #expect(GridView.columns(width: 16 + 160 * 4 + 8 * 3, cellSize: 160) == 4)
        #expect(GridView.columns(width: 16 + 160 * 4 + 8 * 3 - 1, cellSize: 160) == 3)
        #expect(GridView.columns(width: 0, cellSize: 160) == 1, "never none")
    }
}

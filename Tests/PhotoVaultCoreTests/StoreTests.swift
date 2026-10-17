import Testing
import Foundation
@testable import PhotoVaultCore

@Suite("Store", .serialized)
struct StoreTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    private func makeStore() throws -> Store { try Store(root: vault.root) }
    private var packSize: Int { vault.fileSize(vault.packFile) }

    @Test func scanIndexesAndThumbnailsEverything() async throws {
        try vault.writeImage("a.jpg", seed: 0.2)
        try vault.writeImage("2019/b.jpg", seed: 0.6)
        let store = try makeStore()

        try await store.scan(full: true)

        let items = try await store.items(scope: .all, filter: .all)
        #expect(items.count == 2)
        for item in items {
            #expect(item.hasThumb, "\(item.relPath) got no thumbnail")
            let data = try #require(try await store.thumbnailData(for: item))
            #expect(TestVault.isJPEG(data), "\(item.relPath) thumbnail isn't a JPEG")
            #expect(item.width > 0)
            #expect(item.capturedAt != nil, "captured_at falls back to mtime when there's no EXIF")
        }
        await store.close()
    }

    @Test func secondScanIsANoOpAndDoesNotGrowThePack() async throws {
        try vault.writeImage("a.jpg")
        let store = try makeStore()
        try await store.scan(full: true)
        let sizeAfterFirst = packSize

        try await store.scan(full: true)

        #expect(packSize == sizeAfterFirst, "a rescan must not re-append thumbnails that already exist")
        #expect(try await store.photoCount() == 1)
        await store.close()
    }

    @Test func incrementalScanPicksUpANewFile() async throws {
        try vault.writeImage("a.jpg")
        let store = try makeStore()
        try await store.scan(full: true)

        try vault.writeImage("b.jpg", seed: 0.9)
        try await store.scan(full: false)

        #expect(try await store.photoCount() == 2)
        #expect(try await store.items(scope: .all, filter: .all).allSatisfy(\.hasThumb))
        await store.close()
    }

    @Test func deletedFileIsMarkedMissingNotDeleted() async throws {
        try vault.writeImage("a.jpg")
        try vault.writeImage("b.jpg", seed: 0.8)
        let store = try makeStore()
        try await store.scan(full: true)
        let b = try #require(try await store.items(scope: .all, filter: .all).first { $0.displayName == "b.jpg" })
        let album = try await store.createAlbum(named: "Keepers")
        try await store.addToAlbum(album, photoIDs: [b.id])

        try FileManager.default.removeItem(at: vault.photos.appendingPathComponent("b.jpg"))
        try await store.scan(full: false)

        #expect(try await store.photoCount() == 1, "it drops out of the grid")
        let row = try #require(try await store.photo(id: b.id))
        #expect(row.missing, "…but the row survives, so its album membership does too")
        await store.close()
    }

    /// Originals never move on the app's account — but the *user* may move
    /// them, and a moved file must not orphan its albums and favorites.
    @Test func movedFileIsRelinkedAndKeepsAlbumAndFavorite() async throws {
        try vault.writeImage("trip.jpg", seed: 0.33)
        let store = try makeStore()
        try await store.scan(full: true)

        let original = try #require(try await store.items(scope: .all, filter: .all).first)
        let album = try await store.createAlbum(named: "Trip")
        try await store.addToAlbum(album, photoIDs: [original.id])
        try await store.setFavorite(true, for: [original.id])

        try FileManager.default.createDirectory(at: vault.photos.appendingPathComponent("2021"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: vault.photos.appendingPathComponent("trip.jpg"),
            to: vault.photos.appendingPathComponent("2021/trip.jpg"))
        try await store.scan(full: true)

        #expect(try await store.photoCount() == 1, "no duplicate row for the new path")
        let moved = try #require(try await store.photo(id: original.id))
        #expect(moved.relPath == "Photos/2021/trip.jpg")
        #expect(moved.missing == false)
        #expect(moved.favorite, "favorite survived the move")
        #expect(try await store.albumCount(album) == 1, "album membership survived the move")
        #expect(moved.hasThumb, "…and so did its thumbnail, without re-encoding")
        await store.close()
    }

    // MARK: Folders renamed, moved or deleted, on the quick rescan

    /// The quick rescan opening does: a folder renamed, moved into another or
    /// emptied and deleted must leave its photos the same photos at their new
    /// paths — no new thumbnails, no new tags, favorites and albums kept.
    /// Before the fix, a folder that had vanished was skipped, its photos were
    /// never marked gone, and every one turned up again as a new photo.
    private func expectMovedByQuickRescan(_ move: (FileManager) throws -> Void, to newPaths: [String: String]) async throws {
        try vault.writeImage("2019/a.jpg", seed: 0.21)
        try vault.writeImage("2019/sub/b.jpg", seed: 0.42)
        let store = try makeStore()
        try await store.scan(full: true)
        let before = try await store.items(scope: .all, filter: .all)
        let a = try #require(before.first { $0.displayName == "a.jpg" })
        let b = try #require(before.first { $0.displayName == "b.jpg" })
        try await store.setFavorite(true, for: [a.id])
        let album = try await store.createAlbum(named: "Kept")
        try await store.addToAlbum(album, photoIDs: [b.id])
        let pack = packSize

        try move(FileManager.default)
        try await store.scan(full: false)

        #expect(try await store.photoCount() == 2, "no second row for a moved photo")
        let movedA = try #require(try await store.photo(id: a.id))
        let movedB = try #require(try await store.photo(id: b.id))
        #expect(movedA.relPath == newPaths["a.jpg"])
        #expect(movedB.relPath == newPaths["b.jpg"])
        #expect(!movedA.missing && !movedB.missing)
        #expect(movedA.favorite, "the favorite moved with it")
        #expect(try await store.albumCount(album) == 1, "and the album membership")
        #expect(movedA.hasThumb && movedB.hasThumb)
        #expect(packSize == pack, "no thumbnail made again")
        await store.close()
    }

    @Test func aRenamedFolderKeepsItsPhotos() async throws {
        let photos = vault.photos
        try await expectMovedByQuickRescan({ fm in
            try fm.moveItem(at: photos.appendingPathComponent("2019"), to: photos.appendingPathComponent("Summer 2019"))
        }, to: ["a.jpg": "Photos/Summer 2019/a.jpg", "b.jpg": "Photos/Summer 2019/sub/b.jpg"])
    }

    @Test func aFolderMovedIntoANewOneKeepsItsPhotos() async throws {
        let photos = vault.photos
        try await expectMovedByQuickRescan({ fm in
            try fm.createDirectory(at: photos.appendingPathComponent("Archive"), withIntermediateDirectories: true)
            try fm.moveItem(at: photos.appendingPathComponent("2019"), to: photos.appendingPathComponent("Archive/2019"))
        }, to: ["a.jpg": "Photos/Archive/2019/a.jpg", "b.jpg": "Photos/Archive/2019/sub/b.jpg"])
    }

    @Test func photosMovedOutOfAFolderThenDeletedAreKept() async throws {
        let photos = vault.photos
        try await expectMovedByQuickRescan({ fm in
            try fm.createDirectory(at: photos.appendingPathComponent("Family"), withIntermediateDirectories: true)
            try fm.moveItem(at: photos.appendingPathComponent("2019/a.jpg"), to: photos.appendingPathComponent("Family/a.jpg"))
            try fm.moveItem(at: photos.appendingPathComponent("2019/sub/b.jpg"), to: photos.appendingPathComponent("Family/b.jpg"))
            try fm.removeItem(at: photos.appendingPathComponent("2019"))
        }, to: ["a.jpg": "Photos/Family/a.jpg", "b.jpg": "Photos/Family/b.jpg"])
    }

    /// A deleted folder's photos are gone, on the quick rescan too.
    @Test func aDeletedFolderIsGoneOnTheQuickRescan() async throws {
        try vault.writeImage("keep.jpg", seed: 0.1)
        try vault.writeImage("old/a.jpg", seed: 0.2)
        let store = try makeStore()
        try await store.scan(full: true)
        try FileManager.default.removeItem(at: vault.photos.appendingPathComponent("old"))
        try await store.scan(full: false)
        #expect(try await store.photoCount() == 1)
        #expect(try await store.items(scope: .all, filter: .all).map(\.relPath) == ["Photos/keep.jpg"])
        await store.close()
    }

    /// Two identical files where one was: the moved photo takes one path, the
    /// copy gets a row of its own — not one row tried on both, which left a
    /// path with no row at all.
    @Test func aMovedPhotoWithACopyGivesEachFileARow() async throws {
        try vault.writeImage("x/a.jpg", seed: 0.77)
        let store = try makeStore()
        try await store.scan(full: true)
        let original = try #require(try await store.items(scope: .all, filter: .all).first)
        let fm = FileManager.default
        try fm.moveItem(at: vault.photos.appendingPathComponent("x"), to: vault.photos.appendingPathComponent("y"))
        try fm.createDirectory(at: vault.photos.appendingPathComponent("z"), withIntermediateDirectories: true)
        try fm.copyItem(at: vault.photos.appendingPathComponent("y/a.jpg"), to: vault.photos.appendingPathComponent("z/a.jpg"))
        try await store.scan(full: false)

        let rows = try await store.items(scope: .all, filter: .all)
        #expect(Set(rows.map(\.relPath)) == ["Photos/y/a.jpg", "Photos/z/a.jpg"])
        #expect(rows.contains { $0.id == original.id }, "the original row is one of them")
        await store.close()
    }

    /// What the bug left in a vault: the old row still present in a folder
    /// that's gone (and no longer in the directory state), and a second row
    /// for the same photo at its new path. The next quick rescan puts the old
    /// row — favorite, album, thumbnail — on the new path and drops the other.
    @Test func rowsLeftByTheOldBugAreRepairedOnTheQuickRescan() async throws {
        try vault.writeImage("old/a.jpg", seed: 0.55)
        var store = try makeStore()
        try await store.scan(full: true)
        let original = try #require(try await store.items(scope: .all, filter: .all).first)
        try await store.setFavorite(true, for: [original.id])
        let album = try await store.createAlbum(named: "Kept")
        try await store.addToAlbum(album, photoIDs: [original.id])
        await store.close()

        let fm = FileManager.default
        try fm.moveItem(at: vault.photos.appendingPathComponent("old"), to: vault.photos.appendingPathComponent("new"))
        do {
            let catalog = try Catalog(url: vault.catalogFile)
            let url = vault.photos.appendingPathComponent("new/a.jpg")
            let size = Int64(vault.fileSize(url))
            let mtime = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            try catalog.upsertPhoto(PhotoItem(relPath: "Photos/new/a.jpg", fileSize: size,
                                              mtime: mtime.timeIntervalSince1970, contentKey: ContentKey.compute(url: url, fileSize: size)))
            try catalog.removeDirStates(["Photos/old"])
            for dir in ["Photos", "Photos/new"] {
                try catalog.setDirState(dir, mtime: try #require(Scanner.directoryMTime(vault.root.appendingPathComponent(dir))))
            }
            catalog.closeCleanly()
        }

        store = try makeStore()
        try await store.scan(full: false)
        #expect(try await store.photoCount() == 1, "the duplicate is gone")
        let row = try #require(try await store.photo(id: original.id))
        #expect(row.relPath == "Photos/new/a.jpg" && !row.missing)
        #expect(row.favorite && row.hasThumb)
        #expect(try await store.albumCount(album) == 1)
        await store.close()
    }

    /// An identical copy someone has made a favorite (or put in an album) is a
    /// photo of its own: a vanished twin isn't moved on to it.
    @Test func aCopyInUseIsNotTakenOverByAVanishedTwin() async throws {
        try vault.writeImage("x/a.jpg", seed: 0.66)
        try FileManager.default.createDirectory(at: vault.photos.appendingPathComponent("y"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: vault.photos.appendingPathComponent("x/a.jpg"),
                                         to: vault.photos.appendingPathComponent("y/a.jpg"))
        let store = try makeStore()
        try await store.scan(full: true)
        let rows = try await store.items(scope: .all, filter: .all)
        let x = try #require(rows.first { $0.relPath == "Photos/x/a.jpg" })
        let y = try #require(rows.first { $0.relPath == "Photos/y/a.jpg" })
        try await store.setFavorite(true, for: [y.id])

        try FileManager.default.removeItem(at: vault.photos.appendingPathComponent("x"))
        try await store.scan(full: false)
        #expect(try await store.photo(id: y.id)?.relPath == "Photos/y/a.jpg", "the copy keeps its own row")
        #expect(try await store.photo(id: x.id)?.missing == true)
        await store.close()
    }

    /// The whole Photos folder briefly not there — a vault half-mounted — is
    /// not every photo deleted.
    @Test func aMissingPhotosFolderMarksNothingGone() async throws {
        try vault.writeImage("a.jpg", seed: 0.3)
        let store = try makeStore()
        try await store.scan(full: true)
        let aside = vault.root.appendingPathComponent("Photos-aside")
        try FileManager.default.moveItem(at: vault.photos, to: aside)
        try await store.scan(full: false)
        try await store.scan(full: true)
        try FileManager.default.moveItem(at: aside, to: vault.photos)
        #expect(try await store.photoCount() == 1)
        await store.close()
    }

    @Test func unopenableVideoIsBadgedRatherThanRetried() async throws {
        try vault.writeJunk("broken.mkv", bytes: 8192)
        let store = try makeStore()

        try await store.scan(full: true)

        let item = try #require(try await store.items(scope: .all, filter: .videos).first)
        #expect(item.playable == false, "a container AVFoundation can't open must be badged")
        #expect(item.hasThumb == false)
        #expect(item.capturedAt != nil,
                "a badged row still needs a date, or a NULL sorts it ahead of the whole library")
        await store.close()
    }

    @Test func realVideoGetsAPosterFrameAndDuration() async throws {
        try FileManager.default.createDirectory(at: vault.photos, withIntermediateDirectories: true)
        try await VideoFixture.write(to: vault.photos.appendingPathComponent("clip.mp4"), seconds: 3)
        let store = try makeStore()

        try await store.scan(full: true)

        let item = try #require(try await store.items(scope: .all, filter: .videos).first)
        #expect(item.playable)
        #expect(item.hasThumb)
        let duration = try #require(item.duration)
        #expect(abs(duration - 3) < 0.5, "duration was \(duration)")
        #expect(item.posterTime != nil)
        #expect(try await store.items(scope: .all, filter: .photos).isEmpty)
        await store.close()
    }

    /// The recovery contract, exercised end to end: a pack with crash residue
    /// at the tail is truncated back to what the catalog can actually address.
    @Test func orphanedTailBytesAreReclaimedOnNextOpen() async throws {
        try vault.writeImage("a.jpg")
        let store = try makeStore()
        try await store.scan(full: true)
        await store.close()

        let goodSize = packSize
        do {
            let pack = try BlobPack(url: vault.packFile)
            _ = try pack.append(Data(repeating: 0xAB, count: 4096))   // the crash residue
        }
        #expect(packSize == goodSize + 4096)

        let reopened = try makeStore()   // truncateOrphans runs in init
        #expect(packSize == goodSize)
        let item = try #require(try await reopened.items(scope: .all, filter: .all).first)
        #expect(try await reopened.thumbnailData(for: item) != nil, "…without damaging a live thumbnail")
        await reopened.close()
    }

    @Test func cleanShutdownEarnsTheFastPathNextTime() async throws {
        try vault.writeImage("a.jpg")
        let store = try makeStore()
        try await store.scan(full: true)
        await store.close()

        let reopened = try makeStore()
        #expect(try await reopened.needsFullScan() == false, "a clean shutdown earns the fast path")
        await reopened.close()
    }

    @Test func uncleanShutdownForcesAFullRescan() async throws {
        try vault.writeImage("a.jpg")
        let store = try makeStore()
        try await store.scan(full: true)
        // No close(): the volume was yanked.

        let reopened = try makeStore()
        #expect(try await reopened.needsFullScan(), "stale dir mtimes can't be trusted after a crash")
        await reopened.close()
        await store.close()
    }

    @Test func exportIsKeyedOnContentNotPaths() async throws {
        try vault.writeImage("a.jpg", seed: 0.1)
        try vault.writeImage("b.jpg", seed: 0.9)
        let store = try makeStore()
        try await store.scan(full: true)
        let items = try await store.items(scope: .all, filter: .all)
        let album = try await store.createAlbum(named: "Trip")
        try await store.addToAlbum(album, photoIDs: [items[0].id])
        try await store.setFavorite(true, for: [items[1].id])

        let data = try await store.exportMembershipsJSON()
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("\"Trip\""))
        #expect(text.contains(vault.root.path) == false,
                "an export that names this machine can't be replayed on another")
        #expect(text.contains("Photos/a.jpg") == false, "memberships are keyed on content hash, not path")

        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((decoded?["favorites"] as? [String])?.count == 1)
        await store.close()
    }

    /// Nothing in the catalog says where the vault lives, at the whole-vault level: copy the bundle somewhere else
    /// under a different name and it must open unchanged.
    @Test func vaultSurvivesBeingCopiedElsewhere() async throws {
        try vault.writeImage("a.jpg", seed: 0.4)
        let store = try makeStore()
        try await store.scan(full: true)
        let original = try #require(try await store.items(scope: .all, filter: .all).first)
        let album = try await store.createAlbum(named: "Trip")
        try await store.addToAlbum(album, photoIDs: [original.id])
        await store.close()

        let copyRoot = TestVault.sandbox.appendingPathComponent("copied-vault-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: vault.root, to: copyRoot)
        defer { try? FileManager.default.removeItem(at: copyRoot) }

        let copied = try Store(root: copyRoot)
        let items = try await copied.items(scope: .album(album), filter: .all)
        #expect(items.count == 1, "albums came across")
        #expect(try await copied.thumbnailData(for: items[0]) != nil, "and so did the thumbnail pack")
        #expect(try await copied.needsFullScan() == false, "a cleanly-closed vault opens warm on the other side")
        await copied.close()
    }

    @Test func emptyVaultIsNotAnError() async throws {
        let store = try makeStore()
        try await store.scan(full: true)
        #expect(try await store.photoCount() == 0)
        #expect(try await store.items(scope: .all, filter: .all).isEmpty)
        await store.close()
    }
}

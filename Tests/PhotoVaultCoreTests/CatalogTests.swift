import Testing
import Foundation
@testable import PhotoVaultCore

@Suite("Catalog", .serialized)
struct CatalogTests {
    let vault: TestVault
    let catalog: Catalog

    init() throws {
        vault = try TestVault()
        catalog = try Catalog(url: vault.catalogFile, tmpDir: vault.catalogDir.appendingPathComponent("tmp"))
    }

    @Test func schemaVersionIsStamped() throws {
        #expect(try catalog.userVersion() == Catalog.schemaVersion)
    }

    @Test func migrationIsIdempotentAcrossOpens() throws {
        catalog.closeCleanly()
        // Opening an existing catalog must not try to re-run the v1 schema.
        let again = try Catalog(url: vault.catalogFile)
        #expect(try again.userVersion() == Catalog.schemaVersion)
        again.closeCleanly()
    }

    @Test func upsertIsIdempotentOnRelPath() throws {
        let p = PhotoItem(relPath: "Photos/a.jpg", fileSize: 10, mtime: 1)
        let first = try catalog.upsertPhoto(p)
        let second = try catalog.upsertPhoto(p)
        #expect(first == second)
        #expect(try catalog.photoCount() == 1)
    }

    /// The rescan-safety property: re-seeing a file must not wipe what the
    /// user did to it.
    /// The rescan-safety property: re-seeing an unchanged file must not wipe
    /// anything — not the user's favorite, not the thumbnail, and not the
    /// details learned from inside the file. (Before 1.2.0 a rescan blanked
    /// the details of every photo in a folder it re-read.)
    @Test func rescanOfAnUnchangedFileKeepsEverything() throws {
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", fileSize: 10, mtime: 1))
        try catalog.setFavorite(photoID: id, true)
        try catalog.setThumb(photoID: id, offset: 16, length: 200)
        try catalog.setDetails(id: id, width: 4000, height: 3000, orientation: 6, capturedAt: 1_500_000_000, duration: nil)

        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", fileSize: 10, mtime: 1))

        let row = try #require(try catalog.photo(id: id))
        #expect(row.favorite, "a rescan must never clear a favorite")
        #expect(row.thumbOff == 16 && row.thumbLen == 200)
        #expect(row.width == 4000 && row.height == 3000 && row.orientation == 6)
        #expect(row.capturedAt == 1_500_000_000 && row.hasDate)
    }

    /// A file that really changed gets its thumbnail dropped, so the scan
    /// rebuilds it — and with it the details. The favorite stays.
    @Test func rescanOfAChangedFileRebuildsItsThumbnail() throws {
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", fileSize: 10, mtime: 1))
        try catalog.setFavorite(photoID: id, true)
        try catalog.setThumb(photoID: id, offset: 16, length: 200)

        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", fileSize: 99, mtime: 2))

        let row = try #require(try catalog.photo(id: id))
        #expect(row.favorite)
        #expect(row.thumbOff == nil, "the old thumbnail no longer matches the file")
        #expect(row.fileSize == 99 && row.mtime == 2)
        #expect(try catalog.photosNeedingThumbs().map(\.id) == [id])
    }

    @Test func upsertClearsMissingFlag() throws {
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg"))
        try catalog.markMissing(ids: [id])
        #expect(try #require(try catalog.photo(id: id)).missing)
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg"))
        #expect(try #require(try catalog.photo(id: id)).missing == false)
    }

    @Test func missingIsAFlagNotADeleteAndAlbumsSurvive() throws {
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg"))
        let album = try catalog.createAlbum(name: "Trip")
        try catalog.addToAlbum(albumID: album, photoIDs: [id])

        try catalog.markMissing(ids: [id])

        #expect(try catalog.photo(id: id) != nil, "the row stays")
        #expect(try catalog.items(scope: .album(album), filter: .all).isEmpty, "but is hidden")
        #expect(try catalog.items(scope: .album(album), filter: .all, includeMissing: true).count == 1,
                "and its album membership is intact for when the file comes back")
    }

    @Test func maxThumbTailIgnoresRowsWithoutThumbs() throws {
        #expect(try catalog.maxThumbTail() == 0)
        let a = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg"))
        let b = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/b.jpg"))
        _ = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/c.jpg"))
        try catalog.setThumb(photoID: a, offset: 16, length: 100)
        try catalog.setThumb(photoID: b, offset: 116, length: 50)
        #expect(try catalog.maxThumbTail() == 166)
    }

    @Test func relinkKeepsAlbumMembership() throws {
        let old = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/old.jpg", contentKey: "k1"))
        let album = try catalog.createAlbum(name: "Keepers")
        try catalog.addToAlbum(albumID: album, photoIDs: [old])
        try catalog.setFavorite(photoID: old, true)
        try catalog.markMissing(ids: [old])

        try catalog.relink(missingID: old, toRelPath: "Photos/moved/old.jpg")

        let row = try #require(try catalog.photo(id: old))
        #expect(row.relPath == "Photos/moved/old.jpg")
        #expect(row.missing == false)
        #expect(row.favorite)
        #expect(try catalog.items(scope: .album(album), filter: .all).count == 1)
    }

    @Test func deletingAlbumCascadesMembershipButNotPhotos() throws {
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg"))
        let album = try catalog.createAlbum(name: "Temp")
        try catalog.addToAlbum(albumID: album, photoIDs: [id])
        try catalog.deleteAlbum(id: album)
        #expect(try catalog.albums().isEmpty)
        #expect(try catalog.photo(id: id) != nil, "deleting an album never deletes originals")
    }

    @Test func addToAlbumIsIdempotent() throws {
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg"))
        let album = try catalog.createAlbum(name: "Trip")
        try catalog.addToAlbum(albumID: album, photoIDs: [id, id])
        try catalog.addToAlbum(albumID: album, photoIDs: [id])
        #expect(try catalog.albumCount(id: album) == 1)
    }

    @Test func mediaFilterSplitsOneTable() throws {
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", mediaType: .photo))
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/b.mov", mediaType: .video))
        #expect(try catalog.items(scope: .all, filter: .all).count == 2)
        #expect(try catalog.items(scope: .all, filter: .photos).count == 1)
        #expect(try catalog.items(scope: .all, filter: .videos).first?.relPath == "Photos/b.mov")
    }

    @Test func smartAlbumIsJustASavedWhereClause() throws {
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.mov", mediaType: .video, duration: 120))
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/b.mov", mediaType: .video, duration: 3))
        let sa = try catalog.createSmartAlbum(name: "Long Videos", predicate: "p.media_type = 1 AND p.duration > 60")
        #expect(try catalog.items(scope: .smart(sa), filter: .all).map(\.relPath) == ["Photos/a.mov"])
    }

    @Test func itemsSortChronologically() throws {
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/late.jpg", capturedAt: 3000))
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/early.jpg", capturedAt: 1000))
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/mid.jpg", capturedAt: 2000))
        #expect(try catalog.items(scope: .all, filter: .all).map(\.displayName)
                == ["early.jpg", "mid.jpg", "late.jpg"])
    }

    @Test func dirStateRoundTrip() throws {
        try catalog.setDirState("Photos", mtime: 111)
        try catalog.setDirState("Photos/2019", mtime: 222)
        try catalog.setDirState("Photos", mtime: 333)
        #expect(try catalog.dirStates() == ["Photos": 333, "Photos/2019": 222])
        try catalog.removeDirStates(["Photos/2019"])
        #expect(try catalog.dirStates() == ["Photos": 333])
    }

    @Test func transactionRollsBackOnThrow() throws {
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg"))
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try self.catalog.transaction {
                try self.catalog.upsertPhoto(PhotoItem(relPath: "Photos/b.jpg"))
                throw Boom()
            }
        }
        #expect(try catalog.photoCount() == 1)
    }

    /// Nothing in the catalog may say where it currently lives.
    @Test func catalogStoresNothingAboutThisMachine() throws {
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", contentKey: "k"))
        try catalog.createAlbum(name: "Trip")
        try catalog.setDirState("Photos", mtime: 1)
        catalog.closeCleanly()

        let bytes = try Data(contentsOf: vault.catalogFile)
        let text = String(decoding: bytes, as: UTF8.self)
        for forbidden in [vault.root.path, NSUserName(), ProcessInfo.processInfo.hostName, "/Volumes/"] {
            #expect(text.contains(forbidden) == false,
                    "catalog leaked '\(forbidden)' — a copy would be machine-specific")
        }
    }

    /// Clean shutdown must checkpoint-truncate, so a copied catalog is one
    /// self-consistent file rather than a file plus a stale WAL.
    @Test func cleanShutdownLeavesNoWALContent() throws {
        for i in 0..<50 { try catalog.upsertPhoto(PhotoItem(relPath: "Photos/\(i).jpg")) }
        let wal = vault.catalogDir.appendingPathComponent("catalog.sqlite-wal")
        catalog.closeCleanly()

        #expect(vault.fileSize(wal) == 0, "WAL must be truncated on clean shutdown")

        let reopened = try Catalog(url: vault.catalogFile)
        #expect(try reopened.photoCount() == 50, "…without losing anything")
        #expect(try reopened.meta("clean_shutdown") == "1")
        reopened.closeCleanly()
    }
}

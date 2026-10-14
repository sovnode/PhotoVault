import Testing
import Foundation
import SQLite3
import CoreGraphics
import ImageIO
@testable import PhotoVaultCore

@Suite("Natural order")
struct NaturalSortTests {
    private func sorted(_ names: [String]) -> [String] {
        names.sorted { NaturalSort.key($0) < NaturalSort.key($1) }
    }

    /// The case that matters for scanned libraries: 4-digit numbers up to 9999,
    /// then 5 digits. Alphabetical order puts _10634 before _2343.
    @Test func numbersCompareAsNumbers() {
        #expect(sorted(["scan_10634_a.jpg", "scan_2343_a.jpg", "scan_0059_a.jpg"])
                == ["scan_0059_a.jpg", "scan_2343_a.jpg", "scan_10634_a.jpg"])
        #expect(sorted(["IMG_10.jpg", "IMG_9.jpg", "IMG_100.jpg"]) == ["IMG_9.jpg", "IMG_10.jpg", "IMG_100.jpg"])
    }

    @Test func caseAndAccentsAreIgnoredLikeFinder() {
        #expect(NaturalSort.key("Été.jpg") == NaturalSort.key("ete.jpg"))
        #expect(sorted(["b.jpg", "A.jpg", "c.jpg"]) == ["A.jpg", "b.jpg", "c.jpg"])
    }

    @Test func leadingZerosDontChangeTheValue() {
        #expect(NaturalSort.key("x_0059") == NaturalSort.key("x_59"))
    }

    @Test func folderAndNameBothSortNaturally() {
        let paths = ["Photos/2019/IMG_10.jpg", "Photos/2019/IMG_2.jpg", "Photos/10 Trip/a.jpg", "Photos/9 Trip/a.jpg"]
        #expect(paths.sorted { PhotoItem.sortName(of: $0) < PhotoItem.sortName(of: $1) }
                == ["Photos/9 Trip/a.jpg", "Photos/10 Trip/a.jpg", "Photos/2019/IMG_2.jpg", "Photos/2019/IMG_10.jpg"])
    }
}

@Suite("Default sort order")
struct PhotoOrderDefaultTests {
    @Test func aMostlyUndatedVaultDefaultsToFileName() {
        // A library of scans: 41 of 9,800 photos carry a date.
        #expect(PhotoOrder.defaultFor(datedCount: 41, total: 9_800) == .name)
    }

    @Test func aCameraLibraryDefaultsToDate() {
        #expect(PhotoOrder.defaultFor(datedCount: 9_000, total: 9_800) == .date)
        #expect(PhotoOrder.defaultFor(datedCount: 50, total: 100) == .date, "half dated is enough")
    }

    @Test func anEmptyVaultStartsOnDate() {
        #expect(PhotoOrder.defaultFor(datedCount: 0, total: 0) == .date)
    }
}

@Suite("Folder tree")
struct FolderTreeTests {
    @Test func nestsFoldersAndIncludesAncestorsWithoutPhotos() {
        let tree = FolderNode.tree(directCounts: ["Photos": 3, "Photos/2019/summer": 5, "Photos/2020": 2])
        #expect(tree.id == "Photos")
        #expect(tree.directCount == 3)
        #expect(tree.totalCount == 10)
        let kids = tree.children ?? []
        #expect(kids.map(\.name) == ["2019", "2020"])
        #expect(kids[0].directCount == 0, "2019 holds no photos itself but leads to some")
        #expect(kids[0].totalCount == 5)
        #expect(kids[0].children?.map(\.id) == ["Photos/2019/summer"])
        #expect(kids[1].children == nil, "a folder without subfolders has no disclosure arrow")
    }

    @Test func foldersAreInNaturalOrder() {
        let tree = FolderNode.tree(directCounts: ["Photos/Trip 10": 1, "Photos/Trip 9": 1, "Photos/Trip 100": 1])
        #expect(tree.children?.map(\.name) == ["Trip 9", "Trip 10", "Trip 100"])
    }

    @Test func aVaultWithEverythingInOneFolderHasNoSubfolders() {
        let tree = FolderNode.tree(directCounts: ["Photos": 9_800])
        #expect(tree.children == nil)
        #expect(tree.totalCount == 9_800)
    }
}

@Suite("Catalog v3", .serialized)
struct CatalogV3Tests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    /// Upgrading a real v2 catalog: data intact, new columns filled, a copy of
    /// the old file kept first.
    @Test func upgradingFromV2FillsTheNewColumnsAndKeepsABackup() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(vault.catalogFile.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, Catalog.schemaV1, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, Catalog.migrationV2, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, """
            INSERT INTO photo (rel_path, mtime, captured_at, favorite) VALUES
              ('Photos/2019/summer/IMG_10.jpg', 1000, 500, 1),
              ('Photos/scan_0059.jpg', 2000, 2000, 0),
              ('Photos/scan_0060.jpg', 3000, NULL, 0);
            PRAGMA user_version = 2;
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        #expect(try catalog.userVersion() == Catalog.schemaVersion)

        let rows = Dictionary(uniqueKeysWithValues: try catalog.items(scope: .all, filter: .all, sort: .name).map { ($0.relPath, $0) })
        #expect(rows.count == 3)
        #expect(rows["Photos/2019/summer/IMG_10.jpg"]?.favorite == true, "data came through")
        #expect(rows["Photos/2019/summer/IMG_10.jpg"]?.hasDate == true, "a capture date unlike the file date came from the photo")
        #expect(rows["Photos/scan_0059.jpg"]?.hasDate == false, "one equal to the file date can't be trusted")
        #expect(rows["Photos/scan_0060.jpg"]?.hasDate == false)
        #expect(try catalog.folderCounts() == ["Photos/2019/summer": 1, "Photos": 2])

        let backups = try FileManager.default.contentsOfDirectory(atPath: vault.catalogDir.appendingPathComponent("backups").path)
        #expect(backups.contains { $0.hasPrefix("catalog-v2-") })
    }

    @Test func aFolderShowsOnlyItsDirectContentsInNameOrder() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        for path in ["Photos/2019/IMG_10.jpg", "Photos/2019/IMG_9.jpg", "Photos/2019/summer/IMG_1.jpg", "Photos/top.jpg"] {
            try catalog.upsertPhoto(PhotoItem(relPath: path, mtime: 1))
        }
        #expect(try catalog.items(scope: .folder("Photos/2019"), filter: .all).map(\.displayName)
                == ["IMG_9.jpg", "IMG_10.jpg"], "subfolders' photos aren't included; names in natural order")
        #expect(try catalog.items(scope: .folder("Photos"), filter: .all).map(\.displayName) == ["top.jpg"])
    }

    @Test func nameOrderIsNaturalAndDateOrderPutsUndatedLast() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        let a = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/x_10634.jpg", mtime: 1))
        let b = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/x_2343.jpg", mtime: 1))
        _ = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/x_0059.jpg", mtime: 1))   // no date yet
        try catalog.setDetails(id: a, width: 1, height: 1, orientation: 1, capturedAt: 100, duration: nil)
        try catalog.setDetails(id: b, width: 1, height: 1, orientation: 1, capturedAt: 200, duration: nil)

        #expect(try catalog.items(scope: .all, filter: .all, sort: .name).map(\.displayName)
                == ["x_0059.jpg", "x_2343.jpg", "x_10634.jpg"])
        #expect(try catalog.items(scope: .all, filter: .all, sort: .date).map(\.displayName)
                == ["x_10634.jpg", "x_2343.jpg", "x_0059.jpg"], "by date, with the undated photo last")
    }

    @Test func relinkingMovesAPhotoToItsNewFolder() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", contentKey: "k"))
        try catalog.markMissing(ids: [id])
        try catalog.relink(missingID: id, toRelPath: "Photos/2021/a.jpg")
        #expect(try catalog.items(scope: .folder("Photos/2021"), filter: .all).map(\.id) == [id])
    }
}

@Suite("Store details and sorting", .serialized)
struct StoreDetailsTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    /// The bug from 1.0.0: re-reading a folder blanked the details of every
    /// photo already in it. This checks the end result — after adding a photo,
    /// the others' details are intact. (The details pass would also repair the
    /// damage within the same scan, so the cause itself is pinned by the
    /// catalog test `rescanOfAnUnchangedFileKeepsEverything`.)
    @Test func rescanningAChangedFolderKeepsTheOtherPhotosDetails() async throws {
        try vault.writeImage("a.jpg", size: 300, seed: 0.2)
        try vault.writeImage("b.jpg", size: 200, seed: 0.7)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)

        try vault.writeImage("c.jpg", size: 100, seed: 0.5)
        try await store.scan(full: true)

        let rows = try await store.items(scope: .all, filter: .all, sort: .name)
        #expect(rows.count == 3)
        for row in rows {
            #expect(row.width > 0 && row.height > 0, "\(row.displayName) lost its dimensions")
            #expect(row.capturedAt != nil, "\(row.displayName) lost its date")
        }
        #expect(rows.first { $0.displayName == "a.jpg" }?.width == 300)
        await store.close()
    }

    /// A catalog damaged by that bug repairs itself on the next scan, from the
    /// files, without rebuilding thumbnails.
    @Test func damagedDetailsAreReadBackFromTheFiles() async throws {
        try vault.writeImage("a.jpg", size: 320, seed: 0.3)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let before = try #require(try await store.items(scope: .all, filter: .all).first)
        await store.close()

        // What a pre-1.2.0 rescan left behind.
        let raw = try Catalog(url: vault.catalogFile)
        try raw.exec("UPDATE photo SET width = 0, height = 0, captured_at = NULL;")
        raw.closeCleanly()

        let reopened = try Store(root: vault.root)
        try await reopened.scan()
        let after = try #require(try await reopened.photo(id: before.id))
        #expect(after.width == 320 && after.height == 320)
        #expect(after.capturedAt != nil)
        #expect(after.thumbOff == before.thumbOff, "repaired from the header, without rebuilding the thumbnail")
        await reopened.close()
    }

    /// A file edited by another app gets a fresh thumbnail and fresh details.
    @Test func aFileEditedElsewhereIsRebuilt() async throws {
        let url = try vault.writeImage("a.jpg", size: 200, seed: 0.3)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let before = try #require(try await store.items(scope: .all, filter: .all).first)

        try TestVault.jpegData(size: 500, seed: 0.9).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        try await store.scan(full: true)

        let after = try #require(try await store.photo(id: before.id))
        #expect(after.width == 500, "new dimensions read from the edited file")
        #expect(after.thumbOff != before.thumbOff, "and a new thumbnail")
        #expect(after.contentKey != before.contentKey, "and a new content key")
        await store.close()
    }

    @Test func sortOrderDefaultsFromDatesAndRemembersAChoice() async throws {
        try vault.writeImage("a.jpg")   // synthetic: no capture date
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        #expect(try await store.sortOrder() == .name, "no photo carries a date, so file-name order")

        await store.setSortOrder(.date)
        #expect(try await store.sortOrder() == .date)
        await store.close()

        let reopened = try Store(root: vault.root)
        #expect(try await reopened.sortOrder() == .date, "the choice is kept in the vault's catalog")
        await reopened.close()
    }

    @Test func folderTreeReflectsTheVault() async throws {
        try vault.writeImage("top.jpg")
        try vault.writeImage("2019/a.jpg")
        try vault.writeImage("2019/summer/b.jpg")
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let tree = try await store.folderTree()
        #expect(tree.totalCount == 3)
        #expect(tree.children?.map(\.name) == ["2019"])
        #expect(tree.children?.first?.children?.map(\.name) == ["summer"])
        await store.close()
    }
}

@Suite("Where the sort setting applies")
struct SortScopeTests {
    @Test func everythingButAlbumsHasASort() {
        #expect(LibraryScope.all.followsSortOrder)
        #expect(LibraryScope.favorites.followsSortOrder)
        #expect(LibraryScope.trash.followsSortOrder)
        #expect(LibraryScope.smart(1).followsSortOrder)
        #expect(LibraryScope.folder("Photos/2019").followsSortOrder, "a folder can be sorted too")
        #expect(!LibraryScope.album(1).followsSortOrder, "an album has its own order")
    }

    @Test func theLibrarySharesOneSortAndEachSmartAlbumHasItsOwn() {
        for scope in [LibraryScope.all, .favorites, .trash, .folder("Photos"), .folder("Photos/2019/summer")] {
            #expect(scope.sortKey == "sort", "\(scope)")
        }
        #expect(LibraryScope.smart(3).sortKey == "sort.smart.3")
        #expect(LibraryScope.smart(4).sortKey != LibraryScope.smart(3).sortKey)
        #expect(LibraryScope.album(1).sortKey == nil)
    }

    @Test func directionsReadNaturally() {
        #expect(PhotoOrder.date.directionLabel(ascending: true) == "Oldest first")
        #expect(PhotoOrder.created.directionLabel(ascending: false) == "Newest first")
        #expect(PhotoOrder.name.directionLabel(ascending: true) == "A to Z")
        #expect(PhotoOrder.name.directionLabel(ascending: false) == "Z to A")
        #expect(PhotoOrder.allCases.map(\.label) == ["Date Taken", "Date Created", "File Name"])
    }
}

@Suite("Sorting by date created, and either way round", .serialized)
struct SortDirectionTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    @Test func everyOrderRunsBothWaysWithUndatedPhotosLast() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        // Created in a different order from their names and their dates taken.
        let a = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/2019/a_10.jpg", mtime: 1, createdAt: 300))
        let b = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/2019/a_9.jpg", mtime: 1, createdAt: 100))
        _ = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/2019/a_8.jpg", mtime: 1))   // no dates at all
        try catalog.setDetails(id: a, width: 1, height: 1, orientation: 1, capturedAt: 100, duration: nil)
        try catalog.setDetails(id: b, width: 1, height: 1, orientation: 1, capturedAt: 200, duration: nil)
        func names(_ scope: LibraryScope, _ sort: PhotoOrder, _ ascending: Bool) throws -> [String] {
            try catalog.items(scope: scope, filter: .all, sort: sort, ascending: ascending).map(\.displayName)
        }

        #expect(try names(.all, .created, true) == ["a_9.jpg", "a_10.jpg", "a_8.jpg"], "oldest first, the undated last")
        #expect(try names(.all, .created, false) == ["a_10.jpg", "a_9.jpg", "a_8.jpg"], "newest first, the undated still last")
        #expect(try names(.all, .date, false) == ["a_9.jpg", "a_10.jpg", "a_8.jpg"])
        #expect(try names(.all, .name, true) == ["a_8.jpg", "a_9.jpg", "a_10.jpg"])
        #expect(try names(.all, .name, false) == ["a_10.jpg", "a_9.jpg", "a_8.jpg"], "Z to A, still natural")

        // A folder follows the sort like All Media, and only shows its own photos.
        #expect(try names(.folder("Photos/2019"), .created, false) == ["a_10.jpg", "a_9.jpg", "a_8.jpg"])
        #expect(try names(.folder("Photos/2019"), .name, false) == ["a_10.jpg", "a_9.jpg", "a_8.jpg"])
    }

    @Test func aScanRecordsWhenEachFileWasCreated() async throws {
        let url = try vault.writeImage("2019/a.jpg")
        let created = try #require(try url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let row = try #require(try await store.items(scope: .all, filter: .all).first)
        #expect(abs((row.createdAt ?? 0) - created.timeIntervalSince1970) < 1)
        await store.close()
    }

    @Test func anOlderCatalogLearnsItsFilesCreationDates() throws {
        let url = try vault.writeImage("old.jpg")
        let created = try #require(try url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        do {
            let catalog = try Catalog(url: vault.catalogFile)
            try catalog.upsertPhoto(PhotoItem(relPath: "Photos/old.jpg", mtime: 1))
            try catalog.upsertPhoto(PhotoItem(relPath: "Photos/gone.jpg", mtime: 1))
            catalog.closeCleanly()
        }
        // As a catalog from before 1.4.0: no creation dates.
        var db: OpaquePointer?
        try #require(sqlite3_open(vault.catalogFile.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, "UPDATE photo SET created_at = NULL; DROP INDEX idx_photo_created; PRAGMA user_version = 4;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        // (The migration adds the column again: drop it first, as v4 had none.)
        try #require(sqlite3_open(vault.catalogFile.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, "ALTER TABLE photo DROP COLUMN created_at;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        #expect(try catalog.userVersion() == 5)
        let rows = Dictionary(uniqueKeysWithValues: try catalog.items(scope: .all, filter: .all).map { ($0.relPath, $0) })
        #expect(abs((rows["Photos/old.jpg"]?.createdAt ?? 0) - created.timeIntervalSince1970) < 1)
        #expect(rows["Photos/gone.jpg"]?.createdAt == nil, "a file that isn't there has none yet")
    }

    @Test func theLibraryAndEachSmartAlbumRememberTheirOwnSort() async throws {
        try vault.writeImage("a.jpg")
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let smart = try await store.createSmartAlbum(name: "Sky", predicate: "1")
        let other = try await store.createSmartAlbum(name: "Sea", predicate: "1")

        let start = try #require(try await store.sortSetting(for: .all))
        #expect(start.ascending, "oldest first, or A to Z, to begin with")
        #expect(try await store.sortSetting(for: .album(1)) == nil, "an album keeps its own order")

        await store.setSortSetting(SortSetting(order: .created, ascending: false), for: .folder("Photos/2019"))
        for scope in [LibraryScope.all, .folder("Photos"), .favorites, .trash] {
            #expect(try await store.sortSetting(for: scope) == SortSetting(order: .created, ascending: false),
                    "chosen in one folder, the same in \(scope)")
        }
        #expect(try await store.sortSetting(for: .smart(smart)) == SortSetting(order: .created, ascending: false),
                "a smart album starts from the library's")

        await store.setSortSetting(SortSetting(order: .name, ascending: true), for: .smart(smart))
        #expect(try await store.sortSetting(for: .smart(smart)) == SortSetting(order: .name, ascending: true))
        #expect(try await store.sortSetting(for: .all) == SortSetting(order: .created, ascending: false), "the library's is untouched")
        #expect(try await store.sortSetting(for: .smart(other)) == SortSetting(order: .created, ascending: false), "another smart album has its own")
        await store.close()

        let reopened = try Store(root: vault.root)
        #expect(try await reopened.sortSetting(for: .smart(smart)) == SortSetting(order: .name, ascending: true), "kept in the vault's catalog")
        try await reopened.deleteSmartAlbum(smart)
        #expect(await reopened.setting("sort.smart.\(smart).order") == nil, "a deleted smart album's sort goes with it")
        await reopened.close()
    }
}

/// What the properties panel reads from a photo's header.
@Suite("Photo metadata")
struct PhotoMetadataTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    private func photo(_ name: String, properties: [CFString: Any]) throws -> URL {
        let url = vault.photos.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: vault.photos, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    @Test func readsCameraExposureAndLocation() throws {
        let url = try photo("a.jpg", properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Fujifilm", kCGImagePropertyTIFFModel: "X-T4"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 1.0 / 250,
                kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifFocalLength: 18.5,
                kCGImagePropertyExifLensModel: "XF18mmF2 R",
            ],
            // A public landmark, not anyone's photo.
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ])
        let m = PhotoMetadata.read(url: url)
        #expect(m.cameraDescription == "Fujifilm X-T4")
        #expect(m.lens == "XF18mmF2 R")
        #expect(m.exposureDescription == "ƒ/2.8 · 1/250 s · ISO 200 · 18.5 mm")
        #expect(m.coordinatesDescription == "51.5007° N, 0.1246° W", "west and south are negative, shown with letters")
        #expect(m.longitude! < 0)
    }

    @Test func doesntRepeatTheMakerInTheCameraName() throws {
        var m = PhotoMetadata()
        m.cameraMake = "Canon"
        m.cameraModel = "Canon EOS R5"
        #expect(m.cameraDescription == "Canon EOS R5")
    }

    @Test func aPhotoWithoutMetadataHasNothingToShow() throws {
        let m = PhotoMetadata.read(url: try photo("plain.jpg", properties: [:]))
        #expect(m.cameraDescription == nil)
        #expect(m.exposureDescription == nil)
        #expect(m.coordinatesDescription == nil)
    }

    @Test func dimensionsFollowOrientation() {
        #expect(PhotoItem(relPath: "x", width: 4000, height: 3000, orientation: 1).orientedSize == (4000, 3000))
        #expect(PhotoItem(relPath: "x", width: 4000, height: 3000, orientation: 6).orientedSize == (3000, 4000),
                "a quarter turn swaps width and height")
    }

    @Test func albumNamesForAPhoto() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg"))
        let trip = try catalog.createAlbum(name: "Trip")
        let best = try catalog.createAlbum(name: "Best")
        _ = try catalog.createAlbum(name: "Other")
        try catalog.addToAlbum(albumID: trip, photoIDs: [id])
        try catalog.addToAlbum(albumID: best, photoIDs: [id])
        #expect(try catalog.albumNames(containing: id) == ["Trip", "Best"])
    }
}

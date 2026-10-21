import Testing
import Foundation
import SQLite3
@testable import PhotoVaultCore

@Suite("Trash", .serialized)
struct TrashTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    private func scannedStore(_ names: [String]) async throws -> (Store, [String: PhotoItem]) {
        for (i, n) in names.enumerated() { try vault.writeImage(n, seed: Double(i) / Double(max(names.count, 1))) }
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let items = try await store.items(scope: .all, filter: .all)
        return (store, Dictionary(uniqueKeysWithValues: items.map { ($0.displayName, $0) }))
    }

    @Test func trashedPhotoLeavesEveryOtherView() async throws {
        let (store, byName) = try await scannedStore(["a.jpg", "b.jpg"])
        let a = try #require(byName["a.jpg"])
        try await store.setFavorite(true, for: [a.id])
        let album = try await store.createAlbum(named: "Trip")
        try await store.addToAlbum(album, photoIDs: [a.id])
        let smart = try await store.createSmartAlbum(name: "Everything", predicate: "1")

        try await store.moveToTrash([a.id])

        #expect(try await store.items(scope: .all, filter: .all).map(\.displayName) == ["b.jpg"])
        #expect(try await store.items(scope: .favorites, filter: .all).isEmpty)
        #expect(try await store.items(scope: .album(album), filter: .all).isEmpty)
        #expect(try await store.items(scope: .smart(smart), filter: .all).map(\.displayName) == ["b.jpg"],
                "a saved predicate must not see trashed rows either")
        #expect(try await store.items(scope: .trash, filter: .all).map(\.displayName) == ["a.jpg"])
        #expect(try await store.photoCount() == 1)
        #expect(try await store.trashCount() == 1)
        #expect(FileManager.default.fileExists(atPath: vault.photos.appendingPathComponent("a.jpg").path),
                "moving to the Trash must not touch the file")
        await store.close()
    }

    @Test func trashRemovesAlbumMembershipsForGood() async throws {
        let (store, byName) = try await scannedStore(["a.jpg"])
        let a = try #require(byName["a.jpg"])
        let one = try await store.createAlbum(named: "One")
        let two = try await store.createAlbum(named: "Two")
        try await store.addToAlbum(one, photoIDs: [a.id])
        try await store.addToAlbum(two, photoIDs: [a.id])
        try await store.setFavorite(true, for: [a.id])

        try await store.moveToTrash([a.id])
        #expect(try await store.albumCount(one) == 0)
        #expect(try await store.albumCount(two) == 0)

        try await store.restoreFromTrash([a.id])
        #expect(try await store.items(scope: .all, filter: .all).count == 1, "Put Back returns it to the library")
        #expect(try await store.albumCount(one) == 0, "albums were left when it was trashed, as specified")
        #expect(try await store.items(scope: .favorites, filter: .all).count == 1, "the favorite flag survives the round trip")
        await store.close()
    }

    @Test func aRescanDoesNotResurrectATrashedPhoto() async throws {
        let (store, byName) = try await scannedStore(["a.jpg", "b.jpg"])
        try await store.moveToTrash([try #require(byName["a.jpg"]).id])

        try await store.scan(full: true)

        #expect(try await store.trashCount() == 1)
        #expect(try await store.photoCount() == 1)
        await store.close()
    }

    @Test func emptyTrashDeletesOnlyTrashedOriginals() async throws {
        let (store, byName) = try await scannedStore(["a.jpg", "b.jpg", "2019/c.jpg"])
        try await store.moveToTrash([try #require(byName["a.jpg"]).id, try #require(byName["c.jpg"]).id])

        let result = try await store.emptyTrash()

        #expect(result.deleted == 2)
        #expect(result.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: vault.photos.appendingPathComponent("a.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: vault.photos.appendingPathComponent("2019/c.jpg").path))
        #expect(FileManager.default.fileExists(atPath: vault.photos.appendingPathComponent("b.jpg").path),
                "a photo that wasn't in the Trash must be untouched")
        #expect(try await store.trashCount() == 0)

        // And a later scan must not bring anything back, or report anything missing.
        try await store.scan(full: true)
        #expect(try await store.items(scope: .all, filter: .all).map(\.displayName) == ["b.jpg"])
        await store.close()
    }

    @Test func emptyTrashCopesWithAFileThatIsAlreadyGone() async throws {
        let (store, byName) = try await scannedStore(["a.jpg"])
        try await store.moveToTrash([try #require(byName["a.jpg"]).id])
        try FileManager.default.removeItem(at: vault.photos.appendingPathComponent("a.jpg"))

        let result = try await store.emptyTrash()
        #expect(result.deleted == 1)
        #expect(result.problems.isEmpty)
        #expect(try await store.trashCount() == 0)
        await store.close()
    }

    /// If the original can't be deleted, its row stays in the Trash. Dropping
    /// the row anyway would leave a file the next scan quietly re-adds.
    @Test func aFailedDeleteIsReportedAndStaysInTheTrash() async throws {
        let (store, byName) = try await scannedStore(["locked/a.jpg"])
        try await store.moveToTrash([try #require(byName["a.jpg"]).id])
        let folder = vault.photos.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let result = try await store.emptyTrash()

        #expect(result.deleted == 0)
        #expect(result.problems.count == 1)
        #expect(try await store.trashCount() == 1)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.jpg").path))
        await store.close()
    }

    /// The v1 → v2 upgrade on a catalog that already holds a library: data
    /// survives, nothing is trashed, and a copy of the old file is kept first.
    @Test func upgradingAnExistingCatalogBacksItUpFirst() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(vault.catalogFile.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, Catalog.schemaV1, nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "INSERT INTO photo (rel_path, favorite) VALUES ('Photos/old.jpg', 1); PRAGMA user_version = 1;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }

        #expect(try catalog.userVersion() == Catalog.schemaVersion)
        let rows = try catalog.items(scope: .all, filter: .all)
        #expect(rows.map(\.relPath) == ["Photos/old.jpg"], "the library came through")
        #expect(rows.first?.trashed == false)
        #expect(rows.first?.favorite == true)

        let backups = try FileManager.default.contentsOfDirectory(
            at: vault.catalogDir.appendingPathComponent("backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(backup.lastPathComponent.hasPrefix("catalog-v1-"))
        var copy: OpaquePointer?
        #expect(sqlite3_open(backup.path, &copy) == SQLITE_OK)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(copy, "SELECT COUNT(*) FROM photo;", -1, &stmt, nil)
        #expect(sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) == 1, "the backup holds the old library")
        sqlite3_finalize(stmt)
        sqlite3_close(copy)
    }

    @Test func aBrandNewCatalogNeedsNoBackup() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        catalog.closeCleanly()
        #expect(!FileManager.default.fileExists(atPath: vault.catalogDir.appendingPathComponent("backups").path))
    }
}

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

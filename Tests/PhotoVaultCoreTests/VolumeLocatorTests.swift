import Testing
import Foundation
@testable import PhotoVaultCore

@Suite("Volume locator")
struct VolumeLocatorTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    private func realPath(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    @Test func resolvesRootFromAppSittingBesideCatalog() throws {
        let app = vault.root.appendingPathComponent("PhotoVault.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(realPath(try VolumeLocator.resolveRoot(from: app)) == realPath(vault.root))
    }

    @Test func walksUpSeveralLevels() throws {
        let deep = vault.root.appendingPathComponent("a/b/c/Thing.app")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        #expect(realPath(try VolumeLocator.resolveRoot(from: deep)) == realPath(vault.root))
    }

    /// Translocation has to be checked first: the app is running from a random
    /// read-only copy with no vault anywhere near it, so the walk would
    /// otherwise report "volume not found" and send the user hunting.
    @Test func translocationIsDetectedBeforeAnythingElse() throws {
        let fake = URL(fileURLWithPath: "/private/var/folders/xx/AppTranslocation/ABC/d/PhotoVault.app")
        #expect(throws: VaultError.translocated) {
            _ = try VolumeLocator.resolveRoot(from: fake)
        }
        #expect(VaultError.translocated.errorDescription?.contains("quarantine") == true,
                "the message has to name the fix")
    }

    @Test func missingCatalogIsAClearError() throws {
        let elsewhere = TestVault.sandbox.appendingPathComponent("no-vault-\(UUID().uuidString)/App.app")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere.deletingLastPathComponent()) }
        #expect(throws: VaultError.volumeNotFound) {
            _ = try VolumeLocator.resolveRoot(from: elsewhere)
        }
    }

    @Test func bootstrapCreatesScaffoldingBesideAPhotosFolder() throws {
        let bare = TestVault.sandbox.appendingPathComponent("bare-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bare.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bare) }

        let app = bare.appendingPathComponent("PhotoVault.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let root = try VolumeLocator.resolveOrBootstrap(from: app)

        #expect(realPath(root) == realPath(bare))
        for expected in [".catalog", ".catalog/tmp", "Photos", ".metadata_never_index"] {
            #expect(FileManager.default.fileExists(atPath: bare.appendingPathComponent(expected).path),
                    "missing \(expected)")
        }
    }

    /// Spotlight indexing the vault would put an index of the user's filenames
    /// in /.Spotlight-V100 — off-volume as far as a copied bundle is concerned,
    /// and readable without the app.
    @Test func spotlightOptOutMarkerIsCreated() {
        #expect(FileManager.default.fileExists(
            atPath: vault.root.appendingPathComponent(".metadata_never_index").path))
    }

    @Test func scaffoldingIsIdempotent() throws {
        try VolumeLocator.ensureScaffolding(at: vault.root)
        try VolumeLocator.ensureScaffolding(at: vault.root)
        #expect(FileManager.default.fileExists(atPath: vault.catalogDir.path))
    }
}

@Suite("Content key")
struct ContentKeyTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    @Test func sameContentSameKey() throws {
        let a = try vault.writeImage("a.jpg", size: 100, seed: 0.5)
        let b = try vault.writeImage("nested/copy.jpg", size: 100, seed: 0.5)
        #expect(ContentKey.compute(url: a, fileSize: Int64(vault.fileSize(a)))
                == ContentKey.compute(url: b, fileSize: Int64(vault.fileSize(b))),
                "a file that moved must hash the same, or relinking can't work")
    }

    @Test func differentContentDifferentKey() throws {
        let a = try vault.writeImage("a.jpg", size: 100, seed: 0.1)
        let b = try vault.writeImage("b.jpg", size: 100, seed: 0.9)
        #expect(ContentKey.compute(url: a, fileSize: 1) != ContentKey.compute(url: b, fileSize: 1))
    }

    @Test func sizeIsPartOfTheKey() throws {
        let a = try vault.writeImage("a.jpg")
        #expect(ContentKey.compute(url: a, fileSize: 1) != ContentKey.compute(url: a, fileSize: 2))
    }

    @Test func missingFileYieldsNoKey() {
        #expect(ContentKey.compute(url: URL(fileURLWithPath: "/nope/nothing.jpg"), fileSize: 0) == nil)
    }

    @Test func keySaysNothingAboutLocation() throws {
        let a = try vault.writeImage("a.jpg")
        let key = try #require(ContentKey.compute(url: a, fileSize: 10))
        #expect(key.contains("/") == false)
        #expect(key.contains(vault.root.lastPathComponent) == false)
    }

    /// Only the first 64 KB is hashed, which is the deliberate trade: cheap
    /// enough to run during a scan, and distinctive enough for real photos,
    /// which differ in their headers.
    @Test func onlyTheHeadIsHashed() throws {
        try FileManager.default.createDirectory(at: vault.photos, withIntermediateDirectories: true)
        let head = Data((0..<ContentKey.probeBytes).map { UInt8($0 % 251) })
        let a = vault.photos.appendingPathComponent("a.bin")
        let b = vault.photos.appendingPathComponent("b.bin")
        try head.write(to: a)
        try (head + Data(repeating: 0xEE, count: 4096)).write(to: b)

        // Same declared size puts the comparison entirely on the digest, and
        // the two files differ only past the 64 KB probe window.
        #expect(ContentKey.compute(url: a, fileSize: 1) == ContentKey.compute(url: b, fileSize: 1))

        // Sanity check that the fixture would have caught a real difference.
        var differentHead = head
        differentHead[0] = differentHead[0] &+ 1
        let c = vault.photos.appendingPathComponent("c.bin")
        try differentHead.write(to: c)
        #expect(ContentKey.compute(url: a, fileSize: 1) != ContentKey.compute(url: c, fileSize: 1))
    }
}

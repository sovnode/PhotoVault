import Testing
import Foundation
@testable import PhotoVaultCore

@Suite("Scanner")
struct ScannerTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    @Test func fullScanFindsMediaRecursively() throws {
        try vault.writeImage("a.jpg")
        try vault.writeImage("2019/b.jpg")
        try vault.writeImage("2019/summer/c.jpg")
        try vault.writeJunk("2019/notes.txt")

        let result = Scanner.fullScan(root: vault.root)

        #expect(Set(result.files.map(\.relPath))
                == ["Photos/a.jpg", "Photos/2019/b.jpg", "Photos/2019/summer/c.jpg"])
        #expect(Set(result.dirs.keys) == ["Photos", "Photos/2019", "Photos/2019/summer"])
        #expect(result.isFull)
    }

    @Test func mediaTypeComesFromExtension() throws {
        try vault.writeImage("a.jpg")
        try vault.writeJunk("b.mov")
        try vault.writeJunk("c.mkv")
        let byPath = Dictionary(uniqueKeysWithValues: Scanner.fullScan(root: vault.root).files.map { ($0.relPath, $0.type) })
        #expect(byPath["Photos/a.jpg"] == .photo)
        #expect(byPath["Photos/b.mov"] == .video)
        #expect(byPath["Photos/c.mkv"] == .video, "unopenable containers still get a row, badged later")
    }

    @Test func skipsHiddenAndAppleDoubleFiles() throws {
        try vault.writeImage("a.jpg")
        try vault.writeImage("._a.jpg")
        try vault.writeImage(".hidden.jpg")
        #expect(Scanner.fullScan(root: vault.root).files.map(\.relPath) == ["Photos/a.jpg"])
    }

    /// The whole point of the fast scan: an unchanged directory is not walked.
    @Test func incrementalSkipsUnchangedDirectories() throws {
        try vault.writeImage("2019/b.jpg")
        let full = Scanner.fullScan(root: vault.root)

        let incremental = Scanner.incrementalScan(root: vault.root, knownDirs: full.dirs)

        #expect(incremental.enumeratedDirs.isEmpty, "nothing moved, so nothing should be enumerated")
        #expect(incremental.files.isEmpty)
        #expect(Set(incremental.dirs.keys) == Set(full.dirs.keys), "but the state is carried forward")
    }

    @Test func incrementalFindsANewFile() throws {
        try vault.writeImage("2019/b.jpg")
        let full = Scanner.fullScan(root: vault.root)

        try vault.writeImage("2019/new.jpg")
        let result = Scanner.incrementalScan(root: vault.root, knownDirs: full.dirs)

        #expect(result.enumeratedDirs.contains("Photos/2019"))
        #expect(result.files.map(\.relPath).contains("Photos/2019/new.jpg"))
        #expect(result.enumeratedDirs.contains("Photos") == false,
                "the parent's mtime didn't move, so it stays untouched")
    }

    /// A brand-new subtree isn't in dir_state at all, so it has to be walked in
    /// full — the parent's mtime change is the only hint it exists.
    @Test func incrementalWalksAWholeNewSubtree() throws {
        try vault.writeImage("a.jpg")
        let full = Scanner.fullScan(root: vault.root)

        try vault.writeImage("2020/deep/x.jpg")
        let result = Scanner.incrementalScan(root: vault.root, knownDirs: full.dirs)

        #expect(result.files.map(\.relPath).contains("Photos/2020/deep/x.jpg"))
        #expect(result.dirs.keys.contains("Photos/2020/deep"))
    }

    @Test func incrementalDetectsDeletionInsideAWalkedDirectory() throws {
        try vault.writeImage("a.jpg")
        try vault.writeImage("b.jpg")
        let full = Scanner.fullScan(root: vault.root)

        try FileManager.default.removeItem(at: vault.photos.appendingPathComponent("b.jpg"))
        let result = Scanner.incrementalScan(root: vault.root, knownDirs: full.dirs)

        #expect(result.enumeratedDirs.contains("Photos"))
        #expect(result.files.map(\.relPath) == ["Photos/a.jpg"])
    }

    @Test func vanishedDirectoryIsReported() throws {
        try vault.writeImage("gone/a.jpg")
        let full = Scanner.fullScan(root: vault.root)

        try FileManager.default.removeItem(at: vault.photos.appendingPathComponent("gone"))
        let result = Scanner.incrementalScan(root: vault.root, knownDirs: full.dirs)

        #expect(result.vanishedDirs == ["Photos/gone"])
    }

    @Test func emptyDirStateFallsBackToFullScan() throws {
        try vault.writeImage("a.jpg")
        let result = Scanner.incrementalScan(root: vault.root, knownDirs: [:])
        #expect(result.isFull)
        #expect(result.files.count == 1)
    }

    @Test func emptyVaultScansCleanly() throws {
        let result = Scanner.fullScan(root: vault.root)
        #expect(result.files.isEmpty)
        #expect(Set(result.dirs.keys) == ["Photos"], "the Photos directory itself is still recorded")
    }
}

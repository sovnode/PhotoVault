import Testing
import Foundation
@testable import PhotoVaultCore

/// No copies of the user's pixels outside the volume.
///
/// These cover the part that is deterministic in-process. The part that isn't —
/// what Quick Look, `mediaplaybackd` and `VTDecoderXPCService` write *on the
/// app's behalf*, out of process — can only be measured while the real app
/// runs, which is what `Scripts/verify-containment.sh` is for.
@Suite("Containment", .serialized)
struct ContainmentTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    @Test func aFullScanWritesNothingIntoTheSystemTempDirectory() async throws {
        try vault.writeImage("a.jpg", size: 1200, seed: 0.2)
        try vault.writeImage("2019/b.jpg", size: 1200, seed: 0.7)
        try await VideoFixture.write(to: vault.photos.appendingPathComponent("clip.mp4"), seconds: 2)

        let before = tempSnapshot()
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        await store.close()
        let created = tempSnapshot().subtracting(before)

        #expect(created.isEmpty, "scan left files outside the vault: \(created.sorted())")
    }

    @Test func thumbnailEncodingProducesBytesNotFiles() throws {
        let url = try vault.writeImage("a.jpg", size: 900)
        let before = tempSnapshot()
        for _ in 0..<5 { _ = try Thumbnailer.makePhotoThumb(url: url) }
        #expect(tempSnapshot().subtracting(before).isEmpty,
                "encoding must go to CFMutableData, never through a temp file")
    }

    /// Every byte the app persists has to land under `.catalog/`, and the
    /// originals must come back untouched.
    @Test func everythingWrittenLandsInsideTheVaultAndOriginalsAreUnchanged() async throws {
        try vault.writeImage("a.jpg", seed: 0.5)
        let original = vault.photos.appendingPathComponent("a.jpg")
        let originalBytes = try Data(contentsOf: original)
        let originalMtime = try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date

        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        await store.close()

        #expect(try Data(contentsOf: original) == originalBytes, "an original was modified")
        #expect(try FileManager.default.attributesOfItem(atPath: original.path)[.modificationDate] as? Date == originalMtime,
                "even the mtime must be left alone")

        let written = try FileManager.default.contentsOfDirectory(atPath: vault.catalogDir.path)
        #expect(written.contains("catalog.sqlite"))
        #expect(written.contains("thumbs.pack"))
        #expect(written.contains("tmp"))
    }

    @Test func sqliteTempDirPointsInsideTheVault() throws {
        let catalog = try Catalog(url: vault.catalogFile, tmpDir: vault.catalogDir.appendingPathComponent("tmp"))
        defer { catalog.closeCleanly() }
        let tmpDir = String(cString: getenv("SQLITE_TMPDIR"))
        #expect(tmpDir.hasPrefix(vault.root.path), "sort spills would land off-volume: \(tmpDir)")
    }

    /// Snapshot of the system temp directory, minus the test vaults that
    /// legitimately live there.
    private func tempSnapshot() -> Set<String> {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let ours = TestVault.sandbox.path
        guard let e = FileManager.default.enumerator(at: tmp, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: Set<String> = []
        for case let url as URL in e {
            let p = url.path
            if p.hasPrefix(ours) { e.skipDescendants(); continue }
            out.insert(p)
        }
        return out
    }
}

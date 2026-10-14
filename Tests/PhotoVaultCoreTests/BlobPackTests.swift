import Testing
import Foundation
@testable import PhotoVaultCore

@Suite("Blob pack")
struct BlobPackTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    @Test func freshPackStartsAfterHeader() throws {
        let pack = try BlobPack(url: vault.packFile)
        #expect(pack.currentTail == 16, "a new pack is just its 16-byte header")
    }

    @Test func appendAndReadRoundTrip() throws {
        let pack = try BlobPack(url: vault.packFile)
        let blobs = (0..<20).map { Data(repeating: UInt8($0), count: 100 + $0 * 7) }
        var coords: [(offset: Int64, length: Int)] = []
        for b in blobs { coords.append(try pack.append(b)) }

        for (i, c) in coords.enumerated() {
            #expect(try pack.read(offset: c.offset, length: c.length) == blobs[i])
        }
        // Blobs sit back to back, which is the whole point: one file open
        // instead of thousands, and no band-file scatter inside the bundle.
        for i in 1..<coords.count {
            #expect(coords[i].offset == coords[i-1].offset + Int64(coords[i-1].length))
        }
    }

    @Test func reopenKeepsTailAndData() throws {
        var coord: (offset: Int64, length: Int) = (0, 0)
        do {
            let pack = try BlobPack(url: vault.packFile)
            coord = try pack.append(Data("hello pack".utf8))
        }
        let reopened = try BlobPack(url: vault.packFile)
        let read = try reopened.read(offset: coord.offset, length: coord.length)
        #expect(String(data: read, encoding: .utf8) == "hello pack")
        #expect(reopened.currentTail == coord.offset + Int64(coord.length))
    }

    @Test func rejectsForeignFile() throws {
        try Data("not a pack at all".utf8).write(to: vault.packFile)
        #expect(throws: (any Error).self) { _ = try BlobPack(url: self.vault.packFile) }
    }

    /// The recovery half of the write-ordering contract: bytes appended whose
    /// row never committed are unreachable, and truncating to the highest
    /// offset the catalog knows about reclaims them.
    @Test func truncateOrphansDropsUncommittedTail() throws {
        let pack = try BlobPack(url: vault.packFile)
        let kept = try pack.append(Data(repeating: 1, count: 500))
        _ = try pack.append(Data(repeating: 2, count: 900))   // the "crash" residue

        let catalogTail = kept.offset + Int64(kept.length)
        try pack.truncateOrphans(catalogTail: catalogTail)

        #expect(pack.currentTail == catalogTail)
        #expect(try pack.read(offset: kept.offset, length: kept.length).count == 500)
        #expect(throws: VaultError.shortRead) {
            _ = try pack.read(offset: catalogTail, length: 900)
        }
    }

    @Test func truncateNeverEatsTheHeader() throws {
        let pack = try BlobPack(url: vault.packFile)
        _ = try pack.append(Data(repeating: 3, count: 64))
        try pack.truncateOrphans(catalogTail: 0)   // an empty catalog
        #expect(pack.currentTail == 16, "the header must survive an empty catalog")

        // And the file is still openable as a pack afterwards.
        #expect(throws: Never.self) { _ = try BlobPack(url: self.vault.packFile) }
    }

    @Test func rejectsCoordinatesInsideTheHeader() throws {
        let pack = try BlobPack(url: vault.packFile)
        #expect(throws: (any Error).self) { _ = try pack.read(offset: 0, length: 4) }
        #expect(throws: (any Error).self) { _ = try pack.read(offset: 16, length: 0) }
    }

    /// A read past the end of the file must surface as a catchable error, not a
    /// crash — that is the entire reason the pack is `pread` rather than `mmap`.
    @Test func readPastEndOfFileIsCatchable() throws {
        let pack = try BlobPack(url: vault.packFile)
        let c = try pack.append(Data(repeating: 7, count: 32))
        #expect(throws: VaultError.shortRead) {
            _ = try pack.read(offset: c.offset, length: 10_000)
        }
    }
}

import Testing
import Foundation
@testable import PhotoVaultCore

@Suite("pv-prefix-keywords", .serialized)
struct KeywordPrefixerTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    func url(_ name: String) -> URL { vault.photos.appendingPathComponent(name) }

    /// A scanned vault, closed again as the command needs it.
    func scannedVault() async throws {
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        await store.close()
    }

    func mark() throws -> KeywordPrefixer.Survey {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        let prefixer = try KeywordPrefixer(prefix: "ext", label: "OtherTagger")
        let survey = try prefixer.survey(root: vault.root, catalog: catalog)
        #expect(prefixer.apply(survey.toMark, root: vault.root, catalog: catalog).isEmpty)
        return survey
    }

    func sources(_ store: Store, _ name: String) async throws -> Set<String> {
        let item = try #require(try await store.items(scope: .all, filter: .all).first { $0.relPath == "Photos/\(name)" })
        return Set(try await store.tags(for: item.id).map { "\($0.source):\($0.name)" })
    }

    @Test func marksOwnKeywordsInTheCatalogAndLeavesThePhotoAlone() async throws {
        try vault.writeTaggedImage("a.jpg", keywords: ["child", " sea ", "jt:smile", "Paris: Eiffel", "x:y"],
                                   records: [ToolRecord(prefix: "jt", tool: "JoyTag", version: "6b7f163")])
        try await scannedVault()
        let bytes = try Data(contentsOf: url("a.jpg"))

        let survey = try mark()

        #expect(survey.toMark.count == 1 && survey.keywords == 4)
        #expect(try Data(contentsOf: url("a.jpg")) == bytes, "the photo isn't touched")
        let store = try Store(root: vault.root)
        #expect(try await sources(store, "a.jpg") == ["ext:child", "ext:sea", "jt:smile", "ext:Paris: Eiffel", "ext:x:y"])
        let item = try #require(try await store.items(scope: .all, filter: .all).first)
        let record = try #require(try await store.classifications(for: item.id).first { $0.classifier == "ext" })
        #expect(record.label == "OtherTagger" && !record.inFile)
        await store.close()
    }

    @Test func theAppSeesNothingToRedo() async throws {
        try vault.writeTaggedImage("a.jpg", keywords: ["child", "sea"], seed: 0.3)
        try vault.writeTaggedImage("b.jpg", keywords: ["dog"], seed: 0.6)
        try await scannedVault()
        var store = try Store(root: vault.root)
        let before = try await store.items(scope: .all, filter: .all)
        await store.close()

        _ = try mark()

        store = try Store(root: vault.root)
        try await store.scan(full: true)
        let after = try await store.items(scope: .all, filter: .all)
        for (a, b) in zip(before.sorted { $0.id < $1.id }, after.sorted { $0.id < $1.id }) {
            #expect(a.thumbOff == b.thumbOff && a.fileSize == b.fileSize && a.mtime == b.mtime, "\(a.relPath) unchanged")
        }
        #expect(try await sources(store, "a.jpg") == ["ext:child", "ext:sea"])
        #expect(try await store.tagCounts().first { $0.key == "child" }?.sources == ["ext"])
        await store.close()
    }

    @Test func aSecondRunChangesNothing() async throws {
        try vault.writeTaggedImage("a.jpg", keywords: ["child"])
        try await scannedVault()
        _ = try mark()
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        let again = try KeywordPrefixer(prefix: "ext", label: "OtherTagger").survey(root: vault.root, catalog: catalog)
        #expect(again.toMark.isEmpty && again.alreadyMarked == 1)
    }

    /// The mark lives in the catalog, so it has to survive the file being
    /// read again — and a keyword someone adds afterwards is theirs.
    @Test func marksSurviveTheFileBeingReadAgain() async throws {
        try vault.writeTaggedImage("a.jpg", keywords: ["child", "sea"])
        try await scannedVault()
        _ = try mark()

        try vault.writeTaggedImage("a.jpg", keywords: ["child", "sea", "Grandma's favourite"], seed: 0.51)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        #expect(try await sources(store, "a.jpg") == ["ext:child", "ext:sea", "manual:Grandma's favourite"])
        await store.close()
    }

    @Test func photosInTheTrashAreMarkedToo() async throws {
        try vault.writeTaggedImage("kept.jpg", keywords: ["child"], seed: 0.2)
        try vault.writeTaggedImage("binned.jpg", keywords: ["sea"], seed: 0.7)
        var store = try Store(root: vault.root)
        try await store.scan(full: true)
        let binned = try #require(try await store.items(scope: .all, filter: .all).first { $0.relPath == "Photos/binned.jpg" })
        try await store.moveToTrash([binned.id])
        await store.close()

        #expect(try mark().toMark.count == 2)

        store = try Store(root: vault.root)
        try await store.restoreFromTrash([binned.id])
        try await store.scan(full: true)
        #expect(try await sources(store, "binned.jpg") == ["ext:sea"])
        await store.close()
    }

    /// Photos added afterwards keep their keywords as a person's own, and
    /// JoyTag's tags, in the catalog, leave every photo untouched.
    @Test func photosAddedLaterAreLeftAlone() async throws {
        try vault.writeTaggedImage("old.jpg", keywords: ["child"], seed: 0.2)
        try await scannedVault()
        _ = try mark()

        try vault.writeTaggedImage("new.jpg", keywords: ["dog"], seed: 0.8)
        let bytes = try Data(contentsOf: url("new.jpg"))
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        _ = try await store.classify(ids: nil, with: FakeClassifier())
        #expect(try await sources(store, "new.jpg") == ["manual:dog", "jt:long hair", "jt:smile"])
        #expect(try await sources(store, "old.jpg") == ["ext:child", "jt:long hair", "jt:smile"])
        #expect(try Data(contentsOf: url("new.jpg")) == bytes)
        await store.close()
    }

    @Test func refusesPhotoVaultsOwnPrefixAndBadOnes() {
        #expect(throws: VaultError.self) { try KeywordPrefixer(prefix: "jt", label: "Mine") }
        #expect(throws: VaultError.self) { try KeywordPrefixer(prefix: "ex t", label: "OtherTagger") }
        #expect(throws: VaultError.self) { try KeywordPrefixer(prefix: "ext", label: " ") }
        #expect((try? KeywordPrefixer(prefix: "EXT", label: "OtherTagger"))?.record.prefix == "ext")
    }

    /// The command opens the catalog while the app is closed; whether the app
    /// last shut down cleanly is the app's business, and stays as it was.
    @Test func leavesTheAppsShutdownFlagAlone() throws {
        var catalog = try Catalog(url: vault.catalogFile)
        try catalog.setMeta("clean_shutdown", "0")
        catalog.closeCleanly(markingClean: false)
        catalog = try Catalog(url: vault.catalogFile)
        #expect(try catalog.meta("clean_shutdown") == "0")
        catalog.closeCleanly()
    }
}

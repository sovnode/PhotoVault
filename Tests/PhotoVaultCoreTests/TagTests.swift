import Testing
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers
@testable import PhotoVaultCore

extension TestVault {
    /// A real JPEG whose XMP carries `keywords` in `dc:subject` and `records` in
    /// PhotoVault's `pv:classifications` — what the tag writer will produce, and
    /// what another app's keywords look like.
    @discardableResult
    func writeTaggedImage(_ relPath: String, keywords: [String], records: [ToolRecord] = [], seed: Double = 0.5) throws -> URL {
        let url = photos.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = CGImageSourceCreateWithData(try TestVault.jpegData(size: 64, seed: seed) as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let metadata = CGImageMetadataCreateMutable()
        var error: Unmanaged<CFError>?
        CGImageMetadataRegisterNamespaceForPrefix(metadata, PhotoVaultXMP.namespace as CFString,
                                                  PhotoVaultXMP.prefix as CFString, &error)
        if !keywords.isEmpty {
            let subject = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString,
                                                   "subject" as CFString, .arrayUnordered, keywords as CFArray)!
            CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, subject)
        }
        if !records.isEmpty {
            let tag = CGImageMetadataTagCreate(PhotoVaultXMP.namespace as CFString, PhotoVaultXMP.prefix as CFString,
                                               PhotoVaultXMP.classifications as CFString, .arrayUnordered,
                                               records.map(\.line) as CFArray)!
            CGImageMetadataSetTagWithPath(metadata, nil, "pv:classifications" as CFString, tag)
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(dest, image, metadata, nil)
        guard CGImageDestinationFinalize(dest) else { throw VaultError.packCorrupt("couldn't write \(relPath)") }
        return url
    }
}

@Suite("Tag names and records")
struct TagNameTests {
    @Test func keysIgnoreCaseUnderscoresAndSpacing() {
        #expect(TagKey.key("Blonde_Hair") == "blonde hair")
        #expect(TagKey.key("  blonde   hair ") == "blonde hair")
        #expect(TagKey.key("6+boys") == "6+boys")
    }

    @Test func displayKeepsEmoticonUnderscores() {
        #expect(TagKey.display("blonde_hair") == "blonde hair")
        #expect(TagKey.display("star_(sky)") == "star (sky)")
        #expect(TagKey.display("^_^") == "^_^")
        #expect(TagKey.display(":d") == ":d")
    }

    @Test func recordsRoundTripAndTolerateMessyInput() throws {
        let date = Date(timeIntervalSince1970: 1_791_000_000)
        let record = ToolRecord(prefix: "jt", tool: "JoyTag", version: "6b7f163", date: date)
        #expect(record.line == "prefix=jt; tool=JoyTag; version=6b7f163; date=2026-10-03T04:00:00Z")
        #expect(ToolRecord(parsing: record.line) == record)
        let messy = try #require(ToolRecord(parsing: "  tool = OtherTagger ;prefix=ext;extra=1;; "))
        #expect(messy.prefix == "ext" && messy.tool == "OtherTagger" && messy.version == nil && messy.date == nil)
        #expect(ToolRecord(parsing: "tool=JoyTag") == nil, "a record needs a prefix")
        #expect(ToolRecord(parsing: "prefix=Jt!") == nil, "prefixes are lower-case letters and digits")
        #expect(ToolRecord(parsing: "prefix=JT")?.prefix == "jt", "read case-insensitively")
    }

    @Test func keywordsAreSortedBySource() {
        let file = FileTags(keywords: ["child", "jt:beach", "ext:sea", "place: Paris", "JT:Boat", " ", "child", "jt:"],
                            records: [ToolRecord(prefix: "ext", tool: "OtherTagger")])
        let tags = TagSources.split(file)
        #expect(tags.map { "\($0.source)|\($0.name)" } == [
            "manual|child", "jt|beach", "ext|sea", "manual|place: Paris", "jt|Boat", "manual|jt:",
        ])
    }

    @Test func anUndeclaredPrefixIsAPersonsOwnKeyword() {
        let tags = TagSources.split(FileTags(keywords: ["ext:sea"]))
        #expect(tags.map(\.source) == ["manual"])
        #expect(tags.first?.name == "ext:sea", "kept exactly as written")
    }
}

@Suite("Tag reader", .serialized)
struct TagReaderTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    @Test func readsXMPKeywordsAndPhotoVaultRecords() throws {
        let record = ToolRecord(prefix: "jt", tool: "JoyTag", version: "6b7f163", date: Date(timeIntervalSince1970: 1_791_000_000))
        let url = try vault.writeTaggedImage("a.jpg", keywords: ["child", "jt:beach"], records: [record])
        let tags = try #require(TagReader.read(url: url))
        #expect(Set(tags.keywords) == ["child", "jt:beach"])
        #expect(tags.records == [record])
    }

    @Test func fallsBackToIPTCKeywords() throws {
        let url = vault.photos.appendingPathComponent("iptc.jpg")
        let source = CGImageSourceCreateWithData(try TestVault.jpegData(size: 64, seed: 0.3) as CFData, nil)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, CGImageSourceCreateImageAtIndex(source, 0, nil)!, [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["lake", "dog"]]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        #expect(Set(try #require(TagReader.read(url: url)).keywords) == ["lake", "dog"])
    }

    @Test func aPhotoWithoutKeywordsHasNone() throws {
        let tags = try #require(TagReader.read(url: try vault.writeImage("plain.jpg")))
        #expect(tags.keywords.isEmpty && tags.records.isEmpty)
    }

    @Test func anUnreadableFileIsNil() throws {
        #expect(TagReader.read(url: try vault.writeJunk("junk.jpg")) == nil)
    }
}

@Suite("Tag groups file")
struct TagGroupsTests {
    /// The vault's own file is hidden; a visible one from before 1.3.0 still
    /// counts until the vault scripts rename it; the app's copy comes last.
    @Test func theVaultsHiddenFileComesFirst() async throws {
        let vault = try TestVault()
        let store = try Store(root: vault.root)
        let fallback = vault.root.appendingPathComponent("app-copy.txt")
        try "[App]\nboat\n".write(to: fallback, atomically: true, encoding: .utf8)
        #expect(await store.tagGroups(fallback: fallback).names == ["App"])
        try "[Old]\nboat\n".write(to: vault.root.appendingPathComponent("Tag Groups.txt"), atomically: true, encoding: .utf8)
        #expect(await store.tagGroups(fallback: fallback).names == ["Old"])
        try "[Hidden]\nboat\n".write(to: vault.root.appendingPathComponent(".Tag Groups.txt"), atomically: true, encoding: .utf8)
        #expect(await store.tagGroups(fallback: fallback).names == ["Hidden"])
        await store.close()
    }

    @Test func parsesGroupsInOrderIgnoringCommentsAndCase() {
        let groups = TagGroups(text: """
            # a comment
            [Nature]
            Beach
            blonde_hair

            [People]
            child
            beach
            [Nature]
            lake
            """)
        #expect(groups.names == ["Nature", "People"])
        #expect(groups.members["Nature"] == ["beach", "blonde hair", "lake"])
        #expect(groups.groups(of: "beach") == ["Nature", "People"], "a tag can be in two groups")
        #expect(groups.groups(of: TagKey.key("Blonde Hair")) == ["Nature"])
        #expect(groups.groups(of: "tractor") == [TagGroups.other])
    }

    /// The decisions recorded in the shipped file (2026-10-14).
    @Test func theShippedFileKeepsR18ForExplicitContentOnly() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources").appendingPathComponent("Tag Groups.txt")
        let groups = try TagGroups(url: file)
        #expect(groups.names.count == 29)
        #expect(groups.names.last == "R18")
        #expect(groups.groups(of: "nude") == ["R18"])
        #expect(groups.groups(of: "cosplay") == ["Clothing"])
        #expect(groups.groups(of: "topless male") == ["Body"])
        #expect(groups.groups(of: "interracial") == ["People"])
        #expect(groups.groups(of: "hatsune miku") == ["Anime and games"])
        #expect(groups.groups(of: "cat ears") == ["Fantasy and sci-fi"])
        #expect(groups.members.values.reduce(0) { $0 + $1.count } == 5_813)
    }
}

@Suite("Tags in the catalog", .serialized)
struct CatalogTagTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    @Test func upgradingFromV3RebuildsTheTagTablesAndKeepsABackup() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(vault.catalogFile.path, &db) == SQLITE_OK)
        for sql in [Catalog.schemaV1, Catalog.migrationV2, Catalog.migrationV3] {
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        #expect(sqlite3_exec(db, """
            INSERT INTO photo (rel_path, mtime, favorite) VALUES ('Photos/a.jpg', 1, 1);
            INSERT INTO smart_album (name, predicate) VALUES ('Old', 'p.favorite = 1');
            PRAGMA user_version = 3;
            """, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        #expect(try catalog.userVersion() == Catalog.schemaVersion)
        #expect(try catalog.items(scope: .all, filter: .all).first?.favorite == true)
        #expect(try catalog.smartAlbums().map(\.name) == ["Old"], "smart albums come through")
        #expect(try catalog.photosNeedingTags().count == 1, "every photo's tags are read once after the upgrade")
        let backups = try FileManager.default.contentsOfDirectory(atPath: vault.catalogDir.appendingPathComponent("backups").path)
        #expect(backups.contains { $0.hasPrefix("catalog-v3-") })
    }

    @Test func readingAFileReplacesItsTagsAndRecords() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", mtime: 10))
        let jt = ToolRecord(prefix: "jt", tool: "JoyTag", version: "6b7f163", date: Date(timeIntervalSince1970: 100))
        try catalog.transaction {
            try catalog.setFileTags(photoID: id, tags: TagSources.split(FileTags(keywords: ["child", "jt:beach"], records: [jt])),
                                    records: [jt], fileMtime: 10)
        }
        #expect(Set(try catalog.tags(photoID: id).map { "\($0.source)|\($0.name)" }) == ["manual|child", "jt|beach"])
        #expect(try catalog.classifications(photoID: id).map(\.classifier) == ["jt"])
        #expect(try catalog.photosNeedingTags().isEmpty, "read at this mtime")

        // The file is edited elsewhere: JoyTag's record and tags removed.
        try catalog.transaction {
            try catalog.setFileTags(photoID: id, tags: TagSources.split(FileTags(keywords: ["child", "lake"])),
                                    records: [], fileMtime: 20)
        }
        #expect(Set(try catalog.tags(photoID: id).map(\.name)) == ["child", "lake"])
        #expect(try catalog.classifications(photoID: id).isEmpty, "the photo needs classifying again")
    }

    @Test func catalogOnlyJoyTagTagsSurviveAReRead() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.gif", mtime: 10))
        // A GIF can't hold tags: JoyTag's are in the catalog only.
        try catalog.exec("""
            INSERT INTO classification (photo_id, classifier, version, classified_at, in_file) VALUES (\(id), 'jt', 'v', 1, 0);
            INSERT INTO tag (photo_id, source, key, name) VALUES (\(id), 'jt', 'cat', 'cat');
            """)
        try catalog.transaction {
            try catalog.setFileTags(photoID: id, tags: [FileTag(source: FileTag.manual, name: "pet")], records: [], fileMtime: 11)
        }
        #expect(Set(try catalog.tags(photoID: id).map { "\($0.source)|\($0.name)" }) == ["jt|cat", "manual|pet"])
        #expect(try catalog.classifications(photoID: id).first?.inFile == false, "the catalog-only record stays")
    }

    @Test func countsMergeAcrossSourcesAndSkipTrashedAndMissing() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        let a = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", mtime: 1))
        let b = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/b.jpg", mtime: 1))
        let c = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/c.jpg", mtime: 1))
        try catalog.transaction {
            try catalog.setFileTags(photoID: a, tags: [FileTag(source: "jt", name: "blonde hair"), FileTag(source: "manual", name: "Beach")], records: [], fileMtime: 1)
            try catalog.setFileTags(photoID: b, tags: [FileTag(source: "ext", name: "blonde_hair")], records: [], fileMtime: 1)
            try catalog.setFileTags(photoID: c, tags: [FileTag(source: "manual", name: "beach")], records: [], fileMtime: 1)
        }
        try catalog.trash(ids: [c])
        let counts = Dictionary(uniqueKeysWithValues: try catalog.tagCounts().map { ($0.key, $0) })
        #expect(counts["blonde hair"]?.photos == 2)
        #expect(counts["blonde hair"]?.sources == ["jt", "ext"])
        #expect(counts["beach"]?.photos == 1, "the trashed photo doesn't count")
        let album = try catalog.createSmartAlbum(name: "Blonde", rules: TagRules(items: [.init(kind: .tag, name: "blonde hair", state: .include)]))
        #expect(try catalog.items(scope: .smart(album), filter: .all, sort: .name).map(\.relPath) == ["Photos/a.jpg", "Photos/b.jpg"])
    }

    @Test func hidingATagKeepsIt() throws {
        let catalog = try Catalog(url: vault.catalogFile)
        defer { catalog.closeCleanly() }
        try catalog.setTagHidden("1girl", true)
        try catalog.setTagHidden("1girl", true)
        #expect(try catalog.hiddenTagKeys() == ["1girl"])
        try catalog.setTagHidden("1girl", false)
        #expect(try catalog.hiddenTagKeys().isEmpty)
    }
}

@Suite("Reading tags during a scan", .serialized)
struct ScanTagTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    @Test func aScanReadsNewFilesAndReReadsChangedOnesOnly() async throws {
        let other = ToolRecord(prefix: "ext", tool: "OtherTagger")
        try vault.writeTaggedImage("a.jpg", keywords: ["child", "ext:sea"], records: [other], seed: 0.2)
        try vault.writeTaggedImage("b.jpg", keywords: ["dog"], seed: 0.4)
        try vault.writeImage("c.jpg", seed: 0.6)

        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        var counts = Dictionary(uniqueKeysWithValues: try await store.tagCounts().map { ($0.key, $0) })
        #expect(counts["sea"]?.sources == ["ext"], "a declared prefix is that tool's")
        #expect(counts["child"]?.sources == ["manual"])
        #expect(counts["dog"]?.photos == 1)

        // Another app edits b's keywords.
        try await Task.sleep(nanoseconds: 1_100_000_000)   // a new mtime
        try vault.writeTaggedImage("b.jpg", keywords: ["dog", "lake"], seed: 0.4)
        try await store.scan(full: true)
        counts = Dictionary(uniqueKeysWithValues: try await store.tagCounts().map { ($0.key, $0) })
        #expect(counts["lake"]?.photos == 1, "the changed file was read again")
        #expect(counts["sea"]?.photos == 1, "the unchanged one kept its tags")
        await store.close()
    }
}

@Suite("Smart albums from tag rules", .serialized)
struct TagRuleTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    @Test func aClickCyclesIncludeExcludeOffAndKeepsOrder() {
        var rules = TagRules()
        rules.cycle(.tag, "beach")
        rules.cycle(.group, "R18")
        rules.cycle(.tag, "boat")
        #expect(rules.items.map(\.name) == ["beach", "R18", "boat"])
        rules.cycle(.group, "R18")
        #expect(rules.state(.group, "R18") == .exclude)
        #expect(rules.items.map(\.name) == ["beach", "R18", "boat"], "changing a state keeps its place")
        rules.cycle(.group, "R18")
        #expect(rules.state(.group, "R18") == nil)
        #expect(rules.items.map(\.name) == ["beach", "boat"])
    }

    @Test func noRulesMeansEveryPhoto() {
        #expect(TagRules().sql(groups: TagGroups(text: "")) == nil)
    }

    /// Photos: a = beach boat, b = beach lake, c = lake, d = beach nude, e = no tags.
    private func catalogWithPhotos() throws -> Catalog {
        let catalog = try Catalog(url: vault.catalogFile)
        let tags: [String: [String]] = ["a": ["beach", "boat"], "b": ["beach", "lake"], "c": ["lake"], "d": ["beach", "nude"], "e": []]
        try catalog.transaction {
            for name in tags.keys.sorted() {
                let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/\(name).jpg", mtime: 1))
                try catalog.setFileTags(photoID: id, tags: tags[name]!.map { FileTag(source: "jt", name: $0) }, records: [], fileMtime: 1)
            }
        }
        return catalog
    }

    private func names(_ catalog: Catalog, _ rules: TagRules, _ groups: String = "[Nature]\nbeach\nlake\n[R18]\nnude\n") throws -> [String] {
        let id = try catalog.createSmartAlbum(name: "Test", rules: rules)
        defer { try? catalog.deleteSmartAlbum(id: id) }
        return try catalog.items(scope: .smart(id), filter: .all, sort: .name, groups: TagGroups(text: groups))
            .map { ($0.relPath as NSString).lastPathComponent.replacingOccurrences(of: ".jpg", with: "") }
    }

    @Test func includeAllAndAnyNarrowAndWiden() throws {
        let catalog = try catalogWithPhotos()
        defer { catalog.closeCleanly() }
        let both = [TagRules.Item(kind: .tag, name: "beach", state: .include), .init(kind: .tag, name: "lake", state: .include)]
        #expect(try names(catalog, TagRules(items: both, include: .all)) == ["b"])
        #expect(try names(catalog, TagRules(items: both, include: .any)) == ["a", "b", "c", "d"])
    }

    @Test func excludeAnyAndAllHide() throws {
        let catalog = try catalogWithPhotos()
        defer { catalog.closeCleanly() }
        let out = [TagRules.Item(kind: .tag, name: "boat", state: .exclude), .init(kind: .tag, name: "beach", state: .exclude)]
        #expect(try names(catalog, TagRules(items: out, exclude: .any)) == ["c", "e"])
        #expect(try names(catalog, TagRules(items: out, exclude: .all)) == ["b", "c", "d", "e"], "only photos with both are hidden")
    }

    @Test func groupsCountAsOneItemAndFollowTheFile() throws {
        let catalog = try catalogWithPhotos()
        defer { catalog.closeCleanly() }
        let rules = TagRules(items: [.init(kind: .tag, name: "beach", state: .include), .init(kind: .group, name: "R18", state: .exclude)])
        #expect(try names(catalog, rules) == ["a", "b"], "the R18 group hides the nude photo")
        #expect(try names(catalog, rules, "[R18]\nboat\n") == ["b", "d"], "an edited Tag Groups.txt changes what the group means")
        let nature = TagRules(items: [.init(kind: .group, name: "Nature", state: .include)])
        #expect(try names(catalog, nature) == ["a", "b", "c", "d"])
    }

    @Test func otherMeansTagsInNoGroup() throws {
        let catalog = try catalogWithPhotos()
        defer { catalog.closeCleanly() }
        let other = TagRules(items: [.init(kind: .group, name: TagGroups.other, state: .include)])
        #expect(try names(catalog, other) == ["a"], "boat is in no group")
    }

    @Test func rulesAreSavedRenamedAndOldAlbumsStillWork() throws {
        let catalog = try catalogWithPhotos()
        defer { catalog.closeCleanly() }
        let id = try catalog.createSmartAlbum(name: "Lakes", rules: TagRules(items: [.init(kind: .tag, name: "lake", state: .include)]))
        try catalog.updateSmartAlbum(id: id, name: "Lakes and boats",
                                     rules: TagRules(items: [.init(kind: .tag, name: "lake", state: .include), .init(kind: .tag, name: "boat", state: .include)], include: .any))
        let saved = try #require(try catalog.smartAlbum(id: id))
        #expect(saved.name == "Lakes and boats")
        #expect(saved.rules?.include == .any && saved.rules?.items.count == 2)
        #expect(try catalog.items(scope: .smart(id), filter: .all, sort: .name).count == 3)

        let old = try catalog.createSmartAlbum(name: "Old", predicate: "p.rel_path = 'Photos/e.jpg'")
        #expect(try catalog.smartAlbum(id: old)?.rules == nil, "a predicate album has no rules to edit")
        #expect(try catalog.items(scope: .smart(old), filter: .all).map(\.relPath) == ["Photos/e.jpg"])
    }
}

import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoVaultCore

/// Stands in for JoyTag: the same tags for every photo, optionally slowly.
final class FakeClassifier: TagClassifier, @unchecked Sendable {
    let record = ToolRecord(prefix: "jt", tool: "JoyTag", version: "test1")
    private let lock = NSLock()
    private var _tags: [ScoredTag]
    private var _calls = 0
    let delay: UInt64

    init(_ tags: [ScoredTag] = [ScoredTag(name: "long hair", score: 0.9), ScoredTag(name: "smile", score: 0.55)],
         delay: UInt64 = 0) {
        _tags = tags
        self.delay = delay
    }

    var calls: Int { lock.withLock { _calls } }
    let parallelism = 2
    private var _running = 0, _mostAtOnce = 0
    /// The most photos it was ever asked to work on at the same time.
    var mostAtOnce: Int { lock.withLock { _mostAtOnce } }
    var tags: [ScoredTag] {
        get { lock.withLock { _tags } }
        set { lock.withLock { _tags = newValue } }
    }

    func classify(thumbnail: Data, fast: Bool) async throws -> [ScoredTag] {
        lock.withLock { _calls += 1; _running += 1; _mostAtOnce = max(_mostAtOnce, _running) }
        defer { lock.withLock { _running -= 1 } }
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        return tags
    }
}

@Suite("Tagging photos", .serialized)
struct ClassifyTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    func url(_ name: String) -> URL { vault.photos.appendingPathComponent(name) }

    func writeGIF(_ name: String) throws {
        let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let dest = CGImageDestinationCreateWithURL(url(name) as CFURL, UTType.gif.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    func item(_ store: Store, _ name: String) async throws -> PhotoItem {
        try #require(try await store.items(scope: .all, filter: .all).first { $0.relPath == "Photos/\(name)" })
    }

    /// Tags go into the catalog; the photos aren't touched (by design:
    /// rewriting every photo grows a vault's disk image).
    @Test func tagsNewPhotosInTheCatalogAndLeavesThemAlone() async throws {
        try vault.writeTaggedImage("mine.jpg", keywords: ["Grandma", "beach"], seed: 0.2)
        try vault.writeTaggedImage("other.jpg", keywords: ["ext:child", "ext:sea"],
                                   records: [ToolRecord(prefix: "ext", tool: "OtherTagger")], seed: 0.4)
        try vault.writeImage("plain.jpg", seed: 0.6)
        let files = ["mine.jpg", "other.jpg", "plain.jpg"]
        let bytes = try files.map { try Data(contentsOf: url($0)) }
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let before = try await store.items(scope: .all, filter: .all)

        let result = try await store.classify(ids: nil, with: FakeClassifier())

        #expect(result.photos == 3 && result.failures.isEmpty)
        #expect(try files.map { try Data(contentsOf: url($0)) } == bytes, "every photo byte for byte as it was")
        let mine = try await item(store, "mine.jpg")
        let tags = try await store.tags(for: mine.id)
        #expect(Set(tags.map { "\($0.source):\($0.name)" }) == ["manual:Grandma", "manual:beach", "jt:long hair", "jt:smile"])
        #expect(tags.first { $0.name == "long hair" }?.confidence == 0.9, "scores are kept in the catalog")
        let record = try #require(try await store.classifications(for: mine.id).first { $0.classifier == "jt" })
        #expect(!record.inFile && record.version == "test1" && record.label == "JoyTag")
        let other = try await item(store, "other.jpg")
        #expect(Set(try await store.tags(for: other.id).map(\.source)) == ["ext", "jt"], "OtherTagger's tags stay OtherTagger's")

        // A rescan has nothing to do: no thumbnail rebuilt, nothing to tag.
        try await store.scan(full: true)
        let after = try await store.items(scope: .all, filter: .all)
        for (a, b) in zip(before.sorted { $0.id < $1.id }, after.sorted { $0.id < $1.id }) {
            #expect(a.thumbOff == b.thumbOff && a.mtime == b.mtime, "\(a.relPath) unchanged")
        }
        #expect(try await store.tags(for: mine.id).first { $0.name == "long hair" }?.confidence == 0.9)
        #expect(try await store.classificationPlan(ids: nil, prefix: "jt").photos == 0)
        await store.close()
    }

    @Test func aSecondRunClassifiesNothingAndANewPhotoIsPickedUp() async throws {
        try vault.writeImage("a.jpg", seed: 0.2)
        try vault.writeImage("b.jpg", seed: 0.4)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let fake = FakeClassifier()
        _ = try await store.classify(ids: nil, with: fake)
        #expect(fake.calls == 2)

        #expect(try await store.classify(ids: nil, with: fake).photos == 0)
        #expect(fake.calls == 2)

        try vault.writeImage("c.jpg", seed: 0.8)
        try await store.scan(full: false)
        let third = try await store.classify(ids: nil, with: fake)
        #expect(third.photos == 1 && fake.calls == 3)
        let c = try await item(store, "c.jpg")
        #expect(Set(try await store.tags(for: c.id).map(\.name)) == ["long hair", "smile"])
        await store.close()
    }

    @Test func reclassifyingReplacesOnlyJoyTags() async throws {
        try vault.writeTaggedImage("a.jpg", keywords: ["beach", "ext:sea"], records: [ToolRecord(prefix: "ext", tool: "OtherTagger")])
        let bytes = try Data(contentsOf: url("a.jpg"))
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        _ = try await store.classify(ids: nil, with: FakeClassifier())
        let a = try await item(store, "a.jpg")

        let result = try await store.classify(ids: [a.id], with: FakeClassifier([ScoredTag(name: "sand", score: 0.7)]))

        #expect(result.photos == 1)
        let tags = try await store.tags(for: a.id)
        #expect(Set(tags.map { "\($0.source):\($0.name)" }) == ["manual:beach", "ext:sea", "jt:sand"])
        #expect(try Data(contentsOf: url("a.jpg")) == bytes)
        await store.close()
    }

    /// Every format's tags live in the catalog: a GIF and a read-only photo
    /// are tagged like the rest, untouched, and not tried again.
    @Test func everyFormatIsTaggedTheSameWay() async throws {
        try writeGIF("anim.gif")
        try vault.writeTaggedImage("locked.jpg", keywords: ["mine"])
        #expect(chmod(url("locked.jpg").path, 0o444) == 0)
        defer { chmod(url("locked.jpg").path, 0o644) }
        let gif = try Data(contentsOf: url("anim.gif")), locked = try Data(contentsOf: url("locked.jpg"))
        let store = try Store(root: vault.root)
        try await store.scan(full: true)

        #expect(try await store.classificationPlan(ids: nil, prefix: "jt").photos == 2)
        let result = try await store.classify(ids: nil, with: FakeClassifier())

        #expect(result.photos == 2 && result.failures.isEmpty)
        #expect(try Data(contentsOf: url("anim.gif")) == gif)
        #expect(try Data(contentsOf: url("locked.jpg")) == locked)
        for name in ["anim.gif", "locked.jpg"] {
            let photo = try await item(store, name)
            #expect(Set(try await store.tags(for: photo.id).filter { $0.source == "jt" }.map(\.name)) == ["long hair", "smile"])
        }
        #expect(try await store.classificationPlan(ids: nil, prefix: "jt").photos == 0)
        try await store.scan(full: true)
        let lockedItem = try await item(store, "locked.jpg")
        #expect(try await store.tags(for: lockedItem.id).contains { $0.source == "jt" }, "a rescan keeps them")
        await store.close()
    }

    @Test func stoppingKeepsWhatIsDoneAndTheNextRunFinishes() async throws {
        for i in 0..<6 { try vault.writeImage("p\(i).jpg", seed: Double(i) / 6) }
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let slow = FakeClassifier(delay: 200_000_000)

        let run = Task { try await store.classify(ids: nil, with: slow) }
        try await Task.sleep(nanoseconds: 500_000_000)
        run.cancel()
        await #expect(throws: CancellationError.self) { _ = try await run.value }

        let left = try await store.classificationPlan(ids: nil, prefix: "jt").photos
        #expect(left > 0 && left < 6, "stopped part-way: \(6 - left) done")
        let rest = try await store.classify(ids: nil, with: FakeClassifier())
        #expect(rest.photos == left)
        #expect(try await store.classificationPlan(ids: nil, prefix: "jt").photos == 0)
        await store.close()
    }

    /// Tag faster: one photo at a time unless asked, then up to two, from
    /// the next photo on — and the same tags either way.
    @Test func tagFasterWorksOnTwoAtOnceFromTheNextPhoto() async throws {
        for i in 0..<8 { try vault.writeImage("p\(i).jpg", seed: Double(i) / 8) }
        let store = try Store(root: vault.root)
        try await store.scan(full: true)

        let steady = FakeClassifier(delay: 50_000_000)
        _ = try await store.classify(ids: nil, with: steady)
        #expect(steady.mostAtOnce == 1, "the normal pace is one at a time")

        let ids = try await store.items(scope: .all, filter: .all).map(\.id)
        let pace = TaggingPace()
        let faster = FakeClassifier([ScoredTag(name: "sand", score: 0.8)], delay: 100_000_000)
        let run = Task { try await store.classify(ids: ids, with: faster, pace: pace) }
        try await Task.sleep(nanoseconds: 150_000_000)
        pace.isFast = true    // ticked part-way through
        let result = try await run.value
        #expect(result.photos == 8 && faster.calls == 8)
        #expect(faster.mostAtOnce == 2)
        for id in ids {
            #expect(try await store.tags(for: id).filter { $0.source == "jt" }.map(\.name) == ["sand"])
        }
        await store.close()
    }

    @Test func closingWaitsForTagging() async throws {
        for i in 0..<4 { try vault.writeImage("p\(i).jpg", seed: Double(i) / 4) }
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let run = Task { try await store.classify(ids: nil, with: FakeClassifier(delay: 200_000_000)) }
        try await Task.sleep(nanoseconds: 300_000_000)
        await store.close()
        _ = try? await run.value
        let catalog = try Catalog(url: vault.catalogFile)
        #expect(try catalog.meta("clean_shutdown") == "1", "the catalog closed cleanly after the job stopped")
        catalog.closeCleanly()
    }

    /// JoyTag's tags live only in the catalog: a catalog rebuilt from the
    /// files has the photos' own keywords back, and everything to tag again.
    @Test func aRebuiltCatalogTagsAgain() async throws {
        try vault.writeTaggedImage("a.jpg", keywords: ["beach"])
        try vault.writeImage("b.jpg", seed: 0.7)
        var store = try Store(root: vault.root)
        try await store.scan(full: true)
        _ = try await store.classify(ids: nil, with: FakeClassifier())
        await store.close()

        for file in ["catalog.sqlite", "catalog.sqlite-wal", "catalog.sqlite-shm", "thumbs.pack"] {
            try? FileManager.default.removeItem(at: vault.catalogDir.appendingPathComponent(file))
        }
        store = try Store(root: vault.root)
        try await store.scan(full: true)
        let a = try await item(store, "a.jpg")
        #expect(try await store.tags(for: a.id).map(\.name) == ["beach"])
        #expect(try await store.classificationPlan(ids: nil, prefix: "jt").photos == 2)
        await store.close()
    }

    /// A photo moved to another folder — or renamed — keeps its tags: the
    /// scan knows it by its content, and moves its catalog row, tags and all.
    @Test func tagsFollowAPhotoMovedToAnotherFolder() async throws {
        try writeGIF("only-in-catalog.gif")
        try vault.writeTaggedImage("in-file.jpg", keywords: ["beach"])
        var store = try Store(root: vault.root)
        try await store.scan(full: true)
        _ = try await store.classify(ids: nil, with: FakeClassifier())
        let ids = Dictionary(uniqueKeysWithValues: try await store.items(scope: .all, filter: .all).map { ($0.relPath, $0.id) })
        await store.close()

        let moved = vault.photos.appendingPathComponent("2024/trip")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url("only-in-catalog.gif"), to: moved.appendingPathComponent("only-in-catalog.gif"))
        try FileManager.default.moveItem(at: url("in-file.jpg"), to: moved.appendingPathComponent("renamed.jpg"))

        store = try Store(root: vault.root)
        try await store.scan(full: false)
        let gif = try await item(store, "2024/trip/only-in-catalog.gif")
        let jpg = try await item(store, "2024/trip/renamed.jpg")
        #expect(gif.id == ids["Photos/only-in-catalog.gif"] && jpg.id == ids["Photos/in-file.jpg"], "the same rows, moved")
        #expect(Set(try await store.tags(for: gif.id).filter { $0.source == "jt" }.map(\.name)) == ["long hair", "smile"])
        #expect(Set(try await store.tags(for: jpg.id).map { "\($0.source):\($0.name)" }) == ["manual:beach", "jt:long hair", "jt:smile"])
        #expect(try await store.classificationPlan(ids: nil, prefix: "jt").photos == 0, "nothing to tag again")
        #expect(try await store.items(scope: .all, filter: .all).count == 2)
        await store.close()
    }
}

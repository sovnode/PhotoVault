import Foundation

public struct ScanProgress: Sendable {
    public var phase: String
    public var done: Int
    public var total: Int
    public var finished: Bool = false
}

/// Owns the catalog and the pack, and is the only thing that writes to either.
///
/// Making this an actor is what enforces the write-ordering contract: the
/// blob append, its `F_FULLFSYNC`, and the row commit that points at it happen
/// as one uninterrupted unit. Thumbnail *generation* is the expensive part and
/// runs outside, in parallel; only the commit funnels back through here.
public actor Store {
    public let root: URL
    private let catalog: Catalog
    private let pack: BlobPack
    private let thumbnailer: Thumbnailer
    private var closed = false
    /// Latched in `init`, *before* this session marks the catalog dirty.
    /// Reading the flag after overwriting it would make `needsFullScan()`
    /// permanently true, quietly costing a full walk on every single mount.
    private let openedCleanly: Bool

    public init(root: URL, thumbnailer: Thumbnailer = Thumbnailer()) throws {
        try VolumeLocator.ensureScaffolding(at: root)
        let catDir = VolumeLocator.catalogDir(root)

        // All the opening work happens on locals. An actor's `init` is
        // nonisolated, so touching `self.catalog` here would be reaching across
        // the isolation boundary — a warning today and an error under Swift 6.
        let catalog = try Catalog(
            url: catDir.appendingPathComponent("catalog.sqlite"),
            tmpDir: catDir.appendingPathComponent("tmp")
        )
        let pack = try BlobPack(url: catDir.appendingPathComponent("thumbs.pack"))

        // Crash residue: bytes appended whose row never committed. Safe to drop
        // because no row can possibly reference them.
        try pack.truncateOrphans(catalogTail: try catalog.maxThumbTail())

        let wasClean = try catalog.meta("clean_shutdown") == "1"
        let hasDirState = !(try catalog.dirStates().isEmpty)
        try catalog.setMeta("clean_shutdown", "0")

        self.root = root
        self.catalog = catalog
        self.pack = pack
        self.thumbnailer = thumbnailer
        self.openedCleanly = wasClean && hasDirState
    }

    /// A session that ended badly leaves directory mtimes untrustworthy, so the
    /// next mount pays for a full walk rather than trusting stale state.
    public func needsFullScan() -> Bool { !openedCleanly }

    /// Waits for a running scan to stop (it's cancelled first) before closing,
    /// so the catalog is never closed underneath it.
    public func close() async {
        guard !closed else { return }
        closed = true
        activeScan?.cancel()
        _ = await activeScan?.result
        pack.sync()
        catalog.closeCleanly()
    }

    // MARK: - Scanning

    /// The scan in progress, run as a task of its own so `close()` can stop it
    /// and wait for it without help from whoever started it.
    private var activeScan: Task<Void, Error>?

    /// Scans for new, changed and missing files, builds thumbnails, and repairs
    /// missing details. Stoppable: cancelling the calling task stops it between
    /// photos, throwing `CancellationError`. Everything finished so far is kept,
    /// and the next scan carries on from there.
    public func scan(full: Bool? = nil, progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws {
        guard !closed, activeScan == nil else { throw CancellationError() }
        let work = Task { try await performScan(full: full, progress: progress) }
        activeScan = work
        defer { activeScan = nil }
        try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func performScan(full: Bool?, progress: (@Sendable (ScanProgress) -> Void)?) async throws {
        try Task.checkCancellation()
        let doFull = full ?? needsFullScan()
        progress?(ScanProgress(phase: doFull ? "Scanning all folders…" : "Checking for changes…", done: 0, total: 0))

        let known = try catalog.dirStates()
        let result = doFull
            ? Scanner.fullScan(root: root)
            : Scanner.incrementalScan(root: root, knownDirs: known)

        try Task.checkCancellation()
        try applyScan(result)

        let pending = try catalog.photosNeedingThumbs()
        if !pending.isEmpty {
            try await generateThumbs(for: pending, progress: progress)
        }
        try await refreshDetails(progress: progress)
        try await refreshTags(progress: progress)
        progress?(ScanProgress(phase: "Up to date", done: 0, total: 0, finished: true))
    }

    /// Reads the keywords and PhotoVault records of every photo that's new, or
    /// whose file has changed since its tags were last read. Header reads, many
    /// at a time; committed 200 at a time, so a stopped scan keeps what it read.
    func refreshTags(progress: (@Sendable (ScanProgress) -> Void)?) async throws {
        let pending = try catalog.photosNeedingTags()
        guard !pending.isEmpty else { return }
        progress?(ScanProgress(phase: "Reading tags…", done: 0, total: pending.count))
        let root = self.root
        var done = 0
        for start in stride(from: 0, to: pending.count, by: 200) {
            try Task.checkCancellation()
            let batch = Array(pending[start..<min(start + 200, pending.count)])
            let read = await withTaskGroup(of: (Int, FileTags?).self) { group in
                for (i, item) in batch.enumerated() {
                    group.addTask { (i, TagReader.read(url: root.appendingPathComponent(item.relPath))) }
                }
                var out = [FileTags?](repeating: nil, count: batch.count)
                for await (i, tags) in group { out[i] = tags }
                return out
            }
            try catalog.transaction {
                for (item, file) in zip(batch, read) {
                    // An unreadable file is noted as read too, so it isn't
                    // retried on every scan; it simply has no tags.
                    let tags = file ?? FileTags()
                    try catalog.setFileTags(photoID: item.id, tags: TagSources.split(tags),
                                            records: tags.records, fileMtime: item.mtime)
                }
            }
            done += batch.count
            progress?(ScanProgress(phase: "Reading tags…", done: done, total: pending.count))
        }
    }

    /// Re-reads dimensions, orientation and capture date from the files for any
    /// photo whose catalog row has lost them — what a rescan before 1.2.0 did
    /// to every photo in a folder it re-read. Reads headers only; thumbnails
    /// are left as they are.
    func refreshDetails(progress: (@Sendable (ScanProgress) -> Void)?) async throws {
        let damaged = try catalog.photosNeedingDetails()
        guard !damaged.isEmpty else { return }
        progress?(ScanProgress(phase: "Reading photo details…", done: 0, total: damaged.count))
        for (n, item) in damaged.enumerated() {
            try Task.checkCancellation()
            let url = root.appendingPathComponent(item.relPath)
            let details: Thumbnailer.Details?
            switch item.mediaType {
            case .photo: details = try? Thumbnailer.photoDetails(url: url)
            case .video: details = try? await Thumbnailer.videoDetails(url: url)
            }
            if let d = details {
                try catalog.setDetails(id: item.id, width: d.width, height: d.height, orientation: d.orientation,
                                       capturedAt: d.capturedAt, duration: d.duration)
            } else {
                // Unreadable: record the file date and move on, so the photo
                // isn't retried on every scan.
                try catalog.setDetails(id: item.id, width: max(item.width, 1), height: max(item.height, 1),
                                       orientation: item.orientation, capturedAt: nil, duration: nil)
            }
            if (n + 1) % 200 == 0 || n + 1 == damaged.count {
                progress?(ScanProgress(phase: "Reading photo details…", done: n + 1, total: damaged.count))
            }
        }
    }

    func applyScan(_ result: ScanResult) throws {
        let existing = try catalog.allFiles()
        var seen = Set<String>()

        // All or nothing: stopped part-way, the transaction rolls back, nothing
        // is marked missing on half a picture, and the next scan redoes it.
        try catalog.transaction {
            for (n, f) in result.files.enumerated() {
                if n % 200 == 0 { try Task.checkCancellation() }
                seen.insert(f.relPath)
                var item = PhotoItem(
                    relPath: f.relPath,
                    fileSize: f.size,
                    mtime: f.mtime,
                    mediaType: f.type,
                    createdAt: f.created
                )
                // Hashing every file on every pass would undo the point of the
                // fast scan; only new or changed files need a key computed.
                let known = existing[f.relPath]
                if known == nil || known!.size != f.size || known!.mtime != f.mtime {
                    item.contentKey = ContentKey.compute(url: root.appendingPathComponent(f.relPath), fileSize: f.size)
                }
                try catalog.upsertPhoto(item)
            }

            // On an incremental pass, a path can only be declared missing if the
            // directory holding it was actually walked. Anything else was simply
            // not looked at this time.
            let gone: [Int64] = existing.compactMap { relPath, file in
                let id = file.id
                if seen.contains(relPath) { return nil }
                if result.isFull { return id }
                let dir = (relPath as NSString).deletingLastPathComponent
                return result.enumeratedDirs.contains(dir) ? id : nil
            }
            try catalog.markMissing(ids: gone)

            for (dir, mtime) in result.dirs { try catalog.setDirState(dir, mtime: mtime) }
            try catalog.removeDirStates(result.vanishedDirs)
        }

        try relinkMoved(among: result.files)
    }

    /// A row whose path vanished, and a newly-seen file carrying the same
    /// content key, are the same photo moved. Relinking preserves its album
    /// memberships and favorite flag instead of orphaning them.
    func relinkMoved(among files: [ScannedFile]) throws {
        let missing = try catalog.missingPhotosByContentKey()
        guard !missing.isEmpty else { return }

        try catalog.transaction {
            for f in files {
                guard let key = ContentKey.compute(url: root.appendingPathComponent(f.relPath), fileSize: f.size),
                      let missingID = missing[key],
                      let currentID = try catalog.photoID(relPath: f.relPath),
                      currentID != missingID
                else { continue }
                // The fresh row for the new path is the duplicate; drop it and
                // move the original — which carries the album rows — onto the path.
                try catalog.exec("DELETE FROM photo WHERE id = \(currentID);")
                try catalog.relink(missingID: missingID, toRelPath: f.relPath)
            }
        }
    }

    // MARK: - Thumbnails

    func generateThumbs(for items: [PhotoItem], progress: (@Sendable (ScanProgress) -> Void)?) async throws {
        let total = items.count
        var done = 0
        progress?(ScanProgress(phase: "Building thumbnails…", done: 0, total: total))

        // The Thumbnailer's own limiters cap real concurrency; this window just
        // keeps a bounded number of tasks in flight so a 10k library doesn't
        // spawn 10k of them at once.
        let window = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
        var index = 0

        try await withThrowingTaskGroup(of: (PhotoItem, Result<ThumbResult, Error>).self) { group in
            func addNext() {
                guard index < items.count, !Task.isCancelled else { return }
                let item = items[index]
                index += 1
                let url = root.appendingPathComponent(item.relPath)
                let tn = thumbnailer
                group.addTask {
                    (item, await tn.thumbnail(for: url, type: item.mediaType))
                }
            }
            for _ in 0..<min(window, items.count) { addNext() }

            while let (item, outcome) = try await group.next() {
                switch outcome {
                case .success(let thumb):
                    // Keep work already done, even on the way out of a stopped scan.
                    try commit(thumb: thumb, for: item)
                case .failure(let error) where error is CancellationError:
                    break   // stopped, not broken: no badge, retried next scan
                case .failure:
                    // A file AVFoundation can't open (MKV, VP9, DivX-era AVI)
                    // gets badged rather than showing a broken cell. It never
                    // reaches commit(), so its date (the file's) and placeholder
                    // dimensions are set here, which also keeps the details pass
                    // from retrying it.
                    try catalog.exec("""
                        UPDATE photo SET playable = \(item.mediaType == .video ? 0 : 1),
                        captured_at = COALESCE(captured_at, mtime), has_date = 0,
                        width = MAX(width, 1), height = MAX(height, 1)
                        WHERE id = \(item.id);
                        """)
                }
                done += 1
                if done % 16 == 0 || done == total {
                    progress?(ScanProgress(phase: "Building thumbnails…", done: done, total: total))
                }
                addNext()
            }
        }
        try Task.checkCancellation()
    }

    /// The ordering contract, in one place: append, durably flush, *then*
    /// commit the row that points at the bytes. Reversed, a crash leaves rows
    /// addressing data that was never written — indistinguishable from
    /// corruption, and far worse to recover from than orphaned tail bytes.
    func commit(thumb: ThumbResult, for item: PhotoItem) throws {
        let (offset, length) = try pack.append(thumb.jpeg)
        try catalog.transaction {
            try catalog.setThumb(photoID: item.id, offset: offset, length: length)
            try catalog.exec("""
                UPDATE photo SET width = \(thumb.width), height = \(thumb.height),
                orientation = \(thumb.orientation), playable = \(thumb.playable ? 1 : 0)
                WHERE id = \(item.id);
                """)
            if let c = thumb.capturedAt {
                try catalog.exec("UPDATE photo SET captured_at = \(c), has_date = 1 WHERE id = \(item.id);")
            } else {
                try catalog.exec("UPDATE photo SET captured_at = mtime, has_date = 0 WHERE id = \(item.id);")
            }
            if let d = thumb.duration {
                try catalog.exec("UPDATE photo SET duration = \(d) WHERE id = \(item.id);")
            }
            if let t = thumb.posterTime {
                try catalog.setPosterTime(photoID: item.id, t)
            }
        }
    }

    public func thumbnailData(for item: PhotoItem) throws -> Data? {
        guard let off = item.thumbOff, let len = item.thumbLen, len > 0 else { return nil }
        return try pack.read(offset: off, length: len)
    }

    /// Re-poster a video at a chosen time. Just a different seek and another
    /// pack append — the old blob is left in place, reclaimed on a rebuild.
    public func setPoster(for item: PhotoItem, at seconds: Double) async throws {
        guard item.mediaType == .video else { return }
        let url = root.appendingPathComponent(item.relPath)
        var thumb = try await Thumbnailer.makeVideoThumb(url: url)
        thumb.posterTime = seconds
        try commit(thumb: thumb, for: item)
    }

    // MARK: - Reads

    public func items(scope: LibraryScope, filter: MediaFilter, sort: PhotoOrder = .date, ascending: Bool = true,
                      groups: TagGroups = TagGroups(text: "")) throws -> [PhotoItem] {
        try catalog.items(scope: scope, filter: filter, sort: sort, ascending: ascending, groups: groups)
    }

    /// The vault's sort order: the one chosen, or else the default its photos
    /// suggest (see `PhotoOrder.defaultFor`).
    public func sortOrder() throws -> PhotoOrder {
        if let chosen = setting("sort.order").flatMap(PhotoOrder.init(rawValue:)) { return chosen }
        return PhotoOrder.defaultFor(datedCount: try catalog.datedCount(), total: try catalog.photoCount())
    }

    public func setSortOrder(_ order: PhotoOrder) {
        setSetting("sort.order", order.rawValue)
    }

    /// The sort a view follows (see `LibraryScope.sortKey`): the library's, or
    /// a smart album's own — the library's until one is chosen for it. Nil for
    /// an album, which keeps its own order.
    public func sortSetting(for scope: LibraryScope) throws -> SortSetting? {
        guard let key = scope.sortKey else { return nil }
        let library = SortSetting(order: try sortOrder(), ascending: setting("sort.ascending") != "0")
        guard key != "sort" else { return library }
        return SortSetting(order: setting(key + ".order").flatMap(PhotoOrder.init(rawValue:)) ?? library.order,
                           ascending: setting(key + ".ascending").map { $0 != "0" } ?? library.ascending)
    }

    public func setSortSetting(_ sort: SortSetting, for scope: LibraryScope) {
        guard let key = scope.sortKey else { return }
        setSetting(key + ".order", sort.order.rawValue)
        setSetting(key + ".ascending", sort.ascending ? "1" : "0")
    }

    /// The folders under `Photos/` that hold photos, with counts.
    public func folderTree() throws -> FolderNode {
        FolderNode.tree(directCounts: try catalog.folderCounts())
    }

    public func albums() throws -> [Album] { try catalog.albums() }
    public func smartAlbums() throws -> [SmartAlbum] { try catalog.smartAlbums() }
    public func albumCount(_ id: Int64) throws -> Int { try catalog.albumCount(id: id) }
    public func albumNames(containing id: Int64) throws -> [String] { try catalog.albumNames(containing: id) }
    public func photoCount() throws -> Int { try catalog.photoCount() }
    public func photo(id: Int64) throws -> PhotoItem? { try catalog.photo(id: id) }

    // MARK: - Tags

    public func tagCounts() throws -> [TagCount] { try catalog.tagCounts() }
    public func tags(for id: Int64) throws -> [PhotoTag] { try catalog.tags(photoID: id) }
    public func classifications(for id: Int64) throws -> [Classification] { try catalog.classifications(photoID: id) }
    public func hiddenTags() throws -> Set<String> { try catalog.hiddenTagKeys() }
    public func setTagHidden(_ key: String, _ hidden: Bool) throws { try catalog.setTagHidden(key, hidden) }

    /// The vault's Tag Groups.txt, or the copy built into the app when the
    /// vault has none. An unreadable file falls back too, rather than leaving
    /// every tag under Other.
    public func tagGroups(fallback: URL?) -> TagGroups {
        for name in [TagGroups.fileName, TagGroups.legacyFileName] {
            if let groups = try? TagGroups(url: root.appendingPathComponent(name)) { return groups }
        }
        if let fallback, let groups = try? TagGroups(url: fallback) { return groups }
        return TagGroups(text: "")
    }

    // MARK: - Writes

    public func setFavorite(_ on: Bool, for ids: [Int64]) throws {
        try catalog.transaction {
            for id in ids { try catalog.setFavorite(photoID: id, on) }
        }
    }

    @discardableResult
    public func createAlbum(named name: String) throws -> Int64 {
        try catalog.createAlbum(name: name)
    }

    public func renameAlbum(_ id: Int64, to name: String) throws { try catalog.renameAlbum(id: id, to: name) }
    public func deleteAlbum(_ id: Int64) throws { try catalog.deleteAlbum(id: id) }
    public func addToAlbum(_ albumID: Int64, photoIDs: [Int64]) throws { try catalog.addToAlbum(albumID: albumID, photoIDs: photoIDs) }
    public func removeFromAlbum(_ albumID: Int64, photoIDs: [Int64]) throws { try catalog.removeFromAlbum(albumID: albumID, photoIDs: photoIDs) }

    @discardableResult
    public func createSmartAlbum(name: String, predicate: String) throws -> Int64 {
        try catalog.createSmartAlbum(name: name, predicate: predicate)
    }
    public func deleteSmartAlbum(_ id: Int64) throws {
        try catalog.deleteSmartAlbum(id: id)
        // Its sort goes with it, so a later album with the same id starts afresh.
        for suffix in ["order", "ascending"] { try? catalog.deleteMeta("setting.sort.smart.\(id).\(suffix)") }
    }

    @discardableResult
    public func createSmartAlbum(name: String, rules: TagRules) throws -> Int64 {
        try catalog.createSmartAlbum(name: name, rules: rules)
    }

    public func updateSmartAlbum(_ id: Int64, name: String? = nil, rules: TagRules? = nil) throws {
        try catalog.updateSmartAlbum(id: id, name: name, rules: rules)
    }

    // MARK: - Settings

    /// Per-vault settings, kept in the catalog so they travel with the vault and
    /// nothing is written to `~/Library`.
    public func setting(_ key: String) -> String? {
        try? catalog.meta("setting." + key)
    }

    public func setSetting(_ key: String, _ value: String) {
        try? catalog.setMeta("setting." + key, value)
    }

    // MARK: - Trash

    public func moveToTrash(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try catalog.transaction { try catalog.trash(ids: ids) }
    }

    public func restoreFromTrash(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try catalog.transaction { try catalog.restore(ids: ids) }
    }

    public func trashCount() throws -> Int { try catalog.trashCount() }

    public struct EmptyTrashResult: Sendable {
        public var deleted: Int
        public var failures: [String]
    }

    /// Permanently deletes every trashed original from the volume, then its row.
    ///
    /// File first, row second, one photo at a time: if a delete fails the row
    /// stays in the Trash and the failure is reported, rather than leaving a
    /// row-less file that the next scan would quietly bring back. A row whose
    /// file is already gone is simply removed.
    ///
    /// The thumbnail bytes stay in the pack (it is append-only) and stop being
    /// reachable. Note too that a sparse bundle doesn't shrink when files are
    /// deleted; `hdiutil compact` reclaims the space.
    public func emptyTrash() throws -> EmptyTrashResult {
        var result = EmptyTrashResult(deleted: 0, failures: [])
        let fm = FileManager.default
        for item in try catalog.trashedPhotos() {
            let url = root.appendingPathComponent(item.relPath)
            do {
                if fm.fileExists(atPath: url.path) {
                    try fm.removeItem(at: url)
                }
                try catalog.deleteRow(id: item.id)
                result.deleted += 1
            } catch {
                result.failures.append("\(item.relPath): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: - Rotation

    /// Rotates originals a quarter turn — only their orientation value changes
    /// — and rebuilds their thumbnails. Returns a message per item that
    /// couldn't be rotated.
    public func rotate(_ ids: [Int64], clockwise: Bool) throws -> [String] {
        var failures: [String] = []
        for id in ids {
            guard let item = try catalog.photo(id: id) else { continue }
            guard Rotation.canRotate(item), !item.missing else {
                failures.append("\(item.displayName): only JPEG photos can be rotated without changing anything else in the file.")
                continue
            }
            let url = root.appendingPathComponent(item.relPath)
            do {
                try Rotation.rotateOriginal(at: url, clockwise: clockwise)
                // The pack is append-only: the new thumbnail goes on the end and
                // the row is repointed at it, by the same append-then-commit
                // path as every other thumbnail.
                try commit(thumb: try Thumbnailer.makePhotoThumb(url: url), for: item)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? item.fileSize
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? item.mtime
                try catalog.updateFileStats(id: id, fileSize: size, mtime: mtime,
                                            contentKey: ContentKey.compute(url: url, fileSize: size))
            } catch {
                failures.append((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
        return failures
    }

    // MARK: - Classification

    /// What a tagging run would involve, for the question PhotoVault asks
    /// before a large one: how many photos.
    public struct ClassifyPlan: Sendable, Equatable {
        public var photos: Int

        public init(photos: Int) {
            self.photos = photos
        }
    }

    public struct ClassifyResult: Sendable, Equatable {
        public var photos = 0
        public var failures: [String] = []
        public var seconds = 0.0
    }

    /// `ids`, or — with nil — every photo `prefix`'s classifier hasn't tagged.
    public func classificationPlan(ids: [Int64]?, prefix: String) throws -> ClassifyPlan {
        ClassifyPlan(photos: try itemsToClassify(ids, prefix: prefix).count)
    }

    private func itemsToClassify(_ ids: [Int64]?, prefix: String) throws -> [PhotoItem] {
        guard let ids else { return try catalog.photosNeedingClassification(by: prefix) }
        return try ids.compactMap { try catalog.photo(id: $0) }.filter { !$0.missing && !$0.trashed && $0.hasThumb }
    }

    /// Tags photos from their thumbnails — `ids`, or every photo the
    /// classifier hasn't tagged — into the catalog. The photos themselves are
    /// never changed (by design: writing tags into every photo
    /// grows a vault's disk image by about 40% of the photos' size, once, and
    /// a vault may hold 100 GB of photos). Runs as a scan does:
    /// stoppable between photos, each photo committed on its own so stopping
    /// loses nothing, and `close()` waits for it.
    /// `pace` says how hard to work, and may change while it runs (Tag
    /// faster): from the next photo on, up to the classifier's `parallelism`
    /// photos at once, at a higher priority.
    public func classify(ids: [Int64]?, with classifier: TagClassifier, pace: TaggingPace = TaggingPace(),
                         progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws -> ClassifyResult {
        guard !closed, activeScan == nil else { throw CancellationError() }
        let work = Task { try await performClassify(ids: ids, classifier: classifier, pace: pace, progress: progress) }
        activeScan = Task {
            try await withTaskCancellationHandler { _ = try await work.value } onCancel: { work.cancel() }
        }
        defer { activeScan = nil }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private enum Tagged: Sendable {
        case tags(PhotoItem, [ScoredTag])
        case failed(String)
        case skipped
    }

    private func performClassify(ids: [Int64]?, classifier: TagClassifier, pace: TaggingPace,
                                 progress: (@Sendable (ScanProgress) -> Void)?) async throws -> ClassifyResult {
        let base = classifier.record
        let items = try itemsToClassify(ids, prefix: base.prefix)
        var result = ClassifyResult()
        guard !items.isEmpty else { return result }
        let phase = "Tagging with \(base.tool)…"
        progress?(ScanProgress(phase: phase, done: 0, total: items.count))
        let start = Date()
        var next = 0
        try await withThrowingTaskGroup(of: Tagged.self) { group in
            var running = 0
            func window() -> Int { pace.isFast ? max(1, classifier.parallelism) : 1 }
            // Starts the next photo: its row as it is now (it may have gone to
            // the Trash since the list was made) and its thumbnail, read here
            // on the actor; the classifier itself runs off it.
            func startNext() throws -> Bool {
                guard next < items.count else { return false }
                let listed = items[next]
                next += 1
                guard let item = try catalog.photo(id: listed.id), !item.missing, !item.trashed,
                      let thumb = try thumbnailData(for: item) else {
                    group.addTask { .skipped }
                    return true
                }
                let fast = pace.isFast
                group.addTask {
                    do { return .tags(item, try await classifier.classify(thumbnail: thumb, fast: fast)) }
                    catch { return .failed("\(listed.displayName): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)") }
                }
                return true
            }
            try Task.checkCancellation()
            while running < window(), try startNext() { running += 1 }
            while let outcome = try await group.next() {
                running -= 1
                // Stopped: nothing more is saved, and nothing more started.
                try Task.checkCancellation()
                switch outcome {
                case .tags(let item, let tags):
                    var record = base
                    record.date = Date()
                    try catalog.transaction { try catalog.setCatalogOnlyTags(photoID: item.id, record: record, tags) }
                case .failed(let message):
                    result.failures.append(message)
                case .skipped:
                    break
                }
                result.photos += 1
                progress?(ScanProgress(phase: phase, done: result.photos, total: items.count))
                while running < window(), try startNext() { running += 1 }
            }
        }
        result.seconds = Date().timeIntervalSince(start)
        return result
    }

    // MARK: - Export

    /// Albums and favorites keyed on content hash rather than path, so a
    /// diverged copy of the vault can be reconciled later. Writing the exporter
    /// now is cheap; the importer waits until it's actually needed.
    public func exportMembershipsJSON() throws -> Data {
        struct Export: Encodable {
            struct AlbumOut: Encodable { var name: String; var keys: [String] }
            var version = 1
            var favorites: [String]
            var albums: [AlbumOut]
        }
        let favs = try catalog.items(scope: .favorites, filter: .all, includeMissing: true)
            .compactMap(\.contentKey)
        let albumsOut = try catalog.albums().map { album in
            Export.AlbumOut(
                name: album.name,
                keys: try catalog.items(scope: .album(album.id), filter: .all, includeMissing: true)
                    .compactMap(\.contentKey)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Export(favorites: favs, albums: albumsOut))
    }
}

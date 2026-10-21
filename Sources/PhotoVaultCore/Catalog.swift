import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The SQLite sidecar. Not thread-safe on its own — `Store` is the actor that
/// owns one of these and serializes everything through it.
///
/// Nothing written here may identify where the volume currently lives: no
/// volume UUID, no absolute path, no hostname. That rule is what makes a copied
/// bundle work unchanged on another machine under another mount name.
public final class Catalog {
    private var db: OpaquePointer?
    public let url: URL

    public static let schemaVersion: Int32 = 6

    // MARK: - Lifecycle

    public init(url: URL, tmpDir: URL? = nil) throws {
        self.url = url

        // Must be set before the connection opens, or SQLite has already
        // decided where to spill sorts — which would be /var/tmp, off-volume.
        if let tmpDir {
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            setenv("SQLITE_TMPDIR", tmpDir.path, 1)
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(handle)
            throw VaultError.sqlite(msg)
        }
        db = handle
        sqlite3_busy_timeout(db, 5_000)

        try exec("PRAGMA journal_mode = WAL;")
        try exec("PRAGMA synchronous = FULL;")   // ejected often; don't gamble
        try exec("PRAGMA temp_store = MEMORY;")  // no sort spills off-volume
        try exec("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    deinit {
        if db != nil { sqlite3_close_v2(db) }
    }

    /// Checkpoint-truncate so the WAL never carries state across a mount cycle.
    /// This is also what makes a copied catalog a single self-consistent file.
    /// `markingClean: false` leaves the app's clean-shutdown flag as it was —
    /// for a tool that opened the catalog while the app was closed.
    public func closeCleanly(markingClean: Bool = true) {
        guard db != nil else { return }
        if markingClean { try? setMeta("clean_shutdown", "1") }
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
        sqlite3_close_v2(db)
        db = nil
    }

    // MARK: - Raw helpers

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw VaultError.sqlite("\(msg) — while running: \(sql.prefix(120))")
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw VaultError.sqlite(String(cString: sqlite3_errmsg(db)) + " — in: \(sql.prefix(120))")
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw VaultError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try exec("COMMIT;")
            return result
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Migrations

    private func migrate() throws {
        let current = try userVersion()

        // Upgrading a catalog that already holds a library: keep a copy of it
        // as it was first. A migration is one-way, and this file is the only
        // record of the user's albums and favorites.
        if current >= 1 && current < Catalog.schemaVersion {
            try backup(label: "v\(current)")
        }

        if current < 1 {
            try transaction {
                try exec(Catalog.schemaV1)
            }
            try exec("PRAGMA user_version = 1;")
        }
        if current < 2 {
            try transaction {
                try exec(Catalog.migrationV2)
            }
            try exec("PRAGMA user_version = 2;")
        }
        if current < 3 {
            try transaction {
                try exec(Catalog.migrationV3)
                try backfillV3()
            }
            try exec("PRAGMA user_version = 3;")
        }
        if current < 4 {
            try transaction {
                try exec(Catalog.migrationV4)
            }
            try exec("PRAGMA user_version = 4;")
        }
        if current < 5 {
            try transaction {
                try exec(Catalog.migrationV5)
                if current >= 1 { try backfillV5() }
            }
            try exec("PRAGMA user_version = 5;")
        }
        if current < 6 {
            try transaction {
                try exec(Catalog.migrationV6)
            }
            try exec("PRAGMA user_version = 6;")
        }
        // The pragma is the only source of truth for what shape the file is in.
    }

    /// v2: the Trash. A flag rather than a separate table, so a trashed photo
    /// keeps its id, thumbnail and favorite flag in case it is put back.
    static let migrationV2 = """
    ALTER TABLE photo ADD COLUMN trashed INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE photo ADD COLUMN trashed_at REAL;
    CREATE INDEX idx_photo_trashed ON photo(trashed) WHERE trashed = 1;
    """

    /// v3: everything the navigation and tagging work needs, in one step so no
    /// later feature needs another migration.
    /// - `folder` and `sort_name`: browsing by folder, and natural file-name order.
    /// - `has_date`: whether `captured_at` came from the photo or is only the file
    ///   date — decides a vault's default sort order and what the properties
    ///   panel says.
    /// - `tag`, `classification`, `hidden_tag`: empty until tagging ships.
    static let migrationV3 = """
    ALTER TABLE photo ADD COLUMN folder TEXT NOT NULL DEFAULT '';
    ALTER TABLE photo ADD COLUMN sort_name TEXT NOT NULL DEFAULT '';
    ALTER TABLE photo ADD COLUMN has_date INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX idx_photo_folder ON photo(folder);
    CREATE INDEX idx_photo_sort_name ON photo(sort_name);

    CREATE TABLE tag (
      photo_id INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
      source TEXT NOT NULL,
      name TEXT NOT NULL,
      confidence REAL,
      PRIMARY KEY (photo_id, source, name)
    );
    CREATE INDEX idx_tag_name ON tag(name);

    CREATE TABLE classification (
      photo_id INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
      classifier TEXT NOT NULL,
      version TEXT,
      classified_at REAL,
      in_file INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (photo_id, classifier)
    );

    CREATE TABLE hidden_tag (name TEXT PRIMARY KEY);
    """

    /// v4: tagging, and smart albums built from tag rules. The tag tables v3
    /// created were never written to, so they're rebuilt rather than altered.
    /// - `tag.key`: the lower-case form tags from different sources merge on
    ///   (see `TagKey`); `name` keeps the tag as written.
    /// - `photo.tags_read`: the file's mtime when its tags were last read. A
    ///   photo whose file has changed since is read again.
    /// - `classification.label`: the name of the tool behind a prefix.
    /// - `smart_album.rules`: a tag-rule album's rules, as JSON.
    static let migrationV4 = """
    DROP TABLE IF EXISTS tag;
    CREATE TABLE tag (
      photo_id INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
      source TEXT NOT NULL,
      key TEXT NOT NULL,
      name TEXT NOT NULL,
      confidence REAL,
      PRIMARY KEY (photo_id, source, key)
    );
    CREATE INDEX idx_tag_key ON tag(key);
    DROP TABLE IF EXISTS hidden_tag;
    CREATE TABLE hidden_tag (key TEXT PRIMARY KEY);
    ALTER TABLE classification ADD COLUMN label TEXT;
    ALTER TABLE photo ADD COLUMN tags_read REAL;
    ALTER TABLE smart_album ADD COLUMN rules TEXT;
    """

    /// v6: smart albums in an order of their own, set by dragging in the
    /// sidebar — starting from the alphabetical order they were shown in, so
    /// nothing moves on upgrade.
    static let migrationV6 = """
    ALTER TABLE smart_album ADD COLUMN sort_index INTEGER NOT NULL DEFAULT 0;
    UPDATE smart_album SET sort_index = 1 + (
      SELECT COUNT(*) FROM smart_album s2
      WHERE s2.name COLLATE NOCASE < smart_album.name COLLATE NOCASE
         OR (s2.name COLLATE NOCASE = smart_album.name COLLATE NOCASE AND s2.id < smart_album.id));
    """

    /// v5: each file's creation date, for sorting by Date Created.
    static let migrationV5 = """
    ALTER TABLE photo ADD COLUMN created_at REAL;
    CREATE INDEX idx_photo_created ON photo(created_at);
    """

    /// Reads the creation date of every file already in the catalog — from the
    /// file system, without opening the files. About a second for 10,000. A
    /// file that isn't there keeps none, and gets it when a scan finds it.
    private func backfillV5() throws {
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        let read = try prepare("SELECT id, rel_path FROM photo;")
        defer { sqlite3_finalize(read) }
        var rows: [(Int64, String)] = []
        while sqlite3_step(read) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(read, 0), sqlite3_column_text(read, 1).map { String(cString: $0) } ?? ""))
        }
        let write = try prepare("UPDATE photo SET created_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(write) }
        for (id, path) in rows {
            guard let created = (try? root.appendingPathComponent(path).resourceValues(forKeys: [.creationDateKey]))?.creationDate else { continue }
            sqlite3_reset(write)
            sqlite3_bind_double(write, 1, created.timeIntervalSince1970)
            sqlite3_bind_int64(write, 2, id)
            try step(write)
        }
    }

    /// Fills the new columns for rows already in the catalog. A capture date
    /// that differs from the file date must have come from the photo; one equal
    /// to it, or missing, can't be trusted, and the details pass in the next
    /// scan re-reads it from the file.
    private func backfillV3() throws {
        let read = try prepare("SELECT id, rel_path, captured_at, mtime FROM photo;")
        defer { sqlite3_finalize(read) }
        var rows: [(Int64, String, Bool)] = []
        while sqlite3_step(read) == SQLITE_ROW {
            let path = sqlite3_column_text(read, 1).map { String(cString: $0) } ?? ""
            let dated = sqlite3_column_type(read, 2) != SQLITE_NULL
                && abs(sqlite3_column_double(read, 2) - sqlite3_column_double(read, 3)) >= 1
            rows.append((sqlite3_column_int64(read, 0), path, dated))
        }
        let write = try prepare("UPDATE photo SET folder = ?, sort_name = ?, has_date = ? WHERE id = ?;")
        defer { sqlite3_finalize(write) }
        for (id, path, dated) in rows {
            sqlite3_reset(write)
            sqlite3_bind_text(write, 1, PhotoItem.folder(of: path), -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(write, 2, PhotoItem.sortName(of: path), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(write, 3, dated ? 1 : 0)
            sqlite3_bind_int64(write, 4, id)
            try step(write)
        }
    }

    /// A consistent copy of the catalog in `.catalog/backups/`, on the volume
    /// like everything else. `VACUUM INTO` produces a single self-contained
    /// file even while the WAL holds uncommitted pages.
    @discardableResult
    public func backup(label: String) throws -> URL {
        let dir = url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dest = dir.appendingPathComponent("catalog-\(label)-\(stamp).sqlite")
        let path = dest.path.replacingOccurrences(of: "'", with: "''")
        try exec("VACUUM INTO '\(path)';")
        return dest
    }

    public func userVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    static let schemaV1 = """
    CREATE TABLE photo (
      id INTEGER PRIMARY KEY,
      rel_path TEXT NOT NULL UNIQUE,
      file_size INTEGER, mtime REAL, content_key TEXT,
      width INTEGER, height INTEGER, orientation INTEGER,
      captured_at REAL,
      favorite INTEGER DEFAULT 0,
      missing INTEGER DEFAULT 0,
      media_type INTEGER NOT NULL DEFAULT 0,
      duration REAL,
      poster_time REAL,
      playable INTEGER DEFAULT 1,
      thumb_off INTEGER, thumb_len INTEGER
    );

    CREATE TABLE album (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      parent_id INTEGER,
      sort_index INTEGER DEFAULT 0
    );

    CREATE TABLE album_photo (
      album_id INTEGER NOT NULL REFERENCES album(id) ON DELETE CASCADE,
      photo_id INTEGER NOT NULL REFERENCES photo(id) ON DELETE CASCADE,
      position INTEGER DEFAULT 0,
      PRIMARY KEY (album_id, photo_id)
    );

    CREATE TABLE smart_album (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      predicate TEXT NOT NULL
    );

    CREATE TABLE dir_state (rel_path TEXT PRIMARY KEY, mtime REAL);
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);

    CREATE INDEX idx_photo_captured ON photo(captured_at);
    CREATE INDEX idx_photo_fav ON photo(favorite) WHERE favorite = 1;
    CREATE INDEX idx_photo_key ON photo(content_key);
    CREATE INDEX idx_album_photo_photo ON album_photo(photo_id);
    """

    // MARK: - Meta

    public func meta(_ key: String) throws -> String? {
        let stmt = try prepare("SELECT value FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    public func deleteMeta(_ key: String) throws {
        let stmt = try prepare("DELETE FROM meta WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        try step(stmt)
    }

    public func setMeta(_ key: String, _ value: String) throws {
        let stmt = try prepare("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
        try step(stmt)
    }

    // MARK: - Photo rows

    private static let photoColumns = """
    id, rel_path, file_size, mtime, content_key, width, height, orientation, \
    captured_at, favorite, missing, media_type, duration, poster_time, playable, \
    thumb_off, thumb_len, trashed, has_date, created_at
    """

    private func readPhoto(_ s: OpaquePointer) -> PhotoItem {
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(s, i) else { return nil }
            return String(cString: c)
        }
        func optDouble(_ i: Int32) -> Double? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
        }
        func optInt64(_ i: Int32) -> Int64? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_int64(s, i)
        }
        return PhotoItem(
            id: sqlite3_column_int64(s, 0),
            relPath: text(1) ?? "",
            fileSize: sqlite3_column_int64(s, 2),
            mtime: sqlite3_column_double(s, 3),
            contentKey: text(4),
            width: Int(sqlite3_column_int(s, 5)),
            height: Int(sqlite3_column_int(s, 6)),
            orientation: Int(sqlite3_column_int(s, 7)),
            capturedAt: optDouble(8),
            favorite: sqlite3_column_int(s, 9) != 0,
            missing: sqlite3_column_int(s, 10) != 0,
            mediaType: MediaType(rawValue: Int(sqlite3_column_int(s, 11))) ?? .photo,
            duration: optDouble(12),
            posterTime: optDouble(13),
            playable: sqlite3_column_int(s, 14) != 0,
            thumbOff: optInt64(15),
            thumbLen: optInt64(16).map(Int.init),
            trashed: sqlite3_column_int(s, 17) != 0,
            hasDate: sqlite3_column_int(s, 18) != 0,
            createdAt: optDouble(19)
        )
    }

    private func bindPhotoFields(_ stmt: OpaquePointer, _ p: PhotoItem, from start: Int32) {
        var i = start
        sqlite3_bind_int64(stmt, i, p.fileSize); i += 1
        sqlite3_bind_double(stmt, i, p.mtime); i += 1
        if let k = p.contentKey { sqlite3_bind_text(stmt, i, k, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, i) }; i += 1
        sqlite3_bind_int(stmt, i, Int32(p.width)); i += 1
        sqlite3_bind_int(stmt, i, Int32(p.height)); i += 1
        sqlite3_bind_int(stmt, i, Int32(p.orientation)); i += 1
        if let c = p.capturedAt { sqlite3_bind_double(stmt, i, c) } else { sqlite3_bind_null(stmt, i) }; i += 1
        sqlite3_bind_int(stmt, i, p.missing ? 1 : 0); i += 1
        sqlite3_bind_int(stmt, i, Int32(p.mediaType.rawValue)); i += 1
        if let d = p.duration { sqlite3_bind_double(stmt, i, d) } else { sqlite3_bind_null(stmt, i) }; i += 1
        if let t = p.posterTime { sqlite3_bind_double(stmt, i, t) } else { sqlite3_bind_null(stmt, i) }; i += 1
        sqlite3_bind_int(stmt, i, p.playable ? 1 : 0); i += 1
    }

    /// Inserts a newly found file, or records that a known one is still there.
    ///
    /// For a file already in the catalog this touches only what the scan
    /// actually knows: it's present, and its size and date. Everything learned
    /// from inside the file — dimensions, orientation, capture date, duration,
    /// whether a video plays — is left alone. (Until 1.2.0 a rescan overwrote
    /// those with the scanner's blanks; see `photosNeedingDetails`.) If the file
    /// has changed, its thumbnail is dropped so the same scan rebuilds it, and
    /// with it those details. Favorites, album memberships and the Trash flag
    /// are never touched.
    @discardableResult
    public func upsertPhoto(_ p: PhotoItem) throws -> Int64 {
        let sql = """
        INSERT INTO photo (rel_path, file_size, mtime, content_key, width, height, orientation,
                           captured_at, missing, media_type, duration, poster_time, playable,
                           folder, sort_name, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(rel_path) DO UPDATE SET
          missing = 0,
          thumb_off = CASE WHEN photo.file_size != excluded.file_size OR photo.mtime != excluded.mtime
                           THEN NULL ELSE photo.thumb_off END,
          thumb_len = CASE WHEN photo.file_size != excluded.file_size OR photo.mtime != excluded.mtime
                           THEN NULL ELSE photo.thumb_len END,
          file_size = excluded.file_size,
          mtime = excluded.mtime,
          content_key = COALESCE(excluded.content_key, photo.content_key),
          media_type = excluded.media_type,
          created_at = COALESCE(excluded.created_at, photo.created_at);
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, p.relPath, -1, SQLITE_TRANSIENT)
        bindPhotoFields(stmt, p, from: 2)
        sqlite3_bind_text(stmt, 14, PhotoItem.folder(of: p.relPath), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 15, PhotoItem.sortName(of: p.relPath), -1, SQLITE_TRANSIENT)
        if let c = p.createdAt { sqlite3_bind_double(stmt, 16, c) } else { sqlite3_bind_null(stmt, 16) }
        try step(stmt)
        return try photoID(relPath: p.relPath) ?? sqlite3_last_insert_rowid(db)
    }

    /// Every known file's id, size and date, for a scan to tell which files
    /// are new or changed.
    public func allFiles() throws -> [String: (id: Int64, size: Int64, mtime: Double)] {
        let stmt = try prepare("SELECT rel_path, id, file_size, mtime FROM photo;")
        defer { sqlite3_finalize(stmt) }
        var out: [String: (id: Int64, size: Int64, mtime: Double)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                out[String(cString: c)] = (sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2), sqlite3_column_double(stmt, 3))
            }
        }
        return out
    }

    /// Photos whose details are missing although their thumbnail exists: the
    /// damage the pre-1.2.0 rescan left behind. The scan re-reads them from
    /// the files.
    public func photosNeedingDetails(limit: Int = 100_000) throws -> [PhotoItem] {
        let sql = """
        SELECT \(Catalog.photoColumns) FROM photo
        WHERE missing = 0 AND thumb_off IS NOT NULL
          AND (width = 0 OR height = 0 OR captured_at IS NULL)
        ORDER BY id LIMIT ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [PhotoItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(readPhoto(stmt)) }
        return out
    }

    /// Writes what was read from inside a file. `capturedAt` nil means the
    /// file carries no date, so the file's own date stands in for it.
    public func setDetails(id: Int64, width: Int, height: Int, orientation: Int,
                           capturedAt: Double?, duration: Double?) throws {
        let stmt = try prepare("""
            UPDATE photo SET width = ?, height = ?, orientation = ?,
              captured_at = COALESCE(?, mtime), has_date = ?,
              duration = COALESCE(?, duration)
            WHERE id = ?;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(width))
        sqlite3_bind_int(stmt, 2, Int32(height))
        sqlite3_bind_int(stmt, 3, Int32(orientation))
        if let capturedAt { sqlite3_bind_double(stmt, 4, capturedAt) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_bind_int(stmt, 5, capturedAt == nil ? 0 : 1)
        if let duration { sqlite3_bind_double(stmt, 6, duration) } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_int64(stmt, 7, id)
        try step(stmt)
    }

    public func photoID(relPath: String) throws -> Int64? {
        let stmt = try prepare("SELECT id FROM photo WHERE rel_path = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, relPath, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    public func photo(id: Int64) throws -> PhotoItem? {
        let stmt = try prepare("SELECT \(Catalog.photoColumns) FROM photo WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readPhoto(stmt)
    }

    public func allRelPaths() throws -> [String: Int64] {
        let stmt = try prepare("SELECT rel_path, id FROM photo;")
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int64] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                out[String(cString: c)] = sqlite3_column_int64(stmt, 1)
            }
        }
        return out
    }

    /// Records where a thumbnail landed in the pack. Called only *after* the
    /// blob is appended and F_FULLFSYNC'd — never before.
    public func setThumb(photoID: Int64, offset: Int64, length: Int) throws {
        let stmt = try prepare("UPDATE photo SET thumb_off = ?, thumb_len = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, offset)
        sqlite3_bind_int64(stmt, 2, Int64(length))
        sqlite3_bind_int64(stmt, 3, photoID)
        try step(stmt)
    }

    public func setPosterTime(photoID: Int64, _ t: Double) throws {
        let stmt = try prepare("UPDATE photo SET poster_time = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, t)
        sqlite3_bind_int64(stmt, 2, photoID)
        try step(stmt)
    }

    public func setFavorite(photoID: Int64, _ on: Bool) throws {
        let stmt = try prepare("UPDATE photo SET favorite = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, on ? 1 : 0)
        sqlite3_bind_int64(stmt, 2, photoID)
        try step(stmt)
    }

    /// `missing` is a flag, never a delete: a temporarily absent file must not
    /// silently drop out of every album it belongs to.
    public func markMissing(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let stmt = try prepare("UPDATE photo SET missing = 1 WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
    }

    /// The highest byte the catalog knows about. Anything past it in the pack is
    /// crash residue from an append that never got its row committed.
    public func maxThumbTail() throws -> Int64 {
        let stmt = try prepare("SELECT MAX(thumb_off + thumb_len) FROM photo WHERE thumb_off IS NOT NULL;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    /// A file whose path vanished but whose content key turns up under a new
    /// path is the same photo moved. Relinking keeps its album memberships and
    /// its favorite flag instead of orphaning them.
    public func relink(missingID: Int64, toRelPath newPath: String) throws {
        let stmt = try prepare("UPDATE photo SET rel_path = ?, folder = ?, sort_name = ?, missing = 0 WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, newPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, PhotoItem.folder(of: newPath), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, PhotoItem.sortName(of: newPath), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 4, missingID)
        try step(stmt)
    }

    /// Each missing row with a present row of the same content — a photo
    /// that has moved — where the present row carries nothing of a person's
    /// own: no favorite, no album, not in the Trash. The newest such row first
    /// for each missing one: the copy a scan has just made.
    public func relinkCandidates() throws -> [(missingID: Int64, presentID: Int64, relPath: String)] {
        let stmt = try prepare("""
            SELECT m.id, p.id, p.rel_path FROM photo m
            JOIN photo p ON p.content_key = m.content_key AND p.missing = 0 AND p.id != m.id
            WHERE m.missing = 1 AND m.content_key IS NOT NULL
              AND p.favorite = 0 AND p.trashed = 0
              AND NOT EXISTS (SELECT 1 FROM album_photo a WHERE a.photo_id = p.id)
            ORDER BY m.id, p.id DESC;
            """)
        defer { sqlite3_finalize(stmt) }
        var out: [(missingID: Int64, presentID: Int64, relPath: String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let path = sqlite3_column_text(stmt, 2) else { continue }
            out.append((sqlite3_column_int64(stmt, 0), sqlite3_column_int64(stmt, 1), String(cString: path)))
        }
        return out
    }

    public func photosNeedingThumbs(limit: Int = 100_000) throws -> [PhotoItem] {
        let sql = """
        SELECT \(Catalog.photoColumns) FROM photo
        WHERE thumb_off IS NULL AND missing = 0
        ORDER BY id LIMIT ?;
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [PhotoItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(readPhoto(stmt)) }
        return out
    }

    // MARK: - Queries

    public func items(scope: LibraryScope, filter: MediaFilter, sort: PhotoOrder = .date, ascending: Bool = true,
                      seed: UInt64 = 0, includeMissing: Bool = false, groups: TagGroups = TagGroups(text: "")) throws -> [PhotoItem] {
        var joins = ""
        var clauses: [String] = []
        var scopeID: Int64?
        var texts: [String] = []

        switch scope {
        case .all:
            break
        case .favorites:
            clauses.append("p.favorite = 1")
        case .album(let id):
            joins = "JOIN album_photo ap ON ap.photo_id = p.id"
            clauses.append("ap.album_id = ?")
            scopeID = id
        case .smart(let id):
            guard let sa = try smartAlbum(id: id) else { return [] }
            if let rules = sa.rules {
                if let (clause, bindings) = rules.sql(groups: groups) {
                    clauses.append(clause)
                    texts += bindings
                }
            } else if !sa.predicate.isEmpty {
                clauses.append("(\(sa.predicate))")
            }
        case .trash:
            break
        case .folder(let path):
            // The folder and every folder beneath it. As a range rather than
            // LIKE: folder names can hold % and _, and the range uses the
            // index. "/" sorts just before "0", so [path/, path0) is exactly
            // the paths under it — not a neighbour like "2019b".
            clauses.append("(p.folder = ? OR (p.folder >= ? AND p.folder < ?))")
            texts += [path, path + "/", path + "0"]
        }
        // The Trash shows only trashed rows; every other view shows none.
        if case .trash = scope {
            clauses.append("p.trashed = 1")
        } else {
            clauses.append("p.trashed = 0")
        }

        switch filter {
        case .all: break
        case .photos: clauses.append("p.media_type = 0")
        case .videos: clauses.append("p.media_type = 1")
        }
        if !includeMissing { clauses.append("p.missing = 0") }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        // Every view follows its sort, either way round; an album can also keep
        // the order photos were added in. Ties fall back to file name, the same
        // way round; photos with no date at all come last whichever way the
        // dates run.
        let way = ascending ? "ASC" : "DESC"
        let order: String
        switch (scope, sort) {
        case (.album, .added): order = "ap.position \(way), p.sort_name, p.id"
        case (_, .name), (_, .added): order = "p.sort_name \(way), p.rel_path \(way)"
        case (_, .date): order = "p.captured_at IS NULL, p.captured_at \(way), p.sort_name \(way), p.id \(way)"
        case (_, .created): order = "p.created_at IS NULL, p.created_at \(way), p.sort_name \(way), p.id \(way)"
        case (_, .length): order = "COALESCE(p.duration, 0) \(way), p.sort_name \(way), p.id \(way)"
        case (_, .random): order = "p.id"
        }
        let cols = Catalog.photoColumns.split(separator: ",").map { "p.\($0.trimmingCharacters(in: .whitespaces))" }.joined(separator: ", ")

        let stmt = try prepare("SELECT \(cols) FROM photo p \(joins) \(whereSQL) ORDER BY \(order);")
        defer { sqlite3_finalize(stmt) }
        if let scopeID { sqlite3_bind_int64(stmt, 1, scopeID) }
        for (i, text) in texts.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), text, -1, SQLITE_TRANSIENT) }
        var out: [PhotoItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(readPhoto(stmt)) }
        if sort == .random {
            out.sort { Shuffle.key($0.id, seed: seed) < Shuffle.key($1.id, seed: seed) }
        }
        return out
    }

    /// Photos directly in each folder, for the folder tree.
    public func folderCounts() throws -> [String: Int] {
        let stmt = try prepare("SELECT folder, COUNT(*) FROM photo WHERE missing = 0 AND trashed = 0 GROUP BY folder;")
        defer { sqlite3_finalize(stmt) }
        var out: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out[String(cString: c)] = Int(sqlite3_column_int64(stmt, 1)) }
        }
        return out
    }

    /// How many photos carry a real capture date, for the default sort order.
    public func datedCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM photo WHERE missing = 0 AND trashed = 0 AND has_date = 1;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    public func photoCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM photo WHERE missing = 0 AND trashed = 0;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Albums

    @discardableResult
    public func createAlbum(name: String, parentID: Int64? = nil) throws -> Int64 {
        let stmt = try prepare("INSERT INTO album (name, parent_id, sort_index) VALUES (?, ?, (SELECT COALESCE(MAX(sort_index), 0) + 1 FROM album));")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        if let parentID { sqlite3_bind_int64(stmt, 2, parentID) } else { sqlite3_bind_null(stmt, 2) }
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func renameAlbum(id: Int64, to name: String) throws {
        let stmt = try prepare("UPDATE album SET name = ? WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        try step(stmt)
    }

    /// Numbers `ids` 1, 2, 3… in `table`'s `sort_index`, in one transaction.
    func setOrder(table: String, ids: [Int64]) throws {
        precondition(table == "album" || table == "smart_album")
        try transaction {
            let stmt = try prepare("UPDATE \(table) SET sort_index = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            for (i, id) in ids.enumerated() {
                sqlite3_reset(stmt)
                sqlite3_bind_int(stmt, 1, Int32(i + 1))
                sqlite3_bind_int64(stmt, 2, id)
                try step(stmt)
            }
        }
    }

    /// A new album named `name` holding `id`'s photos in the same order.
    public func duplicateAlbum(id: Int64, name: String) throws -> Int64 {
        var copy: Int64 = 0
        try transaction {
            copy = try createAlbum(name: name)
            let stmt = try prepare("""
            INSERT INTO album_photo (album_id, photo_id, position)
            SELECT ?, photo_id, position FROM album_photo WHERE album_id = ?;
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, copy)
            sqlite3_bind_int64(stmt, 2, id)
            try step(stmt)
        }
        return copy
    }

    /// A new smart album named `name` with `id`'s rules (or predicate).
    public func duplicateSmartAlbum(id: Int64, name: String) throws -> Int64 {
        guard let original = try smartAlbum(id: id) else { throw VaultError.sqlite("no smart album \(id)") }
        if let rules = original.rules { return try createSmartAlbum(name: name, rules: rules) }
        return try createSmartAlbum(name: name, predicate: original.predicate)
    }

    public func deleteAlbum(id: Int64) throws {
        let stmt = try prepare("DELETE FROM album WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        try step(stmt)
    }

    public func albums() throws -> [Album] {
        let stmt = try prepare("SELECT id, name, parent_id, sort_index FROM album ORDER BY sort_index, name;")
        defer { sqlite3_finalize(stmt) }
        var out: [Album] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Album(
                id: sqlite3_column_int64(stmt, 0),
                name: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                parentID: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 2),
                sortIndex: Int(sqlite3_column_int(stmt, 3))
            ))
        }
        return out
    }

    public func addToAlbum(albumID: Int64, photoIDs: [Int64]) throws {
        let stmt = try prepare("""
        INSERT INTO album_photo (album_id, photo_id, position)
        VALUES (?, ?, (SELECT COALESCE(MAX(position), 0) + 1 FROM album_photo WHERE album_id = ?))
        ON CONFLICT(album_id, photo_id) DO NOTHING;
        """)
        defer { sqlite3_finalize(stmt) }
        for pid in photoIDs {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, albumID)
            sqlite3_bind_int64(stmt, 2, pid)
            sqlite3_bind_int64(stmt, 3, albumID)
            try step(stmt)
        }
    }

    public func removeFromAlbum(albumID: Int64, photoIDs: [Int64]) throws {
        let stmt = try prepare("DELETE FROM album_photo WHERE album_id = ? AND photo_id = ?;")
        defer { sqlite3_finalize(stmt) }
        for pid in photoIDs {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, albumID)
            sqlite3_bind_int64(stmt, 2, pid)
            try step(stmt)
        }
    }

    /// Names of the albums a photo is in, for the properties panel.
    public func albumNames(containing photoID: Int64) throws -> [String] {
        let stmt = try prepare("""
            SELECT a.name FROM album a JOIN album_photo ap ON ap.album_id = a.id
            WHERE ap.photo_id = ? ORDER BY a.sort_index, a.name;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, photoID)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    public func albumCount(id: Int64) throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM album_photo ap JOIN photo p ON p.id = ap.photo_id WHERE ap.album_id = ? AND p.missing = 0 AND p.trashed = 0;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Smart albums

    @discardableResult
    public func createSmartAlbum(name: String, rules: TagRules) throws -> Int64 {
        let stmt = try prepare("INSERT INTO smart_album (name, predicate, rules, sort_index) VALUES (?, '', ?, (SELECT COALESCE(MAX(sort_index), 0) + 1 FROM smart_album));")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, try Catalog.encode(rules), -1, SQLITE_TRANSIENT)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func updateSmartAlbum(id: Int64, name: String? = nil, rules: TagRules? = nil) throws {
        if let name {
            let stmt = try prepare("UPDATE smart_album SET name = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, id)
            try step(stmt)
        }
        if let rules {
            let stmt = try prepare("UPDATE smart_album SET rules = ? WHERE id = ?;")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, try Catalog.encode(rules), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, id)
            try step(stmt)
        }
    }

    private static func encode(_ rules: TagRules) throws -> String {
        String(data: try JSONEncoder().encode(rules), encoding: .utf8) ?? "{}"
    }

    public func createSmartAlbum(name: String, predicate: String) throws -> Int64 {
        let stmt = try prepare("INSERT INTO smart_album (name, predicate, sort_index) VALUES (?, ?, (SELECT COALESCE(MAX(sort_index), 0) + 1 FROM smart_album));")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, predicate, -1, SQLITE_TRANSIENT)
        try step(stmt)
        return sqlite3_last_insert_rowid(db)
    }

    public func smartAlbums() throws -> [SmartAlbum] {
        let stmt = try prepare("SELECT id, name, predicate, rules FROM smart_album ORDER BY sort_index, name COLLATE NOCASE;")
        defer { sqlite3_finalize(stmt) }
        var out: [SmartAlbum] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rules = sqlite3_column_text(stmt, 3).flatMap {
                try? JSONDecoder().decode(TagRules.self, from: Data(String(cString: $0).utf8))
            }
            out.append(SmartAlbum(
                id: sqlite3_column_int64(stmt, 0),
                name: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                predicate: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "1",
                rules: rules
            ))
        }
        return out
    }

    public func smartAlbum(id: Int64) throws -> SmartAlbum? {
        try smartAlbums().first { $0.id == id }
    }

    public func deleteSmartAlbum(id: Int64) throws {
        let stmt = try prepare("DELETE FROM smart_album WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        try step(stmt)
    }

    // MARK: - Trash

    /// Moves rows to the Trash and out of every album they were in. The files
    /// themselves are untouched until the Trash is emptied.
    public func trash(ids: [Int64], at time: Double = Date().timeIntervalSince1970) throws {
        let mark = try prepare("UPDATE photo SET trashed = 1, trashed_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(mark) }
        let unalbum = try prepare("DELETE FROM album_photo WHERE photo_id = ?;")
        defer { sqlite3_finalize(unalbum) }
        for id in ids {
            sqlite3_reset(mark)
            sqlite3_bind_double(mark, 1, time)
            sqlite3_bind_int64(mark, 2, id)
            try step(mark)
            sqlite3_reset(unalbum)
            sqlite3_bind_int64(unalbum, 1, id)
            try step(unalbum)
        }
    }

    /// Takes rows back out of the Trash. Album memberships were dropped when
    /// they went in and don't come back; the favorite flag was kept and does.
    public func restore(ids: [Int64]) throws {
        let stmt = try prepare("UPDATE photo SET trashed = 0, trashed_at = NULL WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, id)
            try step(stmt)
        }
    }

    public func trashCount() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM photo WHERE trashed = 1;")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Every trashed row, including ones whose file has already gone missing.
    public func trashedPhotos() throws -> [PhotoItem] {
        try items(scope: .trash, filter: .all, includeMissing: true)
    }

    /// Removes a row for good. Only for a photo whose file has been deleted.
    public func deleteRow(id: Int64) throws {
        let stmt = try prepare("DELETE FROM photo WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        try step(stmt)
    }

    /// After the app itself rewrites an original (rotation), the stored size,
    /// mtime and content key must follow, or the next scan treats the file as
    /// changed and moved-file relinking stops recognising it.
    public func updateFileStats(id: Int64, fileSize: Int64, mtime: Double, contentKey: String?) throws {
        let stmt = try prepare("UPDATE photo SET file_size = ?, mtime = ?, content_key = COALESCE(?, content_key) WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, fileSize)
        sqlite3_bind_double(stmt, 2, mtime)
        if let contentKey { sqlite3_bind_text(stmt, 3, contentKey, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int64(stmt, 4, id)
        try step(stmt)
    }

    // MARK: - Directory state (warm start)

    public func dirStates() throws -> [String: Double] {
        let stmt = try prepare("SELECT rel_path, mtime FROM dir_state;")
        defer { sqlite3_finalize(stmt) }
        var out: [String: Double] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                out[String(cString: c)] = sqlite3_column_double(stmt, 1)
            }
        }
        return out
    }

    public func setDirState(_ relPath: String, mtime: Double) throws {
        let stmt = try prepare("INSERT INTO dir_state (rel_path, mtime) VALUES (?, ?) ON CONFLICT(rel_path) DO UPDATE SET mtime = excluded.mtime;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, relPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, mtime)
        try step(stmt)
    }

    public func removeDirStates(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let stmt = try prepare("DELETE FROM dir_state WHERE rel_path = ?;")
        defer { sqlite3_finalize(stmt) }
        for p in paths {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, p, -1, SQLITE_TRANSIENT)
            try step(stmt)
        }
    }

    // MARK: - Tags

    public struct TagReadItem: Sendable {
        public var id: Int64
        public var relPath: String
        public var mtime: Double
    }

    /// Every photo whose file is in the vault, the Trash's included.
    public func presentPhotos() throws -> [PhotoItem] {
        let stmt = try prepare("SELECT \(Catalog.photoColumns) FROM photo WHERE missing = 0 AND media_type = 0 ORDER BY id;")
        defer { sqlite3_finalize(stmt) }
        var out: [PhotoItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(readPhoto(stmt)) }
        return out
    }

    /// Photos whose file is new or has changed since its tags were last read.
    public func photosNeedingTags(limit: Int = 100_000) throws -> [TagReadItem] {
        let stmt = try prepare("""
            SELECT id, rel_path, mtime FROM photo
            WHERE missing = 0 AND trashed = 0 AND media_type = 0
              AND (tags_read IS NULL OR tags_read != mtime)
            ORDER BY id LIMIT ?;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [TagReadItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(TagReadItem(id: sqlite3_column_int64(stmt, 0),
                                   relPath: String(cString: sqlite3_column_text(stmt, 1)),
                                   mtime: sqlite3_column_double(stmt, 2)))
        }
        return out
    }

    /// Replaces what a photo's file says about its tags — its keyword tags and
    /// the records of the tools that wrote them — and notes the file mtime they
    /// were read at. JoyTag tags kept in the catalog only, for a file that can't
    /// hold them, survive the re-read, unless the file now carries JoyTag's own
    /// record. Call inside a transaction.
    public func setFileTags(photoID: Int64, tags: [FileTag], records: [ToolRecord], fileMtime: Double) throws {
        let fileHasJoyTag = records.contains { $0.prefix == JoyTag.prefix }
        let catalogOnly = try inFile(photoID: photoID, classifier: JoyTag.prefix) == false
        let keepCatalogJoyTag = !fileHasJoyTag && catalogOnly
        // Keywords the catalog alone marks as a tool's (pv-prefix-keywords)
        // stay that tool's while they're still in the file.
        let marked = try catalogMarks(photoID: photoID)
        let delete = try prepare("DELETE FROM tag WHERE photo_id = ? AND NOT (? AND source = 'jt');")
        defer { sqlite3_finalize(delete) }
        sqlite3_bind_int64(delete, 1, photoID)
        sqlite3_bind_int(delete, 2, keepCatalogJoyTag ? 1 : 0)
        try step(delete)

        let insert = try prepare("INSERT OR REPLACE INTO tag (photo_id, source, key, name) VALUES (?, ?, ?, ?);")
        defer { sqlite3_finalize(insert) }
        for tag in tags where !(keepCatalogJoyTag && tag.source == JoyTag.prefix) {
            let source = tag.source == FileTag.manual ? (marked[tag.key] ?? tag.source) : tag.source
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, photoID)
            sqlite3_bind_text(insert, 2, source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insert, 3, tag.key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insert, 4, tag.name, -1, SQLITE_TRANSIENT)
            try step(insert)
        }

        // A record that has gone from the file has gone from the photo.
        let prefixes = records.map(\.prefix)
        let gone = try prepare("""
            DELETE FROM classification WHERE photo_id = ? AND in_file = 1
              AND classifier NOT IN (SELECT value FROM json_each(?));
            """)
        defer { sqlite3_finalize(gone) }
        sqlite3_bind_int64(gone, 1, photoID)
        let json = String(data: try JSONEncoder().encode(prefixes), encoding: .utf8) ?? "[]"
        sqlite3_bind_text(gone, 2, json, -1, SQLITE_TRANSIENT)
        try step(gone)

        let upsert = try prepare("""
            INSERT INTO classification (photo_id, classifier, version, classified_at, in_file, label)
            VALUES (?, ?, ?, ?, 1, ?)
            ON CONFLICT(photo_id, classifier) DO UPDATE SET
              version = excluded.version, classified_at = excluded.classified_at,
              in_file = 1, label = excluded.label;
            """)
        defer { sqlite3_finalize(upsert) }
        for record in records {
            sqlite3_reset(upsert)
            sqlite3_bind_int64(upsert, 1, photoID)
            sqlite3_bind_text(upsert, 2, record.prefix, -1, SQLITE_TRANSIENT)
            if let v = record.version { sqlite3_bind_text(upsert, 3, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(upsert, 3) }
            if let d = record.date { sqlite3_bind_double(upsert, 4, d.timeIntervalSince1970) } else { sqlite3_bind_null(upsert, 4) }
            sqlite3_bind_text(upsert, 5, record.tool, -1, SQLITE_TRANSIENT)
            try step(upsert)
        }

        let mark = try prepare("UPDATE photo SET tags_read = ? WHERE id = ?;")
        defer { sqlite3_finalize(mark) }
        sqlite3_bind_double(mark, 1, fileMtime)
        sqlite3_bind_int64(mark, 2, photoID)
        try step(mark)
    }

    /// Each keyword the catalog alone marks as a tool's, with the tool's prefix.
    private func catalogMarks(photoID: Int64) throws -> [String: String] {
        let stmt = try prepare("""
            SELECT t.key, t.source FROM tag t
            JOIN classification c ON c.photo_id = t.photo_id AND c.classifier = t.source
            WHERE t.photo_id = ? AND c.in_file = 0 AND t.source NOT IN ('jt', 'manual');
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, photoID)
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            out[String(cString: sqlite3_column_text(stmt, 0))] = String(cString: sqlite3_column_text(stmt, 1))
        }
        return out
    }

    /// Marks a photo's own keywords — those from its file with no declared
    /// prefix — as a tool's, in the catalog only: the file isn't touched, and
    /// the mark sticks when the file is re-read (see `setFileTags`). Call
    /// inside a transaction.
    public func markOwnKeywords(photoID: Int64, as record: ToolRecord) throws {
        let update = try prepare("UPDATE OR REPLACE tag SET source = ? WHERE photo_id = ? AND source = 'manual';")
        defer { sqlite3_finalize(update) }
        sqlite3_bind_text(update, 1, record.prefix, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(update, 2, photoID)
        try step(update)

        let upsert = try prepare("""
            INSERT INTO classification (photo_id, classifier, version, classified_at, in_file, label)
            VALUES (?, ?, ?, ?, 0, ?)
            ON CONFLICT(photo_id, classifier) DO UPDATE SET
              version = excluded.version, classified_at = excluded.classified_at,
              in_file = 0, label = excluded.label;
            """)
        defer { sqlite3_finalize(upsert) }
        sqlite3_bind_int64(upsert, 1, photoID)
        sqlite3_bind_text(upsert, 2, record.prefix, -1, SQLITE_TRANSIENT)
        if let v = record.version { sqlite3_bind_text(upsert, 3, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(upsert, 3) }
        if let d = record.date { sqlite3_bind_double(upsert, 4, d.timeIntervalSince1970) } else { sqlite3_bind_null(upsert, 4) }
        sqlite3_bind_text(upsert, 5, record.tool, -1, SQLITE_TRANSIENT)
        try step(upsert)
    }

    /// The file mtime a photo's tags were last read at, if they have been.
    public func tagsRead(photoID: Int64) throws -> Double? {
        let stmt = try prepare("SELECT tags_read FROM photo WHERE id = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, photoID)
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, 0)
    }

    /// Whether a classifier's record for a photo is in the file (true), in the
    /// catalog only (false), or absent (nil).
    private func inFile(photoID: Int64, classifier: String) throws -> Bool? {
        let stmt = try prepare("SELECT in_file FROM classification WHERE photo_id = ? AND classifier = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, photoID)
        sqlite3_bind_text(stmt, 2, classifier, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) != 0 : nil
    }

    /// Every tag in the vault's visible photos, merged across sources by key,
    /// with the number of photos carrying it. Most common first.
    public func tagCounts() throws -> [TagCount] {
        let stmt = try prepare("""
            SELECT t.key, MIN(t.name), COUNT(DISTINCT t.photo_id), GROUP_CONCAT(DISTINCT t.source)
            FROM tag t JOIN photo p ON p.id = t.photo_id
            WHERE p.missing = 0 AND p.trashed = 0
            GROUP BY t.key ORDER BY 3 DESC, 1;
            """)
        defer { sqlite3_finalize(stmt) }
        var out: [TagCount] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sources = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            out.append(TagCount(key: String(cString: sqlite3_column_text(stmt, 0)),
                                name: String(cString: sqlite3_column_text(stmt, 1)),
                                photos: Int(sqlite3_column_int(stmt, 2)),
                                sources: Set(sources.split(separator: ",").map(String.init))))
        }
        return out
    }

    /// One photo's tags, every source.
    public func tags(photoID: Int64) throws -> [PhotoTag] {
        let stmt = try prepare("SELECT source, name, key, confidence FROM tag WHERE photo_id = ? ORDER BY source, confidence DESC, key;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, photoID)
        var out: [PhotoTag] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(PhotoTag(source: String(cString: sqlite3_column_text(stmt, 0)),
                                name: String(cString: sqlite3_column_text(stmt, 1)),
                                key: String(cString: sqlite3_column_text(stmt, 2)),
                                confidence: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3)))
        }
        return out
    }

    /// Which tools have tagged a photo, and when.
    public func classifications(photoID: Int64) throws -> [Classification] {
        let stmt = try prepare("SELECT classifier, label, version, classified_at, in_file FROM classification WHERE photo_id = ? ORDER BY classifier;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, photoID)
        var out: [Classification] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Classification(
                classifier: String(cString: sqlite3_column_text(stmt, 0)),
                label: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
                version: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
                classifiedAt: sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3),
                inFile: sqlite3_column_int(stmt, 4) != 0))
        }
        return out
    }

    // MARK: - Classification

    /// Photos and videos a classifier hasn't tagged: no record of it in the
    /// file or the catalog. Only ones with a thumbnail, which is what it reads.
    public func photosNeedingClassification(by classifier: String, limit: Int = 1_000_000) throws -> [PhotoItem] {
        let stmt = try prepare("""
            SELECT \(Catalog.photoColumns) FROM photo p
            WHERE p.missing = 0 AND p.trashed = 0 AND p.thumb_off IS NOT NULL AND p.thumb_len > 0
              AND NOT EXISTS (SELECT 1 FROM classification c WHERE c.photo_id = p.id AND c.classifier = ?)
            ORDER BY p.id LIMIT ?;
            """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, classifier, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [PhotoItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(readPhoto(stmt)) }
        return out
    }

    /// A classifier's tags, kept in the catalog (the photo isn't changed). The
    /// record is `in_file = 0`, and a re-read of the file keeps these tags
    /// (see `setFileTags`). Call inside a transaction.
    public func setCatalogOnlyTags(photoID: Int64, record: ToolRecord, _ tags: [ScoredTag]) throws {
        let delete = try prepare("DELETE FROM tag WHERE photo_id = ? AND source = ?;")
        defer { sqlite3_finalize(delete) }
        sqlite3_bind_int64(delete, 1, photoID)
        sqlite3_bind_text(delete, 2, record.prefix, -1, SQLITE_TRANSIENT)
        try step(delete)

        let insert = try prepare("INSERT OR REPLACE INTO tag (photo_id, source, key, name, confidence) VALUES (?, ?, ?, ?, ?);")
        defer { sqlite3_finalize(insert) }
        var seen = Set<String>()
        for tag in tags {
            let key = TagKey.key(tag.name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            sqlite3_reset(insert)
            sqlite3_bind_int64(insert, 1, photoID)
            sqlite3_bind_text(insert, 2, record.prefix, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insert, 3, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(insert, 4, tag.name, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(insert, 5, tag.score)
            try step(insert)
        }

        let upsert = try prepare("""
            INSERT INTO classification (photo_id, classifier, version, classified_at, in_file, label)
            VALUES (?, ?, ?, ?, 0, ?)
            ON CONFLICT(photo_id, classifier) DO UPDATE SET
              version = excluded.version, classified_at = excluded.classified_at,
              in_file = 0, label = excluded.label;
            """)
        defer { sqlite3_finalize(upsert) }
        sqlite3_bind_int64(upsert, 1, photoID)
        sqlite3_bind_text(upsert, 2, record.prefix, -1, SQLITE_TRANSIENT)
        if let v = record.version { sqlite3_bind_text(upsert, 3, v, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(upsert, 3) }
        if let d = record.date { sqlite3_bind_double(upsert, 4, d.timeIntervalSince1970) } else { sqlite3_bind_null(upsert, 4) }
        sqlite3_bind_text(upsert, 5, record.tool, -1, SQLITE_TRANSIENT)
        try step(upsert)
    }

    public func hiddenTagKeys() throws -> Set<String> {
        let stmt = try prepare("SELECT key FROM hidden_tag;")
        defer { sqlite3_finalize(stmt) }
        var out = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(stmt, 0))) }
        return out
    }

    /// Hides a tag from PhotoVault's lists, or shows it again. Nothing is
    /// deleted: the tag stays on its photos and in their files.
    public func setTagHidden(_ key: String, _ hidden: Bool) throws {
        let stmt = try prepare(hidden ? "INSERT OR IGNORE INTO hidden_tag (key) VALUES (?);"
                                      : "DELETE FROM hidden_tag WHERE key = ?;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        try step(stmt)
    }
}

import Foundation

public struct ScannedFile: Sendable, Hashable {
    public var relPath: String       // relative to the *volume root*, e.g. "Photos/2019/a.jpg"
    public var size: Int64
    public var mtime: Double
    public var type: MediaType
    /// The file's creation date, if the file system records one.
    public var created: Double? = nil
}

public struct ScanResult: Sendable {
    /// Files found in whatever directories were actually walked this pass.
    public var files: [ScannedFile] = []
    /// Directory rel path -> mtime, for every directory walked.
    public var dirs: [String: Double] = [:]
    /// Which directories were walked. On an incremental pass, only files under
    /// these may be concluded missing — everything else was simply not looked at.
    public var enumeratedDirs: Set<String> = []
    /// Known directories that no longer exist — renamed, moved or deleted.
    /// Their photos are gone from there, on an incremental pass too.
    public var vanishedDirs: [String] = []
    public var isFull = false

    public var fileCount: Int { files.count }
}

/// Directory-mtime fast scan.
///
/// A full re-enumeration on every mount would make opening feel slow at 10k
/// items. Instead, stat only the *directories* — a few hundred syscalls rather
/// than tens of thousands — and re-enumerate only the ones whose mtime moved.
/// A full walk happens on first run, or when the last session didn't shut down
/// cleanly and the directory state can't be trusted.
public enum Scanner {

    public static func fullScan(root: URL) -> ScanResult {
        var result = ScanResult()
        result.isFull = true
        walk(root: root, relDir: VolumeLocator.mediaDirName, into: &result)
        return result
    }

    public static func incrementalScan(root: URL, knownDirs: [String: Double]) -> ScanResult {
        var result = ScanResult()
        if knownDirs.isEmpty { return fullScan(root: root) }

        var pending = Set(knownDirs.keys)
        pending.insert(VolumeLocator.mediaDirName)

        while let relDir = pending.popFirst() {
            let url = root.appendingPathComponent(relDir)
            guard let mtime = directoryMTime(url) else {
                result.vanishedDirs.append(relDir)
                continue
            }
            // Unchanged mtime means no entry was added, removed or renamed in
            // this directory. Contents of files may have changed, but that
            // doesn't affect which rows exist.
            if let known = knownDirs[relDir], known == mtime {
                result.dirs[relDir] = mtime
                continue
            }

            let listing = enumerateOne(root: root, relDir: relDir)
            result.dirs[relDir] = mtime
            result.enumeratedDirs.insert(relDir)
            result.files.append(contentsOf: listing.files)

            for sub in listing.subdirs where knownDirs[sub] == nil {
                // A directory we've never seen: walk it in full, since none of
                // its descendants are in dir_state either.
                walk(root: root, relDir: sub, into: &result)
            }
            for sub in listing.subdirs where knownDirs[sub] != nil {
                pending.insert(sub)
            }
        }
        return result
    }

    // MARK: - Walking

    private static func walk(root: URL, relDir: String, into result: inout ScanResult) {
        var stack = [relDir]
        while let dir = stack.popLast() {
            let url = root.appendingPathComponent(dir)
            guard let mtime = directoryMTime(url) else { continue }
            let listing = enumerateOne(root: root, relDir: dir)
            result.dirs[dir] = mtime
            result.enumeratedDirs.insert(dir)
            result.files.append(contentsOf: listing.files)
            stack.append(contentsOf: listing.subdirs)
        }
    }

    struct Listing {
        var files: [ScannedFile] = []
        var subdirs: [String] = []
    }

    static func enumerateOne(root: URL, relDir: String) -> Listing {
        var listing = Listing()
        let dirURL = root.appendingPathComponent(relDir)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return listing }

        for entry in entries {
            let name = entry.lastPathComponent
            // AppleDouble sidecars from FAT/SMB round-trips; never media.
            if name.hasPrefix("._") { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            let rel = relDir + "/" + name

            if values.isDirectory == true {
                listing.subdirs.append(rel)
                continue
            }
            guard values.isRegularFile == true,
                  let type = MediaKinds.mediaType(forExtension: entry.pathExtension)
            else { continue }

            listing.files.append(ScannedFile(
                relPath: rel,
                size: Int64(values.fileSize ?? 0),
                mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                type: type,
                created: values.creationDate?.timeIntervalSince1970
            ))
        }
        return listing
    }

    static func directoryMTime(_ url: URL) -> Double? {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }
}

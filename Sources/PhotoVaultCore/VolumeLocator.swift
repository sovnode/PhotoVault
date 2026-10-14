import Foundation

public enum VaultError: LocalizedError, Equatable {
    case volumeNotFound
    case translocated
    case shortRead
    case sqlite(String)
    case packCorrupt(String)
    case noVideoTrack
    case cannotRotate(String)
    case cannotDelete(String)
    case cannotWriteTags(String)
    case classifierUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .volumeNotFound:
            return "No .catalog folder found alongside the app. Move PhotoVault.app to the top level of the vault."
        case .translocated:
            return "macOS is running this app from a temporary copy, so it can't find the vault. "
                 + "Quit, run `xattr -dr com.apple.quarantine` on the app, and reopen it."
        case .shortRead:
            return "A thumbnail read came up short. The volume may have been ejected."
        case .sqlite(let msg):
            return "Catalog error: \(msg)"
        case .packCorrupt(let msg):
            return "Thumbnail store error: \(msg)"
        case .noVideoTrack:
            return "No playable video track."
        case .cannotRotate(let msg):
            return msg
        case .cannotDelete(let msg):
            return msg
        case .cannotWriteTags(let msg):
            return msg
        case .classifierUnavailable(let msg):
            return msg
        }
    }
}

/// Finds the vault root by walking up from the running binary until a sibling
/// `.catalog` directory appears.
///
/// The root is never hardcoded: macOS appends " 1" to the mount point when a
/// stale mount exists, and anything storing an absolute path would break the
/// moment that happened. Everything downstream of this stores paths relative to
/// whatever this returns, which is also what lets the whole bundle be copied to
/// another machine and just work.
public enum VolumeLocator {
    public static let catalogDirName = ".catalog"
    public static let mediaDirName = "Photos"

    public static func resolveRoot(from start: URL = Bundle.main.bundleURL) throws -> URL {
        // App Translocation: a quarantined app launched from a disk image gets
        // copied to a random read-only path, and the vault is nowhere nearby.
        if start.path.contains("/AppTranslocation/") {
            throw VaultError.translocated
        }

        var dir = start.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<32 {
            if isDirectory(dir.appendingPathComponent(catalogDirName)) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw VaultError.volumeNotFound
    }

    /// Same as `resolveRoot`, but creates the catalog scaffolding if a `Photos`
    /// directory is present without one. Used on first launch in a fresh vault.
    public static func resolveOrBootstrap(from start: URL = Bundle.main.bundleURL) throws -> URL {
        if let root = try? resolveRoot(from: start) {
            try ensureScaffolding(at: root)
            return root
        }

        var dir = start.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<32 {
            if isDirectory(dir.appendingPathComponent(mediaDirName)) {
                try ensureScaffolding(at: dir)
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw VaultError.volumeNotFound
    }

    public static func catalogDir(_ root: URL) -> URL {
        root.appendingPathComponent(catalogDirName, isDirectory: true)
    }

    public static func mediaDir(_ root: URL) -> URL {
        root.appendingPathComponent(mediaDirName, isDirectory: true)
    }

    /// Creates `.catalog/`, `.catalog/tmp/`, `Photos/`, and the Spotlight opt-out
    /// marker. The marker keeps the index off the volume; pair it with
    /// `mdutil -i off` on the mount point for belt and braces.
    public static func ensureScaffolding(at root: URL) throws {
        let fm = FileManager.default
        for dir in [catalogDir(root), catalogDir(root).appendingPathComponent("tmp"), mediaDir(root)] {
            if !isDirectory(dir) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        let marker = root.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) {
            fm.createFile(atPath: marker.path, contents: Data())
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}

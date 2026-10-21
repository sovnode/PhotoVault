import Foundation

/// Why macOS won't let PhotoVault delete or move a file — each wants a
/// different way through, so each is told apart rather than reported as one
/// error.
public enum FileBlocker: String, Sendable, CaseIterable {
    /// The vault (its disk image or drive) is mounted read-only.
    case readOnlyVault
    /// Finder's Locked, on a file this account owns: clearing it is enough.
    case locked
    /// Locked, and owned by another user: only an administrator can unlock it.
    case lockedNotYours
    /// The folder it's in (or the one it's going to) can't be written to by
    /// this account — deleting or moving a file changes its folder, not it.
    case folderReadOnly
    /// The folder lets only a file's owner remove it, and that isn't this
    /// account (a folder with the sticky bit).
    case notYours
    /// Anything else; the message says what macOS said.
    case other

    /// A heading for the group of files with this reason.
    public var title: String {
        switch self {
        case .readOnlyVault: return "The vault is read-only"
        case .locked: return "Locked"
        case .lockedNotYours: return "Locked, and belonging to another user"
        case .folderReadOnly: return "In a folder you can't change"
        case .notYours: return "Belonging to another user"
        case .other: return "Couldn't be changed"
        }
    }

    /// What it means and what can be done, in a sentence or two.
    public var explanation: String {
        switch self {
        case .readOnlyVault:
            return "The vault's disk image or drive is mounted read-only, so nothing on it can change. Eject it and open it again with write access."
        case .locked:
            return "These are locked (Finder › Get Info › Locked). Unlocking them — the same as unticking Locked — lets them go."
        case .lockedNotYours:
            return "These are locked and belong to another user on this Mac (or the one they came from). An administrator's password can unlock them."
        case .folderReadOnly:
            return "Their folder doesn't let this account add or remove files — common for folders copied from another Mac. Fix it in Finder › Get Info › Sharing & Permissions, or use an administrator's password."
        case .notYours:
            return "Their folder only lets each file's owner remove it, and these belong to another user. An administrator's password can remove them."
        case .other:
            return "macOS refused, for the reason given beside each file."
        }
    }

    /// Whether PhotoVault can clear it by itself, without a password.
    public var unlockable: Bool { self == .locked }
    /// Whether an administrator's password can get past it.
    public var needsAdministrator: Bool { self == .lockedNotYours || self == .folderReadOnly || self == .notYours }
}

/// A file PhotoVault couldn't delete or move, and why.
public struct FileProblem: Sendable, Identifiable, Equatable {
    /// The photo's catalog id.
    public let id: Int64
    public let relPath: String
    public let reason: FileBlocker
    /// macOS's own words, for `.other`.
    public let detail: String

    public init(id: Int64, relPath: String, reason: FileBlocker, detail: String = "") {
        self.id = id
        self.relPath = relPath
        self.reason = reason
        self.detail = detail
    }

    public var name: String { (relPath as NSString).lastPathComponent }
}

/// Works out why a file can't be deleted or moved — before trying, so a
/// confirmation can say so, and after a failure, to say which.
public enum FileCheck {
    /// Why `url` couldn't be removed from its folder, or nil if it can be.
    public static func blocker(removing url: URL) -> FileBlocker? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        if isReadOnlyVolume(url) { return .readOnlyVault }
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let mine = (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        if isLocked(url) { return mine ? .locked : .lockedNotYours }
        let folder = url.deletingLastPathComponent()
        if access(folder.path, W_OK) != 0 { return .folderReadOnly }
        // The sticky bit: only a file's owner (or the folder's) may remove it.
        let folderAttrs = (try? fm.attributesOfItem(atPath: folder.path)) ?? [:]
        let mode = (folderAttrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let folderMine = (folderAttrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        if mode & Int(S_ISVTX) != 0, !mine, !folderMine { return .notYours }
        return nil
    }

    /// Why `url` couldn't be moved into `folder`, or nil if it can be.
    public static func blocker(moving url: URL, into folder: URL) -> FileBlocker? {
        if let reason = blocker(removing: url) { return reason }
        if FileManager.default.fileExists(atPath: folder.path), access(folder.path, W_OK) != 0 { return .folderReadOnly }
        return nil
    }

    /// The reason for an error macOS gave, falling back to `.other`.
    public static func reason(for error: Error, removing url: URL, into folder: URL? = nil) -> FileBlocker {
        if let folder { return blocker(moving: url, into: folder) ?? .other }
        return blocker(removing: url) ?? .other
    }

    /// Finder's Locked, or the system's own immutable flag.
    public static func isLocked(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0
    }

    /// Clears Finder's Locked on a file this account owns.
    public static func unlock(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return }
        let flags = info.st_flags & ~UInt32(UF_IMMUTABLE)
        guard chflags(url.path, flags) == 0 else {
            throw VaultError.cannotDelete("\(url.lastPathComponent): couldn't unlock it (\(String(cString: strerror(errno)))).")
        }
    }

    public static func isReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }
}

/// Deleting or moving files with an administrator's password, for the ones
/// this account can't.
///
/// macOS asks for the password in its own window (`do shell script … with
/// administrator privileges`): PhotoVault never sees it, and nothing is
/// remembered — it asks again next time. Only the files listed are touched,
/// each quoted for the shell, and the caller passes only paths inside the
/// vault's Photos folder.
public enum AdministratorFiles {
    public enum Operation: Equatable, Sendable {
        case delete(String)
        case move(from: String, to: String)
    }

    public enum Outcome: Equatable, Sendable {
        case done
        case cancelled
        case failed(String)
    }

    /// A path quoted for the shell: inside single quotes, with any single
    /// quote in it closed, escaped and reopened.
    public static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The one shell command that does them all, carrying on past a failure:
    /// what got done is read back from the disk afterwards. Locked flags are
    /// cleared first (both the user's and the system's).
    public static func command(for operations: [Operation]) -> String {
        operations.map { op -> String in
            switch op {
            case .delete(let path):
                let p = quote(path)
                return "/usr/bin/chflags nouchg,noschg \(p); /bin/rm -f \(p)"
            case .move(let from, let to):
                let f = quote(from), t = quote(to)
                return "/usr/bin/chflags nouchg,noschg \(f); /bin/mv -n \(f) \(t)"
            }
        }.joined(separator: "; ") + "; true"
    }

    /// The arguments for `/usr/bin/osascript`: the command and the prompt go
    /// in as arguments, never into the script's text, so nothing in a file
    /// name can change what the script does.
    public static func osascriptArguments(command: String, prompt: String) -> [String] {
        ["-e", "on run argv",
         "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
         "-e", "end run",
         command, prompt]
    }

    /// Runs them, after macOS asks for the password. Blocks until it's done
    /// or cancelled: call it off the main thread, and outside the Store, so
    /// the catalog isn't held up while the password window is open.
    public static func run(_ operations: [Operation], prompt: String) -> Outcome {
        guard !operations.isEmpty else { return .done }
        return run(command: command(for: operations), prompt: prompt)
    }

    /// Runs one shell command as an administrator, after macOS asks.
    public static func run(command: String, prompt: String) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = osascriptArguments(command: command, prompt: prompt)
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return .failed(error.localizedDescription) }
        let said = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        if process.terminationStatus == 0 { return .done }
        // -128: the person clicked Cancel in the password window.
        if said.contains("-128") { return .cancelled }
        return .failed(said.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Where a moved photo went, so it can be moved back.
public struct MoveRecord: Sendable, Equatable {
    public let id: Int64
    public let from: String
    public let to: String
}

public struct MoveResult: Sendable {
    public var moved: [MoveRecord] = []
    public var problems: [FileProblem] = []
    /// Already in the folder they were dropped on.
    public var alreadyThere = 0

    public init(moved: [MoveRecord] = [], problems: [FileProblem] = [], alreadyThere: Int = 0) {
        self.moved = moved
        self.problems = problems
        self.alreadyThere = alreadyThere
    }
}

/// Names and paths for moving files about the vault.
public enum MovePlanning {
    /// `name` in `folder`, or, if that's taken, "name 2.ext", "name 3.ext" —
    /// as Finder does. `taken` says whether a relative path is in use (on
    /// disk or in the catalog).
    public static func freeName(_ name: String, in folder: String, taken: (String) -> Bool) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = name
        var n = 2
        while taken(folder + "/" + candidate) {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        return candidate
    }

    /// Whether `folder` is the Photos folder or one inside it, with no
    /// way out of it ("..", an empty part).
    public static func isInsidePhotos(_ folder: String) -> Bool {
        let root = VolumeLocator.mediaDirName
        guard folder == root || folder.hasPrefix(root + "/") else { return false }
        let parts = folder.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Whether `name` will do for a new folder.
    public static func isValidFolderName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed == name && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
    }
}

/// Vault › Fix Permissions: finds what under Photos/ would stop PhotoVault
/// moving or deleting it, and puts it right — permissions only, never a
/// photo's contents.
public enum PermissionFixer {
    public enum Kind: String, Sendable, CaseIterable {
        /// "Deny" rules in an access control list — what Time Machine puts on
        /// everything in a backup, kept by files copied out of one.
        case denyRules
        /// Finder's Locked.
        case locked
        /// Not writable even by its owner.
        case readOnly
        /// Belongs to another user: only an administrator can change it.
        case notYours

        public var label: String {
            switch self {
            case .denyRules: return "with rules copied from a backup"
            case .locked: return "locked"
            case .readOnly: return "read-only"
            case .notYours: return "belonging to another user"
            }
        }
    }

    public struct Issue: Sendable, Equatable {
        public let path: String
        public let kinds: Set<Kind>
    }

    /// Everything under `photos` (the folder itself included) with something
    /// to fix.
    public static func scan(_ photos: URL) -> [Issue] {
        var out: [Issue] = []
        func look(_ path: String) {
            let kinds = problems(at: path)
            if !kinds.isEmpty { out.append(Issue(path: path, kinds: kinds)) }
        }
        look(photos.path)
        guard let walker = FileManager.default.enumerator(atPath: photos.path) else { return out }
        for case let rel as String in walker { look(photos.appendingPathComponent(rel).path) }
        return out
    }

    public static func problems(at path: String) -> Set<Kind> {
        var info = stat()
        guard lstat(path, &info) == 0 else { return [] }
        var kinds: Set<Kind> = []
        if info.st_uid != getuid() { kinds.insert(.notYours) }
        if info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0 { kinds.insert(.locked) }
        if info.st_mode & S_IWUSR == 0, (info.st_mode & S_IFMT) != S_IFLNK { kinds.insert(.readOnly) }
        if hasDenyRules(path) { kinds.insert(.denyRules) }
        return kinds
    }

    static func hasDenyRules(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, which, &entry) == 0 {
            var tag = ACL_UNDEFINED_TAG
            if acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY { return true }
            which = ACL_NEXT_ENTRY.rawValue
        }
        return false
    }

    /// Takes the deny rules out of an access control list, keeping any that
    /// allow something.
    static func removeDenyRules(_ path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return true }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        // Deleting while walking the list loses the walker's place: start
        // again from the top after each one.
        var removed = true
        while removed {
            removed = false
            var entry: acl_entry_t?
            var which = ACL_FIRST_ENTRY.rawValue
            while acl_get_entry(acl, which, &entry) == 0 {
                var tag = ACL_UNDEFINED_TAG
                if acl_get_tag_type(entry, &tag) == 0, tag == ACL_EXTENDED_DENY, let e = entry {
                    guard acl_delete_entry(acl, e) == 0 else { return false }
                    removed = true
                    break
                }
                which = ACL_NEXT_ENTRY.rawValue
            }
        }
        return acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) == 0
    }

    /// Fixes what this account can by itself: deny rules removed, Locked
    /// cleared, writable by its owner. Returns whether nothing is left that
    /// it could fix (another user's files need an administrator).
    @discardableResult
    public static func fix(_ issue: Issue) -> Bool {
        let path = issue.path
        var ok = true
        if issue.kinds.contains(.notYours) { return false }
        if issue.kinds.contains(.locked) {
            var info = stat()
            if lstat(path, &info) == 0, chflags(path, info.st_flags & ~UInt32(UF_IMMUTABLE)) != 0 { ok = false }
        }
        if issue.kinds.contains(.denyRules), !removeDenyRules(path) { ok = false }
        if issue.kinds.contains(.readOnly) {
            var info = stat()
            if lstat(path, &info) == 0, chmod(path, (info.st_mode & 0o7777) | S_IWUSR) != 0 { ok = false }
        }
        return ok && problems(at: path).isEmpty
    }

    /// What an administrator does for the rest: makes each this account's,
    /// unlocked, without access rules, and writable by it.
    public static func administratorCommand(for paths: [String]) -> String {
        let user = String(getuid())
        return paths.map { path -> String in
            let p = AdministratorFiles.quote(path)
            return "/usr/bin/chflags nouchg,noschg \(p); /bin/chmod -N \(p); /usr/sbin/chown \(user) \(p); /bin/chmod u+w \(p)"
        }.joined(separator: "; ") + "; true"
    }
}

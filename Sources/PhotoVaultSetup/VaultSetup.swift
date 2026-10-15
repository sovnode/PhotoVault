import Foundation
import Darwin

/// What the installer is doing, for its progress list.
public enum SetupStep: String, Sendable, CaseIterable {
    case creating = "Creating the disk image"
    case opening = "Opening the vault"
    case quitting = "Quitting PhotoVault"
    case installingApp = "Installing PhotoVault"
    /// JoyTag's model — part of PhotoVault, so the list doesn't single it out.
    case installingJoyTag = "Copying PhotoVault's files"
    case checking = "Checking"
}

/// What's on a vault the installer was pointed at.
public struct ExistingVault: Sendable, Equatable {
    /// Where it's mounted.
    public var mountPoint: URL
    /// Its disk image, if it's on one.
    public var image: URL?
    /// The PhotoVault version on it, if any.
    public var installedVersion: String?
    /// Whether PhotoVault has opened it before: it has a catalog.
    public var hasCatalog: Bool
    /// The JoyTag version on it, if any.
    public var joyTagVersion: String?
    /// Whether PhotoVault is open from it; installing quits it first.
    public var photoVaultIsOpen: Bool

    /// The vault's name, as Finder shows it.
    public var name: String {
        (try? mountPoint.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? mountPoint.lastPathComponent
    }

    public init(mountPoint: URL, image: URL?, installedVersion: String?, hasCatalog: Bool,
                joyTagVersion: String?, photoVaultIsOpen: Bool) {
        self.mountPoint = mountPoint
        self.image = image
        self.installedVersion = installedVersion
        self.hasCatalog = hasCatalog
        self.joyTagVersion = joyTagVersion
        self.photoVaultIsOpen = photoVaultIsOpen
    }
}

/// What a finished setup did.
public struct SetupReport: Sendable, Equatable {
    public enum JoyTag: Sendable, Equatable {
        /// Copied onto the vault: all of it, or what was missing.
        case installed(String)
        /// This version was there already, complete.
        case alreadyThere(String)
    }
    public enum TagGroups: Sendable, Equatable {
        case added, renamed, kept
    }

    public var mountPoint: URL
    /// The new vault's disk image; nil after installing.
    public var createdImage: URL?
    public var version: String
    /// The PhotoVault version that was replaced, if there was one.
    public var replacedVersion: String?
    public var quitPhotoVault: Bool
    public var joyTag: JoyTag
    public var tagGroups: TagGroups

    public init(mountPoint: URL, createdImage: URL?, version: String, replacedVersion: String?,
                quitPhotoVault: Bool, joyTag: JoyTag, tagGroups: TagGroups) {
        self.mountPoint = mountPoint
        self.createdImage = createdImage
        self.version = version
        self.replacedVersion = replacedVersion
        self.quitPhotoVault = quitPhotoVault
        self.joyTag = joyTag
        self.tagGroups = tagGroups
    }
}

/// Makes a new vault, or puts PhotoVault on an existing one — what
/// `Scripts/new-vault.sh` and `Scripts/install-to-vault.sh` do, without the
/// project folder.
///
/// A vault is a volume holding `PhotoVault.app`, `Photos/`, the hidden
/// `.catalog/` (made by PhotoVault on first launch, with JoyTag in
/// `.catalog/models/`), `README.txt` and the hidden `.Tag Groups.txt`.
/// Installing replaces the app and the README, adds what's missing — JoyTag
/// included, always — and never touches `Photos/` or the catalog: every file
/// in `.catalog/` apart from JoyTag's is checked before and after.
public enum VaultSetup {
    /// Sizes offered for a new vault: a ceiling, not an allocation.
    public static let sizes: [(label: String, value: String)] = [
        ("50 GB", "50g"), ("100 GB", "100g"), ("250 GB", "250g"), ("500 GB", "500g"), ("1 TB", "1t"), ("2 TB", "2t"),
    ]
    public static let defaultSize = "500g"

    /// Why `name` can't be a vault's name, or nil if it can.
    public static func problem(withName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "The vault needs a name." }
        if trimmed.contains("/") || trimmed.contains(":") { return "A vault's name can't contain / or :." }
        if trimmed.hasPrefix(".") { return "A vault's name can't start with a full stop." }
        // A volume name longer than this is cut short by APFS.
        if trimmed.utf8.count > 60 { return "That name is too long." }
        return nil
    }

    /// The disk image a vault called `name` gets in `folder`.
    public static func bundle(named name: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(name.trimmingCharacters(in: .whitespaces)).sparsebundle")
    }

    // MARK: - Create

    /// A new vault, `<name>.sparsebundle` in `folder`, mounted, with
    /// PhotoVault on it.
    @discardableResult
    /// With a `password`, the vault is encrypted: nobody can open it without
    /// the password, and nothing can recover it if it's forgotten.
    public static func create(name: String, in folder: URL, size: String, payload: Payload, password: String? = nil,
                              mountRoot: URL? = nil, progress: (SetupStep) -> Void = { _ in }) throws -> SetupReport {
        let name = name.trimmingCharacters(in: .whitespaces)
        if let problem = problem(withName: name) { throw SetupError(problem) }
        let bundle = bundle(named: name, in: folder)
        guard !FileManager.default.fileExists(atPath: bundle.path) else {
            throw SetupError("There's already a vault called “\(name)” there. Choose another name, or install on it instead.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw SetupError("The installer can't save in “\(folder.lastPathComponent)”. Choose another folder.")
        }
        if let password, password.isEmpty { throw SetupError("The password can't be empty.") }
        progress(.creating)
        try DiskImages.create(bundle, volumeName: name, size: size, password: password)
        progress(.opening)
        let mount = try DiskImages.attach(bundle, mountRoot: mountRoot, password: password)
        // PhotoVault anchors on Photos/; and Spotlight is told to stay out
        // before any photo arrives.
        try FileManager.default.createDirectory(at: mount.appendingPathComponent("Photos"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mount.appendingPathComponent(".metadata_never_index").path, contents: Data())

        progress(.installingApp)
        let groups = try installApp(at: mount, payload: payload)
        let joyTag = try installJoyTag(payload.joyTag, at: mount, progress: progress)
        progress(.checking)
        try checkSignature(at: mount)
        return SetupReport(mountPoint: mount, createdImage: bundle, version: payload.version, replacedVersion: nil,
                           quitPhotoVault: false, joyTag: joyTag, tagGroups: groups)
    }

    // MARK: - Existing vaults

    /// What's on `target` — a vault's disk image, or a mounted vault —
    /// mounting the image if it isn't already. `mounted` says whether this
    /// call mounted it.
    /// A password-protected image that isn't open throws `PasswordNeeded`
    /// unless its `password` is given.
    public static func open(_ target: URL, mountRoot: URL? = nil, password: String? = nil) throws -> (vault: ExistingVault, mounted: Bool) {
        if DiskImages.isDiskImage(target) {
            guard FileManager.default.fileExists(atPath: target.path) else {
                throw SetupError("“\(target.lastPathComponent)” isn't there any more.")
            }
            if let mount = DiskImages.mountPoint(of: target) {
                return (try inspect(mount, image: target), false)
            }
            let mount = try DiskImages.attach(target, mountRoot: mountRoot, password: password)
            do {
                return (try inspect(mount, image: target), true)
            } catch {
                // Not a vault: put it back as it was.
                try? DiskImages.detach(mount)
                throw error
            }
        }
        return (try inspect(target, image: DiskImages.image(mountedAt: target)), false)
    }

    /// What's on the vault mounted at `mount`, changing nothing.
    public static func inspect(_ mount: URL, image: URL? = nil) throws -> ExistingVault {
        guard isVault(mount) else { throw notAVault(image ?? mount) }
        return ExistingVault(mountPoint: mount, image: image,
                             installedVersion: version(ofAppIn: mount),
                             hasCatalog: FileManager.default.fileExists(atPath: mount.appendingPathComponent(".catalog/catalog.sqlite").path),
                             joyTagVersion: joyTagVersion(in: mount),
                             photoVaultIsOpen: !runningPhotoVaults(in: mount).isEmpty)
    }

    /// Vaults on disk images that are mounted now — the ones the installer
    /// offers first. Only disk images are looked at, so no other drive is
    /// touched.
    public static func mountedVaults() -> [ExistingVault] {
        DiskImages.mounted().compactMap { image, mount in
            let fm = FileManager.default
            guard fm.fileExists(atPath: mount.appendingPathComponent(".catalog").path)
                    || fm.fileExists(atPath: mount.appendingPathComponent("PhotoVault.app").path) else { return nil }
            return try? inspect(mount, image: image)
        }
    }

    /// Puts PhotoVault on an existing vault — its disk image, or the vault
    /// itself — mounting it if needed and quitting a PhotoVault open from it.
    @discardableResult
    public static func install(into target: URL, payload: Payload, password: String? = nil, mountRoot: URL? = nil,
                               progress: (SetupStep) -> Void = { _ in }) throws -> SetupReport {
        if DiskImages.isDiskImage(target), DiskImages.mountPoint(of: target) == nil { progress(.opening) }
        let mount = try open(target, mountRoot: mountRoot, password: password).vault.mountPoint
        let replaced = version(ofAppIn: mount)

        let running = runningPhotoVaults(in: mount)
        if !running.isEmpty {
            progress(.quitting)
            // A scripted quit, as the vault scripts do it: PhotoVault stops any
            // scan or tagging run without asking, and closes its catalog. Only
            // the copy running from this vault is asked.
            for pid in running { kill(pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(15)
            while !runningPhotoVaults(in: mount).isEmpty {
                guard Date() < deadline else {
                    throw SetupError("PhotoVault is still open from this vault. Quit it, then try again.")
                }
                usleep(200_000)
            }
        }

        let before = catalogFiles(in: mount)
        progress(.installingApp)
        let groups = try installApp(at: mount, payload: payload)
        let joyTag = try installJoyTag(payload.joyTag, at: mount, progress: progress)
        progress(.checking)
        try checkSignature(at: mount)
        guard catalogFiles(in: mount) == before else {
            throw SetupError("Something in the vault's catalog changed while installing, and nothing should have. Check the vault before using it.")
        }
        return SetupReport(mountPoint: mount, createdImage: nil, version: payload.version, replacedVersion: replaced,
                           quitPhotoVault: !running.isEmpty, joyTag: joyTag, tagGroups: groups)
    }

    // MARK: - What goes on a vault

    /// PhotoVault, its README, the tag groups file and the volume icon.
    static func installApp(at mount: URL, payload: Payload) throws -> SetupReport.TagGroups {
        let fm = FileManager.default
        // The new app beside the old, then swapped in, so a failure part-way
        // leaves the old one working.
        let app = mount.appendingPathComponent("PhotoVault.app")
        let incoming = mount.appendingPathComponent(".PhotoVault-incoming.app")
        let outgoing = mount.appendingPathComponent(".PhotoVault-outgoing.app")
        try? fm.removeItem(at: incoming)
        try? fm.removeItem(at: outgoing)
        // ditto keeps the signature intact; --noqtn leaves any quarantine
        // behind, which would have macOS run PhotoVault from a read-only copy
        // somewhere else — away from its vault.
        try Shell.run("/usr/bin/ditto", ["--noqtn", payload.app.path, incoming.path])
        if fm.fileExists(atPath: app.path) { try fm.moveItem(at: app, to: outgoing) }
        try fm.moveItem(at: incoming, to: app)
        try? fm.removeItem(at: outgoing)

        // The README beside it, always the current one.
        let readme = mount.appendingPathComponent("README.txt")
        try? fm.removeItem(at: readme)
        try fm.copyItem(at: payload.readme, to: readme)

        // The tag groups file is there to be edited: an existing one is kept,
        // and a visible one from before 1.3.0 renamed rather than replaced.
        let groups = mount.appendingPathComponent(".Tag Groups.txt")
        let legacy = mount.appendingPathComponent("Tag Groups.txt")
        let tagGroups: SetupReport.TagGroups
        if fm.fileExists(atPath: groups.path) {
            tagGroups = .kept
        } else if fm.fileExists(atPath: legacy.path) {
            try fm.moveItem(at: legacy, to: groups)
            tagGroups = .renamed
        } else {
            try fm.copyItem(at: payload.tagGroups, to: groups)
            tagGroups = .added
        }

        if isVolume(mount) { try setVolumeIcon(at: mount, from: app.appendingPathComponent("Contents/Resources/AppIcon.icns")) }
        return tagGroups
    }

    /// The volume shows PhotoVault's icon in Finder: `.VolumeIcon.icns` at
    /// its root, and the root's custom-icon flag set — what `SetFile -a C`
    /// does, which needs Xcode.
    static func setVolumeIcon(at mount: URL, from icon: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: icon.path) else { return }
        let volumeIcon = mount.appendingPathComponent(".VolumeIcon.icns")
        try? fm.removeItem(at: volumeIcon)
        try fm.copyItem(at: icon, to: volumeIcon)
        try FinderInfo.setHasCustomIcon(mount)
    }

    /// JoyTag's folder into `.catalog/models/JoyTag/`. A new version is copied
    /// beside the old, checked file by file, then swapped in whole, so a vault
    /// never holds half of one model and half of another. A vault with this
    /// version gets only the files it's missing — its licence, if it was set
    /// up before the licence shipped — rather than the whole model again,
    /// which would grow its disk image by as much.
    static func installJoyTag(_ package: URL, at mount: URL, progress: (SetupStep) -> Void) throws -> SetupReport.JoyTag {
        progress(.installingJoyTag)
        let fm = FileManager.default
        let version = joyTagVersion(inPackage: package) ?? "?"
        let models = mount.appendingPathComponent(".catalog/models")
        let dest = models.appendingPathComponent("JoyTag")
        let manifest = "manifest.json"
        let wanted = files(in: package)

        if fm.contents(atPath: dest.appendingPathComponent(manifest).path) == fm.contents(atPath: package.appendingPathComponent(manifest).path) {
            let present = Set(files(in: dest))
            let missing = wanted.filter { !present.contains($0) }
            if missing.isEmpty { return .alreadyThere(version) }
            for file in missing {
                let target = dest.appendingPathComponent(file.relativePath)
                let incoming = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent)-incoming")
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: incoming)
                try fm.copyItem(at: package.appendingPathComponent(file.relativePath), to: incoming)
                // rename(2) puts the new file in place of the old in one step.
                guard rename(incoming.path, target.path) == 0 else {
                    try? fm.removeItem(at: incoming)
                    throw SetupError("JoyTag couldn't be completed: \(String(cString: strerror(errno))).")
                }
            }
            guard Set(files(in: dest)).isSuperset(of: wanted) else {
                throw SetupError("JoyTag didn't copy completely. Is the vault full?")
            }
            return .installed(version)
        }

        try fm.createDirectory(at: models, withIntermediateDirectories: true)
        let incoming = models.appendingPathComponent(".JoyTag-incoming")
        let outgoing = models.appendingPathComponent(".JoyTag-outgoing")
        try? fm.removeItem(at: incoming)
        try? fm.removeItem(at: outgoing)
        do {
            try fm.copyItem(at: package, to: incoming)
        } catch {
            try? fm.removeItem(at: incoming)
            throw SetupError("JoyTag couldn't be copied onto the vault: \(error.localizedDescription)")
        }
        guard files(in: incoming) == wanted else {
            try? fm.removeItem(at: incoming)
            throw SetupError("JoyTag didn't copy completely. Is the vault full?")
        }
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: outgoing) }
        try fm.moveItem(at: incoming, to: dest)
        try? fm.removeItem(at: outgoing)
        return .installed(version)
    }

    static func checkSignature(at mount: URL) throws {
        let app = mount.appendingPathComponent("PhotoVault.app")
        do {
            try Shell.run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        } catch {
            throw SetupError("PhotoVault was copied, but its signature doesn't check out, so macOS may refuse to open it.")
        }
    }

    /// Every file under `folder`, by relative path, with its size.
    static func files(in folder: URL) -> [FileEntry] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return []
        }
        var out: [FileEntry] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            out.append(FileEntry(path: relative(url, to: folder), size: Int64(values?.fileSize ?? 0)))
        }
        return out.sorted { $0.path < $1.path }
    }

    struct FileEntry: Hashable {
        /// From the folder, with a leading slash.
        let path: String
        let size: Int64
        var relativePath: String { String(path.drop { $0 == "/" }) }
    }

    /// Every file in the vault's `.catalog/` apart from JoyTag's, with its size
    /// and modification time: what an install must leave exactly as it was.
    static func catalogFiles(in mount: URL) -> [CatalogFile] {
        let catalog = mount.appendingPathComponent(".catalog")
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: catalog, includingPropertiesForKeys: keys) else { return [] }
        var out: [CatalogFile] = []
        for case let url as URL in walker {
            let path = relative(url, to: catalog)
            if path == "/models" { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            out.append(CatalogFile(path: path, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate))
        }
        return out.sorted { $0.path < $1.path }
    }

    struct CatalogFile: Equatable {
        let path: String
        let size: Int64
        let modified: Date?
    }

    private static func relative(_ url: URL, to folder: URL) -> String {
        let base = folder.resolvingSymlinksInPath().path, path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    // MARK: - Looking at a vault

    static func isVault(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("Photos").path)
            || fm.fileExists(atPath: folder.appendingPathComponent(".catalog").path)
    }

    static func isVolume(_ folder: URL) -> Bool {
        (try? folder.resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    static func notAVault(_ target: URL) -> SetupError {
        SetupError("“\(target.lastPathComponent)” isn't a PhotoVault vault: it has no Photos folder. To make one, create a new vault instead.")
    }

    static func version(ofAppIn mount: URL) -> String? {
        let plist = mount.appendingPathComponent("PhotoVault.app/Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    static func joyTagVersion(in mount: URL) -> String? {
        joyTagVersion(inPackage: mount.appendingPathComponent(".catalog/models/JoyTag"))
    }

    public static func joyTagVersion(inPackage folder: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent("manifest.json").path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["version"] as? String
    }

    /// PhotoVaults running from this vault's copy of the app.
    static func runningPhotoVaults(in mount: URL) -> [pid_t] {
        let app = mount.resolvingSymlinksInPath().appendingPathComponent("PhotoVault.app").path + "/"
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(count)).filter { pid in
            pid > 0 && proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasPrefix(app)
        }
    }

    /// -1, 0 or 1 as version `a` is older than, the same as, or newer than `b`.
    public static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}

/// The Finder flags on a folder, in its `com.apple.FinderInfo` attribute.
enum FinderInfo {
    static let name = "com.apple.FinderInfo"
    /// kHasCustomIcon, in the big-endian flags at bytes 8–9.
    static let hasCustomIcon: UInt8 = 0x04

    static func setHasCustomIcon(_ url: URL) throws {
        var info = [UInt8](repeating: 0, count: 32)
        _ = getxattr(url.path, name, &info, info.count, 0, 0)
        info[8] |= hasCustomIcon
        guard setxattr(url.path, name, info, info.count, 0, 0) == 0 else {
            throw SetupError("The vault's icon couldn't be set: \(String(cString: strerror(errno))).")
        }
    }

    static func hasCustomIcon(_ url: URL) -> Bool {
        var info = [UInt8](repeating: 0, count: 32)
        guard getxattr(url.path, name, &info, info.count, 0, 0) == 32 else { return false }
        return info[8] & hasCustomIcon != 0
    }
}

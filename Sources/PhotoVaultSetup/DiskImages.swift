import Foundation

/// Sparse bundles, through `hdiutil`.
public enum DiskImages {
    static let hdiutil = "/usr/bin/hdiutil"

    /// The extensions a vault's disk image can have.
    public static let extensions: Set<String> = ["sparsebundle", "sparseimage", "dmg"]

    public static func isDiskImage(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// A new, empty APFS sparse bundle. `size` is a ceiling, not an
    /// allocation: the bundle takes only the space its contents use. Bands
    /// of 32 MB, as `Scripts/new-vault.sh` makes them: a long video spans
    /// fewer band files.
    public static func create(_ bundle: URL, volumeName: String, size: String) throws {
        try Shell.run(hdiutil, ["create", "-size", size, "-fs", "APFS", "-type", "SPARSEBUNDLE",
                                "-imagekey", "sparse-band-size=65536", "-volname", volumeName, bundle.path])
    }

    /// Mounts an image and returns where. Never assumes `/Volumes/<name>`:
    /// macOS appends " 1" when that's taken. `mountRoot` mounts it elsewhere,
    /// out of Finder's sidebar — for the tests.
    public static func attach(_ image: URL, mountRoot: URL? = nil) throws -> URL {
        // Already attached: attaching again makes a second attachment of the
        // same bundle, and detaching either takes the real mount down.
        if let mounted = mountPoint(of: image) { return mounted }
        var args = ["attach", "-plist"]
        if let mountRoot { args += ["-mountroot", mountRoot.path, "-nobrowse"] }
        args.append(image.path)
        let plist = try Shell.plist(try Shell.run(hdiutil, args))
        let entities = plist["system-entities"] as? [[String: Any]] ?? []
        guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw SetupError("The disk image opened, but macOS didn't say where.")
        }
        return URL(fileURLWithPath: mount)
    }

    /// Where `image` is mounted now, if it is.
    public static func mountPoint(of image: URL) -> URL? {
        let target = canonical(image)
        return mounted().first { canonical($0.image) == target }?.mount
    }

    /// The disk image mounted at `mount`, if it's on one.
    public static func image(mountedAt mount: URL) -> URL? {
        let target = canonical(mount)
        return mounted().first { canonical($0.mount) == target }?.image
    }

    /// Every disk image that's mounted now, with where.
    public static func mounted() -> [(image: URL, mount: URL)] {
        guard let data = try? Shell.run(hdiutil, ["info", "-plist"]), let plist = try? Shell.plist(data) else { return [] }
        return (plist["images"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = entry["image-path"] as? String else { return nil }
            let entities = entry["system-entities"] as? [[String: Any]] ?? []
            guard let mount = entities.compactMap({ $0["mount-point"] as? String }).first else { return nil }
            return (URL(fileURLWithPath: path), URL(fileURLWithPath: mount))
        }
    }

    public static func detach(_ mountPoint: URL, force: Bool = false) throws {
        try Shell.run(hdiutil, ["detach", mountPoint.path] + (force ? ["-force"] : []))
    }

    static func canonical(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
}

/// Runs a system tool and returns what it printed.
enum Shell {
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Both pipes read at once, so neither can fill up and stall the tool.
        var errors = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errors = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = (tool as NSString).lastPathComponent
            let said = String(decoding: errors, as: UTF8.self)
                .split(separator: "\n").filter { !$0.contains("deprecated") }.joined(separator: " ")
            throw SetupError("\(name) failed\(said.isEmpty ? "" : ": \(said)")")
        }
        return output
    }

    static func plist(_ data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw SetupError("hdiutil answered in a form the installer couldn't read.")
        }
        return plist
    }
}

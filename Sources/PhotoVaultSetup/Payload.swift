import Foundation

/// What the installer carries and puts on every vault: PhotoVault itself, the
/// README that goes beside it, the default tag groups, and JoyTag — its model
/// files, tag list and licence. JoyTag isn't optional: every vault gets it.
public struct Payload: Sendable {
    public let folder: URL
    /// PhotoVault's version, from its Info.plist.
    public let version: String
    /// JoyTag's version, from its manifest.
    public let joyTagVersion: String

    public var app: URL { folder.appendingPathComponent("PhotoVault.app") }
    public var readme: URL { folder.appendingPathComponent("README.txt") }
    public var tagGroups: URL { folder.appendingPathComponent("Tag Groups.txt") }
    public var joyTag: URL { folder.appendingPathComponent("JoyTag") }

    public init(folder: URL) throws {
        self.folder = folder
        let fm = FileManager.default
        let plist = folder.appendingPathComponent("PhotoVault.app/Contents/Info.plist")
        guard let data = fm.contents(atPath: plist.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              fm.isExecutableFile(atPath: folder.appendingPathComponent("PhotoVault.app/Contents/MacOS/PhotoVault").path),
              fm.fileExists(atPath: folder.appendingPathComponent("README.txt").path),
              fm.fileExists(atPath: folder.appendingPathComponent("Tag Groups.txt").path),
              let joyTagVersion = VaultSetup.joyTagVersion(inPackage: folder.appendingPathComponent("JoyTag")),
              fm.fileExists(atPath: folder.appendingPathComponent("JoyTag/JoyTag.mlmodelc").path),
              fm.fileExists(atPath: folder.appendingPathComponent("JoyTag/tags.txt").path)
        else { throw SetupError("This copy of the installer is incomplete: part of it is missing. Download it again.") }
        self.version = version
        self.joyTagVersion = joyTagVersion
    }

    /// The payload inside the running installer app.
    public static func bundled() throws -> Payload {
        guard let resources = Bundle.main.resourceURL else {
            throw SetupError("This copy of the installer is incomplete: part of it is missing. Download it again.")
        }
        return try Payload(folder: resources.appendingPathComponent("Payload"))
    }

    /// The size of JoyTag's files, for the installer to show.
    public var joyTagBytes: Int64 {
        VaultSetup.files(in: joyTag).reduce(0) { $0 + $1.size }
    }
}

/// The vault is password-protected and isn't open: ask for its password, then
/// try again with it.
public struct PasswordNeeded: LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? { "This vault is protected with a password." }
}

/// A failure, in words for the person running the installer.
public struct SetupError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

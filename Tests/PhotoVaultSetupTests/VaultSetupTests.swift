import Testing
import Foundation
@testable import PhotoVaultSetup

/// The installer's work, on real sparse bundles: small ones, in the project's
/// .build folder, mounted out of Finder's sight and always detached afterwards.
@Suite("Vault setup", .serialized)
struct VaultSetupTests {
    let fm = FileManager.default

    @Test func aNewVaultHasEverythingOnIt() throws {
        let scratch = try Scratch()
        let payload = try scratch.payload(version: "1.3.0")
        var steps: [SetupStep] = []
        let report = try VaultSetup.create(name: "Test Vault", in: scratch.root, size: "100m", payload: payload,
                                           mountRoot: scratch.mountRoot) { steps.append($0) }
        let mount = report.mountPoint
        #expect(steps == [.creating, .opening, .installingApp, .installingJoyTag, .checking])
        #expect(report.createdImage?.path == scratch.root.appendingPathComponent("Test Vault.sparsebundle").path)
        #expect(mount.path.hasPrefix(scratch.mountRoot.path))
        #expect(report.version == "1.3.0")
        #expect(report.replacedVersion == nil)
        #expect(report.joyTag == .installed("test1"))
        #expect(report.tagGroups == .added)

        for item in ["Photos", ".metadata_never_index", "README.txt", ".Tag Groups.txt", "PhotoVault.app/Contents/MacOS/PhotoVault"] {
            #expect(fm.fileExists(atPath: mount.appendingPathComponent(item).path), "\(item)")
        }
        #expect(try Data(contentsOf: mount.appendingPathComponent("README.txt")) == Data(contentsOf: payload.readme))
        let jt = mount.appendingPathComponent(".catalog/models/JoyTag")
        #expect(VaultSetup.files(in: jt) == VaultSetup.files(in: payload.joyTag))
        #expect(fm.fileExists(atPath: jt.appendingPathComponent("LICENSE.txt").path))

        // The volume shows PhotoVault's icon, as build-app.sh sets it.
        let icon = payload.app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        #expect(try Data(contentsOf: mount.appendingPathComponent(".VolumeIcon.icns")) == Data(contentsOf: icon))
        #expect(FinderInfo.hasCustomIcon(mount))

        // 32 MB bands, as new-vault.sh makes them.
        let info = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: report.createdImage!.appendingPathComponent("Info.plist")), format: nil) as? [String: Any]
        #expect(info?["band-size"] as? Int == 32 * 1024 * 1024)

        // It's offered as a vault to install on, and looks like what was put there.
        let found = try #require(VaultSetup.mountedVaults().first { $0.mountPoint == mount })
        #expect(found.installedVersion == "1.3.0")
        #expect(found.joyTagVersion == "test1")
        #expect(found.hasCatalog == false)
        #expect(found.photoVaultIsOpen == false)
        #expect(DiskImages.canonical(found.image!) == DiskImages.canonical(report.createdImage!))

        // A second with the same name is refused, before anything is made.
        #expect(throws: SetupError.self) {
            try VaultSetup.create(name: "Test Vault", in: scratch.root, size: "100m", payload: payload,
                                  mountRoot: scratch.mountRoot)
        }
    }

    @Test func installingLeavesThePhotosAndTheCatalogAlone() throws {
        let scratch = try Scratch()
        let old = try scratch.payload(version: "1.2.0")
        let mount = try VaultSetup.create(name: "Old Vault", in: scratch.root, size: "100m", payload: old,
                                          mountRoot: scratch.mountRoot).mountPoint
        // As a vault set up before JoyTag came with PhotoVault.
        try fm.removeItem(at: mount.appendingPathComponent(".catalog/models"))
        // What a vault in use has: photos, a catalog, and the visible tag
        // groups file from before 1.3.0.
        let photo = mount.appendingPathComponent("Photos/2019/IMG_0001.jpg")
        try fm.createDirectory(at: photo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<5000).map { UInt8($0 % 251) }).write(to: photo)
        try fm.createDirectory(at: mount.appendingPathComponent(".catalog/backups"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: mount.appendingPathComponent(".catalog/catalog.sqlite"))
        try Data(repeating: 2, count: 8192).write(to: mount.appendingPathComponent(".catalog/thumbs.pack"))
        try Data(repeating: 3, count: 100).write(to: mount.appendingPathComponent(".catalog/backups/catalog-1.sqlite"))
        try fm.moveItem(at: mount.appendingPathComponent(".Tag Groups.txt"), to: mount.appendingPathComponent("Tag Groups.txt"))
        let photoBefore = try Data(contentsOf: photo)
        let catalogBefore = VaultSetup.catalogFiles(in: mount)
        #expect(catalogBefore.count == 3)

        let vault = try VaultSetup.inspect(mount)
        #expect(vault.installedVersion == "1.2.0")
        #expect(vault.hasCatalog)
        #expect(vault.joyTagVersion == nil)
        #expect(!vault.photoVaultIsOpen)

        let new = try scratch.payload(version: "1.3.0")
        var steps: [SetupStep] = []
        let report = try VaultSetup.install(into: mount, payload: new) { steps.append($0) }
        #expect(steps == [.installingApp, .installingJoyTag, .checking])
        #expect(report.version == "1.3.0")
        #expect(report.replacedVersion == "1.2.0")
        #expect(report.createdImage == nil)
        #expect(report.joyTag == .installed("test1"))
        #expect(report.tagGroups == .renamed)
        #expect(VaultSetup.version(ofAppIn: mount) == "1.3.0")
        #expect(try Data(contentsOf: mount.appendingPathComponent("README.txt")) == Data(contentsOf: new.readme))
        #expect(!fm.fileExists(atPath: mount.appendingPathComponent("Tag Groups.txt").path))
        #expect(try String(contentsOf: mount.appendingPathComponent(".Tag Groups.txt"), encoding: .utf8) == "# groups 1.2.0")

        #expect(try Data(contentsOf: photo) == photoBefore)
        #expect(VaultSetup.catalogFiles(in: mount) == catalogBefore)
        for leftover in [".PhotoVault-incoming.app", ".PhotoVault-outgoing.app", ".catalog/models/.JoyTag-incoming", ".catalog/models/.JoyTag-outgoing"] {
            #expect(!fm.fileExists(atPath: mount.appendingPathComponent(leftover).path), "\(leftover)")
        }

        // Again: JoyTag is there already, and a tag groups file someone has
        // edited is kept.
        try Data("edited".utf8).write(to: mount.appendingPathComponent(".Tag Groups.txt"))
        let again = try VaultSetup.install(into: mount, payload: new)
        #expect(again.joyTag == .alreadyThere("test1"))
        #expect(again.tagGroups == .kept)
        #expect(again.replacedVersion == "1.3.0")
        #expect(try String(contentsOf: mount.appendingPathComponent(".Tag Groups.txt"), encoding: .utf8) == "edited")

        // This JoyTag with its licence missing, as on a vault set up before the
        // licence shipped: the licence is added, and the model isn't copied
        // again — that would grow the disk image by its whole size.
        let jt = mount.appendingPathComponent(".catalog/models/JoyTag")
        let weights = jt.appendingPathComponent("JoyTag.mlmodelc/weights/weight.bin")
        let weightsCopied = try fm.attributesOfItem(atPath: weights.path)[.creationDate] as? Date
        try fm.removeItem(at: jt.appendingPathComponent("LICENSE.txt"))
        #expect(try VaultSetup.install(into: mount, payload: new).joyTag == .installed("test1"))
        #expect(VaultSetup.files(in: jt) == VaultSetup.files(in: new.joyTag))
        #expect(try fm.attributesOfItem(atPath: weights.path)[.creationDate] as? Date == weightsCopied)

        // Another JoyTag version is replaced whole.
        let newer = try scratch.payload(version: "1.3.1", joyTagVersion: "test2")
        #expect(try VaultSetup.install(into: mount, payload: newer).joyTag == .installed("test2"))
        #expect(VaultSetup.files(in: jt) == VaultSetup.files(in: newer.joyTag))
        #expect(VaultSetup.joyTagVersion(in: mount) == "test2")
        #expect(VaultSetup.catalogFiles(in: mount) == catalogBefore)
    }

    @Test func aDiskImageThatIsntOpenIsOpenedToInstall() throws {
        let scratch = try Scratch()
        let payload = try scratch.payload(version: "1.3.0")
        let created = try VaultSetup.create(name: "Closed", in: scratch.root, size: "100m", payload: payload,
                                            mountRoot: scratch.mountRoot)
        let image = try #require(created.createdImage)
        try DiskImages.detach(created.mountPoint)
        #expect(DiskImages.mountPoint(of: image) == nil)

        var steps: [SetupStep] = []
        let report = try VaultSetup.install(into: image, payload: payload, mountRoot: scratch.mountRoot) { steps.append($0) }
        #expect(steps == [.opening, .installingApp, .installingJoyTag, .checking])
        #expect(DiskImages.mountPoint(of: image).map(DiskImages.canonical) == DiskImages.canonical(report.mountPoint))
        #expect(report.joyTag == .alreadyThere("test1"))
    }

    @Test func aPhotoVaultOpenFromTheVaultIsQuitFirst() throws {
        let scratch = try Scratch()
        let payload = try scratch.payload(version: "1.3.0")
        let mount = try VaultSetup.create(name: "In Use", in: scratch.root, size: "100m", payload: payload,
                                          mountRoot: scratch.mountRoot).mountPoint
        // The stand-in PhotoVault is a copy of sleep, run from the vault.
        let running = Process()
        running.executableURL = mount.appendingPathComponent("PhotoVault.app/Contents/MacOS/PhotoVault")
        running.arguments = ["60"]
        try running.run()
        defer { if running.isRunning { running.terminate() } }
        let deadline = Date().addingTimeInterval(5)
        while VaultSetup.runningPhotoVaults(in: mount).isEmpty, Date() < deadline { usleep(50_000) }
        #expect(try VaultSetup.inspect(mount).photoVaultIsOpen)

        var steps: [SetupStep] = []
        let report = try VaultSetup.install(into: mount, payload: payload) { steps.append($0) }
        #expect(steps == [.quitting, .installingApp, .installingJoyTag, .checking])
        #expect(report.quitPhotoVault)
        running.waitUntilExit()
        #expect(running.terminationReason == .uncaughtSignal)
        #expect(running.terminationStatus == SIGTERM)
    }

    @Test func somethingThatIsntAVaultIsRefused() throws {
        let scratch = try Scratch()
        let payload = try scratch.payload(version: "1.3.0")
        let folder = scratch.root.appendingPathComponent("Not a vault")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: SetupError.self) { try VaultSetup.install(into: folder, payload: payload) }
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("PhotoVault.app").path))

        // A disk image that isn't a vault is closed again, as it was.
        let image = scratch.root.appendingPathComponent("Other.sparsebundle")
        try DiskImages.create(image, volumeName: "Other", size: "100m")
        #expect(throws: SetupError.self) { try VaultSetup.open(image, mountRoot: scratch.mountRoot) }
        #expect(DiskImages.mountPoint(of: image) == nil)
    }

    @Test func anInstallerWithoutJoyTagIsRefused() throws {
        let scratch = try Scratch()
        let payload = try scratch.payload(version: "1.3.0")
        #expect(payload.joyTagVersion == "test1")
        #expect(payload.joyTagBytes == 100_000 + 4 + 18 + Int64(Scratch.manifest("test1").utf8.count))
        try fm.removeItem(at: payload.joyTag.appendingPathComponent("JoyTag.mlmodelc"))
        #expect(throws: SetupError.self) { try Payload(folder: payload.folder) }
        try fm.removeItem(at: payload.joyTag)
        #expect(throws: SetupError.self) { try Payload(folder: payload.folder) }

        let other = try scratch.payload(version: "1.3.1")
        try fm.removeItem(at: other.readme)
        #expect(throws: SetupError.self) { try Payload(folder: other.folder) }
    }

    @Test func namesAreChecked() {
        #expect(VaultSetup.problem(withName: "Family Photos") == nil)
        #expect(VaultSetup.problem(withName: "  ") != nil)
        #expect(VaultSetup.problem(withName: "Family/Photos") != nil)
        #expect(VaultSetup.problem(withName: "Family:Photos") != nil)
        #expect(VaultSetup.problem(withName: ".Photos") != nil)
        #expect(VaultSetup.problem(withName: String(repeating: "x", count: 61)) != nil)
        #expect(VaultSetup.bundle(named: " Family ", in: URL(fileURLWithPath: "/x")).path == "/x/Family.sparsebundle")
    }

    @Test func versionsCompareByNumber() {
        #expect(VaultSetup.compare("1.3.0", "1.10.0") == -1)
        #expect(VaultSetup.compare("1.3", "1.3.0") == 0)
        #expect(VaultSetup.compare("2.0.0", "1.9.9") == 1)
    }
}

/// A folder for disk images and their mount points, in the project's .build
/// folder. Everything mounted from it is detached when it goes.
final class Scratch {
    let root: URL
    let mountRoot: URL
    static func manifest(_ version: String) -> String { #"{"tool": "JoyTag", "version": "\#(version)"}"# }

    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = package.resolvingSymlinksInPath()
            .appendingPathComponent(".build/setup-tests/\(UUID().uuidString.prefix(8))")
        mountRoot = root.appendingPathComponent("mnt")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
    }

    deinit {
        let prefix = root.path + "/"
        for (image, mount) in DiskImages.mounted() where DiskImages.canonical(image).hasPrefix(prefix) {
            if (try? DiskImages.detach(mount)) == nil { try? DiskImages.detach(mount, force: true) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// What the installer carries, with a small signed stand-in for
    /// PhotoVault — a copy of sleep — and a small one for JoyTag.
    func payload(version: String, joyTagVersion: String = "test1") throws -> Payload {
        let fm = FileManager.default
        let folder = root.appendingPathComponent("payload-\(version)")
        let contents = folder.appendingPathComponent("PhotoVault.app/Contents")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleExecutable": "PhotoVault", "CFBundleIdentifier": "local.photovault.setup-test",
                                   "CFBundleName": "PhotoVault", "CFBundlePackageType": "APPL",
                                   "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try fm.copyItem(atPath: "/bin/sleep", toPath: contents.appendingPathComponent("MacOS/PhotoVault").path)
        try Data("icon \(version)".utf8).write(to: contents.appendingPathComponent("Resources/AppIcon.icns"))
        try Shell.run("/usr/bin/codesign", ["-s", "-", "-f", folder.appendingPathComponent("PhotoVault.app").path])
        try Data("README \(version)".utf8).write(to: folder.appendingPathComponent("README.txt"))
        try Data("# groups \(version)".utf8).write(to: folder.appendingPathComponent("Tag Groups.txt"))
        let jt = folder.appendingPathComponent("JoyTag")
        try fm.createDirectory(at: jt.appendingPathComponent("JoyTag.mlmodelc/weights"), withIntermediateDirectories: true)
        try Data(Self.manifest(joyTagVersion).utf8).write(to: jt.appendingPathComponent("manifest.json"))
        try Data(repeating: 7, count: 100_000).write(to: jt.appendingPathComponent("JoyTag.mlmodelc/weights/weight.bin"))
        try Data("tag\n".utf8).write(to: jt.appendingPathComponent("tags.txt"))
        try Data("Apache License 2.0".utf8).write(to: jt.appendingPathComponent("LICENSE.txt"))
        return try Payload(folder: folder)
    }
}

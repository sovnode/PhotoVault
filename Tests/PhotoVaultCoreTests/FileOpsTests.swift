import Testing
import Foundation
@testable import PhotoVaultCore

@Suite("Moving photos into folders", .serialized)
struct MoveTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    private func store(with paths: [String]) async throws -> (Store, [String: PhotoItem]) {
        for (n, path) in paths.enumerated() { try vault.writeImage(path, seed: 0.1 + Double(n) * 0.07) }
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let items = try await store.items(scope: .all, filter: .all)
        return (store, Dictionary(uniqueKeysWithValues: items.map { ($0.relPath, $0) }))
    }

    private var packSize: Int { vault.fileSize(vault.packFile) }

    @Test func aMovedPhotoKeepsEverythingAndNothingIsRedone() async throws {
        let (store, items) = try await store(with: ["2019/a.jpg", "2020/b.jpg"])
        let a = try #require(items["Photos/2019/a.jpg"])
        try await store.setFavorite(true, for: [a.id])
        let album = try await store.createAlbum(named: "Kept")
        try await store.addToAlbum(album, photoIDs: [a.id])
        let pack = packSize

        let result = try await store.move([a.id], toFolder: "Photos/2020")
        #expect(result.moved == [MoveRecord(id: a.id, from: "Photos/2019/a.jpg", to: "Photos/2020/a.jpg")])
        #expect(result.problems.isEmpty)
        #expect(FileManager.default.fileExists(atPath: vault.photos.appendingPathComponent("2020/a.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: vault.photos.appendingPathComponent("2019/a.jpg").path))
        let moved = try #require(try await store.photo(id: a.id))
        #expect(moved.relPath == "Photos/2020/a.jpg" && moved.folder == "Photos/2020")
        #expect(moved.favorite && moved.hasThumb)
        #expect(try await store.albumCount(album) == 1)

        // The next scan finds nothing to do: no new row, no new thumbnail.
        try await store.scan(full: false)
        #expect(try await store.photoCount() == 2)
        #expect(packSize == pack)
        #expect(try await store.photo(id: a.id)?.relPath == "Photos/2020/a.jpg")
        await store.close()
    }

    @Test func aNameAlreadyThereIsNeverOverwritten() async throws {
        let (store, items) = try await store(with: ["x/a.jpg", "y/a.jpg"])
        let xa = try #require(items["Photos/x/a.jpg"])
        let ya = try #require(items["Photos/y/a.jpg"])
        let before = try Data(contentsOf: vault.photos.appendingPathComponent("y/a.jpg"))
        let result = try await store.move([xa.id], toFolder: "Photos/y")
        #expect(result.moved.first?.to == "Photos/y/a 2.jpg", "as Finder names it")
        #expect(try Data(contentsOf: vault.photos.appendingPathComponent("y/a.jpg")) == before, "the one there is untouched")
        #expect(try await store.photo(id: ya.id)?.relPath == "Photos/y/a.jpg")
        await store.close()
    }

    @Test func undoPutsEachBackWithItsOwnName() async throws {
        let (store, items) = try await store(with: ["x/a.jpg", "y/a.jpg", "z/c.jpg"])
        let xa = try #require(items["Photos/x/a.jpg"]), zc = try #require(items["Photos/z/c.jpg"])
        let moved = try await store.move([xa.id, zc.id], toFolder: "Photos/y")
        #expect(moved.moved.count == 2)
        let back = try await store.moveBack(moved.moved)
        #expect(back.moved.count == 2)
        #expect(try await store.photo(id: xa.id)?.relPath == "Photos/x/a.jpg")
        #expect(try await store.photo(id: zc.id)?.relPath == "Photos/z/c.jpg")
        #expect(FileManager.default.fileExists(atPath: vault.photos.appendingPathComponent("y/a.jpg").path))
        await store.close()
    }

    @Test func aNewFolderIsMadeAndPhotosAlreadyThereAreLeft() async throws {
        let (store, items) = try await store(with: ["a.jpg", "trip/b.jpg"])
        let a = try #require(items["Photos/a.jpg"]), b = try #require(items["Photos/trip/b.jpg"])
        let result = try await store.move([a.id, b.id], toFolder: "Photos/trip")
        #expect(result.moved.count == 1 && result.alreadyThere == 1)
        let made = try await store.move([b.id], toFolder: "Photos/trip/2024 summer")
        #expect(made.moved.first?.to == "Photos/trip/2024 summer/b.jpg")
        #expect(try await store.folderTree().children?.first?.children?.first?.name == "2024 summer")
        await store.close()
    }

    @Test func nothingMovesOutsideThePhotosFolder() async throws {
        let (store, items) = try await store(with: ["a.jpg"])
        let a = try #require(items["Photos/a.jpg"])
        for bad in ["", ".catalog", "Photos/../.catalog", "Photos//x", "/tmp"] {
            await #expect(throws: (any Error).self) { try await store.move([a.id], toFolder: bad) }
        }
        #expect(try await store.photo(id: a.id)?.relPath == "Photos/a.jpg")
        await store.close()
    }

    @Test func aLockedPhotoSaysSoAndUnlockingMovesIt() async throws {
        let (store, items) = try await store(with: ["a.jpg"])
        let a = try #require(items["Photos/a.jpg"])
        let url = vault.photos.appendingPathComponent("a.jpg")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }

        let refused = try await store.move([a.id], toFolder: "Photos/new")
        #expect(refused.moved.isEmpty)
        #expect(refused.problems.map(\.reason) == [.locked])
        #expect(try await store.photo(id: a.id)?.relPath == "Photos/a.jpg", "the row stays with the file")

        let unlocked = try await store.move([a.id], toFolder: "Photos/new", unlocking: true)
        #expect(unlocked.moved.count == 1)
        #expect(try await store.photo(id: a.id)?.relPath == "Photos/new/a.jpg")
        await store.close()
    }
}

@Suite("Files macOS won't let go", .serialized)
struct FileProblemTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    @Test func emptyTrashSaysWhyAndUnlockingFinishesIt() async throws {
        try vault.writeImage("a.jpg", seed: 0.2)
        try vault.writeImage("b.jpg", seed: 0.4)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let ids = try await store.items(scope: .all, filter: .all).map(\.id)
        try await store.moveToTrash(ids)
        let locked = vault.photos.appendingPathComponent("a.jpg")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }

        let ahead = try await store.trashProblems()
        #expect(ahead.map(\.name) == ["a.jpg"] && ahead.first?.reason == .locked, "known before anything is deleted")

        let first = try await store.emptyTrash()
        #expect(first.deleted == 1)
        #expect(first.problems.map(\.reason) == [.locked])
        #expect(try await store.trashCount() == 1, "the locked one stays in the Trash")
        #expect(FileManager.default.fileExists(atPath: locked.path))

        let second = try await store.emptyTrash(ids: first.problems.map(\.id), unlocking: true)
        #expect(second.deleted == 1 && second.problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: locked.path))
        #expect(try await store.trashCount() == 0)
        await store.close()
    }

    @Test func aFolderThatCantBeChangedIsToldApart() async throws {
        try vault.writeImage("shut/a.jpg", seed: 0.3)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let id = try #require(try await store.items(scope: .all, filter: .all).first?.id)
        try await store.moveToTrash([id])
        let folder = vault.photos.appendingPathComponent("shut")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let result = try await store.emptyTrash()
        #expect(result.deleted == 0)
        #expect(result.problems.map(\.reason) == [.folderReadOnly])
        #expect(result.problems.first?.reason.needsAdministrator == true)
        await store.close()
    }

    @Test func pathsForAnAdministratorAreQuotedAndStayArguments() {
        #expect(AdministratorFiles.quote("/V/Photos/it's here.jpg") == "'/V/Photos/it'\\''s here.jpg'")
        let command = AdministratorFiles.command(for: [.delete("/V/Photos/a b.jpg"), .move(from: "/V/Photos/c.jpg", to: "/V/Photos/x/c.jpg")])
        #expect(command == "/usr/bin/chflags nouchg,noschg '/V/Photos/a b.jpg'; /bin/rm -f '/V/Photos/a b.jpg'; "
                + "/usr/bin/chflags nouchg,noschg '/V/Photos/c.jpg'; /bin/mv -n '/V/Photos/c.jpg' '/V/Photos/x/c.jpg'; true")
        let args = AdministratorFiles.osascriptArguments(command: "rm '$(evil)'", prompt: "\"; beep")
        #expect(args.suffix(2) == ["rm '$(evil)'", "\"; beep"], "the command and prompt never enter the script's text")
        #expect(!args.dropLast(2).joined().contains("evil"))
    }

    @Test func namesAndFoldersForMoving() {
        let taken: Set<String> = ["Photos/a.jpg", "Photos/a 2.jpg", "Photos/notes"]
        #expect(MovePlanning.freeName("a.jpg", in: "Photos") { taken.contains($0) } == "a 3.jpg")
        #expect(MovePlanning.freeName("notes", in: "Photos") { taken.contains($0) } == "notes 2")
        #expect(MovePlanning.freeName("b.jpg", in: "Photos") { taken.contains($0) } == "b.jpg")
        #expect(MovePlanning.isInsidePhotos("Photos") && MovePlanning.isInsidePhotos("Photos/2019/summer"))
        for bad in ["", "Photo", "Photos2", "Photos/../x", "Photos/./x", "Photos//x", "Photos/", ".catalog"] {
            #expect(!MovePlanning.isInsidePhotos(bad), "\(bad)")
        }
        #expect(MovePlanning.isValidFolderName("Summer 2024"))
        for bad in ["", " ", " lead", "trail ", ".hidden", "a/b", "a:b"] {
            #expect(!MovePlanning.isValidFolderName(bad), "\(bad)")
        }
    }
}

@Suite("Fix Permissions", .serialized)
struct PermissionFixerTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    private func chmod(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    @Test func findsAndFixesWhatWouldStopAMoveOrDelete() throws {
        let backup = try vault.writeImage("restored/a.jpg", seed: 0.2)
        let locked = try vault.writeImage("b.jpg", seed: 0.3)
        let readOnly = try vault.writeImage("c.jpg", seed: 0.4)
        let fine = try vault.writeImage("d.jpg", seed: 0.5)
        // What Time Machine leaves on a file copied out of a backup — plus an
        // allow rule someone set, which must stay.
        try chmod(["+a", "group:everyone deny write,delete,append,writeattr,writeextattr,chown", backup.path])
        try chmod(["+a", "group:everyone allow read", backup.path])
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnly.path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
            if FileManager.default.fileExists(atPath: backup.path) { try? chmod(["-N", backup.path]) }
        }

        let issues = PermissionFixer.scan(vault.photos)
        let byName = Dictionary(uniqueKeysWithValues: issues.map { (($0.path as NSString).lastPathComponent, $0.kinds) })
        #expect(byName == ["a.jpg": [.denyRules], "b.jpg": [.locked], "c.jpg": [.readOnly]], "\(byName)")
        #expect(FileCheck.blocker(removing: backup) != nil || (try? FileManager.default.removeItem(at: backup)) == nil)

        for issue in issues { #expect(PermissionFixer.fix(issue), "\(issue.path)") }
        #expect(PermissionFixer.scan(vault.photos).isEmpty)
        #expect(PermissionFixer.problems(at: fine.path).isEmpty)
        // The allow rule is still there; only the deny went.
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ls")
        p.arguments = ["-le", backup.path]
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let listing = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(listing.contains("allow read") && !listing.contains("deny"))
        try FileManager.default.removeItem(at: backup)
        try FileManager.default.removeItem(at: locked)
    }

    @Test func anAdministratorsCommandIsQuotedPerFile() {
        let command = PermissionFixer.administratorCommand(for: ["/V/Photos/it's.jpg"])
        #expect(command.hasPrefix("/usr/bin/chflags nouchg,noschg '/V/Photos/it'\\''s.jpg'; /bin/chmod -N '/V/Photos/it'\\''s.jpg'; /usr/sbin/chown \(getuid()) "))
        #expect(command.hasSuffix("; true"))
    }
}

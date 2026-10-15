import Foundation
import AppKit
import SwiftUI
import PhotoVaultSetup
import QuietPreferences

/// The installer without its window, for scripts.
@MainActor
enum Headless {
    static var usage: String {
        var text = """
        PhotoVault Installer: makes a new vault, or puts PhotoVault on an existing one.
        With no arguments it opens its window.

          PhotoVaultInstaller --create <folder>/<Name>.sparsebundle [--size 500g]
          PhotoVaultInstaller --install <vault.sparsebundle | mounted vault> [--allow-older]
          PhotoVaultInstaller --inspect <vault.sparsebundle | mounted vault>

          --size <size>       the most the new vault can hold, as hdiutil reads it: 500g, 1t
          --allow-older       install over a newer PhotoVault
          --password-stdin    a password, read from standard input: protects a new
                              vault, or opens a protected one to install on it
          --mount-root <dir>  mount disk images there, out of Finder's sidebar
        """
        #if DEBUG
        text += """

          --payload <folder>  install from that folder, not the one inside the app
          --snapshot <dir>    draw each of the window's screens into PNG files there
        """
        #endif
        return text
    }

    /// Runs a command, returning its exit status — or nil when there's no
    /// command, and the window should open.
    static func run(_ arguments: [String]) -> Int32? {
        let args = Array(arguments.dropFirst())
        var commands = ["--create", "--install", "--inspect", "--help", "-h"]
        var options = ["--size", "--mount-root"]
        #if DEBUG
        commands.append("--snapshot")
        options.append("--payload")
        #endif
        guard let command = args.first, commands.contains(command) else { return nil }
        if command == "--help" || command == "-h" {
            print(usage)
            return 0
        }

        var values: [String: String] = [:]
        var allowOlder = false
        var passwordFromStdin = false
        var i = 0
        while i < args.count {
            let arg = args[i]
            if commands.contains(arg) || options.contains(arg) {
                guard i + 1 < args.count else { return fail("\(arg) needs a value.\n\n\(usage)") }
                values[arg] = args[i + 1]
                i += 2
            } else if arg == "--allow-older" {
                allowOlder = true
                i += 1
            } else if arg == "--password-stdin" {
                passwordFromStdin = true
                i += 1
            } else {
                return fail("unknown argument \(arg)\n\n\(usage)")
            }
        }
        guard let value = values[command] else { return fail(usage) }
        let target = URL(fileURLWithPath: value)
        let mountRoot = values["--mount-root"].map { URL(fileURLWithPath: $0) }
        // Read, used and dropped; never printed.
        let password: String? = passwordFromStdin
            ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            : nil

        do {
            if command == "--inspect" {
                let (vault, mounted) = try VaultSetup.open(target, mountRoot: mountRoot, password: password)
                describe(vault)
                if mounted { print("(opened to look; it's still open)") }
                return 0
            }
            var payload: Payload
            #if DEBUG
            payload = try values["--payload"].map { try Payload(folder: URL(fileURLWithPath: $0)) } ?? Payload.bundled()
            if command == "--snapshot" {
                try Snapshots.render(to: target, payload: payload)
                print("Drew the installer's screens into \(target.path)")
                return 0
            }
            #else
            payload = try Payload.bundled()
            #endif
            if command == "--create" {
                var name = target.lastPathComponent
                if name.hasSuffix(".sparsebundle") { name = String(name.dropLast(".sparsebundle".count)) }
                print("PhotoVault Installer \(payload.version): creating “\(name)” in \(target.deletingLastPathComponent().path)")
                let report = try VaultSetup.create(name: name, in: target.deletingLastPathComponent(),
                                                   size: values["--size"] ?? VaultSetup.defaultSize, payload: payload,
                                                   password: password, mountRoot: mountRoot, progress: say)
                describe(report)
            } else {
                let (vault, _) = try VaultSetup.open(target, mountRoot: mountRoot, password: password)
                if let installed = vault.installedVersion, VaultSetup.compare(installed, payload.version) > 0, !allowOlder {
                    throw SetupError("The vault has PhotoVault \(installed), newer than \(payload.version). Add --allow-older to install the older version.")
                }
                print("PhotoVault Installer \(payload.version): installing on “\(vault.name)”")
                let report = try VaultSetup.install(into: target, payload: payload, password: password,
                                                    mountRoot: mountRoot, progress: say)
                describe(report)
            }
            return 0
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func say(_ step: SetupStep) {
        print("  \(step.rawValue)…")
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 1
    }

    private static func describe(_ report: SetupReport) {
        print("Done.")
        print("  Vault:      \(report.mountPoint.path)")
        if let image = report.createdImage { print("  Disk image: \(image.path)") }
        print("  PhotoVault: \(report.version)\(report.replacedVersion.map { " (replaced \($0))" } ?? "")")
        switch report.joyTag {
        case .installed(let v): print("  JoyTag:     \(v), installed")
        case .alreadyThere(let v): print("  JoyTag:     \(v), there already")
        }
        switch report.tagGroups {
        case .added: print("  Tag groups: added")
        case .renamed: print("  Tag groups: Tag Groups.txt hidden as .Tag Groups.txt")
        case .kept: print("  Tag groups: kept")
        }
        if report.quitPhotoVault { print("  PhotoVault was quit to install.") }
    }

    private static func describe(_ vault: ExistingVault) {
        print("Vault:      \(vault.mountPoint.path)")
        print("Disk image: \(vault.image?.path ?? "none")")
        print("PhotoVault: \(vault.installedVersion ?? "not installed")")
        print("Catalog:    \(vault.hasCatalog ? "yes" : "none yet")")
        print("JoyTag:     \(vault.joyTagVersion ?? "not installed")")
        print("Open:       \(vault.photoVaultIsOpen ? "PhotoVault is open from it" : "no")")
    }
}

#if DEBUG
/// Draws the window's screens into PNG files, offscreen, with made-up vaults —
/// for checking how they look without opening the installer. Debug builds
/// only.
@MainActor
enum Snapshots {
    static func render(to folder: URL, payload: Payload) throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        PreferencesGuard.install()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, dark, setUp) in states(payload) {
            let model = InstallerModel(preview: payload)
            setUp(model)
            let png = try draw(InstallerView().environmentObject(model), dark: dark)
            try png.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }

    private static func states(_ payload: Payload) -> [(String, Bool, (InstallerModel) -> Void)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let older = ExistingVault(mountPoint: URL(fileURLWithPath: "/Volumes/Family Photos"),
                                  image: home.appendingPathComponent("Family Photos.sparsebundle"),
                                  installedVersion: "1.2.0", hasCatalog: true, joyTagVersion: nil, photoVaultIsOpen: true)
        var newer = older
        newer.installedVersion = "9.0.0"
        newer.photoVaultIsOpen = false
        newer.joyTagVersion = payload.joyTagVersion
        let created = SetupReport(mountPoint: URL(fileURLWithPath: "/Volumes/PhotoVault"),
                                  createdImage: home.appendingPathComponent("PhotoVault.sparsebundle"),
                                  version: payload.version, replacedVersion: nil, quitPhotoVault: false,
                                  joyTag: .installed(payload.joyTagVersion), tagGroups: .added)
        let installed = SetupReport(mountPoint: older.mountPoint, createdImage: nil, version: payload.version,
                                    replacedVersion: "1.2.0", quitPhotoVault: true,
                                    joyTag: .installed(payload.joyTagVersion), tagGroups: .renamed)
        let install = { (vault: ExistingVault) in
            { (m: InstallerModel) in
                m.mode = .install
                m.vaults = [vault]
                m.chosenMount = vault.mountPoint
            }
        }
        return [
            ("1-create", false, { _ in }),
            ("1-create-dark", true, { _ in }),
            ("2-create-bad-name", false, { $0.name = "Family/Photos" }),
            ("2-create-protected", false, { m in
                m.protect = true
                m.password = "secret"
                m.confirmation = "secret"
            }),
            ("3-install-locked", false, { m in
                m.mode = .install
                m.locked = home.appendingPathComponent("Family Photos.sparsebundle")
            }),
            ("3-install-none-open", false, { $0.mode = .install }),
            ("4-install-update", false, install(older)),
            ("4-install-update-dark", true, install(older)),
            ("5-install-older", false, install(newer)),
            ("6-working", false, { m in
                m.workTitle = "Creating “PhotoVault”"
                m.steps = [.init(step: .creating, status: .done), .init(step: .opening, status: .done),
                           .init(step: .installingApp, status: .active), .init(step: .installingJoyTag), .init(step: .checking)]
                m.phase = .working
            }),
            ("7-done-created", false, { $0.phase = .done(created) }),
            ("8-done-installed", false, { $0.phase = .done(installed) }),
            ("9-failed", false, { $0.phase = .failed(title: "The vault couldn't be created",
                                                    message: "hdiutil failed: create failed - No space left on device") }),
        ]
    }

    private static func draw(_ view: some View, dark: Bool) throws -> Data {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 580, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SetupError("Couldn't draw the window.") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw SetupError("Couldn't save the drawing.") }
        return png
    }
}
#endif

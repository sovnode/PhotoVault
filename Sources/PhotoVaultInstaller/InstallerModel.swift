import SwiftUI
import AppKit
import PhotoVaultSetup

/// The installer's state: which kind of setup, what's been chosen for it, and
/// how it's going.
@MainActor
final class InstallerModel: ObservableObject {
    enum Mode: Hashable { case create, install }

    enum Phase: Equatable {
        case choosing
        case working
        case done(SetupReport)
        case failed(title: String, message: String)
    }

    struct Step: Identifiable, Equatable {
        enum Status { case waiting, active, done }
        let step: SetupStep
        var status: Status = .waiting
        var id: SetupStep { step }
    }

    /// One line about a vault, and how much it matters.
    struct Fact: Hashable {
        enum Kind { case fine, note, warning }
        let kind: Kind
        let text: String
    }

    let payload: Payload?
    let version: String
    let joyTagBytes: Int64
    let joyTagVersion: String
    /// For the snapshot renderer: nothing is looked up, chosen or changed.
    let isPreview: Bool

    @Published var mode: Mode = .create
    @Published var phase: Phase = .choosing

    /// Photo tagging (JoyTag) goes on the vault. Unticked, the vault is
    /// smaller by the model's size — and an existing vault's copy comes off.
    @Published var tagging = true

    // A new vault
    @Published var name = "PhotoVault"
    @Published var folder = FileManager.default.homeDirectoryForCurrentUser
    @Published var size = VaultSetup.defaultSize
    /// Protect with a password: the disk image is encrypted.
    @Published var protect = false
    @Published var password = ""
    @Published var confirmation = ""
    /// Whether the vault just created is protected, for the done screen.
    private var createdProtected = false

    // An existing vault
    @Published var vaults: [ExistingVault] = []
    @Published var chosenMount: URL?
    /// The name of a vault being opened.
    @Published var opening: String?
    @Published var chooseProblem: String?
    /// A protected vault that isn't open, waiting for its password.
    @Published var locked: URL?
    @Published var unlockPassword = ""

    // Working
    @Published var workTitle = ""
    @Published var steps: [Step] = []

    private var observers: [NSObjectProtocol] = []
    /// Vaults chosen by hand that aren't on a disk image — a vault folder —
    /// kept in the list across refreshes.
    private var chosenByHand: [URL] = []

    init() {
        isPreview = false
        let payload: Payload
        do {
            payload = try Payload.bundled()
        } catch {
            self.payload = nil
            version = ""
            joyTagBytes = 0
            joyTagVersion = ""
            phase = .failed(title: "This installer can't be used", message: error.localizedDescription)
            return
        }
        self.payload = payload
        version = payload.version
        joyTagBytes = payload.joyTagBytes
        joyTagVersion = payload.joyTagVersion

        // Vaults opened or ejected while the installer is open.
        let center = NSWorkspace.shared.notificationCenter
        for note in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: note, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVaults() }
            })
        }
        refreshVaults()
    }

    init(preview payload: Payload) {
        isPreview = true
        self.payload = payload
        version = payload.version
        joyTagBytes = payload.joyTagBytes
        joyTagVersion = payload.joyTagVersion
    }

    // MARK: - A new vault

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    /// Why a vault can't be created with this name here, or nil.
    var nameProblem: String? {
        if let problem = VaultSetup.problem(withName: name) { return problem }
        if FileManager.default.fileExists(atPath: VaultSetup.bundle(named: name, in: folder).path) {
            return "There's already a vault called “\(trimmedName)” here."
        }
        return nil
    }

    /// iCloud Drive would upload every photo put in the vault.
    var folderIsInICloud: Bool {
        (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
            || folder.path.contains("/Library/Mobile Documents/")
    }

    /// Where the folder is, for the line under its name.
    var folderDescription: String { Self.place(folder) }

    var freeSpace: String? {
        guard let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage else { return nil }
        return "\(Self.bytes(free)) available"
    }

    func chooseFolder() {
        guard !isPreview else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        panel.prompt = "Choose"
        panel.message = "Choose where to save the new vault's disk image."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.folder = url }
        }
    }

    // MARK: - An existing vault

    var chosen: ExistingVault? { vaults.first { $0.mountPoint == chosenMount } }

    /// What installing on `vault` does, in lines.
    func facts(for vault: ExistingVault) -> [Fact] {
        var facts: [Fact] = []
        if let installed = vault.installedVersion {
            switch VaultSetup.compare(installed, version) {
            case -1: facts.append(Fact(kind: .fine, text: "PhotoVault \(installed) is on it, and is updated to \(version)."))
            case 0: facts.append(Fact(kind: .fine, text: "PhotoVault \(version) is on it already. A fresh copy goes in its place."))
            default: facts.append(Fact(kind: .warning, text: "It has a newer PhotoVault, \(installed). Installing puts the older \(version) in its place."))
            }
        } else {
            facts.append(Fact(kind: .fine, text: "PhotoVault isn't on it yet."))
        }
        facts.append(Fact(kind: .fine, text: vault.hasCatalog ? "Its photos, albums and tags stay as they are." : "Its photos stay as they are."))
        if vault.photoVaultIsOpen {
            facts.append(Fact(kind: .note, text: "PhotoVault is open from it. The installer quits it first; a scan or tagging run carries on when it's next opened."))
        }
        return facts
    }

    /// Where a vault is, for the line under its name.
    func location(of vault: ExistingVault) -> String {
        Self.abbreviated(vault.image ?? vault.mountPoint)
    }

    func chooseVault() {
        guard !isPreview else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = chosen?.image?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Choose"
        panel.message = "Choose a vault's disk image (.sparsebundle), or the vault itself if it's open."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.choose(url) }
        }
    }

    /// A vault chosen in the panel or dropped on the window: its disk image
    /// is opened, to see what's on it.
    func choose(_ url: URL, password: String? = nil) {
        guard !isPreview, opening == nil, phase == .choosing else { return }
        mode = .install
        chooseProblem = nil
        opening = DiskImages.isDiskImage(url) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try VaultSetup.open(url, password: password).vault }
            DispatchQueue.main.async {
                self.opening = nil
                switch result {
                case .failure(is PasswordNeeded):
                    self.locked = url
                    self.unlockPassword = ""
                case .success(let vault):
                    self.locked = nil
                    self.unlockPassword = ""
                    if vault.image == nil, !self.chosenByHand.contains(vault.mountPoint) { self.chosenByHand.append(vault.mountPoint) }
                    self.show(self.vaults.filter { $0.mountPoint != vault.mountPoint } + [vault])
                    self.chosenMount = vault.mountPoint
                case .failure(let error):
                    self.chooseProblem = error.localizedDescription
                }
            }
        }
    }

    /// Opens the locked vault with the password typed. Passed on and forgotten.
    func unlock() {
        guard let url = locked, !unlockPassword.isEmpty else { return }
        let password = unlockPassword
        unlockPassword = ""
        choose(url, password: password)
    }

    /// Looks again for vaults on mounted disk images.
    func refreshVaults() {
        guard !isPreview else { return }
        let byHand = chosenByHand
        DispatchQueue.global(qos: .userInitiated).async {
            var found = VaultSetup.mountedVaults()
            for mount in byHand where !found.contains(where: { $0.mountPoint == mount }) {
                if let vault = try? VaultSetup.inspect(mount) { found.append(vault) }
            }
            DispatchQueue.main.async { self.show(found) }
        }
    }

    private func show(_ found: [ExistingVault]) {
        var list = found
        // One just opened may not be in hdiutil's list yet.
        if let current = chosen, !list.contains(where: { $0.mountPoint == current.mountPoint }),
           FileManager.default.fileExists(atPath: current.mountPoint.path) {
            list.append(current)
        }
        vaults = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if chosen == nil { chosenMount = vaults.first?.mountPoint }
    }

    // MARK: - Either

    /// Why the password can't be used yet, or nil.
    var passwordProblem: String? {
        guard protect else { return nil }
        if password.isEmpty { return "Choose a password." }
        if confirmation != password { return confirmation.isEmpty ? "Type it again to confirm it." : "The two passwords don't match." }
        return nil
    }

    /// Shown, not enforced: a short password is easy to guess.
    var passwordIsShort: Bool { protect && !password.isEmpty && password.count < 8 }

    var canStart: Bool {
        guard payload != nil, phase == .choosing, opening == nil else { return false }
        switch mode {
        case .create: return nameProblem == nil && passwordProblem == nil
        case .install: return chosen != nil
        }
    }

    var startLabel: String {
        switch mode {
        case .create: return "Create Vault"
        case .install:
            guard let installed = chosen?.installedVersion else { return "Install" }
            switch VaultSetup.compare(installed, version) {
            case -1: return "Update"
            case 0: return "Reinstall"
            default: return "Install Older Version"
            }
        }
    }

    func start() {
        guard canStart, let payload else { return }
        let tagging = tagging
        var plan: [SetupStep]
        let failure: String
        let work: ((SetupStep) -> Void) throws -> SetupReport
        switch mode {
        case .create:
            let (name, folder, size) = (trimmedName, folder, size)
            let password = protect ? password : nil
            // Passed on to hdiutil and forgotten: nothing keeps it.
            self.password = ""
            confirmation = ""
            createdProtected = password != nil
            workTitle = "Creating “\(name)”"
            failure = "The vault couldn't be created"
            plan = [.creating, .opening, .installingApp]
            work = { progress in
                try VaultSetup.create(name: name, in: folder, size: size, payload: payload, password: password,
                                      tagging: tagging, progress: progress)
            }
        case .install:
            guard let vault = chosen else { return }
            // Looked at again: PhotoVault may have been opened or quit since.
            let now = (try? VaultSetup.inspect(vault.mountPoint, image: vault.image)) ?? vault
            let target = vault.image ?? vault.mountPoint
            workTitle = "Installing PhotoVault on “\(now.name)”"
            failure = "PhotoVault couldn't be installed"
            plan = (now.photoVaultIsOpen ? [.quitting] : []) + [.installingApp]
            work = { progress in
                try VaultSetup.install(into: target, payload: payload, tagging: tagging, progress: progress)
            }
        }
        plan += (tagging ? [.installingJoyTag] : []) + [.checking]
        steps = plan.map { Step(step: $0) }
        phase = .working
        setCloseButtonEnabled(false)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work { step in DispatchQueue.main.async { self.advance(to: step) } } }
            DispatchQueue.main.async { self.finish(result, failure: failure) }
        }
    }

    private func advance(to step: SetupStep) {
        if !steps.contains(where: { $0.step == step }) {
            // Not foreseen: the vault was ejected meanwhile, and is opened again.
            let order = SetupStep.allCases
            let rank = { (s: SetupStep) in order.firstIndex(of: s) ?? 0 }
            steps.insert(Step(step: step), at: steps.firstIndex { rank($0.step) > rank(step) } ?? steps.endIndex)
        }
        guard let index = steps.firstIndex(where: { $0.step == step }) else { return }
        for i in steps.indices { steps[i].status = i < index ? .done : i == index ? .active : .waiting }
    }

    private func finish(_ result: Result<SetupReport, Error>, failure: String) {
        setCloseButtonEnabled(true)
        switch result {
        case .success(let report):
            for i in steps.indices { steps[i].status = .done }
            phase = .done(report)
        case .failure(let error):
            phase = .failed(title: failure, message: error.localizedDescription)
        }
        refreshVaults()
    }

    func back() {
        phase = .choosing
        refreshVaults()
    }

    private func setCloseButtonEnabled(_ enabled: Bool) {
        for window in NSApp.windows { window.standardWindowButton(.closeButton)?.isEnabled = enabled }
    }

    // MARK: - Done

    /// JoyTag's size, as people read it: "370 MB".
    var tagSize: String { ByteCountFormatter.string(fromByteCount: joyTagBytes, countStyle: .file) }

    /// What the Photo tagging box means, under it.
    func taggingNote(for vault: ExistingVault?) -> (text: String, warning: Bool) {
        if tagging {
            if let vault, vault.joyTagVersion != nil {
                return ("JoyTag names what's in each photo, for smart albums. It's on this vault already.", false)
            }
            return ("JoyTag names what's in each photo, for smart albums. It takes \(tagSize) on the vault.", false)
        }
        if let vault, vault.joyTagVersion != nil {
            return ("JoyTag will be taken off this vault, freeing \(tagSize). PhotoVault won't tag new photos; tags it already made are kept. Install again with this ticked to bring it back.", true)
        }
        return ("Saves \(tagSize). PhotoVault won't tag photos, so smart albums can't pick photos by what's in them. Install again with this ticked to add it later.", true)
    }

    func doneTitle(_ report: SetupReport) -> String {
        if report.createdImage != nil { return "“\(report.mountPoint.lastPathComponent)” is ready" }
        return "PhotoVault \(report.version) is on “\(report.mountPoint.lastPathComponent)”"
    }

    /// What was done, in sentences.
    func doneLines(_ report: SetupReport) -> [String] {
        var lines: [String] = []
        if let image = report.createdImage {
            lines.append("It's open in Finder as a disk called “\(report.mountPoint.lastPathComponent)”. The disk image it lives in is “\(image.lastPathComponent)”, in \(Self.place(image.deletingLastPathComponent()).lowercasedFirst).")
            if createdProtected {
                lines.append("It's protected with a password: macOS asks for it each time the vault is opened. If the password is forgotten, the photos can't be recovered.")
            }
            return lines
        }
        switch report.replacedVersion {
        case nil: break
        case report.version?: lines.append("A fresh copy replaced the one that was there.")
        case let old?: lines.append("It replaced PhotoVault \(old).")
        }
        if report.tagGroups == .renamed {
            lines.append("Its Tag Groups.txt is hidden now, as .Tag Groups.txt. To edit it, show hidden files in Finder: press ⇧⌘ and the full stop key.")
        }
        if report.quitPhotoVault { lines.append("PhotoVault was quit to install. Open it again to carry on.") }
        if case .removed = report.joyTag {
            lines.append("Photo tagging was taken off the vault, freeing \(tagSize). Tags it already made are kept, and smart albums using them still work.")
        }
        lines.append("Its photos, albums and tags are as they were.")
        return lines
    }

    /// What to do next with a new vault.
    let nextSteps = [
        "Copy your photos and videos into its Photos folder.",
        "Open PhotoVault from the disk. It finds the photos and makes their thumbnails.",
        "When you're done, eject the disk from inside PhotoVault, with ⌘E.",
    ]

    func showInFinder() {
        guard case .done(let report) = phase else { return }
        let target = report.createdImage != nil ? "Photos" : "PhotoVault.app"
        NSWorkspace.shared.activateFileViewerSelecting([report.mountPoint.appendingPathComponent(target)])
    }

    func openPhotoVault() {
        guard case .done(let report) = phase else { return }
        let app = report.mountPoint.appendingPathComponent("PhotoVault.app")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            DispatchQueue.main.async {
                guard let error else { NSApp.terminate(nil); return }
                let alert = NSAlert()
                alert.messageText = "PhotoVault didn't open"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: - Wording

    /// Sizes as Finder gives them, in powers of 1000, without decimals that
    /// don't help: 369 MB, 4.2 GB, 221 GB.
    static func bytes(_ count: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(count), unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(count) bytes" }
        return value < 10 ? String(format: "%.1f %@", value, units[unit]) : "\(Int(value.rounded())) \(units[unit])"
    }

    static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// A folder, in words: “Your home folder”, or its path from there.
    static func place(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return url.standardizedFileURL.path == home.standardizedFileURL.path ? "Your home folder" : abbreviated(url)
    }
}

private extension String {
    /// “Your home folder” in the middle of a sentence; a path as it is.
    var lowercasedFirst: String {
        guard let first, first.isUppercase else { return self }
        return first.lowercased() + dropFirst()
    }
}

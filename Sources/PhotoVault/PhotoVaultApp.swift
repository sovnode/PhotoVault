import SwiftUI
import AppKit
import PhotoVaultCore
import QuietPreferences

@main
struct PhotoVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = LibraryModel()

    init() {
        _ = SmokeHooks.launched
        // The first of the app's code to run: before NSApplication finishes
        // launching, and so before SwiftUI creates — and AppKit saves — any window.
        PreferencesGuard.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.thumbs)
                .task {
                    delegate.model = model
                    await model.start()
                }
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Replaces the system Edit items rather than adding beside them.
            // Adding a second ⌘A after the built-in Select All did nothing:
            // the menu fires the first match, and the built-in one sends
            // selectAll: to a grid that doesn't implement it. Cut, Copy and
            // Paste are kept for text fields; Copy never puts pixels on the
            // pasteboard, since nothing in the grid answers it.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                    .keyboardShortcut("x")
                Button("Copy") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c")
                Button("Paste") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v")
                Divider()
                Button("Select All") { model.selectAllCommand() }
                    .keyboardShortcut("a")
                Button("Deselect All") { model.clearSelection() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            // No Share menu: share extensions run out-of-process and copy their
            // input off the volume. No Print: CUPS spools to /var/spool/cups.
            CommandGroup(replacing: .printItem) {}
            CommandGroup(after: .sidebar) {
                Toggle("Show Whole Photos", isOn: Binding(get: { model.showWholePhotos },
                                                          set: { _ in model.toggleWholePhotos() }))
            }
            CommandMenu("Image") {
                // ⌘L / ⌘R as in Preview. These and the rest of this menu act on
                // the open photo in the viewer, or on the grid selection.
                Button("Rotate Left") { model.rotateCommand(clockwise: false) }
                    .keyboardShortcut("l")
                    .disabled(!model.canRotateCurrent)
                Button("Rotate Right") { model.rotateCommand(clockwise: true) }
                    .keyboardShortcut("r")
                    .disabled(!model.canRotateCurrent)
                Divider()
                Button("Move to Trash") { model.trashCommand() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!model.canTrashCurrent)
                Divider()
                // The classifiers listed are the ones installed in the
                // vault: JoyTag is the only one PhotoVault knows.
                Menu("Classifier") {
                    Menu("Re-classify Selection With") {
                        Button("JoyTag") { model.retagCommand() }
                            .disabled(!model.canRetagCurrent)
                    }
                    Button("Tag Untagged Photos") { model.tagUntaggedCommand() }
                        .disabled(!model.canTag || model.scanning)
                    if let why = model.taggerUnavailable {
                        Divider()
                        Text(why)
                    }
                }
                Divider()
                // Menu-level shortcuts fire whichever view has keyboard focus.
                Button("Previous Photo") { model.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(model.viewing == nil)
                Button("Next Photo") { model.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(model.viewing == nil)
                Button(model.showProperties ? "Hide Properties" : "Show Properties") {
                    model.toggleProperties()
                }
                .keyboardShortcut("i")
                .disabled(model.viewing == nil)
                Button("Show in Library") {
                    if let target = model.showInLibraryTarget { model.showInLibrary(target) }
                }
                .disabled(model.showInLibraryTarget == nil)
                Button("Back to Library") { model.viewing = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.viewing == nil)
            }
            CommandMenu("Vault") {
                Button("Rescan Changed Folders") { model.rescan(full: false) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.scanning)
                Button("Full Rescan") { model.rescan(full: true) }
                    .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                    .disabled(model.scanning)
                Button(model.job == .scan ? "Stop Scan" : "Stop Tagging") { model.stopScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.scanning)
                Divider()
                Button("Empty Trash…") { model.confirmingEmptyTrash = true }
                    .disabled(model.trashCount == 0)
                Divider()
                Button("Export Albums & Favorites…") { Task { await model.exportMemberships() } }
                Divider()
                Button("Eject Volume") { delegate.ejectVolume() }
                    .keyboardShortcut("e")
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: LibraryModel

    var body: some View {
        ZStack {
            NavigationSplitView {
                SidebarView().frame(minWidth: 200)
            } detail: {
                GridView()
            }
            // The viewer sits *outside* the split view on purpose. Nested in
            // the detail pane it was framed by the sidebar and the window's
            // toolbar strip, which in full screen read as a white bar across
            // the top of the display.
            .toolbar(model.viewing == nil ? .automatic : .hidden, for: .windowToolbar)
            .alert(model.taggingQuestion?.title ?? "", isPresented: Binding(
                get: { model.taggingQuestion != nil },
                set: { if !$0 { model.taggingQuestion = nil } }
            ), presenting: model.taggingQuestion) { question in
                Button(question.action) { model.answerTagging(question, tag: true) }
                Button("Not Now", role: .cancel) { model.answerTagging(question, tag: false) }
            } message: { question in
                Text(question.message)
            }

            if let item = model.viewing {
                // Only the photo and its black backdrop extend under the
                // titlebar (inside ViewerView). The header must not: in a
                // window, the transparent titlebar strip swallows clicks, so a
                // close button drawn there looks clickable but isn't.
                ViewerView(item: item)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .background(WindowChrome(viewing: model.viewing != nil, savedFrame: model.savedWindowFrame))
        .sheet(item: $model.newAlbumRequest) { request in NewAlbumForPhotosSheet(request: request) }
        .alert("PhotoVault", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// Test-only behaviour for `Scripts/smoke-test.sh`. Every hook is inert unless
/// its environment variable is set, which only the smoke test does.
enum SmokeHooks {
    /// `PHOTOVAULT_SMOKE_TIMING=1`: seconds since launch at each milestone of
    /// opening a vault, for measuring how long it takes.
    static let launched = Date()
    static func mark(_ event: String) {
        guard ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_TIMING"] == "1" else { return }
        print(String(format: "smoke: %.2f s %@", Date().timeIntervalSince(launched), event))
        fflush(stdout)
    }

    /// Smoke test only: zoom the video on screen, or say how far it's zoomed,
    /// as a pinch would — synthetic gestures need Accessibility permission.
    static func watchVideoZoom(_ surface: VideoSurface.Coordinator) {
        guard ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_PLAYBACK"] == "1" else { return }
        let center = NotificationCenter.default
        surface.observers.append(center.addObserver(forName: .smokeZoomVideo, object: nil, queue: .main) { [weak surface] note in
            MainActor.assumeIsolated {
                if let zoom = (note.object as? NSNumber).map({ CGFloat($0.doubleValue) }) {
                    surface?.view?.magnification = zoom
                } else {
                    say(String(format: "video zoom %.1f", surface?.view?.magnification ?? 0))
                }
            }
        })
    }

    /// A line for the smoke test's log, only when a smoke hook is running.
    static func say(_ line: String) {
        guard ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("PHOTOVAULT_SMOKE_") }) else { return }
        print("smoke: \(line)")
        fflush(stdout)
    }

    /// `PHOTOVAULT_SMOKE_SCREEN=2`: the window opens centred on that display
    /// (1 is the main one), so tests running while someone works on the main
    /// display stay out of their way.
    static func placeOnRequestedScreen(_ window: NSWindow) {
        guard let n = ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_SCREEN"].flatMap(Int.init),
              n >= 1, n <= NSScreen.screens.count else { return }
        let area = NSScreen.screens[n - 1].visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, area.width)
        frame.size.height = min(frame.height, area.height)
        frame.origin = NSPoint(x: area.midX - frame.width / 2, y: area.midY - frame.height / 2)
        window.setFrame(frame, display: true)
    }

    /// `PHOTOVAULT_SMOKE_RESIZE=1`: everything known to make AppKit or SwiftUI
    /// save to `~/Library/Preferences` — resizing the window, dragging the
    /// sidebar divider, the window becoming active — plus a value written
    /// straight to the app's user defaults, so the smoke test can check that
    /// nothing is written there. See PreferencesGuard.
    static func exerciseWindowIfRequested(_ window: NSWindow) {
        guard ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_RESIZE"] == "1" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var frame = window.frame
            frame.size.width = max(900, frame.size.width - 60)
            frame.size.height = max(600, frame.size.height - 40)
            window.setFrame(frame, display: true)
            if let split = splitViews(in: window.contentView).first, let first = split.subviews.first {
                split.setPosition(first.frame.width + 40, ofDividerAt: 0)
            }
            // The smoke test opens PhotoVault as Finder does, which normally
            // makes its window active. It doesn't if another app keeps the
            // focus, so tell SwiftUI the window became active either way.
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

            let defaults = UserDefaults.standard
            let key = "PhotoVaultSmokeTest"
            defaults.set("held", forKey: key)
            let held = defaults.string(forKey: key) == "held"
                && defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] == nil

            let refused = PreferencesGuard.refused.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("smoke: resized window and sidebar")
            print("smoke: refused: \(refused)")
            print("smoke: defaults write held in memory: \(held ? "yes" : "no")")
            fflush(stdout)
        }
    }
}

/// Why the app is quitting.
enum QuitReason {
    /// ⌘Q, the Quit menu item, closing the last window, Quit from the Dock.
    case user
    /// SIGTERM — scripts, including the vault scripts and the smoke test.
    case signal
    /// Logging out, restarting or shutting down.
    case powerOff
    /// Already confirmed, e.g. by the eject question.
    case confirmed
}

enum QuitPolicy {
    /// Ask before quitting only when a scan would be interrupted and a person
    /// asked to quit. Anything else quits at once: a question nobody will see
    /// would hang a logout or a script.
    static func shouldAsk(scanRunning: Bool, reason: QuitReason) -> Bool {
        scanRunning && reason == .user
    }
}

/// Every `NSSplitView` under `view`, depth first.
func splitViews(in view: NSView?) -> [NSSplitView] {
    guard let view else { return [] }
    var found: [NSSplitView] = []
    if let split = view as? NSSplitView { found.append(split) }
    for sub in view.subviews { found += splitViews(in: sub) }
    return found
}

/// Reaches the `NSWindow` behind the SwiftUI hierarchy.
///
/// A full-screen photo has to paint over the titlebar strip, and nothing in
/// SwiftUI can do that: it needs `.fullSizeContentView` plus a transparent,
/// title-less titlebar on the window object itself.
///
/// Everything here is guarded on actually having changed. An earlier version
/// re-applied on every SwiftUI update and also drove `toolbar.isVisible`
/// directly, which fought the `.toolbar(.hidden, for: .windowToolbar)` modifier
/// in `RootView`: each set provoked another update, the two ping-ponged, and
/// the main thread saturated to the point that the app stopped answering the
/// quit AppleEvent. Toolbar visibility is SwiftUI's business alone now.
struct WindowChrome: NSViewRepresentable {
    let viewing: Bool
    /// From the vault's catalog; applied once, as soon as it is known.
    let savedFrame: String?

    final class Coordinator {
        var configured = false
        var lastViewing: Bool?
        var frameRestored = false
        var placed = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let probe = NSView(frame: .zero)
        // The view isn't in a window yet on this pass.
        DispatchQueue.main.async { apply(to: probe.window, context.coordinator) }
        return probe
    }

    func updateNSView(_ probe: NSView, context: Context) {
        guard let window = probe.window else {
            DispatchQueue.main.async { apply(to: probe.window, context.coordinator) }
            return
        }
        apply(to: window, context.coordinator)
    }

    private func apply(to window: NSWindow?, _ state: Coordinator) {
        guard let window else { return }

        if !state.configured {
            state.configured = true
            // Saved window state for an image browser is a snapshot of the
            // window contents, written outside the volume.
            window.isRestorable = false
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            stopSavingGeometryOutsideTheVault(window)
            SmokeHooks.exerciseWindowIfRequested(window)
        }

        if !state.frameRestored, let savedFrame {
            state.frameRestored = true
            restore(window, to: savedFrame)
            SmokeHooks.placeOnRequestedScreen(window)
        }
        if !state.placed {
            state.placed = true
            SmokeHooks.placeOnRequestedScreen(window)
        }

        // Hiding the toolbar for the viewer brings back a plain title bar,
        // grey and showing the view's name across the top of the photo. Put
        // the transparent, title-less one back — now and once SwiftUI has
        // finished hiding the toolbar. Only when it differs: setting it
        // unconditionally on every update is how the earlier loop began.
        Self.keepTitlebarClear(window)
        if state.lastViewing != viewing {
            DispatchQueue.main.async { Self.keepTitlebarClear(window) }
        }

        guard state.lastViewing != viewing else { return }
        state.lastViewing = viewing

        window.backgroundColor = viewing ? .black : .windowBackgroundColor

        // In full screen the traffic lights would otherwise float over the
        // photo; Escape and Cmd-Ctrl-F still get you out.
        let hideButtons = viewing && window.styleMask.contains(.fullScreen)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = hideButtons
        }
    }

    static func keepTitlebarClear(_ window: NSWindow) {
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if !window.styleMask.contains(.fullSizeContentView) { window.styleMask.insert(.fullSizeContentView) }
    }

    /// Nothing may be written outside the vault. Window tabs would save
    /// their state to `~/Library/Preferences`. Window and sidebar geometry are
    /// refused at the source — see PreferencesGuard — and the window frame is
    /// saved to the vault's catalog at quit instead.
    private func stopSavingGeometryOutsideTheVault(_ window: NSWindow) {
        window.tabbingMode = .disallowed
    }

    private func restore(_ window: NSWindow, to saved: String) {
        let rect = NSRectFromString(saved)
        guard rect.width >= 600, rect.height >= 400,
              let screen = window.screen ?? NSScreen.main,
              screen.visibleFrame.intersects(rect) else { return }
        window.setFrame(window.constrainFrameRect(rect, to: screen), display: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LibraryModel?
    private var terminationSignal: DispatchSourceSignal?
    /// Why the app is being asked to quit; decides whether to ask first.
    private var quitReason: QuitReason = .user

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM — `kill <pid>`, and how the smoke test stops the one copy it
        // launched — would by default end the process on the spot, skipping
        // applicationWillTerminate and leaving the WAL un-checkpointed. Route it
        // through a normal quit instead. If the main thread is wedged this never
        // runs, which is exactly what lets the smoke test detect a hang.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in
            self?.quitReason = .signal
            NSApp.terminate(nil)
        }
        term.resume()
        terminationSignal = term

        // Saved window state is written to ~/Library/Saved Application State,
        // and for an image app that means a snapshot of the window contents.
        for window in NSApp.windows { window.isRestorable = false }

        // Finder can start an eject without asking us. Quiesce on the
        // notification, not just on our own eject path.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumeWillUnmount(_:)),
            name: NSWorkspace.willUnmountNotification, object: nil
        )
        // Logging out, restarting or shutting down must never wait on a question.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification, object: nil
        )
    }

    @objc private func willPowerOff(_ note: Notification) {
        quitReason = .powerOff
    }

    /// Quitting during a scan asks first — unless the quit comes from the
    /// system or a script, which must never hang waiting for an answer.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, QuitPolicy.shouldAsk(scanRunning: model.scanning, reason: quitReason) else {
            return .terminateNow
        }
        if askToStopScan(model, action: "Stop and Quit") {
            return .terminateNow   // applicationWillTerminate stops the scan and closes the catalog
        }
        return .terminateCancel
    }

    /// Shows the "a scan is running" question. True means stop it.
    private func askToStopScan(_ model: LibraryModel, action: String) -> Bool {
        let alert = NSAlert()
        let question = model.stopQuestion
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: model.job == .scan ? "Keep Scanning" : "Keep Tagging")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown(windowFrame: currentWindowFrame())
    }

    /// The main window's frame, for the catalog — unless it's in full screen,
    /// where the frame is just the screen and isn't worth restoring.
    private func currentWindowFrame() -> String? {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
              !window.styleMask.contains(.fullScreen) else { return nil }
        return NSStringFromRect(window.frame)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc private func volumeWillUnmount(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
              let root = model?.root else { return }
        // Path comparison, not identity: the mount point is whatever it is this
        // session, including a " 1" suffix after a stale mount.
        guard root.path.hasPrefix(url.path) else { return }
        model?.shutdown()
    }

    /// The binary is mapped from the volume it's being asked to eject, so it
    /// cannot unmount itself. Close everything, then hand the job to a process
    /// launched from a system path — one that keeps running after this one is
    /// gone.
    func ejectVolume() {
        guard let model, let root = model.root else { return }
        if QuitPolicy.shouldAsk(scanRunning: model.scanning, reason: .user),
           !askToStopScan(model, action: "Stop and Eject") {
            return
        }
        quitReason = .confirmed
        model.shutdown()

        let volumePath = volumeMountPoint(for: root)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")   // system path, not the volume
        // The sleep gives mediaplaybackd and VTDecoderXPCService the beat they
        // need to drop their own references; 200 ms is enough in practice.
        task.arguments = ["-c", "sleep 1; /usr/bin/hdiutil detach '\(volumePath.replacingOccurrences(of: "'", with: "'\\''"))'"]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func volumeMountPoint(for root: URL) -> String {
        (try? root.resourceValues(forKeys: [.volumeURLKey]).volume?.path) ?? root.path
    }
}

import SwiftUI
import AppKit
import QuietPreferences

struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(InstallerDelegate.self) private var delegate
    @StateObject private var model = InstallerModel()

    init() {
        // Before AppKit creates the window: the installer, like PhotoVault,
        // leaves nothing in ~/Library/Preferences.
        PreferencesGuard.install()
    }

    var body: some Scene {
        Window("PhotoVault Installer", id: "installer") {
            InstallerView()
                .environmentObject(model)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .printItem) {}
        }
    }
}

final class InstallerDelegate: NSObject, NSApplicationDelegate {
    weak var model: InstallerModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Saved window state would go to ~/Library/Saved Application State.
        for window in NSApp.windows { window.isRestorable = false }
        #if DEBUG
        // Test-only: PHOTOVAULT_INSTALLER_TRY=close|done puts the window on
        // display 2, then closes it as the red button does, or quits as Done
        // does, and says so — to see that the installer really goes.
        if let how = ProcessInfo.processInfo.environment["PHOTOVAULT_INSTALLER_TRY"],
           let folder = ProcessInfo.processInfo.environment["PHOTOVAULT_INSTALLER_TRY_FOLDER"], how == "create" {
            // Creates a vault in that folder, then quits as Done does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let model = self?.model else { return print("try: no model") }
                if NSScreen.screens.count > 1, let window = NSApp.windows.first(where: \.isVisible) {
                    let area = NSScreen.screens[1].visibleFrame
                    window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
                }
                model.mode = .create
                model.name = "Quit Test"
                model.folder = URL(fileURLWithPath: folder)
                model.size = "2g"
                if let secret = ProcessInfo.processInfo.environment["PHOTOVAULT_INSTALLER_TRY_PASSWORD"] {
                    model.protect = true
                    model.password = secret
                    model.confirmation = secret
                }
                model.start()
                print("try: started, phase \(model.phase)"); fflush(stdout)
                @MainActor func waitDone() {
                    if case .working = model.phase {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { waitDone() } }
                        return
                    }
                    print("try: finished, phase \(model.phase)"); fflush(stdout)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        print("try: Done pressed"); fflush(stdout)
                        NSApp.terminate(nil)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { print("try: still running 2 s later"); fflush(stdout) }
                    }
                }
                waitDone()
            }
        } else if let how = ProcessInfo.processInfo.environment["PHOTOVAULT_INSTALLER_TRY"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if NSScreen.screens.count > 1, let window = NSApp.windows.first(where: \.isVisible) {
                    let area = NSScreen.screens[1].visibleFrame
                    window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2, y: area.midY - window.frame.height / 2))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    print("try: \(how), windows \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible)" })"); fflush(stdout)
                    if how == "close" { NSApp.windows.first(where: \.isVisible)?.performClose(nil) } else { NSApp.terminate(nil) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        print("try: still running 2 s later; windows \(NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible)" })"); fflush(stdout)
                    }
                }
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PHOTOVAULT_INSTALLER_TRY"] != nil { print("try: terminating"); fflush(stdout) }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting part-way would leave a vault half set up: wait instead.
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.phase == .working else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "The installer is still working"
        alert.informativeText = "Quit when it's done. It takes a minute or so."
        alert.runModal()
        return .terminateCancel
    }
}

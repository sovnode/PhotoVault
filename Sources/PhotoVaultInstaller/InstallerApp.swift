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

import Testing
import AppKit
@testable import QuietPreferences

/// Nothing written outside the vault, for what AppKit and SwiftUI save on their own: see
/// PreferencesGuard. The end-to-end test checks `~/Library/Preferences` itself;
/// these check each layer in-process. Every test cleans up after itself, so a
/// broken guard leaves nothing behind in the test runner's preferences either.
@MainActor
@Suite("Preferences guard")
struct PreferencesGuardTests {
    init() { PreferencesGuard.install() }

    private let defaults = UserDefaults.standard
    /// What layer 2 holds in memory.
    private var held: [String: Any] { defaults.volatileDomain(forName: UserDefaults.argumentDomain) }
    /// What would be written to disk.
    private var saved: [String: Any] {
        defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName) ?? [:]
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        return NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 480),
                        styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    }

    @Test func everyMethodWasReplaced() {
        #expect(PreferencesGuard.notInstalled.isEmpty)
    }

    /// The route 1.0 and 1.1 missed: SwiftUI saving the window's frame itself
    /// when the window becomes active.
    @Test func savingAWindowFrameSavesNothing() {
        let name = "PhotoVaultTest-\(UUID().uuidString)"
        let key = "NSWindow Frame \(name)"
        defer { defaults.removeObject(forKey: key) }

        let before = PreferencesGuard.refused["save frame", default: 0]
        window().saveFrame(usingName: name)

        #expect(PreferencesGuard.refused["save frame", default: 0] == before + 1)
        // Refused at the source: never even reaches the defaults.
        #expect(held[key] == nil)
        #expect(saved[key] == nil)
        #expect(!window().setFrameUsingName(name))
    }

    /// The route 1.1 closed: setting the autosave name saves the frame at once.
    @Test func anAutosaveNameIsAcceptedButNeverStored() {
        let name = "PhotoVaultTest-\(UUID().uuidString)"
        let key = "NSWindow Frame \(name)"
        defer { defaults.removeObject(forKey: key) }

        let w = window()
        #expect(w.setFrameAutosaveName(name))
        #expect(w.frameAutosaveName.isEmpty)
        w.setFrame(NSRect(x: 120, y: 120, width: 700, height: 500), display: false)
        #expect(held[key] == nil)
        #expect(saved[key] == nil)
    }

    @Test func theSidebarSplitViewNeverTakesAnAutosaveName() {
        let split = NSSplitView()
        split.autosaveName = "PhotoVaultTest"
        #expect(split.autosaveName?.isEmpty ?? true)
    }

    /// Layer 2: anything else written to the app's defaults reads back for the
    /// rest of the session and is never saved.
    @Test func defaultsWritesAreHeldInMemory() {
        let key = "PhotoVaultTest-\(UUID().uuidString)"
        defer { defaults.removeObject(forKey: key) }

        defaults.set("kept for the session", forKey: key)
        #expect(defaults.string(forKey: key) == "kept for the session")
        #expect(held[key] as? String == "kept for the session")
        #expect(saved[key] == nil)

        defaults.removeObject(forKey: key)
        #expect(defaults.object(forKey: key) == nil)
        #expect(held[key] == nil)
    }

    @Test func typedSettersAreHeldToo() {
        let base = "PhotoVaultTest-\(UUID().uuidString)-"
        let suffixes = ["int", "bool", "double", "float", "url", "file"]
        defer { for s in suffixes { defaults.removeObject(forKey: base + s) } }

        defaults.set(42, forKey: base + "int")
        defaults.set(true, forKey: base + "bool")
        defaults.set(2.5, forKey: base + "double")
        defaults.set(Float(1.5), forKey: base + "float")
        defaults.set(URL(string: "https://example.com/a"), forKey: base + "url")
        defaults.set(URL(fileURLWithPath: "/Volumes/Somewhere/a.jpg"), forKey: base + "file")

        #expect(defaults.integer(forKey: base + "int") == 42)
        #expect(defaults.bool(forKey: base + "bool"))
        #expect(defaults.double(forKey: base + "double") == 2.5)
        #expect(defaults.float(forKey: base + "float") == 1.5)
        #expect(defaults.url(forKey: base + "url") == URL(string: "https://example.com/a"))
        #expect(defaults.url(forKey: base + "file")?.path == "/Volumes/Somewhere/a.jpg")
        for s in suffixes {
            #expect(held[base + s] != nil, "\(s) not held")
            #expect(saved[base + s] == nil, "\(s) would be saved")
        }
    }
}

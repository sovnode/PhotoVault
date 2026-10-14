import AppKit
import ObjectiveC

/// Keeps PhotoVault — and its installer — out of `~/Library/Preferences`.
/// Nothing is written outside the vault.
///
/// PhotoVault keeps its own settings in the vault's catalog and never uses user
/// defaults. AppKit and SwiftUI do, unasked: they save window geometry to
/// `~/Library/Preferences/local.photovault.app.plist` by at least three routes.
///
/// - Setting a window's frame-autosave name saves the frame at once, if nothing
///   is saved under that name yet. SwiftUI sets one on every window it creates,
///   before any of the app's code sees the window.
/// - SwiftUI also saves the frame itself, with `saveFrame(usingName:)`, when the
///   window first becomes the active window. This one went unnoticed until 1.2:
///   the end-to-end test launched the app in the background, where its window
///   never became active.
/// - The sidebar's split view saves its divider position.
///
/// So there are two layers, installed by `PhotoVaultApp.init`, before AppKit has
/// created anything:
///
/// 1. Those three are refused at the source: each method accepts the call and
///    saves nothing.
/// 2. Anything else written to the app's own user defaults is held in memory —
///    readable until PhotoVault quits, never saved — so a route nobody has found
///    yet can't reach the disk either. Code calling `CFPreferences` directly
///    would get past this layer; the end-to-end test is what catches that.
///
/// The window's size is remembered in the vault's catalog instead.
public enum PreferencesGuard {
    /// What layer 1 has refused so far, by route. The smoke test prints it, to
    /// show that the routes it exercises were really taken.
    public private(set) static var refused: [String: Int] = [:]
    /// Methods that couldn't be replaced. Empty unless a macOS update renamed
    /// one; the tests check.
    public private(set) static var notInstalled: [String] = []

    private static var installed = false
    private static let lock = NSLock()
    /// The app's own defaults, captured before any method is replaced.
    fileprivate static var appDefaults: UserDefaults?

    public static func install() {
        guard !installed else { return }
        installed = true
        appDefaults = UserDefaults.standard

        // Layer 1: window geometry, refused at the source.
        swap(NSWindow.self, "setFrameAutosaveName:", "pv_refuseFrameAutosaveName:")
        swap(NSWindow.self, "saveFrameUsingName:", "pv_refuseSaveFrameUsingName:")
        swap(NSSplitView.self, "setAutosaveName:", "pv_refuseAutosaveName:")

        // Layer 2: anything else written to the app's defaults, held in memory.
        for setter in ["setObject:forKey:", "removeObjectForKey:", "setInteger:forKey:", "setFloat:forKey:",
                       "setDouble:forKey:", "setBool:forKey:", "setURL:forKey:"] {
            swap(UserDefaults.self, setter, "pv_session_" + setter)
        }
    }

    private static func swap(_ cls: AnyClass, _ original: String, _ replacement: String) {
        guard let o = class_getInstanceMethod(cls, NSSelectorFromString(original)),
              let r = class_getInstanceMethod(cls, NSSelectorFromString(replacement)) else {
            notInstalled.append("\(cls) \(original)")
            return
        }
        method_exchangeImplementations(o, r)
    }

    fileprivate static func noteRefused(_ route: String) {
        lock.lock(); defer { lock.unlock() }
        refused[route, default: 0] += 1
    }

    /// Layer 2's store is the argument domain, which is searched before every
    /// other domain and never saved. (The registration domain is never saved
    /// either, but it's searched last, so a value left in an old preferences
    /// file would hide what's held there.)
    fileprivate static func hold(_ value: Any?, forKey key: String) {
        guard let defaults = appDefaults else { return }
        lock.lock(); defer { lock.unlock() }
        var session = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        session[key] = value
        defaults.setVolatileDomain(session, forName: UserDefaults.argumentDomain)
    }
}

// MARK: - Layer 1

extension NSWindow {
    /// Stands in for `setFrameAutosaveName(_:)`: reports success, saves nothing.
    @objc(pv_refuseFrameAutosaveName:)
    func pv_refuseFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool {
        PreferencesGuard.noteRefused("autosave name")
        return true
    }

    /// Stands in for `saveFrame(usingName:)`: saves nothing.
    @objc(pv_refuseSaveFrameUsingName:)
    func pv_refuseSaveFrame(usingName name: NSWindow.FrameAutosaveName) {
        PreferencesGuard.noteRefused("save frame")
    }
}

extension NSSplitView {
    /// Stands in for the `autosaveName` setter: the name is never stored.
    @objc(pv_refuseAutosaveName:)
    func pv_refuseAutosaveName(_ name: NSSplitView.AutosaveName?) {
        PreferencesGuard.noteRefused("split view")
    }
}

// MARK: - Layer 2

// Once swapped, a call from one of these to itself runs the original method:
// that's how writes to any defaults other than the app's own pass through.
extension UserDefaults {
    private var isAppDefaults: Bool { self === PreferencesGuard.appDefaults }

    @objc(pv_session_setObject:forKey:)
    func pv_sessionSetObject(_ value: Any?, forKey key: String) {
        guard isAppDefaults else { return pv_sessionSetObject(value, forKey: key) }
        PreferencesGuard.hold(value, forKey: key)
    }

    @objc(pv_session_removeObjectForKey:)
    func pv_sessionRemoveObject(forKey key: String) {
        guard isAppDefaults else { return pv_sessionRemoveObject(forKey: key) }
        PreferencesGuard.hold(nil, forKey: key)
    }

    @objc(pv_session_setInteger:forKey:)
    func pv_sessionSetInteger(_ value: Int, forKey key: String) {
        guard isAppDefaults else { return pv_sessionSetInteger(value, forKey: key) }
        PreferencesGuard.hold(value, forKey: key)
    }

    @objc(pv_session_setFloat:forKey:)
    func pv_sessionSetFloat(_ value: Float, forKey key: String) {
        guard isAppDefaults else { return pv_sessionSetFloat(value, forKey: key) }
        PreferencesGuard.hold(value, forKey: key)
    }

    @objc(pv_session_setDouble:forKey:)
    func pv_sessionSetDouble(_ value: Double, forKey key: String) {
        guard isAppDefaults else { return pv_sessionSetDouble(value, forKey: key) }
        PreferencesGuard.hold(value, forKey: key)
    }

    @objc(pv_session_setBool:forKey:)
    func pv_sessionSetBool(_ value: Bool, forKey key: String) {
        guard isAppDefaults else { return pv_sessionSetBool(value, forKey: key) }
        PreferencesGuard.hold(value, forKey: key)
    }

    @objc(pv_session_setURL:forKey:)
    func pv_sessionSetURL(_ url: URL?, forKey key: String) {
        guard isAppDefaults else { return pv_sessionSetURL(url, forKey: key) }
        // Held the way url(forKey:) reads it back: a file URL as its path,
        // anything else archived.
        var value: Any?
        if let url {
            if url.isFileURL {
                value = url.path
            } else {
                value = try? NSKeyedArchiver.archivedData(withRootObject: url, requiringSecureCoding: false)
            }
        }
        PreferencesGuard.hold(value, forKey: key)
    }
}

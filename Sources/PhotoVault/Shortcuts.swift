import SwiftUI

/// Every command's keyboard shortcut, in one place. The menu bar, the
/// right-click menus, the buttons' tooltips and Help › Keyboard Shortcuts all
/// read from here, so a shortcut can't show in one place and be different — or
/// missing — in another. Showing it wherever the command is teaches the faster
/// way to someone using the slower one.
///
/// A plain key (no ⌘) works only where nothing is being typed: the commands
/// behind them hand the key to a text field when one is being typed in, and
/// are greyed out — leaving the key to the view — where they don't apply.
/// They're never switched off by taking the shortcut away: SwiftUI left the
/// menu bar out of step when a shortcut came and went.
enum Shortcut: CaseIterable {
    // Anywhere
    case newAlbum, newSmartAlbum, undoMove
    case selectAll, deselectAll
    case rescan, fullRescan, stop, eject
    // Library and albums
    case allMedia, photosOnly, videosOnly
    case biggerThumbnails, smallerThumbnails, wholePhotos
    case sortUp, sortDown, autoScroll
    case favorite, rotateLeft, rotateRight, trash
    // Viewer
    case previous, next, back, properties
    case repeatToggle, playNextToggle
    // Sidebar
    case duplicateAlbum, renameAlbum

    enum Place: String, CaseIterable {
        case anywhere = "Anywhere"
        case library = "Library and albums"
        case viewer = "Viewing a photo or video"
        case sidebar = "In the sidebar"
    }

    var title: String {
        switch self {
        case .newAlbum: return "New Album"
        case .newSmartAlbum: return "New Smart Album"
        case .undoMove: return "Undo Move (photos moved to a folder)"
        case .selectAll: return "Select All"
        case .deselectAll: return "Deselect All"
        case .rescan: return "Rescan Changed Folders"
        case .fullRescan: return "Full Rescan"
        case .stop: return "Stop Scan or Tagging"
        case .eject: return "Eject Volume"
        case .allMedia: return "Show All"
        case .photosOnly: return "Show Only Photos"
        case .videosOnly: return "Show Only Videos"
        case .biggerThumbnails: return "Bigger Thumbnails"
        case .smallerThumbnails: return "Smaller Thumbnails"
        case .wholePhotos: return "Show Whole Photos"
        case .sortUp: return "Sort Oldest First (A to Z), or Shuffle Again"
        case .sortDown: return "Sort Newest First (Z to A), or Shuffle Again"
        case .autoScroll: return "Scroll Automatically / Pause"
        case .favorite: return "Add to Favorites / Remove"
        case .rotateLeft: return "Rotate Left"
        case .rotateRight: return "Rotate Right"
        case .trash: return "Move to Trash"
        case .previous: return "Previous Photo"
        case .next: return "Next Photo"
        case .back: return "Back to Library"
        case .properties: return "Show or Hide Properties"
        case .repeatToggle: return "Repeat"
        case .playNextToggle: return "Play Next"
        case .duplicateAlbum: return "Duplicate Album"
        case .renameAlbum: return "Rename Album"
        }
    }

    var place: Place {
        switch self {
        case .newAlbum, .newSmartAlbum, .undoMove, .selectAll, .deselectAll, .rescan, .fullRescan, .stop, .eject: return .anywhere
        case .allMedia, .photosOnly, .videosOnly, .biggerThumbnails, .smallerThumbnails, .wholePhotos,
             .sortUp, .sortDown, .autoScroll, .favorite, .rotateLeft, .rotateRight, .trash: return .library
        case .previous, .next, .back, .properties, .repeatToggle, .playNextToggle: return .viewer
        case .duplicateAlbum, .renameAlbum: return .sidebar
        }
    }

    var key: KeyEquivalent {
        switch self {
        case .newAlbum, .newSmartAlbum: return "n"
        case .undoMove: return "z"
        case .selectAll, .deselectAll: return "a"
        case .rescan, .fullRescan: return "r"
        case .stop: return "."
        case .eject: return "e"
        case .allMedia: return "1"
        case .photosOnly: return "2"
        case .videosOnly: return "3"
        case .biggerThumbnails: return "+"
        case .smallerThumbnails: return "-"
        // Not ⇧⌘W: pressed a little off, it was ⌘W, and the window closed.
        case .wholePhotos: return "0"
        case .sortUp: return .upArrow
        case .sortDown: return .downArrow
        case .autoScroll: return .space
        case .favorite: return "."
        case .rotateLeft: return "l"
        case .rotateRight: return "r"
        case .trash: return .delete
        case .previous: return .leftArrow
        case .next: return .rightArrow
        case .back: return .escape
        case .properties: return "i"
        case .repeatToggle: return "r"
        case .playNextToggle: return "n"
        case .duplicateAlbum: return "d"
        case .renameAlbum: return .return
        }
    }

    var modifiers: EventModifiers {
        switch self {
        case .newSmartAlbum, .rescan: return [.command, .option]
        case .deselectAll: return [.command, .shift]
        case .fullRescan: return [.command, .option, .shift]
        case .sortUp, .sortDown: return [.command, .option]
        case .autoScroll, .favorite, .previous, .next, .back, .repeatToggle, .playNextToggle, .renameAlbum:
            return []
        default: return .command
        }
    }

    /// How the shortcut reads: "⌥⌘↑", ".", "Space".
    var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .delete: text += "⌫"
        case .escape: text += "Esc"
        case .return: text += "↩"
        case .space: text += "Space"
        default:
            let c = String(key.character)
            text += c == "-" ? "−" : c.uppercased()
        }
        return text
    }

    /// A tooltip ending with the shortcut, as "Rotate Left (⌘L)".
    func help(_ text: String) -> String { "\(text) (\(label))" }
}

extension View {
    /// The command's shortcut: live in the menu bar, shown beside the item in
    /// a right-click menu.
    func shortcut(_ s: Shortcut) -> some View { keyboardShortcut(s.key, modifiers: s.modifiers) }
}

/// Help › Keyboard Shortcuts: every shortcut, by where it works.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Shortcut.Place.allCases, id: \.self) { place in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(place.rawValue).font(.headline)
                            ForEach(Shortcut.allCases.filter { $0.place == place }, id: \.self) { s in
                                HStack {
                                    Text(s.title)
                                    Spacer(minLength: 16)
                                    Text(s.label).font(.body.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Text("In the library and albums, with one photo picked, ← → ↑ ↓ pick the photo beside, above or below it, and ⇧ on its own opens it. In the viewer, ⇧ goes back to the library, as Esc does.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Drag photos onto a folder in the sidebar to move them there, or onto an album to add them to it.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Pinch zooms a photo or video; two fingers move it about while zoomed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 560)
    }
}

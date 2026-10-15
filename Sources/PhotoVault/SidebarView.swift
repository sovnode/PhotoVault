import SwiftUI
import UniformTypeIdentifiers
import PhotoVaultCore

/// Dragging an album or smart album up or down among its own kind.
///
/// Not `List`'s `.onMove`: with two reorderable sections in one sidebar list,
/// macOS put the drop line in the wrong section and the drop went nowhere.
/// Each row is draggable, carrying "<kind>:<id>" as text, and each row of the
/// same kind takes the drop — above itself or below, by which half of the row
/// the pointer is over — with a line showing where it will land.
private struct Reorderable: ViewModifier {
    let scope: LibraryScope
    /// A row only takes a drag of its own kind.
    let kind: String
    @Binding var target: SidebarView.DropTarget?
    let move: (_ dragged: Int64, _ after: Bool) -> Void
    @State private var height: CGFloat = 22

    private var id: Int64 {
        switch scope {
        case .album(let id), .smart(let id): return id
        default: return 0
        }
    }

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear.onAppear { height = g.size.height }.onChange(of: g.size.height) { _, h in height = h }
            })
            // The list's own way to drag a row. `.onDrag` took the mouse-down
            // for itself, so clicking an album no longer selected it.
            .itemProvider { NSItemProvider(object: "\(kind):\(id)" as NSString) }
            .onDrop(of: [.plainText, .utf8PlainText, .text],
                    delegate: RowDrop(scope: scope, kind: kind, id: id, height: height, target: $target, move: move))
            .overlay(alignment: target?.after == true ? .bottom : .top) {
                if target?.scope == scope {
                    Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
                }
            }
    }

    static func parse(_ text: String, kind: String) -> Int64? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, parts[0] == kind else { return nil }
        return Int64(parts[1])
    }
}

private struct RowDrop: DropDelegate {
    let scope: LibraryScope
    let kind: String
    let id: Int64
    let height: CGFloat
    @Binding var target: SidebarView.DropTarget?
    let move: (_ dragged: Int64, _ after: Bool) -> Void

    private func after(_ info: DropInfo) -> Bool { info.location.y > height / 2 }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropEntered(info: DropInfo) { target = SidebarView.DropTarget(scope: scope, after: after(info)) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let now = SidebarView.DropTarget(scope: scope, after: after(info))
        if target != now { target = now }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if target?.scope == scope { target = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let below = after(info)
        target = nil
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String,
                  let dragged = Reorderable.parse(text, kind: kind), dragged != id else { return }
            DispatchQueue.main.async { move(dragged, below) }
        }
        return true
    }
}

struct SidebarView: View {
    static let albumDrag = "photovault-album"
    static let smartDrag = "photovault-smart-album"

    @EnvironmentObject var model: LibraryModel
    @State private var showingNewAlbum = false
    @State private var renaming: RenameTarget?
    /// The row an album being dragged would land beside, and on which side.
    @State private var dropTarget: DropTarget?
    /// The rows picked: one, or several with ⌘- or ⇧-click — albums and smart
    /// albums to delete together. The grid shows the one row picked, and stays
    /// put while several are.
    @State private var selected: Set<LibraryScope> = [.all]
    /// Albums and smart albums waiting for "Delete them?" to be answered.
    @State private var deleting: [LibraryScope] = []

    struct DropTarget: Equatable {
        let scope: LibraryScope
        let after: Bool
    }

    var body: some View {
        List(selection: $selected) {
            Section("Library") {
                // All Media is the root of the folder tree: it expands into the
                // folders under Photos/, nested as deep as they go. Choosing a
                // folder shows only the photos directly in it.
                if let tree = model.folderTree {
                    OutlineGroup([tree], children: \.children) { node in
                        if node.id == tree.id {
                            Label("All Media", systemImage: "photo.on.rectangle")
                                .badge(model.totalCount)
                                .tag(LibraryScope.all)
                        } else {
                            Label(node.name, systemImage: "folder")
                                .badge(node.directCount)
                                .tag(LibraryScope.folder(node.id))
                                .help(node.directCount == node.totalCount
                                      ? "\(node.directCount) photos"
                                      : "\(node.directCount) photos here, \(node.totalCount) including subfolders")
                        }
                    }
                } else {
                    Label("All Media", systemImage: "photo.on.rectangle")
                        .badge(model.totalCount)
                        .tag(LibraryScope.all)
                }
                Label("Favorites", systemImage: "heart")
                    .tag(LibraryScope.favorites)
                Label("Trash", systemImage: model.trashCount > 0 ? "trash.fill" : "trash")
                    .badge(model.trashCount)
                    .tag(LibraryScope.trash)
            }

            if !model.albums.isEmpty {
                Section("Albums") {
                    ForEach(model.albums) { album in
                        Label(album.name, systemImage: "rectangle.stack")
                            .badge(model.albumCounts[album.id] ?? 0)
                            .tag(LibraryScope.album(album.id))
                            .modifier(Reorderable(scope: .album(album.id), kind: Self.albumDrag, target: $dropTarget) { dragged, after in
                                model.moveAlbum(dragged, beside: album.id, after: after)
                            })
                    }
                }
            }

            if !model.smartAlbums.isEmpty {
                Section("Smart Albums") {
                    ForEach(model.smartAlbums) { sa in
                        Label(sa.name, systemImage: sa.rules != nil ? "line.3.horizontal.decrease.circle" : "gearshape.2")
                            .tag(LibraryScope.smart(sa.id))
                            .modifier(Reorderable(scope: .smart(sa.id), kind: Self.smartDrag, target: $dropTarget) { dragged, after in
                                model.moveSmartAlbum(dragged, beside: sa.id, after: after)
                            })
                    }
                }
            }

        }
        .listStyle(.sidebar)
        // One menu for the whole list, built from what's picked: right-click
        // a row, or several picked with ⌘ or ⇧.
        .contextMenu(forSelectionType: LibraryScope.self) { items in menu(for: items) }
        // The grid follows the sidebar only when one row is picked. While
        // several are — ⌘- or ⇧-clicking albums to delete — it stays where it
        // is: switching it for each row added queued up a reload per row, and
        // the sidebar lagged for seconds afterwards.
        .onChange(of: selected) { _, new in
            if new.count == 1, let only = new.first, only != model.scope { model.scope = only }
        }
        // The view can change from elsewhere — Show in Library, a new album.
        .onChange(of: model.scope) { _, scope in
            if !selected.contains(scope) { selected = [scope] }
        }
        .onAppear { selected = [model.scope] }
        .alert(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } })) {
            Button("Delete", role: .destructive) {
                let doomed = deleting
                deleting = []
                Task { await model.deleteAlbums(doomed) }
            }
            Button("Cancel", role: .cancel) { deleting = [] }
        } message: {
            Text("Their photos stay in the library — only the albums go.")
        }
        // Built afresh when a whole section comes or goes, rather than patched:
        // deleting the only smart album took its section with it, and the row's
        // name stayed drawn over the rows below. That's rare enough (the first
        // album, or the last) that losing the folder tree's open state is fine.
        .id([model.albums.isEmpty, model.smartAlbums.isEmpty])
        .safeAreaInset(edge: .bottom) {
            Button {
                showingNewAlbum = true
            } label: {
                Label("New Album", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        // A sheet rather than an alert: an alert can't hold the Smart album
        // checkbox.
        .sheet(isPresented: $showingNewAlbum) { NewAlbumSheet() }
        .sheet(item: $renaming) { target in RenameSheet(target: target) }
    }

    @ViewBuilder
    private func menu(for items: Set<LibraryScope>) -> some View {
        let albums = items.filter { if case .album = $0 { return true } else { return false } }
        let smart = items.filter { if case .smart = $0 { return true } else { return false } }
        if items.count == 1, let only = items.first {
            switch only {
            case .trash:
                Button("Empty Trash…") { model.confirmingEmptyTrash = true }
                    .disabled(model.trashCount == 0)
            case .album(let id):
                if let album = model.albums.first(where: { $0.id == id }) {
                    Button("Rename…") { renaming = RenameTarget(kind: .album, id: id, name: album.name) }
                    Button("Duplicate Album") { Task { await model.duplicateAlbum(id) } }
                    Divider()
                    Button("Delete Album") { afterMenuCloses { await model.deleteAlbum(id) } }
                }
            case .smart(let id):
                if let sa = model.smartAlbums.first(where: { $0.id == id }) {
                    if sa.rules != nil {
                        Button("Edit Filter…") {
                            model.scope = .smart(id)
                            model.editingFilter = true
                        }
                    }
                    Button("Rename…") { renaming = RenameTarget(kind: .smart, id: id, name: sa.name) }
                    Button("Duplicate Smart Album") { Task { await model.duplicateSmartAlbum(id) } }
                    Divider()
                    Button("Delete Smart Album") { afterMenuCloses { await model.deleteSmartAlbum(id) } }
                }
            default:
                EmptyView()
            }
        } else if !albums.isEmpty || !smart.isEmpty {
            Button("Delete \(Self.count(albums: albums.count, smart: smart.count))…") {
                deleting = Array(albums) + Array(smart)
            }
        }
    }

    private var deleteTitle: String {
        let albums = deleting.filter { if case .album = $0 { return true } else { return false } }.count
        return "Delete \(Self.count(albums: albums, smart: deleting.count - albums))?"
    }

    /// "3 Albums", "2 Smart Albums", "1 Album and 1 Smart Album".
    static func count(albums: Int, smart: Int) -> String {
        func noun(_ n: Int, _ one: String) -> String { "\(n) \(one)\(n == 1 ? "" : "s")" }
        switch (albums, smart) {
        case (_, 0): return noun(albums, "Album")
        case (0, _): return noun(smart, "Smart Album")
        default: return "\(noun(albums, "Album")) and \(noun(smart, "Smart Album"))"
        }
    }

    /// Changes the sidebar only once the right-click menu has closed. Removing
    /// the row a menu was opened on while the menu is still closing left the
    /// row's name drawn over the rows below it.
    private func afterMenuCloses(_ work: @escaping @MainActor () async -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Task { @MainActor in await work() }
        }
    }
}

/// What a Rename sheet is renaming.
struct RenameTarget: Identifiable {
    enum Kind { case album, smart }
    let kind: Kind
    let id: Int64
    let name: String
}

/// New Album, with the Smart album checkbox: a smart album chooses its own
/// photos from tag rules, set in the filter panel it opens with.
private struct NewAlbumSheet: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var smart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Album").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(create)
            Toggle("Smart album", isOn: $smart)
                .toggleStyle(.checkbox)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private var explanation: String {
        if smart { return "Chooses its own photos from tag rules, which you set next." }
        return model.selection.isEmpty ? "Creates an empty album."
                                       : "The \(model.selection.count) selected item(s) will be added."
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        let name = trimmed, smart = smart
        dismiss()
        Task {
            if smart { await model.newSmartAlbum(named: name) } else { await model.newAlbum(named: name) }
        }
    }
}

private struct RenameSheet: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let target: RenameTarget
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.kind == .smart ? "Rename Smart Album" : "Rename Album").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(rename)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .onAppear { name = target.name }
    }

    private func rename() {
        let new = name.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty else { return }
        dismiss()
        Task {
            switch target.kind {
            case .album: await model.renameAlbum(target.id, to: new)
            case .smart: await model.renameSmartAlbum(target.id, to: new)
            }
        }
    }
}

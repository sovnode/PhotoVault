import SwiftUI
import PhotoVaultCore

struct SidebarView: View {
    @EnvironmentObject var model: LibraryModel
    @State private var showingNewAlbum = false
    @State private var renaming: RenameTarget?

    var body: some View {
        List(selection: Binding(
            get: { model.scope },
            set: { if let s = $0 { model.scope = s } }
        )) {
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
                    .contextMenu {
                        Button("Empty Trash…") { model.confirmingEmptyTrash = true }
                            .disabled(model.trashCount == 0)
                    }
            }

            if !model.albums.isEmpty {
                Section("Albums") {
                    ForEach(model.albums) { album in
                        Label(album.name, systemImage: "rectangle.stack")
                            .badge(model.albumCounts[album.id] ?? 0)
                            .tag(LibraryScope.album(album.id))
                            .contextMenu {
                                Button("Rename…") { renaming = RenameTarget(kind: .album, id: album.id, name: album.name) }
                                Button("Delete Album") { afterMenuCloses { await model.deleteAlbum(album.id) } }
                            }
                    }
                }
            }

            if !model.smartAlbums.isEmpty {
                Section("Smart Albums") {
                    ForEach(model.smartAlbums) { sa in
                        Label(sa.name, systemImage: sa.rules != nil ? "line.3.horizontal.decrease.circle" : "gearshape.2")
                            .tag(LibraryScope.smart(sa.id))
                            .contextMenu {
                                if sa.rules != nil {
                                    Button("Edit Filter…") {
                                        model.scope = .smart(sa.id)
                                        model.editingFilter = true
                                    }
                                }
                                Button("Rename…") { renaming = RenameTarget(kind: .smart, id: sa.id, name: sa.name) }
                                Button("Delete Smart Album") { afterMenuCloses { await model.deleteSmartAlbum(sa.id) } }
                            }
                    }
                }
            }

        }
        .listStyle(.sidebar)
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

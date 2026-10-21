import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotoVaultCore

extension UTType {
    /// Photos dragged from the grid: their catalog ids, never the files, so a
    /// drop onto Finder or another app copies nothing off the vault. Declared
    /// in Info.plist.
    static let photoIDs = UTType(exportedAs: "local.photovault.photo-ids", conformingTo: .data)
}

/// The drag payload: catalog ids, comma-separated.
enum PhotoDrag {
    static func provider(_ ids: [Int64]) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(ids.map(String.init).joined(separator: ",").utf8)
        // Visible to all: a drag goes through the system's pasteboard, even
        // from the grid to the sidebar of the same window. Only PhotoVault
        // knows the type, so anywhere else the drop is refused.
        provider.registerDataRepresentation(forTypeIdentifier: UTType.photoIDs.identifier, visibility: .all) { done in
            done(data, nil)
            return nil
        }
        return provider
    }

    static func ids(from data: Data) -> [Int64] {
        String(decoding: data, as: UTF8.self).split(separator: ",").compactMap { Int64($0) }
    }

    /// Reads the ids out of a drop, then hands them over on the main thread.
    static func load(_ providers: [NSItemProvider], then use: @escaping @MainActor ([Int64]) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.photoIDs.identifier) })
        else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.photoIDs.identifier) { data, _ in
            guard let data else { return }
            let ids = ids(from: data)
            DispatchQueue.main.async { MainActor.assumeIsolated { use(ids) } }
        }
        return true
    }
}

/// A sidebar row photos can be dropped on — a folder (they move there) or an
/// album (they're added) — drawn highlighted while they're over it.
struct PhotoDropTarget: ViewModifier {
    let accept: @MainActor ([Int64]) -> Void
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.photoIDs], isTargeted: $over) { providers in
                PhotoDrag.load(providers, then: accept)
            }
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.accentColor.opacity(over ? 0.3 : 0))
                    .padding(.horizontal, -6)
                    .allowsHitTesting(false)
            )
    }
}

/// A folder's subfolders as menu items, nested as in the sidebar: a folder
/// with folders inside it is a submenu, led by an item for itself. A flat list
/// of every folder was unusable on a library with hundreds of them.
struct FolderMenuItems: View {
    let node: FolderNode
    /// The item that picks the submenu's own folder: "Move Here".
    let here: String
    let pick: (String) -> Void

    var body: some View {
        ForEach(node.children ?? []) { child in
            if let inside = child.children, !inside.isEmpty {
                Menu(child.name) {
                    Button(here) { pick(child.id) }
                    Divider()
                    // Erased: a view holding itself can't name its own type.
                    AnyView(FolderMenuItems(node: child, here: here, pick: pick))
                }
            } else {
                Button(child.name) { pick(child.id) }
            }
        }
    }
}

/// Move to Folder ›: New Folder…, the top of the Photos folder, and every
/// folder under it, nested.
struct MoveToFolderMenu: View {
    @EnvironmentObject var model: LibraryModel
    let targets: () -> [PhotoItem]
    var title = "Move to Folder"

    var body: some View {
        Menu(title) {
            Button("New Folder…") {
                let items = targets()
                // Beside the photos: inside the folder they're in now, when
                // they're all in one.
                let folders = Set(items.map { PhotoItem.folder(of: $0.relPath) })
                model.newFolderRequest = .init(photoIDs: items.map(\.id),
                                               parent: folders.count == 1 ? folders.first! : VolumeLocator.mediaDirName)
            }
            Divider()
            if let tree = model.folderTree {
                Button("Photos (top level)") { model.moveToFolder(tree.id, items: targets()) }
                FolderMenuItems(node: tree, here: "Move Here") { model.moveToFolder($0, items: targets()) }
            }
        }
    }
}

/// A name for a new folder, and where it goes; the photos then move into it.
struct NewFolderSheet: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let request: LibraryModel.NewFolderRequest
    @State private var name = ""
    @State private var parent = VolumeLocator.mediaDirName

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Folder").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit(create)
            HStack {
                Text("In")
                // The same nested menu as Move to Folder, rather than a list
                // of every folder.
                Menu(parent.split(separator: "/").joined(separator: " › ")) {
                    if let tree = model.folderTree {
                        Button("Photos (top level)") { parent = tree.id }
                        FolderMenuItems(node: tree, here: "Choose This Folder") { parent = $0 }
                    }
                }
                .fixedSize()
            }
            Text(request.photoIDs.count == 1 ? "The photo will be moved into it."
                                             : "The \(request.photoIDs.count) photos will be moved into it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create and Move", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!MovePlanning.isValidFolderName(trimmed))
            }
        }
        .padding(20)
        .onAppear { parent = request.parent }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    private func create() {
        guard MovePlanning.isValidFolderName(trimmed) else { return }
        let name = trimmed, parent = parent, ids = request.photoIDs
        dismiss()
        model.moveToNewFolder(named: name, in: parent, photoIDs: ids)
    }
}

/// What couldn't be deleted or moved, grouped by why, with what can be done
/// about each — instead of an error that leaves nothing to do but leave.
struct FileProblemsSheet: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let sheet: LibraryModel.FileProblems

    private var noun: String { sheet.problems.count == 1 ? "1 item" : "\(sheet.problems.count) items" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(sheet.action == .delete ? "\(noun) couldn't be deleted" : "\(noun) couldn't be moved")
                .font(.title3.weight(.semibold))
            if !sheet.doneNote.isEmpty {
                Text(sheet.doneNote + (sheet.action == .delete ? " These are still in the Trash." : " These are where they were."))
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sheet.groups, id: \.reason) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(group.reason.title) (\(group.problems.count))").font(.headline)
                            Text(group.reason.explanation)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(group.problems.prefix(6)) { problem in
                                Text("• " + problem.name + (problem.detail.isEmpty ? "" : " — " + problem.detail))
                                    .font(.callout)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                            if group.problems.count > 6 {
                                Text("and \(group.problems.count - 6) more").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            // The ways through, on their own row; then looking, trying again
            // and leaving it.
            if !sheet.readOnly, sheet.anyUnlockable || sheet.anyNeedsAdministrator {
                HStack {
                    Spacer()
                    if sheet.anyNeedsAdministrator {
                        Button("\(sheet.verb) with Administrator Password…") { model.retryProblemsAsAdministrator() }
                            .help("macOS asks for an administrator's password in its own window; PhotoVault never sees it, and asks again each time")
                    }
                    if sheet.anyUnlockable {
                        Button("Unlock and \(sheet.verb)") { model.retryProblems(unlocking: true) }
                            .keyboardShortcut(.defaultAction)
                            .help("Clears Locked on the files you own — as unticking Locked in Finder does — then tries again")
                    }
                }
            }
            HStack {
                Button("Show in Finder") { model.revealProblems() }
                    .help("Shows the files, in list view, to change their permissions there; then Try Again")
                Spacer()
                Button(sheet.action == .delete ? "Keep in Trash" : "Leave Them", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !sheet.readOnly {
                    Button("Try Again") { model.retryProblems(unlocking: false) }
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

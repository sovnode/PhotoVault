import SwiftUI
import AppKit
import PhotoVaultCore

/// `LazyVGrid`, not `NSCollectionView`.
///
/// The threshold where AppKit's collection view starts to matter sits around
/// 20–30k cells; a large library is ~10k. The condition is that cells stay
/// trivial — a plain `Image` at a fixed frame, no shadows, no `.clipShape`
/// forcing an offscreen pass. Break that and the scrolling regresses long
/// before the item count does.
struct GridView: View {
    @EnvironmentObject var model: LibraryModel
    private var cellSize: Double { model.thumbnailSize }
    /// Cell size when a pinch began; the gesture scales from there.
    @State private var pinchStart: Double?
    /// The photo at the top-left of the screen: the view's place.
    @State private var topID: Int64?
    /// Up to 600 points: a few photos across with the sidebar hidden. The
    /// 512-pixel thumbnails are sharp to about 256 points on a Retina screen,
    /// slightly soft above; the viewer shows the full photo.
    private static let sizeRange: ClosedRange<Double> = 90...600

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.5), spacing: 8)]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.editingFilter, let album = model.currentSmartAlbum, album.rules != nil {
                TagFilterPanel(album: album)
                Divider()
            }
            if model.items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { _ in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(model.items) { item in
                            Cell(item: item, size: cellSize, selected: model.selection.contains(item.id),
                                 whole: model.showWholePhotos)
                                // One tap handler, not a double-tap handler stacked on a
                                // single-tap one. With both, SwiftUI holds every click for
                                // the double-click interval to see whether a second is
                                // coming — the lag on selection. The click count of the
                                // event itself says whether this is the second click.
                                .onTapGesture {
                                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                        model.select(only: item.id)
                                        model.viewing = item
                                    } else {
                                        model.handleClick(on: item, kind: GridView.clickKind())
                                    }
                                }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(8)
                }
                .scrollPosition(id: $topID, anchor: .topLeading)
                .onChange(of: topID) { _, id in model.notePlace(id) }
                // `.task(id:)` rather than onChange: it also runs when the grid
                // first appears, which on opening a vault is the same moment
                // the request to go to its place is made — onChange missed it.
                .task(id: model.scrollRequest?.token) {
                    guard let request = model.scrollRequest, model.takeScrollRequest(request) else { return }
                    // Through the scroll position itself: with it attached, the
                    // reader's scrollTo is overruled by it. The photo comes to
                    // the top row.
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) { topID = request.id }
                    if request.restoresPlace {
                        // Once the scroll has landed, what's at the top is
                        // this view's place again.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.placeRestored() }
                    }
                }
                // A scroll area of its own for each view: scrolling one album
                // never moves another, and each comes back where it was left.
                .id(model.scope.placeKey(model.filter))
                // Clicking past the last cell clears the selection, as in
                // Finder. Attached to the scroll view rather than to its
                // content: an unbounded frame inside a ScrollView makes the two
                // renegotiate their size on every layout pass.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearSelection() }
                )
                // Pinch resizes the thumbnails, exactly as the slider does.
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStart ?? cellSize
                            if pinchStart == nil { pinchStart = start }
                            model.setThumbnailSize(min(Self.sizeRange.upperBound,
                                                       max(Self.sizeRange.lowerBound, start * value.magnification)))
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                }
            }
        }
        // No title while a photo or video is open: it showed over the top of
        // the picture whenever macOS brought the title bar back.
        .navigationTitle(model.viewing == nil ? model.scopeTitle : "")
        .alert("Empty the Trash?", isPresented: $model.confirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) { Task { await model.emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.trashCount == 1
                 ? "The original file for 1 item will be permanently deleted from this vault. This can't be undone."
                 : "The original files for \(model.trashCount) items will be permanently deleted from this vault. This can't be undone.")
        }
    }

    /// `onTapGesture` reports no modifiers on macOS, so the flags are read from
    /// the current event instead. They are accurate at the moment the tap is
    /// dispatched, which is exactly when this runs.
    static func clickKind() -> LibraryModel.ClickKind {
        let flags = NSEvent.modifierFlags
        switch (flags.contains(.shift), flags.contains(.command)) {
        case (true, true): return .extendUnion
        case (true, false): return .extend
        case (false, true): return .toggle
        case (false, false): return .replace
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.filter) {
                ForEach(MediaFilter.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)

            Spacer()
            ActivityStatus(activity: model.activity)
            Spacer()

            if let album = model.currentSmartAlbum, album.rules != nil, !model.editingFilter {
                Button {
                    model.editingFilter = true
                } label: {
                    Label("Edit Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("Change which tags this smart album shows")
            }

            if let sort = model.sort {
                Picker("Sort", selection: Binding(get: { sort.order },
                                                  set: { model.setSortOrder($0) })) {
                    ForEach(PhotoOrder.choices(for: model.scope), id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                .help(model.scope.isAlbum
                      ? "Order photos as they were added to the album, by date taken or created, file name, video length, or at random"
                      : "Order photos by date taken or created, file name, video length (photos count as none), or at random")
                Button {
                    model.toggleSortDirection()
                } label: {
                    Image(systemName: sort.order == .random ? "shuffle" : sort.ascending ? "arrow.up" : "arrow.down")
                        .frame(width: 14)
                }
                .help(sort.order == .random
                      ? "Shuffle again"
                      : "\(sort.order.directionLabel(ascending: sort.ascending)). Click for \(sort.order.directionLabel(ascending: !sort.ascending).lowercased()).")
                .accessibilityLabel(sort.order == .random ? "Shuffle again" : sort.order.directionLabel(ascending: sort.ascending))
            }

            Image(systemName: "photo")
                .font(.caption2)
            Slider(value: Binding(get: { model.thumbnailSize }, set: { model.setThumbnailSize($0) }),
                   in: Self.sizeRange).frame(width: 120)
            Image(systemName: "photo.fill")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40))
            if model.scope == .trash {
                Text("The Trash is empty").font(.title3)
            } else if case .folder = model.scope {
                Text("No photos directly in this folder").font(.title3)
                Text("Its subfolders are listed under it in the sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let album = model.currentSmartAlbum, album.rules != nil {
                Text("No photos match this filter").font(.title3)
                if !model.editingFilter {
                    Button("Edit Filter") { model.editingFilter = true }
                }
            } else {
                Text(model.scanning ? "Scanning…" : "Nothing here yet")
                    .font(.title3)
                Text("Drop files into the Photos folder at the top of the volume, then choose Rescan.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func menu(for item: PhotoItem) -> some View {
        let targets = model.contextTargets(for: item)
        let noun = targets.count == 1 ? "Photo" : "\(targets.count) Photos"
        let allFavorite = targets.allSatisfy(\.favorite)
        let rotatable = targets.filter { Rotation.canRotate($0) }

        if model.scope == .trash {
            Button("Put Back \(noun)") { Task { await model.restore(targets) } }
        } else {
        Button(allFavorite ? "Remove \(noun) from Favorites" : "Add \(noun) to Favorites") {
            Task { await model.setFavorite(!allFavorite, for: targets) }
        }
        Menu("Add \(noun) to Album") {
            Button("New Album…") { model.newAlbumRequest = .init(photoIDs: targets.map(\.id)) }
            if !model.albums.isEmpty { Divider() }
            ForEach(model.albums) { album in
                Button(album.name) {
                    Task { await model.addToAlbum(album.id, items: targets) }
                }
            }
        }
        if case .album(let albumID) = model.scope {
            Button("Remove \(noun) from This Album") {
                Task { await model.removeFromAlbum(albumID, items: targets) }
            }
        }
        Divider()
        Button("Rotate Left") { Task { await model.rotate(rotatable, clockwise: false) } }
            .disabled(rotatable.isEmpty)
        Button("Rotate Right") { Task { await model.rotate(rotatable, clockwise: true) } }
            .disabled(rotatable.isEmpty)
        Button(targets.count == 1 ? "Re-tag with JoyTag" : "Re-tag \(targets.count) Photos with JoyTag") {
            model.retag(targets)
        }
        .disabled(!model.canTag || model.scanning)
        Divider()
        Button("Move \(noun) to Trash") { Task { await model.moveToTrash(targets) } }
        }
        if model.scope != .all, model.scope != .trash, targets.count == 1 {
            Divider()
            Button("Show in Library") { model.showInLibrary(item) }
        }
        Divider()
        // Reveal puts a *path* on the table, never pixels — and Finder must be
        // left in list or column view, because icon and gallery view ask Quick
        // Look, and Quick Look caches decoded frames off-volume.
        Button("Reveal in Finder (list view only)") {
            NSWorkspace.shared.activateFileViewerSelecting(
                model.contextTargets(for: item).compactMap { model.url(for: $0) })
        }
    }
}

/// The status line: progress and a way to stop while something runs — a
/// first scan of a big library takes a while, and nothing is lost by
/// stopping it. Watches `activity`, so progress redraws only this.
///
/// Laid out setting, progress, action: the Tag faster checkbox on
/// the left with its words beside it, the Stop button labelled and on the
/// right behind a divider, and the status text a fixed width so neither
/// control moves as the count ticks over.
private struct ActivityStatus: View {
    @EnvironmentObject var model: LibraryModel
    @ObservedObject var activity: Activity

    var body: some View {
        if model.scanning {
            if model.job != .scan {
                Toggle("Tag faster", isOn: $activity.fast)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .help("Uses more of the Mac to finish sooner; the Mac gets busier. Off again next time.")
                    .padding(.trailing, 12)
            }
            HStack(spacing: 8) {
                if let p = activity.progress, p.total > 0 {
                    ProgressView(value: Double(p.done), total: Double(p.total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 110)
                }
                Text(activity.status)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 280, alignment: .leading)
            }
            Divider().frame(height: 16).padding(.horizontal, 8)
            Button {
                model.stopScan()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(model.job == .scan ? "Stops the scan (⌘.); it carries on next time PhotoVault opens."
                  : model.job == .tagging ? "Stops tagging (⌘.); it carries on next time PhotoVault opens."
                  : "Stops re-tagging (⌘.); photos already done keep their new tags.")
        } else {
            Text(model.selection.isEmpty ? activity.status : "\(model.selection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                // In a narrow window, "63 items" broke into three lines.
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private struct Cell: View {
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var thumbs: ThumbnailSignal
    let item: PhotoItem
    let size: Double
    let selected: Bool
    /// The whole photo at its own shape, rather than a square from its middle.
    let whole: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let cg = model.cachedThumb(item) {
                // CGImage straight into the Image; no NSImage round trip.
                Image(cg, scale: 1, label: Text(item.displayName))
                    .resizable()
                    .aspectRatio(contentMode: whole ? .fit : .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay {
                        if !item.hasThumb {
                            Image(systemName: item.playable ? "photo" : "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            HStack(spacing: 4) {
                if item.mediaType == .video {
                    Image(systemName: item.playable ? "play.circle.fill" : "questionmark.circle.fill")
                    if let d = item.duration { Text(Self.timecode(d)).font(.caption2.monospacedDigit()) }
                }
                if item.favorite { Image(systemName: "heart.fill") }
            }
            .padding(5)
            .foregroundStyle(.white)
            .shadow(radius: 2)
        }
        .border(selected ? Color.accentColor : Color.clear, width: 3)
        .onAppear {
            model.loadThumb(item)
            if !Cell.firstShown {
                Cell.firstShown = true
                SmokeHooks.mark("first thumbnail cell shown")
            }
        }
        .help(item.displayName)
    }

    @MainActor static var firstShown = false

    static func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// New Album… from Add to Album: a name, then a regular album holding the
/// photos the menu was opened on.
struct NewAlbumForPhotosSheet: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let request: LibraryModel.NewAlbumRequest
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Album").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(create)
            Text(request.photoIDs.count == 1 ? "The photo will be added to it."
                                             : "The \(request.photoIDs.count) photos will be added to it.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private func create() {
        guard !trimmed.isEmpty else { return }
        let name = trimmed, ids = request.photoIDs
        dismiss()
        Task { await model.newAlbum(named: name, adding: ids) }
    }
}

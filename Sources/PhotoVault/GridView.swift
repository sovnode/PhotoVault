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
    static let sizeRange: ClosedRange<Double> = 90...600

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
                                    // The arrow keys belong to the grid after a
                                    // click in it, not to the sidebar clicked last.
                                    if let window = NSApp.keyWindow, window.firstResponder is NSTableView {
                                        window.makeFirstResponder(nil)
                                    }
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
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { model.gridWidth = $0 }
                    // Drives the scroll view this grid sits in while it
                    // scrolls by itself.
                    .background(AutoScroller(running: model.autoScrolling,
                                             pointsPerSecond: model.scrollSpeed * (cellSize + 8) / 60,
                                             reveal: model.revealRequest,
                                             holdToken: model.sortChanges,
                                             rowHeight: cellSize,
                                             onStop: { model.autoScrolling = false },
                                             onMoved: { y, width in notePlace(atOffset: y, width: width) }))
                }
                .scrollPosition(id: $topID, anchor: .topLeading)
                // Not when it's cleared after scrolling by itself (below).
                .onChange(of: topID) { _, id in if let id { model.notePlace(id) } }
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

    /// The grid scrolled by itself: SwiftUI's scroll position doesn't follow
    /// a scroll it didn't make, so the photo at the top-left is worked out
    /// from the offset — the grid's rows are regular — and kept as the place.
    /// The stale position is cleared, so asking for that photo later still
    /// scrolls to it.
    private func notePlace(atOffset y: CGFloat, width: CGFloat) {
        let columns = Self.columns(width: width, cellSize: cellSize)
        let row = max(0, Int(((Double(y) - Self.padding) / (cellSize + Self.spacing)).rounded()))
        let index = min(model.items.count - 1, row * columns)
        guard index >= 0 else { return }
        if topID != nil { topID = nil }
        model.notePlace(model.items[index].id)
    }

    static let spacing = 8.0, padding = 8.0

    /// How many photos a row holds at `width` — as the adaptive grid works it
    /// out: as many of the smallest size as fit, spacing between.
    static func columns(width: CGFloat, cellSize: Double) -> Int {
        max(1, Int((Double(width) - 2 * padding + spacing) / (cellSize + spacing)))
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
            .help("Show all, only photos or only videos (⌘1, ⌘2, ⌘3)")

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
                      ? "Shuffle again (⌥⌘↑)"
                      : "\(sort.order.directionLabel(ascending: sort.ascending)). Click for \(sort.order.directionLabel(ascending: !sort.ascending).lowercased()) (\((sort.ascending ? Shortcut.sortDown : .sortUp).label)).")
                .accessibilityLabel(sort.order == .random ? "Shuffle again" : sort.order.directionLabel(ascending: sort.ascending))
            }

            autoScrollButton

            Image(systemName: "photo")
                .font(.caption2)
            Slider(value: Binding(get: { model.thumbnailSize }, set: { model.setThumbnailSize($0) }),
                   in: Self.sizeRange).frame(width: 120)
                .help("Thumbnail size (⌘+, ⌘−)")
            Image(systemName: "photo.fill")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Play/pause for scrolling by itself, with the speed in its menu.
    private var autoScrollButton: some View {
        Menu {
            ForEach(LibraryModel.scrollSpeeds, id: \.self) { rows in
                Toggle(Self.speedLabel(rows), isOn: Binding(get: { model.scrollSpeed == rows },
                                                            set: { _ in model.setScrollSpeed(rows) }))
            }
        } label: {
            Image(systemName: model.autoScrolling ? "pause.fill" : "play.fill")
        } primaryAction: {
            model.autoScrollCommand()
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(model.items.isEmpty)
        .help(Shortcut.autoScroll.help(model.autoScrolling
              ? "Pause scrolling. Scrolling, clicking or a key pauses it too"
              : "Scroll down by itself, \(Self.speedLabel(model.scrollSpeed).lowercased()); the arrow beside it sets the speed"))
        .accessibilityLabel(model.autoScrolling ? "Pause scrolling" : "Scroll automatically")
    }

    /// "10 rows a minute".
    static func speedLabel(_ rows: Double) -> String {
        "\(Int(rows)) \(rows == 1 ? "row" : "rows") a minute"
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
        .shortcut(.favorite)
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
            .shortcut(.rotateLeft)
            .disabled(rotatable.isEmpty)
        Button("Rotate Right") { Task { await model.rotate(rotatable, clockwise: true) } }
            .shortcut(.rotateRight)
            .disabled(rotatable.isEmpty)
        Button(targets.count == 1 ? "Re-tag with JoyTag" : "Re-tag \(targets.count) Photos with JoyTag") {
            model.retag(targets)
        }
        .disabled(!model.canTag || model.scanning)
        Divider()
        Button("Move \(noun) to Trash") { Task { await model.moveToTrash(targets) } }
            .shortcut(.trash)
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

/// Scrolls the NSScrollView behind the grid down at a steady pace, once per
/// display frame, while `running`. Started at the bottom, it goes back to the
/// top first. Stops — through `onStop` — at the bottom, and when the person scrolls,
/// clicks in the grid or presses a key: scrolling by itself should never fight
/// them. The grid's place follows the scroll as it would by hand.
struct AutoScroller: NSViewRepresentable {
    let running: Bool
    let pointsPerSecond: Double
    /// A photo to bring into view (the arrow keys moved to it), by its index.
    let reveal: LibraryModel.RevealRequest?
    /// Changes when the sort does: the scroll stays where it is, rather than
    /// following the photo that was at the top to its new spot.
    let holdToken: Int
    let rowHeight: Double
    let onStop: () -> Void
    /// Where it has got to — the offset and the grid's width — every half
    /// second and when it stops.
    let onMoved: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> DriverView { DriverView() }

    func updateNSView(_ view: DriverView, context: Context) {
        view.speed = pointsPerSecond
        view.onStop = onStop
        view.onMoved = onMoved
        if view.heldToken == nil {
            view.heldToken = holdToken
        } else if holdToken != view.heldToken {
            view.heldToken = holdToken
            view.holdScroll()
        }
        if let reveal, reveal != view.revealed {
            view.revealed = reveal
            view.reveal(index: reveal.index, rowHeight: rowHeight)
        }
        view.running = running
    }

    static func dismantleNSView(_ view: DriverView, coordinator: ()) { view.running = false }

    final class DriverView: NSView {
        var speed: Double = 0
        var onStop: () -> Void = {}
        var onMoved: (CGFloat, CGFloat) -> Void = { _, _ in }
        /// Where the scroll would be: the clip view's origin is rounded to
        /// device pixels, so slow speeds would never move off the spot.
        private var position: CGFloat = 0
        private var lastFrame: CFTimeInterval?
        private var link: CADisplayLink?
        /// Stands in for the display link where it never fires — seen on a
        /// virtual display.
        private var timer: Timer?
        private var monitor: Any?
        private var frames = 0
        private var rewinding = false
        var revealed: LibraryModel.RevealRequest?
        var heldToken: Int?
        private var holdObserver: Any?

        /// Keeps the scroll offset as it is while the grid reorders: the grid
        /// lets go of the photo at its top, and for a moment any move the
        /// reorder makes is undone. Then the photo now at the top is the place.
        func holdScroll() {
            guard let scroll = enclosingScrollView else { return }
            let clip = scroll.contentView
            let y = clip.bounds.origin.y
            onMoved(y, clip.bounds.width)
            if let holdObserver { NotificationCenter.default.removeObserver(holdObserver) }
            clip.postsBoundsChangedNotifications = true
            holdObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak scroll] _ in
                MainActor.assumeIsolated {
                    guard let scroll, let document = scroll.documentView else { return }
                    let target = min(y, Self.bottom(of: scroll, document))
                    guard abs(scroll.contentView.bounds.origin.y - target) > 1 else { return }
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: target))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                if let observer = self.holdObserver { NotificationCenter.default.removeObserver(observer) }
                self.holdObserver = nil
                self.onMoved(scroll.contentView.bounds.origin.y, scroll.contentView.bounds.width)
                SmokeHooks.say("sort changed, scroll held at \(Int(y)), now \(Int(scroll.contentView.bounds.origin.y))")
            }
        }

        /// Scrolls just far enough that the row holding photo `index` shows
        /// whole — not at all if it does already.
        func reveal(index: Int, rowHeight: Double) {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let columns = GridView.columns(width: clip.bounds.width, cellSize: rowHeight)
            let top = CGFloat(GridView.padding + Double(index / columns) * (rowHeight + GridView.spacing))
            let bottom = top + CGFloat(rowHeight)
            var y = clip.bounds.origin.y
            if top < y {
                y = top - CGFloat(GridView.padding)
            } else if bottom > y + clip.bounds.height {
                y = bottom + CGFloat(GridView.padding) - clip.bounds.height
            } else {
                return
            }
            y = min(max(0, y), Self.bottom(of: scroll, document))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            position = y
            onMoved(y, clip.bounds.width)
        }

        var running = false {
            didSet { if running != oldValue { running ? start() : stop() } }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func start() {
            guard let scroll = enclosingScrollView else { return DispatchQueue.main.async { self.onStop() } }
            position = scroll.contentView.bounds.origin.y
            // The grid lets go of the photo it last scrolled to: holding on to
            // it, SwiftUI pulled the grid back there as new rows were laid out.
            let rewind = Self.atEnd(position, of: scroll)
            onMoved(rewind ? 0 : position, scroll.contentView.bounds.width)
            if rewind {
                // Back to the top once it has let go — on the next turn.
                position = 0
                rewinding = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, let scroll = self.enclosingScrollView else { return }
                    self.rewinding = false
                    scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            lastFrame = nil
            frames = 0
            let link = displayLink(target: self, selector: #selector(linkFired(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.running, self.frames == 0, self.timer == nil else { return }
                SmokeHooks.say("auto-scroll: no display frames, using a timer")
                let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.step(at: CACurrentMediaTime()) }
                }
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                self?.interrupted(by: event)
                return event
            }
            SmokeHooks.say("auto-scroll started at \(Int(position)) of \(scroll.documentView.map { Int(Self.bottom(of: scroll, $0)) } ?? -1)")
        }

        private func stop() {
            if let scroll = enclosingScrollView, frames > 0 {
                onMoved(scroll.contentView.bounds.origin.y, scroll.contentView.bounds.width)
            }
            link?.invalidate()
            link = nil
            timer?.invalidate()
            timer = nil
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// A scroll or click in the grid, or a key — except Space and ⌘
        /// shortcuts, which are the menu's: Space pauses it there, and ⌘+
        /// can change the size while it runs.
        private func interrupted(by event: NSEvent) {
            guard let scroll = enclosingScrollView, event.window === window else { return }
            switch event.type {
            case .keyDown:
                if event.keyCode == 49 || event.modifierFlags.contains(.command) { return }
            case .scrollWheel, .leftMouseDown, .rightMouseDown:
                let point = scroll.convert(event.locationInWindow, from: nil)
                guard scroll.bounds.contains(point) else { return }
            default:
                return
            }
            onStop()
        }

        /// The furthest the grid scrolls.
        static func bottom(of scroll: NSScrollView, _ document: NSView) -> CGFloat {
            max(0, document.frame.height - scroll.contentView.bounds.height)
        }

        /// At the bottom, give or take the clip view's rounding to pixels.
        static func atEnd(_ y: CGFloat, of scroll: NSScrollView) -> Bool {
            guard let document = scroll.documentView else { return true }
            return y >= bottom(of: scroll, document) - 2
        }

        @objc private func linkFired(_ link: CADisplayLink) {
            if timer != nil { link.invalidate(); self.link = nil; return }
            step(at: link.timestamp)
        }

        private func step(at now: CFTimeInterval) {
            guard let scroll = enclosingScrollView, let document = scroll.documentView else { return onStop() }
            guard !rewinding else { return }
            defer { lastFrame = now }
            guard let last = lastFrame else { return }
            let clip = scroll.contentView
            // Picks up a scroll made since — a resize, or the place restored.
            if abs(clip.bounds.origin.y - position) > 2 { position = clip.bounds.origin.y }
            let bottom = Self.bottom(of: scroll, document)
            if Self.atEnd(position, of: scroll) {
                SmokeHooks.say("auto-scroll reached the end")
                return onStop()
            }
            position = min(bottom, position + CGFloat(speed * min(now - last, 0.1)))
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: position))
            scroll.reflectScrolledClipView(clip)
            frames += 1
            if frames % 30 == 0 { onMoved(position, clip.bounds.width) }
        }
    }
}

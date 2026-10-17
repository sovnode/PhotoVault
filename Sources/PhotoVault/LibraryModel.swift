import Foundation
import SwiftUI
import IOKit.pwr_mgt
import AppKit
import CoreGraphics
import PhotoVaultCore

/// The status line and a running job's progress (see `LibraryModel.activity`).
@MainActor
final class Activity: ObservableObject {
    @Published var status = "Starting…"
    @Published var progress: ScanProgress?
    /// Tag faster, for the run going now. Off at the start of every run and
    /// never saved.
    @Published var fast = false { didSet { pace.isFast = fast } }
    let pace = TaggingPace()
}

/// Fires when a thumbnail lands in the cache (see `LibraryModel.thumbs`).
@MainActor
final class ThumbnailSignal: ObservableObject {}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var smartAlbums: [SmartAlbum] = []
    @Published private(set) var albumCounts: [Int64: Int] = [:]
    @Published private(set) var totalCount = 0
    @Published private(set) var trashCount = 0
    @Published var confirmingEmptyTrash = false
    /// The window frame saved in this vault's catalog at the last quit, for the
    /// window to restore. AppKit's own frame autosave is off: it writes to
    /// `~/Library/Preferences`.
    @Published private(set) var savedWindowFrame: String?
    /// What's running, for the status bar, and when thumbnails arrive, for
    /// the cells showing them: each its own object, so these frequent changes
    /// — several a second while tagging — redraw only what shows them. As
    /// part of the model they redrew everything watching it, the menu bar
    /// among it, and an open menu closed itself.
    let activity = Activity()
    let thumbs = ThumbnailSignal()
    private(set) var status: String {
        get { activity.status }
        set { activity.status = newValue }
    }
    private(set) var scanProgress: ScanProgress? {
        get { activity.progress }
        set { activity.progress = newValue }
    }
    @Published private(set) var scanning = false
    private var scanTask: Task<Void, Never>?
    private var smokeViewerOpened = false
    private var smokeFilterOpened = false
    @Published var errorMessage: String?

    @Published var scope: LibraryScope = .all {
        didSet {
            // Leaving a view: its place is written now, not after the delay
            // that scrolling waits for.
            savePlace(oldValue.placeKey(filter))
            restoringPlace = true
            autoScrolling = false
            clearSelection()
            if case .smart = scope {} else { editingFilter = false }
            // Opening where it was left: start() reloads once it has it all.
            guard !resuming else { return }
            rememberView()
            let scope = self.scope
            Task {
                await applyViewFilter(of: scope)
                await reload()
            }
        }
    }
    /// All, Photos or Videos. Each keeps its own place in every view, so
    /// filtering and coming back to All finds the place where it was.
    @Published var filter: MediaFilter = .all {
        didSet {
            savePlace(scope.placeKey(oldValue))
            restoringPlace = true
            autoScrolling = false
            clearSelection()
            guard !resuming else { return }
            rememberView()
            rememberFilter()
            Task { await reload() }
        }
    }
    @Published var viewing: PhotoItem? {
        didSet {
            // Closing the viewer lands on the photo last shown, wherever the
            // arrow keys took it, not wherever the grid was scrolled before.
            if viewing == nil, let last = oldValue { scrollRequest = ScrollRequest(id: last.id) }
            // Closing it also ends a slideshow, so one never starts by itself
            // the next time a photo is opened.
            if viewing == nil {
                if nextOn { nextOn = false }
            } else if autoScrolling {
                // Opening a photo pauses scrolling the grid.
                autoScrolling = false
            }
            if viewing?.id != oldValue?.id { rememberView() }
            updateSlideshowAssertion()
        }
    }

    // MARK: - Repeat and Play Next

    /// Loops the video on screen; a slideshow that reaches the end starts again.
    @Published var repeatOn = false
    /// Moves on to the next item when a video ends, or after a photo's time.
    /// No Random beside it: the Random sort order shows a view in a random
    /// order, which Play Next then follows.
    @Published var nextOn = false { didSet { updateSlideshowAssertion() } }
    /// Seconds each photo stays in a slideshow. Saved per vault.
    @Published private(set) var slideInterval: Double = 5
    static let slideIntervals: [Double] = [2, 3, 5, 10, 20, 30]
    /// One playback speed for every video. Saved per vault.
    private(set) var videoSpeed: Float = 1
    private var displayAwake: IOPMAssertionID = 0
    /// How many times Play Next has moved on. For the smoke test.
    private var smokeMoves = 0

    var slideshowOn: Bool { nextOn }

    func setSlideInterval(_ seconds: Double) {
        slideInterval = seconds
        Task { await store?.setSetting("viewer.interval", String(seconds)) }
    }

    func setVideoSpeed(_ speed: Float) {
        guard abs(speed - videoSpeed) > 0.001 else { return }
        videoSpeed = speed
        Task { await store?.setSetting("video.speed", String(speed)) }
    }

    /// Play Next: the item after the one open, in the view's order. It stops
    /// at the end unless Repeat is on. Returns whether it moved.
    @discardableResult
    func advance() -> Bool {
        guard let open = viewing, !items.isEmpty else { return false }
        guard let i = items.firstIndex(where: { $0.id == open.id }) else { return false }
        if i + 1 < items.count { return show(items[i + 1]) }
        if repeatOn, let first = items.first, first.id != open.id { return show(first) }
        return false
    }

    private func show(_ item: PhotoItem) -> Bool {
        SmokeHooks.say("moved on by itself to \(item.id)")
        smokeMoves += 1
        lastStep = 1
        viewing = item
        select(only: item.id)
        return true
    }

    /// The display stays awake while a slideshow runs or the grid scrolls by
    /// itself — a power assertion, which writes nothing to disk.
    private func updateSlideshowAssertion() {
        let wanted = viewing != nil ? slideshowOn : autoScrolling
        if wanted, displayAwake == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "PhotoVault slideshow" as CFString, &displayAwake)
        } else if !wanted, displayAwake != 0 {
            IOPMAssertionRelease(displayAwake)
            displayAwake = 0
        }
    }

    /// The current view's sort, chosen in the toolbar: the library's — All
    /// Media, its folders, Favorites and the Trash share one — or an album's
    /// or smart album's own.
    @Published private(set) var sort: SortSetting?
    /// The folders under Photos/ that hold photos, for the sidebar.
    @Published private(set) var folderTree: FolderNode?
    /// Whether the viewer's properties panel is open. Saved in the vault.
    @Published private(set) var showProperties = false

    /// Every tag in the vault, most common first, merged across sources.
    @Published private(set) var tagCounts: [TagCount] = []
    /// The vault's Tag Groups.txt (or the app's copy).
    @Published private(set) var tagGroups = TagGroups(text: "")
    @Published private(set) var hiddenTags: Set<String> = []
    /// The visible tags under their groups, in the file's order, each group's
    /// tags most common first. Groups with no tags in the vault are left out.
    @Published private(set) var tagGroupLists: [TagGroupList] = []
    private(set) var tagByKey: [String: TagCount] = [:]
    /// Whether the open smart album's filter panel is showing.
    @Published var editingFilter = false
    /// The grid's thumbnail size, saved per vault.
    @Published private(set) var thumbnailSize: Double = 160
    private var thumbnailSizeSave: Task<Void, Never>?
    /// Bumped whenever tags change, so views showing a photo's tags reload.
    @Published private(set) var tagsVersion = 0

    /// JoyTag's files in this vault; nil with `taggerUnavailable` saying why.
    private var joyTagFiles: JoyTagFiles?
    @Published private(set) var taggerUnavailable: String? = "JoyTag isn't installed in this vault."
    /// What the background task is, while `scanning`: a scan or tagging.
    @Published private(set) var job: Job = .scan
    /// The question before a large tagging run.
    @Published var taggingQuestion: TaggingQuestion?
    /// "Not Now" to tagging the photos JoyTag hasn't seen: not asked again
    /// until PhotoVault next opens. Tag Untagged Photos still works.
    private var taggingDeclined = false

    enum Job: Equatable { case scan, tagging, retagging }

    struct TaggingQuestion: Identifiable {
        let id = UUID()
        /// The photos to re-tag, or nil for every photo JoyTag hasn't tagged.
        let ids: [Int64]?
        let title: String
        let message: String
        let action: String
    }

    struct TagGroupList: Identifiable, Equatable {
        let name: String
        let tags: [TagCount]
        var id: String { name }
    }

    /// A one-off request for the grid to scroll a photo into view. Each request
    /// is distinct, so asking for the same photo twice still scrolls.
    struct ScrollRequest: Equatable {
        let id: Int64
        var anchor: UnitPoint = .center
        /// Returning to a view's remembered place, rather than revealing a photo.
        var restoresPlace = false
        let token = UUID()
    }
    @Published var scrollRequest: ScrollRequest?

    /// Each view's place: the photo at the top of the screen when it was last
    /// looked at, by `LibraryScope.placeKey`. Kept in the vault's catalog.
    private var places: [String: Int64] = [:]
    private var placeSave: Task<Void, Never>?
    /// The view and filter the grid last scrolled to the place of.
    private struct Shown: Equatable {
        let scope: LibraryScope
        let filter: MediaFilter
    }
    private var lastShown: Shown?
    private var lastShownScope: LibraryScope? { lastShown?.scope }

    /// The current view's place, with the current filter.
    private var placeKey: String { scope.placeKey(filter) }

    /// A place being left is written now, not after the delay that scrolling
    /// waits for.
    private func savePlace(_ key: String) {
        if let id = places[key], let store { Task { await store.setSetting(key, String(id)) } }
    }
    /// While a view is coming up and before it has been scrolled to its place,
    /// what the grid reports at the top belongs to no view yet.
    private var restoringPlace = true
    /// What the grid last reported at its top, place or not. For the smoke test.
    private(set) var gridTop: Int64?

    /// The grid's top photo changed: this view's place, saved a moment after
    /// scrolling stops.
    func notePlace(_ id: Int64?) {
        gridTop = id
        guard !restoringPlace, viewing == nil, let id, items.contains(where: { $0.id == id }) else { return }
        let key = placeKey
        guard places[key] != id else { return }
        places[key] = id
        placeSave?.cancel()
        placeSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let store = self?.store else { return }
            await store.setSetting(key, String(id))
        }
    }

    /// The grid has scrolled to the view's place; from now on its top photo is
    /// this view's place.
    func placeRestored() {
        restoringPlace = false
        SmokeHooks.mark("place restored")
    }

    /// The grid acts on each scroll request once — not again when it's rebuilt
    /// for another view while the old request is still set.
    private var handledScroll: UUID?
    func takeScrollRequest(_ request: ScrollRequest) -> Bool {
        guard handledScroll != request.token else { return false }
        handledScroll = request.token
        return true
    }

    /// Scrolls a view that has just come up to where it was left, or to its
    /// top. A photo that has left the view since starts it at the top.
    private func restorePlace(of scope: LibraryScope, filter: MediaFilter, revealing: Bool) async {
        // This filter's own place; or, the first time a filter is used in the
        // view, the unfiltered place if the filter still shows that photo.
        var keys = [scope.placeKey(filter)]
        if filter != .all { keys.append(scope.placeKey(.all)) }
        for key in keys where places[key] == nil {
            if let saved = await store?.setting(key).flatMap(Int64.init) { places[key] = saved }
        }
        guard !revealing else { restoringPlace = false; return }
        let remembered = keys.lazy.compactMap { self.places[$0] }.first { id in self.items.contains { $0.id == id } }
        guard let target = remembered ?? items.first?.id else { restoringPlace = false; return }
        scrollRequest = ScrollRequest(id: target, anchor: .top, restoresPlace: true)
        // Should the grid never act on it, places are noted again all the same.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let self, self.lastShown == Shown(scope: scope, filter: filter) { self.restoringPlace = false }
        }
    }
    /// A photo to select and scroll to once the next reload has it — set by
    /// Show in Library before it switches the view.
    private var pendingReveal: Int64?

    /// The Finder click rules live in `PhotoVaultCore.Selection`, which is
    /// plain logic and covered by tests; this type only routes events to it.
    @Published private(set) var sel = Selection()
    var selection: Set<Int64> { sel.ids }

    private(set) var store: Store?
    private(set) var root: URL?
    private let cache = ThumbnailCache()
    let fullRes = FullResCache(capacity: 3)
    /// Direction of the last step through the viewer, so prefetch decodes the
    /// photo you're heading towards first.
    private var lastStep = 1
    private var inFlight: Set<Int64> = []

    // MARK: - Lifecycle

    func start() async {
        do {
            let root = try VolumeLocator.resolveOrBootstrap()
            self.root = root
            // Test-only: the smoke test slows thumbnails so it can stop a scan
            // part-way through.
            let slow = ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_SLOW_THUMBS"] == "1"
            let store = try Store(root: root, thumbnailer: slow
                ? Thumbnailer(photoConcurrency: 2, testDelayNanoseconds: 1_000_000_000)
                : Thumbnailer())
            self.store = store
            savedWindowFrame = await store.setting("window.frame")
            showProperties = await store.setting("viewer.properties") == "1"
            if let size = await store.setting("grid.size").flatMap(Double.init) { thumbnailSize = size }
            showWholePhotos = await store.setting("grid.whole") == "1"
            if let seconds = await store.setting("viewer.interval").flatMap(Double.init), seconds > 0 { slideInterval = seconds }
            if let speed = await store.setting("video.speed").flatMap(Float.init), speed > 0 { videoSpeed = speed }
            if let rows = await store.setting("grid.scrollSpeed").flatMap(Double.init), rows > 0 { scrollSpeed = rows }
            installKeyMonitor()
            locateTagger(root: root)
            await reloadTags()
            await resumeWhereLeft(store)
            runScan(full: nil)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = "Not ready"
        }
    }

    // MARK: - Opening where it was left

    /// Set while the view PhotoVault was left on is put back, so the scope and
    /// filter being set don't each reload, or save themselves again.
    private var resuming = false
    private var viewSave: Task<Void, Never>?

    /// The view on screen — album, folder, filter, the photo open in the
    /// viewer — kept in the catalog as it changes, so PhotoVault opens there
    /// next time. Each view's scroll position is kept already (its place).
    private func rememberView() {
        guard let store, !resuming else { return }
        let view = scope.storageValue, filter = String(self.filter.rawValue)
        let open = viewing.map { String($0.id) } ?? ""
        let previous = viewSave
        viewSave = Task {
            await previous?.value
            await store.setSetting("last.view", view)
            await store.setSetting("last.filter", filter)
            await store.setSetting("last.viewing", open)
        }
    }

    /// All, Photos or Videos, as each view was last left: the filter is the
    /// view's own, not one for every view.
    private var viewFilters: [String: MediaFilter] = [:]
    /// A photo Show in Library is about to reveal: All Media's filter mustn't
    /// hide it.
    private var revealing: MediaType?

    private static func filterKey(_ scope: LibraryScope) -> String { "filter.\(scope.storageValue)" }

    private func rememberFilter() {
        let key = Self.filterKey(scope), filter = self.filter
        viewFilters[key] = filter
        Task { await store?.setSetting(key, String(filter.rawValue)) }
    }

    /// Puts back the filter `scope` was left with, quietly — the reload
    /// that follows shows it.
    private func applyViewFilter(of scope: LibraryScope, fallback: MediaFilter = .all) async {
        guard let store else { return }
        let key = Self.filterKey(scope)
        var saved: MediaFilter
        if let known = viewFilters[key] {
            saved = known
        } else {
            saved = await store.setting(key).flatMap(Int.init).flatMap(MediaFilter.init(rawValue:)) ?? fallback
            viewFilters[key] = saved
        }
        guard self.scope == scope else { return }
        if let kind = revealing {
            revealing = nil
            if (saved == .photos && kind == .video) || (saved == .videos && kind == .photo) {
                saved = .all
                rememberFilterQuietly(saved, for: key)
            }
        }
        guard saved != filter else { return }
        resuming = true
        filter = saved
        resuming = false
    }

    private func rememberFilterQuietly(_ filter: MediaFilter, for key: String) {
        viewFilters[key] = filter
        Task { await store?.setSetting(key, String(filter.rawValue)) }
    }

    /// Opens the view PhotoVault was left on, at its place, with the photo
    /// that was open opened again. An album deleted since, or a folder gone,
    /// opens All Media instead.
    private func resumeWhereLeft(_ store: Store) async {
        var reopen: Int64?
        if ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_NO_RESUME"] != "1",
           let saved = await store.setting("last.view").flatMap(LibraryScope.init(storageValue:)) {
            resuming = true
            scope = saved
            resuming = false
            // The view's own filter; a catalog from before views had their
            // own keeps the one it was left with.
            let left = await store.setting("last.filter").flatMap(Int.init).flatMap(MediaFilter.init(rawValue:)) ?? .all
            await applyViewFilter(of: saved, fallback: left)
            reopen = await store.setting("last.viewing").flatMap(Int64.init)
        }
        await reload()
        if !viewExists(scope) {
            scope = .all
            return
        }
        if let id = reopen, let item = items.first(where: { $0.id == id }) {
            select(only: id)
            viewing = item
        }
        if ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_RESUME"] == "1" {
            print("smoke: opened at \(scope.storageValue) filter \(filter.rawValue) viewing \(viewing.map { String($0.id) } ?? "none")")
            fflush(stdout)
        }
    }

    private func viewExists(_ scope: LibraryScope) -> Bool {
        func has(_ path: String, in node: FolderNode) -> Bool {
            node.id == path || (node.children ?? []).contains { has(path, in: $0) }
        }
        switch scope {
        case .album(let id): return albums.contains { $0.id == id }
        case .smart(let id): return smartAlbums.contains { $0.id == id }
        case .folder(let path): return folderTree.map { has(path, in: $0) } ?? false
        case .all, .favorites, .trash: return true
        }
    }

    // MARK: - Keys the views don't get first

    private var keyMonitor: Any?

    /// Space and the arrow keys, looked at before any view or the menu bar
    /// sees them. Space as a menu shortcut never arrived while the sidebar had
    /// the focus; the arrows move the grid's selection, which no view does;
    /// and in the viewer the arrows step through the view in its order — a
    /// playing video took them for itself, so with Play Next a video skipped to
    /// its end and the item after it came next.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return false }
                self.trackShift(event)
                return event.type == .keyDown && self.handleKey(event)
            } ? nil : event
        }
    }

    /// The window a key or Shift press is for, if it's the main window with
    /// no sheet over it and nothing being typed. (An event made by the smoke
    /// test may carry no window: the main window is assumed.)
    private func mainWindow(for event: NSEvent) -> NSWindow? {
        guard let window = event.window ?? Self.typingWindow, window === Self.typingWindow, !window.isSheet,
              window.attachedSheet == nil, !isEditingText else { return nil }
        return window
    }

    /// Shift pressed and let go on its own — no key, click or scroll while it
    /// was down, so ⇧-click and ⇧-arrow selecting never count — opens the one
    /// photo picked, or in the viewer goes back to the library, as Esc does.
    private var shiftAlone = false
    private var shiftDownAt: TimeInterval = 0

    private func trackShift(_ event: NSEvent) {
        guard event.type == .flagsChanged else { shiftAlone = false; return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let isShift = event.keyCode == 56 || event.keyCode == 60
        if isShift, flags == .shift {
            shiftAlone = true
            shiftDownAt = event.timestamp
        } else if isShift, flags.isEmpty, shiftAlone {
            shiftAlone = false
            // A long hold isn't a press: it was meant for something else.
            guard event.timestamp - shiftDownAt < 0.8, mainWindow(for: event) != nil else { return }
            shiftPressed()
        } else {
            shiftAlone = false
        }
    }

    private func shiftPressed() {
        if viewing != nil {
            viewing = nil
        } else if selection.count == 1, let id = selection.first, let item = items.first(where: { $0.id == id }) {
            viewing = item
        }
    }

    /// Whether the key was used here.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Only in the main window, not a sheet over it, and not while typing.
        guard let window = mainWindow(for: event),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        else { return false }
        let arrow: GridMove?
        switch event.keyCode {
        case 53:
            // Esc: back to the library — from a playing video too, which
            // otherwise kept it.
            guard viewing != nil else { return false }
            viewing = nil
            return true
        case 123: arrow = .left
        case 124: arrow = .right
        case 125: arrow = .down
        case 126: arrow = .up
        case 49:
            // Space: in the viewer it's the video's play and pause.
            guard viewing == nil else { return false }
            autoScrollCommand()
            return true
        default: return false
        }
        guard let arrow else { return false }
        if viewing != nil {
            switch arrow {
            case .left: step(-1); return true
            case .right: step(1); return true
            case .up, .down: return false
            }
        }
        // The sidebar's own arrows move through its list.
        if window.firstResponder is NSTableView { return false }
        return moveSelection(arrow)
    }

    enum GridMove { case left, right, up, down }

    /// The grid's width, for how many photos a row holds.
    var gridWidth: CGFloat = 0
    /// A photo the grid should scroll just far enough to show.
    @Published private(set) var revealRequest: RevealRequest?

    struct RevealRequest: Equatable {
        let index: Int
        let token = UUID()
    }

    /// The arrow keys with one photo picked in the grid: the photo beside it,
    /// or the one above or below. Quick for going through photos one by one —
    /// to rotate them (⌘L, ⌘R), say.
    func moveSelection(_ move: GridMove) -> Bool {
        guard selection.count == 1, let id = selection.first,
              let i = items.firstIndex(where: { $0.id == id }) else { return false }
        let columns = GridView.columns(width: gridWidth, cellSize: thumbnailSize)
        let j: Int
        switch move {
        case .left: j = i - 1
        case .right: j = i + 1
        case .up: j = i - columns
        case .down: j = i + columns
        }
        guard items.indices.contains(j) else { return true }
        select(only: items[j].id)
        revealRequest = RevealRequest(index: j)
        return true
    }

    // MARK: - Scanning

    /// Starts a scan in the background, unless one is already running. It can
    /// be stopped (`stopScan`), and quitting or ejecting asks first while it
    /// runs.
    func runScan(full: Bool?) {
        guard let store, scanTask == nil else { return }
        scanning = true
        job = .scan
        scanProgress = nil
        let sink = progressSink()
        scanTask = Task { [weak self] in
            var stopped = false
            do {
                try await store.scan(full: full, progress: sink)
            } catch is CancellationError {
                stopped = true
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard let self else { return }
            self.scanning = false
            self.scanProgress = nil
            self.scanTask = nil
            SmokeHooks.mark("scan finished")
            await self.reloadTags()
            await self.reload()
            if stopped {
                self.status = "Scan stopped — it carries on next time PhotoVault opens"
            } else {
                self.openViewerForSmokeTest()
                await self.openFilterForSmokeTest()
                await self.checkPlacesForSmokeTest()
                await self.checkPlaybackForSmokeTest()
                await self.checkKeysForSmokeTest()
                await self.leaveForSmokeTest()
                await self.timeSwitchingForSmokeTest()
                await self.considerTagging()
            }
        }
    }

    private func progressSink() -> @Sendable (ScanProgress) -> Void {
        { [weak self] p in
            Task { @MainActor in
                guard let self, self.scanning else { return }
                self.scanProgress = p
                self.status = Self.describe(p)
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
    }

    /// What the running scan is doing, for the quit and eject questions.
    var scanDescription: String {
        guard let p = scanProgress else {
            return job == .scan ? "PhotoVault is checking the vault for changes." : "PhotoVault is loading JoyTag."
        }
        let text = Self.describe(p)
        return "PhotoVault is \(text.prefix(1).lowercased() + text.dropFirst())."
    }

    /// The quit and eject question for whatever is running.
    var stopQuestion: (title: String, message: String) {
        switch job {
        case .scan:
            return ("PhotoVault is still scanning",
                    scanDescription + " If you stop now, it carries on from where it left off the next time PhotoVault opens.")
        case .tagging:
            return ("PhotoVault is still tagging photos",
                    scanDescription + " If you stop now, it carries on from where it left off the next time PhotoVault opens.")
        case .retagging:
            return ("PhotoVault is still re-tagging photos",
                    scanDescription + " If you stop now, the photos already re-tagged keep their new tags and the rest keep their old ones.")
        }
    }

    private static func describe(_ p: ScanProgress) -> String {
        guard p.total > 0 else { return p.phase }
        let n = NumberFormatter.localizedString(from: NSNumber(value: p.done), number: .decimal)
        let t = NumberFormatter.localizedString(from: NSNumber(value: p.total), number: .decimal)
        return "\(p.phase.replacingOccurrences(of: "…", with: "")) — \(n) of \(t)"
    }

    /// Hook for `Scripts/smoke-test.sh`: once indexing finishes, open the first
    /// photo so the end-to-end run can exercise the viewer without UI scripting,
    /// which would need Accessibility permission. Inert unless the variable is set.
    private func openViewerForSmokeTest() {
        guard !smokeViewerOpened,
              ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_OPEN_VIEWER"] == "1",
              let first = items.first(where: { $0.mediaType == .photo }) else { return }
        smokeViewerOpened = true
        select(only: first.id)
        viewing = first
        if ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_SLIDESHOW"] == "1" {
            setSlideInterval(30)
            nextOn = true
        }
        print("smoke: viewer opened \(first.relPath)")
        // With the properties panel open too, so the idle-CPU check covers it.
        if !showProperties {
            toggleProperties()
            print("smoke: properties panel open")
        }
        fflush(stdout)
    }

    /// Hook for `Scripts/smoke-test.sh`: a smart album including the tag "sky",
    /// left with its filter panel open, so the run can check what it matches and
    /// that the panel sits idle. Inert unless the variable is set.
    private func openFilterForSmokeTest() async {
        guard !smokeFilterOpened, ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_FILTER"] == "1" else { return }
        smokeFilterOpened = true
        await newSmartAlbum(named: "Smoke filter")
        guard let album = currentSmartAlbum else { return }
        var rules = TagRules()
        rules.cycle(.tag, "sky")
        await updateRules(album.id, rules)
        print("smoke: filter panel open, \(items.count) photos match")
        fflush(stdout)
    }

    /// Hook for `Scripts/smoke-test.sh`: scrolls All Media down, visits a
    /// folder, comes back, and reports whether each view kept its own place —
    /// without synthetic scrolling, which would need Accessibility permission.
    /// Inert unless the variable is set.
    private var smokePlacesChecked = false
    private var smokeFirstItems = false
    private func checkPlacesForSmokeTest() async {
        guard !smokePlacesChecked, ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_PLACES"] == "1",
              scope == .all, items.count > 30,
              let folder = folderTree?.children?.first(where: { $0.directCount > 0 })?.id else { return }
        smokePlacesChecked = true
        func settle() async { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        await settle()
        scrollRequest = ScrollRequest(id: items[items.count * 2 / 3].id, anchor: .top)
        await settle()
        let allPlace = gridTop
        scope = .folder(folder)
        await settle()
        let folderTop = gridTop, folderFirst = items.first?.id
        scope = .all
        await settle()
        let back = gridTop
        print("smoke: place kept: \(allPlace != nil && back == allPlace ? "yes" : "no") (\(allPlace.map(String.init) ?? "-") then \(back.map(String.init) ?? "-"))")
        print("smoke: a folder opens at its top: \(folderTop != nil && folderTop == folderFirst ? "yes" : "no")")

        // Only videos, then all again: the place is where it was.
        filter = .videos
        await settle()
        filter = .all
        await settle()
        print("smoke: place kept through a filter: \(gridTop == allPlace ? "yes" : "no") (\(allPlace.map(String.init) ?? "-") then \(gridTop.map(String.init) ?? "-"))")
        // Photos only, in another view and back: the place is a photo, so
        // Photos finds it too.
        filter = .photos
        await settle()
        scope = .folder(folder)
        await settle()
        scope = .all
        await settle()
        print("smoke: place kept with a filter on: \(gridTop == allPlace ? "yes" : "no") (\(allPlace.map(String.init) ?? "-") then \(gridTop.map(String.init) ?? "-"))")
        filter = .all
        await settle()
        fflush(stdout)
    }

    /// Hook for measuring: switches between All Media and a folder a few
    /// times, timing each switch until the main thread is free again.
    /// `PHOTOVAULT_SMOKE_SWITCH=1`; inert otherwise.
    private func timeSwitchingForSmokeTest() async {
        guard ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_SWITCH"] == "1",
              let folder = folderTree?.children?.first(where: { $0.directCount > 0 })?.id else { return }
        func settle() async { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        await settle()
        for target in [LibraryScope.folder(folder), .all, .folder(folder), .all] {
            let start = Date()
            scope = target
            // Until the reload has landed and the main thread has drawn it.
            while lastShownScope != target { try? await Task.sleep(nanoseconds: 5_000_000) }
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
            SmokeHooks.say(String(format: "switch to %@ took %.0f ms (%d items)",
                                  target == .all ? "All Media" : "a folder", Date().timeIntervalSince(start) * 1000, items.count))
            await settle()
        }
    }

    /// Hook for `Scripts/smoke-test.sh`: a slideshow, a video looping with
    /// Repeat, its speed changed in the player as the controls' speed menu
    /// does, and Play Next moving on when it ends. Inert unless the variable
    /// is set.
    private var smokePlaybackChecked = false
    private func checkPlaybackForSmokeTest() async {
        guard !smokePlaybackChecked, ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_PLAYBACK"] == "1",
              let photo = items.first(where: { $0.mediaType == .photo }),
              let video = items.first(where: { $0.mediaType == .video && $0.playable && ($0.duration ?? 99) < 4 })
        else { return }
        smokePlaybackChecked = true
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

        select(only: photo.id)
        viewing = photo
        setSlideInterval(2)
        nextOn = true
        let before = smokeMoves
        await wait(5)
        print("smoke: slideshow moved on \(smokeMoves - before) times; display kept awake: \(displayAwake != 0 ? "yes" : "no")")

        nextOn = false
        repeatOn = true
        viewing = video
        await wait(1)
        NotificationCenter.default.post(name: .smokeSetVideoRate, object: NSNumber(value: 1.5))
        NotificationCenter.default.post(name: .smokeZoomVideo, object: NSNumber(value: 2.5))
        await wait(4)
        print("smoke: video speed taken from the player: \(videoSpeed)")
        // Looped (Repeat) at least once by now: the zoom stays.
        print("smoke: after looping,"); fflush(stdout)
        NotificationCenter.default.post(name: .smokeZoomVideo, object: nil)

        repeatOn = false
        nextOn = true
        let atVideo = smokeMoves
        await wait(3)
        print("smoke: moved on after the video ended: \(smokeMoves > atVideo ? "yes" : "no")")
        // Opened again — a new player — it starts unzoomed.
        nextOn = false
        viewing = video
        // Time for the video to load and its view to appear, on a busy run too.
        await wait(2.5)
        print("smoke: opened again,"); fflush(stdout)
        NotificationCenter.default.post(name: .smokeZoomVideo, object: nil)
        await wait(0.5)
        viewing = nil
        print("smoke: closing the viewer ended the slideshow: \(!slideshowOn && displayAwake == 0 ? "yes" : "no")")
        fflush(stdout)
    }

    /// Hook for `Scripts/smoke-test.sh`: goes to a folder, shows only photos
    /// and opens one, then reports where — for the next launch to open there.
    /// `PHOTOVAULT_SMOKE_LEAVE=1`; inert otherwise.
    private var smokeLeft = false
    private func leaveForSmokeTest() async {
        guard !smokeLeft, ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_LEAVE"] == "1",
              let folder = folderTree?.children?.first(where: { $0.directCount > 1 })?.id else { return }
        smokeLeft = true
        func wait(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        scope = .folder(folder)
        await wait(1.5)
        filter = .photos
        await wait(1.5)
        guard items.count > 1 else { return print("smoke: left nowhere: too few photos") }
        select(only: items[1].id)
        viewing = items[1]
        await wait(1.5)
        print("smoke: left at \(scope.storageValue) filter \(filter.rawValue) viewing \(items[1].id)")
        fflush(stdout)
    }

    /// Hook for `Scripts/smoke-test.sh`: presses the keyboard shortcuts as
    /// key events sent to the app itself — through the menus, as typing them
    /// would, without the Accessibility permission synthetic input needs — and
    /// reports what each did. `PHOTOVAULT_SMOKE_KEYS=1`; inert otherwise.
    private var smokeKeysChecked = false
    private func checkKeysForSmokeTest() async {
        guard !smokeKeysChecked, ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_KEYS"] == "1",
              scope == .all, viewing == nil, let photo = items.first(where: { $0.mediaType == .photo }) else { return }
        smokeKeysChecked = true
        func wait(_ seconds: Double = 0.6) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func press(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) async {
            // The app may be in the background — the test doesn't take the
            // keyboard from whoever is using the Mac — so the window is found
            // rather than asked for as the key window. A sheet on it gets the keys.
            guard let window = Self.typingWindow,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: chars,
                                               charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: code)
            else { return print("smoke: keys: no key window") }
            // In the background AppKit doesn't bring the menu bar up to date
            // between events, as it does for the app in front; this does.
            func update(_ menu: NSMenu) {
                menu.delegate?.menuNeedsUpdate?(menu)
                menu.update()
                menu.items.compactMap(\.submenu).forEach(update)
            }
            NSApp.mainMenu.map(update)
            NSApp.sendEvent(event)
            await wait()
        }
        /// Menu items sharing a key, by their titles: only one of them would ever fire.
        func clashes() -> [String] {
            func walk(_ menu: NSMenu) -> [(String, String)] {
                menu.items.flatMap { item -> [(String, String)] in
                    var out: [(String, String)] = []
                    // An upper-case key means ⇧ too. The system's Services
                    // items are left out: they're whatever other apps add.
                    let key = item.keyEquivalent, shift = key != key.lowercased()
                    let mask = item.keyEquivalentModifierMask.union(shift ? .shift : [])
                    if !key.isEmpty { out.append(("\(key.lowercased()) \(mask.rawValue)", item.title)) }
                    guard item.submenu != NSApp.servicesMenu else { return out }
                    return out + (item.submenu.map(walk) ?? [])
                }
            }
            return Dictionary(grouping: NSApp.mainMenu.map(walk) ?? [], by: \.0).values
                .filter { $0.count > 1 }.map { $0.map(\.1).joined(separator: " / ") }
        }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
        }
        func report(_ what: String, _ ok: Bool) { print("smoke: key \(what): \(ok ? "yes" : "no")"); fflush(stdout) }
        let arrows: NSEvent.ModifierFlags = [.function, .numericPad]
        let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))

        select(only: photo.id)
        await wait()
        report("no two menu items share a shortcut in the grid \(clashes())", clashes().isEmpty)
        let wasFavorite = photo.favorite
        await press(".", 47)
        report(". adds to favorites in the grid", items.first { $0.id == photo.id }?.favorite == !wasFavorite)
        await press(".", 47)
        report(". again takes it back off", items.first { $0.id == photo.id }?.favorite == wasFavorite)

        await press("2", 19, .command)
        report("⌘2 shows only photos", filter == .photos)
        await press("1", 18, .command)
        report("⌘1 shows all", filter == .all)

        let size = thumbnailSize
        await press("=", 24, .command)
        let biggerWithEquals = thumbnailSize > size
        if !biggerWithEquals { await press("+", 24, [.command, .shift]) }
        report("⌘+ makes thumbnails bigger (⌘= \(biggerWithEquals ? "too" : "alone doesn't"))", thumbnailSize > size)
        await press("-", 27, .command)
        report("⌘− makes them smaller again", abs(thumbnailSize - size) < 2)
        setThumbnailSize(size)

        let whole = showWholePhotos
        await press("0", 29, .command)
        report("⌘0 shows whole photos", showWholePhotos != whole)
        if showWholePhotos != whole { toggleWholePhotos() }
        report("and the window is still open", Self.typingWindow != nil)

        // The arrow keys move the one photo picked.
        if items.count > 2 {
            let columns = GridView.columns(width: gridWidth, cellSize: thumbnailSize)
            select(only: items[0].id)
            let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
            let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
            func picked() -> Int { selection.count == 1 ? items.firstIndex { $0.id == selection.first } ?? -1 : -1 }
            await press(right, 124, arrows)
            report("→ picks the next photo in the grid", picked() == 1)
            if items.count > columns + 1 {
                await press(down, 125, arrows)
                report("↓ the one below it (\(columns) to a row)", picked() == 1 + columns)
                await press(up, 126, arrows)
                report("↑ back up", picked() == 1)
            }
            await press(left, 123, arrows)
            report("← back to the first", picked() == 0)
            await press(left, 123, arrows)
            report("and no further", picked() == 0)
            // Far down, the grid scrolls to show it.
            let far = items.count - 1
            select(only: items[far - 1].id)
            await press(right, 124, arrows)
            report("→ at the end of the grid scrolls to show it (place \(gridTop.map(String.init) ?? "-"))",
                   picked() == far && gridTop.flatMap { id in items.firstIndex { $0.id == id } }.map { $0 > far - 4 * columns } == true)
        }

        if let before = sort, before.order != .random {
            await press(before.ascending ? down : up, before.ascending ? 125 : 126, arrows.union([.command, .option]))
            report("⌥⌘↑/↓ turns the sort round", sort?.ascending == !before.ascending)
            await press(before.ascending ? up : down, before.ascending ? 126 : 125, arrows.union([.command, .option]))
            report("and back", sort?.ascending == before.ascending)
        }

        clearSelection()
        // Big thumbnails, so even a small test vault is taller than the window.
        let top = gridTop, speed = scrollSpeed
        setThumbnailSize(GridView.sizeRange.upperBound * 0.75)
        await wait(1.5)
        setScrollSpeed(80)
        await press(" ", 49)
        report("Space starts scrolling by itself", autoScrolling)
        await wait(3)
        report("the grid moved down (\(top.map(String.init) ?? "-") then \(gridTop.map(String.init) ?? "-"))", gridTop != top)
        await press(" ", 49)
        report("Space pauses it", !autoScrolling)
        // Its place is where it stopped: away and back, the grid is there.
        func offset() -> Int { Self.typingWindow?.contentView.flatMap(Self.scrollOffsets(in:))?.split(separator: ",").compactMap { Int($0) }.max() ?? -1 }
        let stoppedAt = offset()
        await wait(2.5)
        scope = .favorites
        await wait(1.5)
        scope = .all
        await wait(2)
        report("its place is kept (\(stoppedAt) then \(offset()))", abs(offset() - stoppedAt) < Int(thumbnailSize) + 8)
        setScrollSpeed(speed)
        await press(" ", 49)
        await press("x", 7)
        report("a key pauses it too", !autoScrolling)
        // Left running, it stops at the bottom. (From near it: a big vault
        // takes minutes to scroll through.)
        setScrollSpeed(80)
        if let grid = Self.typingWindow?.contentView.flatMap(scrollViews(in:))?
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
           let document = grid.documentView {
            grid.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - grid.contentView.bounds.height - 2000))
            grid.reflectScrolledClipView(grid.contentView)
        }
        await wait(1.5)
        await press(" ", 49)
        for _ in 0..<40 where autoScrolling { await wait(0.5) }
        report("it stops by itself at the end", !autoScrolling)
        let end = offset()
        await press(" ", 49)
        report("started at the end, it goes back to the top (\(end) then \(offset()))", autoScrolling && offset() < end - 50)
        await press(" ", 49)
        setScrollSpeed(speed)

        // Changing the sort leaves the scroll where it is.
        if let grid = Self.typingWindow?.contentView.flatMap(scrollViews(in:))?
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
           let document = grid.documentView, let before = sort, before.order != .random {
            let y = (document.frame.height - grid.contentView.bounds.height) / 2
            grid.contentView.scroll(to: NSPoint(x: 0, y: y))
            grid.reflectScrolledClipView(grid.contentView)
            await wait(1)
            let held = Int(grid.contentView.bounds.origin.y)
            await press(before.ascending ? down : up, before.ascending ? 125 : 126, arrows.union([.command, .option]))
            await wait(1.5)
            report("the scroll stays put when the sort turns round (\(held) then \(offset()))", abs(offset() - held) <= 2)
            await press(before.ascending ? up : down, before.ascending ? 126 : 125, arrows.union([.command, .option]))
            await wait(1.5)
            report("and when it turns back (\(offset()))", abs(offset() - held) <= 2)
        }
        setThumbnailSize(size)

        // Each view keeps its own All, Photos or Videos.
        await press("2", 19, .command)
        scope = .favorites
        await wait(1.5)
        let favoritesFilter = filter
        await press("3", 20, .command)
        scope = .all
        await wait(1.5)
        report("All Media comes back showing only photos, as left", filter == .photos)
        scope = .favorites
        await wait(1.5)
        report("Favorites comes back showing only videos, as left (it opened on \(favoritesFilter))", filter == .videos)
        await press("1", 18, .command)
        scope = .all
        await wait(1.5)
        await press("1", 18, .command)
        report("and All Media shows all again", filter == .all)

        // Plain keys belong to a text field being typed in.
        await press("n", 45, .command)
        report("⌘N opens New Album", newAlbumSheet != nil)
        await wait()
        for (c, code) in [("a", UInt16(0)), (".", 47), (" ", 49), ("r", 15), ("s", 1), ("n", 45)] { await press(c, code) }
        let sheet = NSApp.windows.first { $0.isSheet && $0.isVisible }
        let typed = (sheet?.firstResponder as? NSTextView)?.string ?? "-"
        report("a name typed with . Space R S N is kept whole (\"\(typed)\")", typed == "a. rsn")
        report("and favorites and scrolling were left alone", items.first { $0.id == photo.id }?.favorite == wasFavorite && !autoScrolling)
        await press("\u{1b}", 53)
        report("Esc closes it", newAlbumSheet == nil)

        select(only: photo.id)
        viewing = photo
        await wait(1)
        report("or in the viewer \(clashes())", clashes().isEmpty)
        await press("r", 15)
        report("R turns Repeat on in the viewer", repeatOn)
        await press("r", 15)
        await press("n", 45)
        report("N turns Play Next on", nextOn)
        await press("n", 45)
        await press(".", 47)
        report(". adds the photo on screen to favorites", items.first { $0.id == photo.id }?.favorite == !wasFavorite)
        await press(".", 47)
        await press("\u{1b}", 53)
        report("Esc goes back to the library", viewing == nil)

        // Shift on its own opens the photo picked, and goes back again.
        func tapShift() async {
            for down in [true, false] {
                guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: down) else { return }
                cg.type = .flagsChanged
                cg.flags = down ? .maskShift : []
                if let event = NSEvent(cgEvent: cg) { NSApp.sendEvent(event) }
            }
            await wait(1)
        }
        select(only: photo.id)
        await tapShift()
        report("⇧ opens the photo picked", viewing?.id == photo.id)
        await tapShift()
        report("⇧ again goes back to the library", viewing == nil)
        if let video = items.first(where: { $0.mediaType == .video && $0.playable }) {
            select(only: video.id)
            viewing = video
            await wait(1.5)
            await press("\u{1b}", 53)
            report("Esc goes back from a playing video", viewing == nil)
        }
        report("Repeat and Play Next are off again", !repeatOn && !nextOn)

        // With Play Next on, the arrows still go through the view in its
        // order — a video's too, which took them for itself.
        let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        // Each followed by a photo: a short test video next would end, and
        // Play Next would rightly move on from it by itself.
        func followedByPhoto(_ kind: MediaType) -> PhotoItem? {
            items.indices.dropLast().first { items[$0].mediaType == kind && items[$0].playable && items[$0 + 1].mediaType == .photo }
                .map { items[$0] }
        }
        for item in [followedByPhoto(.photo), followedByPhoto(.video)].compactMap({ $0 }) {
            guard let i = items.firstIndex(where: { $0.id == item.id }), i + 1 < items.count else { continue }
            select(only: item.id)
            viewing = item
            // Play Next on only now: a short test video could end while it
            // loaded, and Play Next would rightly move on by itself.
            await wait(1.5)
            nextOn = true
            await press(right, 124, arrows)
            report("→ with Play Next on goes to the next \(item.mediaType == .video ? "after a video" : "after a photo") (\(item.id) to \(viewing.map { String($0.id) } ?? "none"), expected \(items[i + 1].id))", viewing?.id == items[i + 1].id)
            nextOn = false
            viewing = nil
            await wait(0.5)
        }
        report("the photo is as it was", items.first { $0.id == photo.id }?.favorite == wasFavorite)
    }

    /// The scroll views' offsets under `view`, for the smoke test's log.
    static func scrollOffsets(in view: NSView) -> String? {
        if let scroll = view as? NSScrollView { return "\(Int(scroll.contentView.bounds.origin.y))" }
        let found = view.subviews.compactMap(scrollOffsets(in:))
        return found.isEmpty ? nil : found.joined(separator: ",")
    }

    /// Everything that must happen before the volume can go away. Called from
    /// the unmount notification as well as from quit, because Finder can start
    /// an eject without asking us first.
    /// `windowFrame`, when given, is saved to the catalog before it closes.
    func shutdown(windowFrame: String? = nil) {
        cache.removeAll()
        // Stop a running scan. The Store's close() waits for it to wind down,
        // which needs nothing from the main thread blocked below.
        scanTask?.cancel()
        guard let store else { return }
        self.store = nil

        // Blocking the main thread here is deliberate. This runs from
        // applicationWillTerminate and from willUnmountNotification, and both
        // of those are races: fire the close off as a detached task and the
        // process exits — or the volume vanishes — long before the WAL
        // checkpoint lands, leaving the vault as a database plus a stale WAL.
        // That is precisely the state a copied vault must never be in.
        //
        // No deadlock risk: the Store actor runs on the cooperative pool and
        // has no work that needs the main thread. The timeout is a backstop for
        // a scan still in flight, which close() has to queue behind.
        let done = DispatchSemaphore(value: 0)
        let placeKey = self.placeKey, place = places[placeKey]
        placeSave?.cancel()
        Task.detached(priority: .userInitiated) {
            if let windowFrame { await store.setSetting("window.frame", windowFrame) }
            if let place { await store.setSetting(placeKey, String(place)) }
            await store.close()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            NSLog("PhotoVault: catalog close timed out; the next mount will rescan in full")
        }
    }

    func reload() async {
        guard let store else { return }
        do {
            let scope = self.scope, filter = self.filter
            // Everything is fetched first and published together, and only
            // what changed: each published value redraws the whole window, the
            // grid's every photo included, and publishing them one by one
            // between catalog reads made switching views take a quarter of a
            // second on a library of thousands of photos.
            let sort = try await store.sortSetting(for: scope)
            let newItems = try await store.items(scope: scope, filter: filter, sort: sort?.order ?? .date,
                                                 ascending: sort?.ascending ?? true, seed: sort?.seed ?? 0, groups: tagGroups)
            let albums = try await store.albums(), smartAlbums = try await store.smartAlbums()
            let total = try await store.photoCount()
            let trash = try await store.trashCount()
            let tree = try await store.folderTree()
            var counts: [Int64: Int] = [:]
            for a in albums { counts[a.id] = try await store.albumCount(a.id) }

            if self.sort != sort { self.sort = sort }
            if items != newItems { items = newItems }
            // Rows appear and disappear in the sidebar without animating: an
            // animated removal could leave the old row's text behind.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                if self.albums != albums { self.albums = albums }
                if self.smartAlbums != smartAlbums { self.smartAlbums = smartAlbums }
            }
            if totalCount != total { totalCount = total }
            if trashCount != trash { trashCount = trash }
            if folderTree != tree { folderTree = tree }
            if albumCounts != counts { albumCounts = counts }
            // `viewing` is a value copy taken when the photo was opened. Without
            // this it keeps the favorite flag it had at that moment, so the
            // heart in the viewer only caught up on close and reopen.
            // A photo can also drop out of the current view while open — unfavorite
            // it while browsing Favorites — so fall back to its row by id. Only
            // when the row is gone altogether does the viewer close.
            if let open = viewing {
                if let row = items.first(where: { $0.id == open.id }) {
                    viewing = row
                } else {
                    viewing = try await store.photo(id: open.id)
                }
            }
            sel.intersect(with: order)
            var revealing = false
            if let id = pendingReveal, items.contains(where: { $0.id == id }) {
                pendingReveal = nil
                revealing = true
                select(only: id)
                scrollRequest = ScrollRequest(id: id)
            }
            let shown = Shown(scope: scope, filter: filter)
            if lastShown != shown, self.scope == scope, self.filter == filter {
                lastShown = shown
                await restorePlace(of: scope, filter: filter, revealing: revealing)
            }
            if !scanning { status = "\(totalCount) items" }
            if !smokeFirstItems, !items.isEmpty {
                smokeFirstItems = true
                SmokeHooks.mark("first items loaded (\(items.count))")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rescan(full: Bool) {
        runScan(full: full)
    }

    // MARK: - Tags

    /// Tag counts are a query over every tag in the vault, so they're
    /// refreshed after scans and tag changes rather than on every reload.
    func reloadTags() async {
        guard let store else { return }
        tagsVersion += 1
        let fallback = Bundle.main.url(forResource: "Tag Groups", withExtension: "txt")
        tagGroups = await store.tagGroups(fallback: fallback)
        tagCounts = (try? await store.tagCounts()) ?? []
        hiddenTags = (try? await store.hiddenTags()) ?? []
        tagByKey = Dictionary(tagCounts.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        if let saved = await store.setting("tags.showR18") {
            showR18 = saved == "1"
        } else {
            // Nothing chosen yet: on if a smart album already uses R18 tags —
            // whoever made it clearly uses them.
            let albums = (try? await store.smartAlbums()) ?? []
            showR18 = albums.contains { $0.rules.map(tagGroups.usesRestricted) ?? false }
        }
        regroupTags()
    }

    private func regroupTags() {
        var byGroup: [String: [TagCount]] = [:]
        for tag in tagCounts where !hiddenTags.contains(tag.key) && !isHiddenTag(tag.key) {
            for group in tagGroups.groups(of: tag.key) { byGroup[group, default: []].append(tag) }
        }
        tagGroupLists = (tagGroups.names + [TagGroups.other]).compactMap { name in
            byGroup[name].map { TagGroupList(name: name, tags: $0) }
        }
    }

    /// The most common visible tags, for the filter panel's first row.
    func mostUsedTags(_ n: Int) -> [TagCount] {
        Array(tagCounts.lazy.filter { !self.hiddenTags.contains($0.key) && !self.isHiddenTag($0.key) }.prefix(n))
    }

    /// How many tags the filter can offer.
    var offeredTagCount: Int { tagCounts.filter { !isHiddenTag($0.key) }.count }

    // MARK: - R18

    /// Image › Classifier › Show R18 Tags. Off, tags in the R18 group are left
    /// out of a photo's details and the smart album filter's lists — only the
    /// tags: the photos still show, and smart albums still find them. Kept in
    /// the vault's catalog.
    @Published private(set) var showR18 = false

    func setShowR18(_ on: Bool) {
        guard on != showR18 else { return }
        showR18 = on
        regroupTags()
        Task { await store?.setSetting("tags.showR18", on ? "1" : "0") }
    }

    /// Whether a tag is kept out of sight: R18, with Show R18 Tags off.
    func isHiddenTag(_ key: String) -> Bool { !showR18 && tagGroups.isRestricted(key) }

    func tagName(_ key: String) -> String { tagByKey[key]?.name ?? key }

    func setTagHidden(_ key: String, _ hidden: Bool) async {
        guard let store else { return }
        try? await store.setTagHidden(key, hidden)
        await reloadTags()
    }

    // MARK: - Smart albums

    var currentSmartAlbum: SmartAlbum? {
        guard case .smart(let id) = scope else { return nil }
        return smartAlbums.first { $0.id == id }
    }

    /// A new smart album, opened with its filter panel showing.
    func newSmartAlbum(named name: String) async {
        guard let store, let id = try? await store.createSmartAlbum(name: name, rules: TagRules()) else { return }
        smartAlbums = (try? await store.smartAlbums()) ?? smartAlbums
        scope = .smart(id)
        editingFilter = true
    }

    func updateRules(_ id: Int64, _ rules: TagRules) async {
        guard let store else { return }
        try? await store.updateSmartAlbum(id, rules: rules)
        await reload()
    }

    func renameSmartAlbum(_ id: Int64, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let store, !name.isEmpty else { return }
        try? await store.updateSmartAlbum(id, name: name)
        await reload()
    }

    func deleteSmartAlbum(_ id: Int64) async {
        guard let store else { return }
        // Move off the album before its row goes, so the sidebar never removes
        // the selected row.
        if case .smart(let current) = scope, current == id {
            scope = .all
            await reload()
        }
        try? await store.deleteSmartAlbum(id)
        await reload()
    }

    func renameAlbum(_ id: Int64, to name: String) async {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let store, !name.isEmpty else { return }
        try? await store.renameAlbum(id, to: name)
        await reload()
    }

    // MARK: - Tagging

    /// More photos than this and PhotoVault asks first: nothing in them
    /// changes, but a long run keeps the Mac busy.
    static let askAbove = 100
    /// Until a run has measured this Mac: JoyTag and preparing its input, per
    /// photo.
    static let defaultSecondsPerPhoto = 0.17

    var canTag: Bool { joyTagFiles != nil }

    private func locateTagger(root: URL) {
        guard #available(macOS 15.0, *) else {
            taggerUnavailable = "JoyTag needs macOS 15 or later."
            return
        }
        do {
            joyTagFiles = try JoyTagFiles.load(from: JoyTagFiles.folder(in: root))
            taggerUnavailable = nil
        } catch {
            joyTagFiles = nil
            taggerUnavailable = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// After a scan: tag the photos JoyTag hasn't seen — straight away for a
    /// few, after asking for a large run.
    private func considerTagging() async {
        guard !taggingDeclined else { return }
        await offerTagging(ids: nil, quietlyIfNone: true)
    }

    /// Image ▸ Classifier ▸ Tag Untagged Photos.
    func tagUntaggedCommand() {
        Task { await offerTagging(ids: nil, quietlyIfNone: false) }
    }

    /// Image ▸ Classifier ▸ Re-classify Selection With ▸ JoyTag, on the photo
    /// open in the viewer or the grid selection; and Re-tag in the grid's menu.
    func retagCommand() {
        retag(viewing.map { [$0] } ?? selectedItems)
    }

    func retag(_ targets: [PhotoItem]) {
        guard !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        Task { await offerTagging(ids: ids, quietlyIfNone: false) }
    }

    var canRetagCurrent: Bool {
        canTag && !scanning && (viewing.map { !$0.trashed } ?? !selection.isEmpty) && scope != .trash
    }

    private func offerTagging(ids: [Int64]?, quietlyIfNone: Bool) async {
        guard let store, joyTagFiles != nil, scanTask == nil, taggingQuestion == nil else { return }
        guard let plan = try? await store.classificationPlan(ids: ids, prefix: JoyTag.prefix), plan.photos > 0 else {
            if !quietlyIfNone { status = ids == nil ? "Every photo is tagged" : "Nothing to re-tag" }
            return
        }
        guard plan.photos > Self.askAbove else {
            startTagging(ids: ids)
            return
        }
        let perPhoto = await store.setting("tagging.secondsPerPhoto").flatMap(Double.init) ?? Self.defaultSecondsPerPhoto
        taggingQuestion = Self.question(ids: ids, plan: plan, secondsPerPhoto: perPhoto)
    }

    func answerTagging(_ question: TaggingQuestion, tag: Bool) {
        taggingQuestion = nil
        if tag {
            startTagging(ids: question.ids)
        } else if question.ids == nil {
            taggingDeclined = true
        }
    }

    static func question(ids: [Int64]?, plan: Store.ClassifyPlan, secondsPerPhoto: Double) -> TaggingQuestion {
        let n = NumberFormatter.localizedString(from: NSNumber(value: plan.photos), number: .decimal)
        var message = ids == nil
            ? "JoyTag looks at each photo and names what it sees. Its tags are kept in PhotoVault's catalog; "
                + "the photos themselves aren't changed."
            : "Their JoyTag tags are replaced. The photos themselves aren't changed."
        message += " It takes \(roughly(Double(plan.photos) * secondsPerPhoto))."
        message += ids == nil
            ? " You can stop at any time; it carries on the next time PhotoVault opens."
            : " You can stop at any time; photos already re-tagged keep their new tags."
        return TaggingQuestion(ids: ids,
                               title: ids == nil ? "Tag \(n) photos with JoyTag?" : "Re-tag \(n) photos with JoyTag?",
                               message: message,
                               action: ids == nil ? "Tag Photos" : "Re-tag Photos")
    }

    static func roughly(_ seconds: Double) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 90 { return minutes == 1 ? "about a minute" : "about \(minutes) minutes" }
        let hours = seconds / 3600
        return hours < 10 ? String(format: "about %.1f hours", hours) : String(format: "about %.0f hours", hours)
    }

    /// Runs JoyTag as a scan runs: in the background, with Stop, and the quit
    /// question while it works. The model is loaded for the run and released
    /// after it (it takes about 400 MB of memory).
    func startTagging(ids: [Int64]?) {
        guard let store, let files = joyTagFiles, scanTask == nil else { return }
        guard #available(macOS 15.0, *) else { return }
        scanning = true
        job = ids == nil ? .tagging : .retagging
        scanProgress = nil
        status = "Loading JoyTag…"
        activity.fast = false
        let pace = activity.pace
        let sink = progressSink()
        scanTask = Task { [weak self] in
            var stopped = false
            var result: Store.ClassifyResult?
            do {
                var classifier: TagClassifier = try await Task.detached(priority: .utility) {
                    try JoyTagClassifier(files: files)
                }.value
                // Test-only: the smoke test slows tagging so it can stop a run part-way.
                if ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_SLOW_TAGGING"] == "1" {
                    classifier = SlowedClassifier(base: classifier, nanoseconds: 700_000_000)
                }
                try Task.checkCancellation()
                result = try await store.classify(ids: ids, with: classifier, pace: pace, progress: sink)
            } catch is CancellationError {
                stopped = true
            } catch {
                self?.errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            guard let self else { return }
            self.scanning = false
            self.scanProgress = nil
            self.scanTask = nil
            self.activity.fast = false
            await self.reloadTags()
            await self.reload()
            if stopped {
                self.status = ids == nil ? "Tagging stopped — it carries on next time PhotoVault opens" : "Re-tagging stopped"
            } else if let result {
                await self.report(result, retag: ids != nil)
            }
        }
    }

    /// For `Scripts/smoke-test.sh` only: JoyTag with a pause before each photo.
    private struct SlowedClassifier: TagClassifier {
        let base: TagClassifier
        let nanoseconds: UInt64
        var record: ToolRecord { base.record }
        var parallelism: Int { base.parallelism }
        func classify(thumbnail: Data, fast: Bool) async throws -> [ScoredTag] {
            try await Task.sleep(nanoseconds: nanoseconds)
            return try await base.classify(thumbnail: thumbnail, fast: fast)
        }
    }

    private func report(_ result: Store.ClassifyResult, retag: Bool) async {
        let n = result.photos
        status = "\(retag ? "Re-tagged" : "Tagged") \(n) \(n == 1 ? "photo" : "photos") with JoyTag"
        if !result.failures.isEmpty {
            errorMessage = "\(result.failures.count) photo(s) couldn't be tagged:\n" + result.failures.prefix(5).joined(separator: "\n")
        }
        // A run long enough to be a fair measure sets the next estimate.
        if n >= 20, let store {
            await store.setSetting("tagging.secondsPerPhoto", String(format: "%.3f", result.seconds / Double(n)))
        }
        print("smoke: tagged \(n), failures \(result.failures.count)")
        fflush(stdout)
    }

    // MARK: - Thumbnail size

    /// Saved half a second after the slider or pinch comes to rest.
    /// View › Show Whole Photos: each thumbnail uncropped, at its own shape,
    /// rather than a square from its middle. Saved per vault.
    @Published private(set) var showWholePhotos = false

    func toggleWholePhotos() {
        showWholePhotos.toggle()
        let on = showWholePhotos
        Task { await store?.setSetting("grid.whole", on ? "1" : "0") }
    }

    func setThumbnailSize(_ size: Double) {
        thumbnailSize = size
        thumbnailSizeSave?.cancel()
        guard let store else { return }
        thumbnailSizeSave = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await store.setSetting("grid.size", String(Int(size)))
        }
    }

    // MARK: - Properties panel

    func toggleProperties() {
        showProperties.toggle()
        let open = showProperties
        guard let store else { return }
        Task { await store.setSetting("viewer.properties", open ? "1" : "0") }
    }

    func albumNames(for item: PhotoItem) async -> [String] {
        (try? await store?.albumNames(containing: item.id)) ?? []
    }

    func tags(for item: PhotoItem) async -> [PhotoTag] {
        (try? await store?.tags(for: item.id)) ?? []
    }

    func classifications(for item: PhotoItem) async -> [Classification] {
        (try? await store?.classifications(for: item.id)) ?? []
    }

    // MARK: - Order and Show in Library

    func setSortOrder(_ order: PhotoOrder) {
        guard var sort, order != sort.order else { return }
        sort.order = order
        // Random: a new shuffle each time it's chosen.
        if order == .random { sort.seed = UInt64.random(in: 1...UInt64.max) }
        save(sort)
    }

    /// Oldest first ⇄ newest first, or A to Z ⇄ Z to A — or, in Random,
    /// another shuffle.
    func toggleSortDirection() {
        guard var sort else { return }
        if sort.order == .random {
            sort.seed = UInt64.random(in: 1...UInt64.max)
        } else {
            sort.ascending.toggle()
        }
        save(sort)
    }

    /// Counts sort changes made here, so the grid can keep its scroll where
    /// it is while the photos reorder under it.
    @Published private(set) var sortChanges = 0

    private func save(_ sort: SortSetting) {
        guard let store else { return }
        let scope = self.scope
        sortChanges += 1
        self.sort = sort
        Task {
            await store.setSortSetting(sort, for: scope)
            await reload()
        }
    }

    /// Open All Media at `item`, selected and scrolled into view, so
    /// the photos around it — in the vault's order — are right there.
    func showInLibrary(_ item: PhotoItem) {
        guard !item.trashed else { return }
        pendingReveal = item.id
        viewing = nil
        // A filter that would hide it (Photos only, for a video) is cleared —
        // All Media's own, once it's open.
        if scope != .all {
            revealing = item.mediaType
            scope = .all      // reloads, and the reload reveals it
        } else if (filter == .photos && item.mediaType == .video) || (filter == .videos && item.mediaType == .photo) {
            filter = .all
        } else {
            Task { await reload() }
        }
    }

    /// The photo Show in Library would act on: the one open in the viewer, or
    /// a single selected photo outside All Media.
    var showInLibraryTarget: PhotoItem? {
        if let open = viewing { return open.trashed ? nil : open }
        guard scope != .all, scope != .trash, selection.count == 1 else { return nil }
        return selectedItems.first
    }

    // MARK: - Thumbnails

    func cachedThumb(_ item: PhotoItem) -> CGImage? { cache.image(for: item.id) }

    /// Cells call this on appear. The `inFlight` set keeps a fast scroll from
    /// queueing the same read a dozen times as a cell bounces in and out.
    func loadThumb(_ item: PhotoItem) {
        guard item.hasThumb, cache.image(for: item.id) == nil, !inFlight.contains(item.id), let store else { return }
        inFlight.insert(item.id)
        Task {
            defer { inFlight.remove(item.id) }
            guard let data = try? await store.thumbnailData(for: item),
                  let cg = ThumbnailCache.decode(data) else { return }
            cache.insert(cg, for: item.id)
            // Nudge the cells; each re-reads from the cache synchronously.
            thumbs.objectWillChange.send()
        }
    }

    // MARK: - Selection

    typealias ClickKind = Selection.Click

    private var order: [Int64] { items.map(\.id) }

    func handleClick(on item: PhotoItem, kind: ClickKind) {
        sel.click(item.id, kind: kind, in: order)
    }

    /// What a right-click on `item` should act on: the whole selection when the
    /// item is part of it, otherwise just that item. Read-only by design — the
    /// context menu body is evaluated during a render pass, and publishing from
    /// there sends SwiftUI into a rebuild loop.
    func contextTargets(for item: PhotoItem) -> [PhotoItem] {
        sel.contains(item.id) && sel.count > 1 ? selectedItems : [item]
    }

    func selectAll() { sel.selectAll(order) }

    func clearSelection() { sel.clear() }

    func select(only id: Int64) { sel.click(id, kind: .replace, in: order) }

    var selectedItems: [PhotoItem] {
        items.filter { selection.contains($0.id) }
    }

    // MARK: - Commands

    func toggleFavorite() async {
        guard let store, !selection.isEmpty else { return }
        let ids = Array(selection)
        let makeFavorite = !items.filter { ids.contains($0.id) }.allSatisfy(\.favorite)
        try? await store.setFavorite(makeFavorite, for: ids)
        await reload()
    }

    /// Favorite exactly the photo on screen, regardless of what the grid has
    /// selected behind it.
    func toggleFavoriteForViewing() async {
        guard let store, let open = viewing else { return }
        try? await store.setFavorite(!open.favorite, for: [open.id])
        await reload()
    }

    /// Photos waiting on the name for a New Album… chosen from Add to Album.
    @Published var newAlbumRequest: NewAlbumRequest?

    struct NewAlbumRequest: Identifiable {
        let id = UUID()
        let photoIDs: [Int64]
    }

    /// A regular album holding `photoIDs`, in that order. The view stays where
    /// it is, so more photos can go on being added.
    func newAlbum(named name: String, adding photoIDs: [Int64]) async {
        guard let store else { return }
        guard let id = try? await store.createAlbum(named: name) else { return }
        if !photoIDs.isEmpty { try? await store.addToAlbum(id, photoIDs: photoIDs) }
        await reload()
    }

    func newAlbum(named name: String) async {
        guard let store else { return }
        guard let id = try? await store.createAlbum(named: name) else { return }
        if !selection.isEmpty {
            try? await store.addToAlbum(id, photoIDs: Array(selection))
        }
        await reload()
    }

    func setFavorite(_ on: Bool, for targets: [PhotoItem]) async {
        guard let store, !targets.isEmpty else { return }
        try? await store.setFavorite(on, for: targets.map(\.id))
        await reload()
    }

    func addToAlbum(_ albumID: Int64, items targets: [PhotoItem]) async {
        guard let store, !targets.isEmpty else { return }
        try? await store.addToAlbum(albumID, photoIDs: targets.map(\.id))
        await reload()
    }

    func removeFromAlbum(_ albumID: Int64, items targets: [PhotoItem]) async {
        guard let store, !targets.isEmpty else { return }
        try? await store.removeFromAlbum(albumID, photoIDs: targets.map(\.id))
        await reload()
    }

    func addSelectionToAlbum(_ albumID: Int64) async {
        guard let store, !selection.isEmpty else { return }
        try? await store.addToAlbum(albumID, photoIDs: Array(selection))
        await reload()
    }

    func removeSelectionFromCurrentAlbum() async {
        guard let store, case .album(let id) = scope, !selection.isEmpty else { return }
        try? await store.removeFromAlbum(id, photoIDs: Array(selection))
        await reload()
    }

    /// A drag in the sidebar: `dragged` put just before or after `target`, and
    /// the new order kept in the vault's catalog.
    func moveAlbum(_ dragged: Int64, beside target: Int64, after: Bool) {
        guard let list = Self.moving(dragged, beside: target, after: after, in: albums) else { return }
        albums = list
        Task {
            try? await store?.setAlbumOrder(list.map(\.id))
            await reload()
        }
    }

    func moveSmartAlbum(_ dragged: Int64, beside target: Int64, after: Bool) {
        guard let list = Self.moving(dragged, beside: target, after: after, in: smartAlbums) else { return }
        smartAlbums = list
        Task {
            try? await store?.setSmartAlbumOrder(list.map(\.id))
            await reload()
        }
    }

    /// `list` with `dragged` moved to just before or after `target`; nil if
    /// either isn't in it.
    static func moving<T: Identifiable>(_ dragged: T.ID, beside target: T.ID, after: Bool, in list: [T]) -> [T]? {
        guard dragged != target, let from = list.firstIndex(where: { $0.id == dragged }),
              list.contains(where: { $0.id == target }) else { return nil }
        var out = list
        let item = out.remove(at: from)
        guard let at = out.firstIndex(where: { $0.id == target }) else { return nil }
        out.insert(item, at: after ? at + 1 : at)
        return out
    }

    /// Duplicate Album: a copy named "<name> (copy)", just below it, shown.
    func duplicateAlbum(_ id: Int64) async {
        guard let store, let copy = try? await store.duplicateAlbum(id) else { return }
        await reload()
        scope = .album(copy)
    }

    func duplicateSmartAlbum(_ id: Int64) async {
        guard let store, let copy = try? await store.duplicateSmartAlbum(id) else { return }
        await reload()
        scope = .smart(copy)
    }

    /// Several albums and smart albums at once, picked with ⌘ or ⇧.
    func deleteAlbums(_ doomed: [LibraryScope]) async {
        guard let store else { return }
        // Off any of them first, so the sidebar never removes the selected row.
        if doomed.contains(scope) {
            scope = .all
            await reload()
        }
        for item in doomed {
            switch item {
            case .album(let id): try? await store.deleteAlbum(id)
            case .smart(let id): try? await store.deleteSmartAlbum(id)
            default: break
            }
        }
        await reload()
    }

    func deleteAlbum(_ id: Int64) async {
        guard let store else { return }
        if case .album(let current) = scope, current == id {
            scope = .all
            await reload()
        }
        try? await store.deleteAlbum(id)
        await reload()
    }

    /// Writes the JSON next to the catalog — on the volume, like everything else.
    func exportMemberships() async {
        guard let store, let root else { return }
        do {
            let data = try await store.exportMembershipsJSON()
            let out = VolumeLocator.catalogDir(root).appendingPathComponent("memberships.json")
            try data.write(to: out, options: .atomic)
            status = "Exported to .catalog/memberships.json"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Navigation

    func url(for item: PhotoItem) -> URL? {
        root?.appendingPathComponent(item.relPath)
    }

    func step(_ delta: Int) {
        guard let current = viewing,
              let i = items.firstIndex(where: { $0.id == current.id }) else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        lastStep = delta < 0 ? -1 : 1
        viewing = items[j]
        select(only: items[j].id)
    }

    /// Decodes the photos either side of `item` at low priority, the one in
    /// the direction of travel first, so the next step lands on a sharp image.
    func prefetchNeighbors(of item: PhotoItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        for j in [i + lastStep, i - lastStep] where items.indices.contains(j) {
            let neighbour = items[j]
            guard neighbour.mediaType == .photo else { continue }
            loadThumb(neighbour)
            let url = url(for: neighbour)
            Task { _ = await fullRes.load(neighbour.id, url: url, priority: .utility) }
        }
    }

    // MARK: - Trash and rotation

    /// Moves photos to the Trash: out of every view and every album, file
    /// untouched until the Trash is emptied.
    func moveToTrash(_ targets: [PhotoItem]) async {
        guard let store, !targets.isEmpty else { return }
        do { try await store.moveToTrash(targets.map(\.id)) } catch { errorMessage = error.localizedDescription }
        clearSelection()
        await reload()
        status = targets.count == 1 ? "Moved 1 item to the Trash" : "Moved \(targets.count) items to the Trash"
    }

    func restore(_ targets: [PhotoItem]) async {
        guard let store, !targets.isEmpty else { return }
        do { try await store.restoreFromTrash(targets.map(\.id)) } catch { errorMessage = error.localizedDescription }
        clearSelection()
        await reload()
        status = targets.count == 1 ? "Put back 1 item" : "Put back \(targets.count) items"
    }

    /// Trashes the photo on screen and moves on to the next one (or the
    /// previous, at the end of the set), the way Photos does.
    func trashViewing() async {
        guard let store, let open = viewing, !open.trashed else { return }
        let next = neighbour(of: open)
        do { try await store.moveToTrash([open.id]) } catch { errorMessage = error.localizedDescription; return }
        fullRes.remove(open.id)
        viewing = next
        if let next { select(only: next.id) } else { clearSelection() }
        await reload()
    }

    func restoreViewing() async {
        guard let store, let open = viewing, open.trashed else { return }
        let next = neighbour(of: open)
        do { try await store.restoreFromTrash([open.id]) } catch { errorMessage = error.localizedDescription; return }
        viewing = next
        await reload()
    }

    private func neighbour(of item: PhotoItem) -> PhotoItem? {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        if items.indices.contains(i + 1) { return items[i + 1] }
        if items.indices.contains(i - 1) { return items[i - 1] }
        return nil
    }

    /// Permanently deletes every original in the Trash. Only ever called from
    /// the confirmation dialog.
    func emptyTrash() async {
        guard let store else { return }
        if viewing?.trashed == true { viewing = nil }    // releases a playing video's file
        do {
            let result = try await store.emptyTrash()
            await reload()
            status = result.deleted == 1 ? "Deleted 1 item" : "Deleted \(result.deleted) items"
            if !result.failures.isEmpty {
                errorMessage = "\(result.failures.count) item(s) couldn't be deleted and are still in the Trash:\n"
                    + result.failures.prefix(5).joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rotate(_ targets: [PhotoItem], clockwise: Bool) async {
        guard let store, !targets.isEmpty else { return }
        let ids = targets.map(\.id)
        do {
            let failures = try await store.rotate(ids, clockwise: clockwise)
            if !failures.isEmpty {
                errorMessage = failures.prefix(5).joined(separator: "\n")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        // The old pixels are stale everywhere they're cached.
        for id in ids {
            cache.remove(id)
            fullRes.remove(id)
        }
        await reload()
        for item in items where ids.contains(item.id) { loadThumb(item) }
    }

    func rotateViewing(clockwise: Bool) async {
        guard let open = viewing else { return }
        await rotate([open], clockwise: clockwise)
    }

    // MARK: - Menu commands

    /// Whether a text field has keyboard focus — the New Album name, say. Menu
    /// shortcuts like ⌘A and ⌘⌫ then belong to the text, not the photos.
    var isEditingText: Bool {
        Self.typingWindow?.firstResponder is NSText
    }

    /// The window keys go to: the key window — or, with the app in the
    /// background (the smoke test sends it keys without taking the keyboard),
    /// a sheet showing, else the main window.
    static var typingWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isSheet && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }

    func selectAllCommand() {
        if isEditingText {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        } else if viewing == nil {
            selectAll()
        }
    }

    func trashCommand() {
        if isEditingText {
            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
            return
        }
        Task {
            if viewing != nil {
                await trashViewing()
            } else if scope != .trash {
                await moveToTrash(selectedItems)
            }
        }
    }

    func rotateCommand(clockwise: Bool) {
        guard !isEditingText else { return }
        Task {
            if viewing != nil {
                await rotateViewing(clockwise: clockwise)
            } else {
                await rotate(selectedItems.filter { Rotation.canRotate($0) && !$0.trashed }, clockwise: clockwise)
            }
        }
    }

    var canRotateCurrent: Bool {
        if let open = viewing { return Rotation.canRotate(open) && !open.trashed }
        return selectedItems.contains { Rotation.canRotate($0) && !$0.trashed }
    }

    var canTrashCurrent: Bool {
        if let open = viewing { return !open.trashed }
        return scope != .trash && !selection.isEmpty
    }

    // MARK: - Keyboard commands

    /// A plain key typed while a text field has focus: it goes into the text.
    /// Menu items on plain keys (".", Space) see the key first — without this
    /// a full stop or a space could never be typed in a tag search.
    private func typeIntoText(_ text: String) {
        (Self.typingWindow?.firstResponder as? NSTextView)?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// "." — Add to Favorites, or Remove: the photo on screen, or the grid's
    /// selection (all of it favorite → removed, otherwise added).
    func favoriteCommand() {
        if isEditingText { return typeIntoText(".") }
        Task {
            if viewing != nil {
                await toggleFavoriteForViewing()
            } else {
                await toggleFavorite()
            }
        }
    }

    var canFavoriteCurrent: Bool {
        if let open = viewing { return !open.trashed }
        return scope != .trash && !selection.isEmpty
    }

    /// The Image menu's wording: "Remove from Favorites" when every photo it
    /// would act on already is one.
    var favoriteCommandTitle: String {
        let targets = viewing.map { [$0] } ?? selectedItems
        return !targets.isEmpty && targets.allSatisfy(\.favorite) ? "Remove from Favorites" : "Add to Favorites"
    }

    /// ⌘+ and ⌘−: a quarter bigger or smaller each time, within the slider's range.
    func stepThumbnailSize(bigger: Bool) {
        let size = thumbnailSize * (bigger ? 1.25 : 0.8)
        setThumbnailSize(min(GridView.sizeRange.upperBound, max(GridView.sizeRange.lowerBound, size.rounded())))
    }

    /// ⌥⌘↑ / ⌥⌘↓: oldest first (A to Z) or newest first (Z to A). In Random,
    /// either one shuffles again.
    func sortCommand(ascending: Bool) {
        guard var sort else { return }
        if sort.order == .random {
            sort.seed = UInt64.random(in: 1...UInt64.max)
        } else {
            guard sort.ascending != ascending else { return }
            sort.ascending = ascending
        }
        save(sort)
    }

    /// File › New Album (⌘N) and New Smart Album (⌥⌘N). Nil while the sheet
    /// isn't showing; otherwise whether it opens with Smart album ticked.
    @Published var newAlbumSheet: NewAlbumKind?

    struct NewAlbumKind: Identifiable {
        let smart: Bool
        var id: Bool { smart }
    }

    /// Help › Keyboard Shortcuts.
    @Published var showingShortcuts = false

    /// The album or smart album being renamed, from the sidebar or File menu.
    @Published var renaming: RenameTarget?

    /// The album or smart album on screen, for File › Duplicate and Rename.
    var currentAlbumTarget: RenameTarget? {
        switch scope {
        case .album(let id):
            return albums.first { $0.id == id }.map { RenameTarget(kind: .album, id: id, name: $0.name) }
        case .smart(let id):
            return smartAlbums.first { $0.id == id }.map { RenameTarget(kind: .smart, id: id, name: $0.name) }
        default:
            return nil
        }
    }

    func duplicateCurrentAlbum() {
        guard let target = currentAlbumTarget else { return }
        Task {
            switch target.kind {
            case .album: await duplicateAlbum(target.id)
            case .smart: await duplicateSmartAlbum(target.id)
            }
        }
    }

    /// R and N in the viewer: Repeat and Play Next on or off.
    func playbackCommand(_ flag: ReferenceWritableKeyPath<LibraryModel, Bool>, key: String) {
        if isEditingText { return typeIntoText(key) }
        guard viewing != nil else { return }
        self[keyPath: flag].toggle()
    }

    // MARK: - Scrolling by itself

    /// The grid scrolling down on its own (Space, or the toolbar's play
    /// button). Scrolling, a click in the grid, a key, opening a photo or
    /// changing view stops it. Never saved: a vault always opens still.
    @Published var autoScrolling = false { didSet { updateSlideshowAssertion() } }
    /// How fast, in rows of thumbnails a minute — the same pace at any
    /// thumbnail size. Saved per vault.
    @Published private(set) var scrollSpeed: Double = 10
    static let scrollSpeeds: [Double] = [2, 5, 10, 20, 40, 80]

    func setScrollSpeed(_ rows: Double) {
        scrollSpeed = rows
        Task { await store?.setSetting("grid.scrollSpeed", String(rows)) }
    }

    /// Space: start or pause. While typing, Space is a space.
    func autoScrollCommand() {
        if isEditingText { return typeIntoText(" ") }
        guard viewing == nil, !items.isEmpty else { return }
        autoScrolling.toggle()
    }

    var scopeTitle: String {
        switch scope {
        case .all: return "All Media"
        case .favorites: return "Favorites"
        case .album(let id): return albums.first { $0.id == id }?.name ?? "Album"
        case .smart(let id): return smartAlbums.first { $0.id == id }?.name ?? "Smart Album"
        case .trash: return "Trash"
        case .folder(let path):
            // "2019 › summer" rather than the bare last name, so where you
            // are in the tree is clear.
            let prefix = VolumeLocator.mediaDirName + "/"
            let inside = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
            return inside.split(separator: "/").joined(separator: " › ")
        }
    }
}

extension Notification.Name {
    /// Smoke test only: set the playing video's rate, as the controls' speed
    /// menu would.
    static let smokeSetVideoRate = Notification.Name("PhotoVaultSmokeSetVideoRate")
    /// Smoke test only: zoom the video (object: the zoom), or report its zoom
    /// (no object).
    static let smokeZoomVideo = Notification.Name("PhotoVaultSmokeZoomVideo")
}

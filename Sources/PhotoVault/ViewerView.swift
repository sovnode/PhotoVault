import SwiftUI
import AppKit
import AVKit
import AVFoundation
import ImageIO
import CoreGraphics
import PhotoVaultCore

/// Holds the one live `AVPlayer` and, more importantly, gives everything else a
/// single place to call to let go of it.
///
/// `AVPlayer` keeps the file open for as long as an item is loaded — not just
/// while playing — and `mediaplaybackd` may hold its own reference on top. If
/// either survives, Finder's eject fails with "volume in use" and names no
/// culprit. Pausing is not enough; the item has to be replaced with nil.
@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    /// One speed for every video: applied as each one starts, and taken from
    /// the player whenever the person picks another in its controls.
    @Published private(set) var speed: Float = 1
    var onSpeedChange: ((Float) -> Void)?
    /// The video reached its end.
    var onEnded: (() -> Void)?
    private var endObserver: NSObjectProtocol?
    private var rateObservations: [NSKeyValueObservation] = []

    func setSpeed(_ speed: Float) {
        guard speed > 0 else { return }
        self.speed = speed
        player?.defaultRate = speed
    }

    func play(url: URL) {
        release()
        let p = AVPlayer(url: url)
        p.defaultRate = speed
        p.playImmediately(atRate: speed)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: p.currentItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        // The controls' speed menu changes the player's rate (while playing)
        // or its default rate: either way, a new speed for every video.
        for path in [\AVPlayer.rate, \AVPlayer.defaultRate] {
            rateObservations.append(p.observe(path, options: [.new]) { [weak self] player, _ in
                let chosen = player.rate > 0 ? player.rate : player.defaultRate
                DispatchQueue.main.async { self?.adopt(chosen) }
            })
        }
        player = p
    }

    private func adopt(_ chosen: Float) {
        guard chosen > 0, abs(chosen - speed) > 0.01 else { return }
        speed = chosen
        player?.defaultRate = chosen
        onSpeedChange?(chosen)
    }

    /// Repeat: back to the start, at the same speed.
    func replay() {
        guard let p = player else { return }
        p.seek(to: .zero)
        p.playImmediately(atRate: speed)
    }

    func release() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        rateObservations = []
        guard let p = player else { return }
        p.pause()
        p.replaceCurrentItem(with: nil)   // this is the part that matters
        player = nil
    }
}

struct ViewerView: View {
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var thumbs: ThumbnailSignal   // redraws when its thumbnail lands
    @StateObject private var playback = PlaybackController()
    @State private var full: FullFrame?
    @State private var decodeTask: Task<Void, Never>?
    /// Hidden until the cursor actually moves — including when a photo first
    /// opens — so stepping with the arrow keys shows nothing but the photo.
    @State private var chromeVisible = false
    /// Where the cursor was when the header last appeared (screen coordinates).
    @State private var lastPointer: CGPoint?
    @State private var hideTask: Task<Void, Never>?
    let item: PhotoItem

    /// A full-resolution decode, tagged with the picture it belongs to. A slow
    /// decode for a photo already stepped past can then never land on top of
    /// the current one — that race was half of the stretching on fast cycling.
    struct FullFrame {
        let key: String
        let image: CGImage
    }

    /// Changes when the picture itself changes: a different photo, or the same
    /// photo rotated. Zoom resets on a new key and only then — not when the
    /// thumbnail is upgraded to the full decode of the same picture.
    private var imageKey: String { "\(item.id):\(item.orientation):\(item.thumbOff ?? 0)" }

    /// The best image available right now: this photo's full decode if it has
    /// landed, one decoded ahead as a neighbour, or else its thumbnail. All are
    /// already oriented and share an aspect ratio, so moving between them
    /// changes sharpness, never shape.
    private var displayImage: CGImage? {
        if let full, full.key == imageKey { return full.image }
        if let ready = model.fullRes.image(for: item.id) { return ready }
        return model.cachedThumb(item)
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black.ignoresSafeArea()

                if item.mediaType == .video {
                    if !item.playable {
                        unsupportedVideo
                    } else if let player = playback.player {
                        VideoSurface(player: player, speed: playback.speed).ignoresSafeArea()
                    } else {
                        ProgressView().controlSize(.large)
                    }
                } else {
                    // Always present for photos, even before any image is ready, so
                    // it keeps keyboard focus from one photo to the next.
                    ZoomableImage(image: displayImage,
                                  imageKey: imageKey,
                                  onMouseMove: { pointerMoved() },
                                  onEscape: { model.viewing = nil },
                                  onStep: { model.step($0) },
                                  onShowInLibrary: (model.viewing ?? item).trashed ? nil : {
                                      model.showInLibrary(model.viewing ?? item)
                                  },
                                  onAddToAlbum: (model.viewing ?? item).trashed ? nil : { albumID in
                                      let live = model.viewing ?? item
                                      if let albumID {
                                          Task { await model.addToAlbum(albumID, items: [live]) }
                                      } else {
                                          model.newAlbumRequest = .init(photoIDs: [live.id])
                                      }
                                  },
                                  albums: model.albums.map { ($0.id, $0.name) })
                        .ignoresSafeArea()
                }

                VStack {
                    header
                        .opacity(chromeVisible ? 1 : 0)
                        // A faded-out header must not keep intercepting clicks…
                        .allowsHitTesting(chromeVisible)
                        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
                    Spacer()
                }
            }
            // The properties panel takes the right edge and the photo
            // re-fits to the space left. It stays open while the header hides,
            // and from photo to photo.
            if model.showProperties {
                PropertiesPanel(item: model.viewing ?? item)
                    .frame(width: 300)
                    .ignoresSafeArea()
            }
        }
        .background(Color.black.ignoresSafeArea())
        // …and must come back whenever the pointer moves, zoomed or not, so
        // there is always a visible way out. It hides again after a pause, which
        // is what keeps full screen down to just the photo.
        .onContinuousHover { phase in
            if case .active = phase { pointerMoved() }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_SHOW_HEADER"] == "1" { revealChrome() }
            lastPointer = NSEvent.mouseLocation
            playback.setSpeed(model.videoSpeed)
            playback.onSpeedChange = { model.setVideoSpeed($0) }
            playback.onEnded = { videoEnded() }
            load()
        }
        // A slideshow: each photo stays for the chosen time, then the next
        // item. Restarts whenever the photo changes — including a step
        // by hand — or the setting does; a video moves on when it ends instead.
        .task(id: "\(item.id) \(model.slideshowOn) \(model.slideInterval)") {
            guard model.slideshowOn, item.mediaType == .photo || !item.playable else { return }
            try? await Task.sleep(nanoseconds: UInt64(model.slideInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            model.advance()
        }
        .onDisappear { unload(); hideTask?.cancel() }
        .onChange(of: imageKey) { _, _ in load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // Decoded full-resolution pixels can page to swap under memory
            // pressure. This narrows that window to the time the app is
            // actually in front of the user.
            full = nil
            model.fullRes.removeAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if item.mediaType == .photo { load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.willUnmountNotification).receive(on: RunLoop.main)) { _ in
            unload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .smokeSetVideoRate)) { note in
            if let rate = (note.object as? NSNumber)?.floatValue { playback.player?.rate = rate }
        }
    }

    private var header: some View {
        let live = model.viewing ?? item
        return HStack(spacing: 14) {
            // Escape and the arrow keys are menu commands (Image menu), which
            // fire regardless of which view has keyboard focus.
            Button { model.viewing = nil } label: {
                Label("Library", systemImage: "chevron.backward")
            }
            .help("Back to Library (Esc or ⇧)")
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .help(Shortcut.previous.help("Previous"))
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .help(Shortcut.next.help("Next"))
            Text(item.displayName).lineLimit(1)
            Spacer()
            playbackControls
            Divider().frame(height: 16)
            Group {
                Button { Task { await model.rotateViewing(clockwise: false) } } label: {
                    Image(systemName: "rotate.left")
                }
                .help(Shortcut.rotateLeft.help("Rotate Left"))
                Button { Task { await model.rotateViewing(clockwise: true) } } label: {
                    Image(systemName: "rotate.right")
                }
                .help(Shortcut.rotateRight.help("Rotate Right"))
            }
            .disabled(!Rotation.canRotate(live) || live.trashed)
            if live.trashed {
                Button { Task { await model.restoreViewing() } } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Put Back")
            } else {
                Button { Task { await model.trashViewing() } } label: {
                    Image(systemName: "trash")
                }
                .help(Shortcut.trash.help("Move to Trash"))
            }
            Button {
                Task { await model.toggleFavoriteForViewing() }
            } label: {
                // Driven by the live row, not the copy this view was built
                // with, so it fills in the moment the write lands.
                Image(systemName: live.favorite ? "heart.fill" : "heart")
                    .foregroundStyle(live.favorite ? .red : .white)
            }
            // The key is the Image menu's Add to Favorites, which acts on the
            // photo on screen here.
            .help(Shortcut.favorite.help(live.favorite ? "Remove from Favorites" : "Add to Favorites"))
            Button { model.toggleProperties() } label: {
                Image(systemName: model.showProperties ? "info.circle.fill" : "info.circle")
            }
            .help(Shortcut.properties.help(model.showProperties ? "Hide Properties" : "Show Properties"))
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.35))
    }

    /// Repeat and Play Next, and — while a slideshow can run — how
    /// long each photo stays.
    private var playbackControls: some View {
        HStack(spacing: 12) {
            toggle(\.repeatOn, symbol: "repeat", key: .repeatToggle, help: "Repeat: loop the video; start a slideshow again at the end")
            toggle(\.nextOn, symbol: "forward.end", key: .playNextToggle, help: "Play Next: move on to the next item when a video ends, or after a photo's time")
            if model.slideshowOn {
                // A plain button-style menu draws its label as given — white,
                // like the icons beside it. The borderless menu style drew it in
                // the system's dark text, lost on the dark header.
                Menu {
                    ForEach(LibraryModel.slideIntervals, id: \.self) { seconds in
                        Button("\(Int(seconds)) seconds") { model.setSlideInterval(seconds) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "timer")
                        Text("\(Int(model.slideInterval)) s").font(.callout.monospacedDigit())
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("How long each photo stays in the slideshow")
            }
        }
    }

    private func toggle(_ flag: ReferenceWritableKeyPath<LibraryModel, Bool>, symbol: String, key: Shortcut, help: String) -> some View {
        let on = model[keyPath: flag]
        return Button { model[keyPath: flag].toggle() } label: {
            Image(systemName: symbol)
                .foregroundStyle(on ? Color.accentColor : .white)
                .padding(3)
                .background(on ? Color.white.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .help("\(help) — \(on ? "on" : "off") (\(key.label))")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// A video reached its end: loop it, move on, or stop.
    private func videoEnded() {
        if model.repeatOn {
            playback.replay()
            SmokeHooks.say("video ended and looped")
        } else if model.slideshowOn {
            model.advance()
        }
    }

    /// Shows the header, but only for real movement. When the picture under a
    /// still cursor changes — every arrow-key step — macOS can deliver hover
    /// and mouse-moved events without the pointer moving, which would bring the
    /// header straight back. Reading the cursor's actual position and comparing
    /// it with the last one filters those out, from either source.
    private func pointerMoved() {
        let now = NSEvent.mouseLocation
        guard PointerMotion.hasMoved(from: lastPointer, to: now) else {
            if lastPointer == nil { lastPointer = now }
            return
        }
        lastPointer = now
        revealChrome()
    }

    private func revealChrome() {
        if !chromeVisible { chromeVisible = true }
        hideTask?.cancel()
        // Smoke test only: the header stays, to be looked at in a screenshot.
        if ProcessInfo.processInfo.environment["PHOTOVAULT_SMOKE_SHOW_HEADER"] == "1" { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { chromeVisible = false }
        }
    }

    private var unsupportedVideo: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.video").font(.system(size: 40))
            Text("No playable video track").font(.title3)
            Text("AVFoundation doesn't open this container — MKV, VP9 and DivX-era AVI among them. The file is untouched on the volume.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .foregroundStyle(.white)
    }

    private func load() {
        guard let url = model.url(for: item) else { return }
        decodeTask?.cancel()
        if item.mediaType == .video {
            if item.playable { playback.play(url: url) }
            return
        }
        // Stepping from a video to a photo: let go of the movie file, or the
        // volume stays busy for as long as the viewer is open.
        playback.release()
        model.loadThumb(item)    // the grid may never have shown this one

        let target = item
        let key = imageKey
        decodeTask = Task { @MainActor in
            // During a burst of held-down arrow keys, don't start a full decode
            // for every photo flicked past. The thumbnails carry the burst; the
            // full image is decoded for wherever it comes to rest.
            if model.fullRes.image(for: target.id) == nil {
                try? await Task.sleep(nanoseconds: 70_000_000)
                if Task.isCancelled { return }
            }
            guard let image = await model.fullRes.load(target.id, url: url),
                  !Task.isCancelled else { return }
            full = FullFrame(key: key, image: image)
            model.prefetchNeighbors(of: target)
        }
    }

    private func unload() {
        decodeTask?.cancel()
        playback.release()
        full = nil
    }

    /// ImageIO again, with the EXIF transform applied. `kCGImageSourceThumbnail`
    /// with a large max pixel size gives a correctly-oriented full decode in one
    /// step; `CreateImageAtIndex` would hand back raw pixels needing the
    /// rotation applied separately.
    nonisolated static func decodeFull(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 6_000,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}

/// `AVPlayerView` rather than SwiftUI's `VideoPlayer`, because the teardown path
/// has to reach the view's own player reference too.
///
/// Pinch zooms the video, and two fingers move it about while zoomed, as for
/// photos — AVPlayerView's own magnification. A video looping with Repeat
/// keeps its zoom (the same player plays it again); the next video, or the
/// same one opened again, starts unzoomed: nothing is remembered.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    /// The one speed for every video, shown as chosen in the controls.
    var speed: Float = 1

    final class Coordinator {
        weak var view: AVPlayerView?
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.allowsMagnification = true
        v.player = player
        context.coordinator.view = v
        SmokeHooks.watchVideoZoom(context.coordinator)
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player {
            v.player = player
            // A different video starts unzoomed.
            v.magnification = 1
        }
        if let match = v.speeds.first(where: { abs($0.rate - speed) < 0.01 }), v.selectedSpeed != match {
            v.selectSpeed(match)
        }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: Coordinator) {
        v.player?.pause()
        v.player?.replaceCurrentItem(with: nil)
        v.player = nil
    }
}

/// Decides whether the pointer has really moved since `last`.
enum PointerMotion {
    /// Points, in screen coordinates. Below this is sensor jitter, not intent.
    static let threshold: CGFloat = 2

    static func hasMoved(from last: CGPoint?, to current: CGPoint) -> Bool {
        guard let last else { return false }    // no baseline yet
        return hypot(current.x - last.x, current.y - last.y) >= threshold
    }
}

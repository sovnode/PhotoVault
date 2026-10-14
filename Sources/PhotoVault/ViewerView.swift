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

    func play(url: URL) {
        release()
        let p = AVPlayer(url: url)
        p.play()
        player = p
    }

    func release() {
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
                        VideoSurface(player: player).ignoresSafeArea()
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
                                  })
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
            lastPointer = NSEvent.mouseLocation
            load()
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
    }

    private var header: some View {
        let live = model.viewing ?? item
        return HStack(spacing: 14) {
            // Escape and the arrow keys are menu commands (Image menu), which
            // fire regardless of which view has keyboard focus.
            Button { model.viewing = nil } label: {
                Label("Library", systemImage: "chevron.backward")
            }
            .help("Back to Library (Esc)")
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous (←)")
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .help("Next (→)")
            Text(item.displayName).lineLimit(1)
            Spacer()
            Group {
                Button { Task { await model.rotateViewing(clockwise: false) } } label: {
                    Image(systemName: "rotate.left")
                }
                .help("Rotate Left (⌘L)")
                Button { Task { await model.rotateViewing(clockwise: true) } } label: {
                    Image(systemName: "rotate.right")
                }
                .help("Rotate Right (⌘R)")
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
                .help("Move to Trash (⌘⌫)")
            }
            Button {
                Task { await model.toggleFavoriteForViewing() }
            } label: {
                // Driven by the live row, not the copy this view was built
                // with, so it fills in the moment the write lands.
                Image(systemName: live.favorite ? "heart.fill" : "heart")
                    .foregroundStyle(live.favorite ? .red : .white)
            }
            .keyboardShortcut(".", modifiers: [])
            .help("Favorite (.)")
            Button { model.toggleProperties() } label: {
                Image(systemName: model.showProperties ? "info.circle.fill" : "info.circle")
            }
            .help(model.showProperties ? "Hide Properties (⌘I)" : "Show Properties (⌘I)")
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.35))
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
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.showsFullScreenToggleButton = true
        v.player = player
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
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

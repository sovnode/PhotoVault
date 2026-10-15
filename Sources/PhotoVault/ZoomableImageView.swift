import AppKit
import SwiftUI
import CoreGraphics

/// Pinch-zoom and two-finger pan over a `CGImage`, drawn straight into a layer.
///
/// This is AppKit rather than SwiftUI gestures for one reason: a two-finger
/// trackpad pan arrives as `scrollWheel`, not as a drag, and pinch arrives as
/// `magnify(with:)`. SwiftUI's `MagnifyGesture` covers the pinch but nothing in
/// SwiftUI sees a precise scroll, so panning would only ever work by clicking
/// and dragging. Overriding the two AppKit events gets both, and the layer
/// keeps the display path the design asks for — no `NSImage`, no second decode.
final class ZoomableImageNSView: NSView {
    private let imageLayer = CALayer()

    /// 1.0 means "fitted to the view". Zoom never goes below that: an image
    /// smaller than its window has nowhere useful to go.
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private let maxZoom: CGFloat = 12

    private(set) var cgImage: CGImage?
    private(set) var imageKey: String?

    /// This view takes first responder, so it reports pointer movement and the
    /// keys it handles itself, or the SwiftUI layer never hears about them.
    var onMouseMove: (() -> Void)?
    var onEscape: (() -> Void)?
    var onStep: ((Int) -> Void)?
    /// When set, right-clicking the photo offers Show in Library.
    var onShowInLibrary: (() -> Void)?
    /// When set, right-clicking offers Add to Album: nil is New Album….
    var onAddToAlbum: ((Int64?) -> Void)?
    var albums: [(id: Int64, name: String)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Aspect-fit even though the frame is always computed to the image's
        // exact aspect: if contents and frame are ever momentarily out of step,
        // the picture letterboxes instead of stretching.
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.magnificationFilter = .trilinear
        imageLayer.minificationFilter = .trilinear
        // No implicit animations on this layer, ever. The default 0.25 s
        // crossfade on `contents` drew the previous photo into the next photo's
        // frame — the stretch that dominated fast cycling.
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull()]
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Take keyboard focus as soon as the viewer opens, so the arrow keys
        // work before anything has been clicked.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    /// Shows `image`. A new `key` means a different picture: the zoom resets.
    /// The same key with a new image is a sharper version of the same picture —
    /// the thumbnail upgraded to the full decode — and the zoom is kept.
    func show(_ image: CGImage?, key: String) {
        let newPicture = key != imageKey
        guard newPicture || image !== cgImage else { return }
        cgImage = image
        imageKey = key
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        if newPicture {
            zoom = 1
            offset = .zero
        }
        applyLayout()
        CATransaction.commit()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Geometry

    /// The size the image occupies at zoom 1 — aspect-fitted to the view.
    private var fittedSize: CGSize {
        guard let img = cgImage, img.width > 0, img.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let scale = min(bounds.width / iw, bounds.height / ih)
        return CGSize(width: iw * scale, height: ih * scale)
    }

    override func layout() {
        super.layout()
        applyLayout()
    }

    private func applyLayout() {
        let fitted = fittedSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard fitted.width > 0 else {
            imageLayer.frame = .zero
            return
        }
        let size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        clampOffset(for: size)
        imageLayer.frame = CGRect(
            x: (bounds.width - size.width) / 2 + offset.x,
            y: (bounds.height - size.height) / 2 + offset.y,
            width: size.width, height: size.height
        )
    }

    /// Stops the photo being flung off-screen: an axis that fits entirely stays
    /// centred, and one that overflows can travel only as far as its own edge.
    private func clampOffset(for size: CGSize) {
        let limitX = max(0, (size.width - bounds.width) / 2)
        let limitY = max(0, (size.height - bounds.height) / 2)
        offset.x = min(limitX, max(-limitX, offset.x))
        offset.y = min(limitY, max(-limitY, offset.y))
    }

    /// Zooms while holding whatever is under the cursor still, which is what
    /// makes pinch feel anchored rather than lurching toward the centre.
    private func setZoom(_ requested: CGFloat, around point: CGPoint) {
        let fitted = fittedSize
        guard fitted.width > 0 else { return }
        let next = min(maxZoom, max(1, requested))
        guard abs(next - zoom) > 0.0001 else { return }

        let oldSize = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        let oldOrigin = CGPoint(
            x: (bounds.width - oldSize.width) / 2 + offset.x,
            y: (bounds.height - oldSize.height) / 2 + offset.y
        )
        let relX = oldSize.width > 0 ? (point.x - oldOrigin.x) / oldSize.width : 0.5
        let relY = oldSize.height > 0 ? (point.y - oldOrigin.y) / oldSize.height : 0.5

        zoom = next
        let newSize = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
        offset.x = (point.x - relX * newSize.width) - (bounds.width - newSize.width) / 2
        offset.y = (point.y - relY * newSize.height) - (bounds.height - newSize.height) / 2

        applyLayout()
        window?.invalidateCursorRects(for: self)
    }

    private func cursor(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    // MARK: - Trackpad, mouse and keyboard

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), around: cursor(event))
    }

    /// Two-finger double-tap: snap between fitted and 2x, like Preview.
    override func smartMagnify(with event: NSEvent) {
        setZoom(zoom > 1.01 ? 1 : 2, around: cursor(event))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            setZoom(zoom * (1 + event.scrollingDeltaY * 0.01), around: cursor(event))
            return
        }
        guard zoom > 1.001 else {
            super.scrollWheel(with: event)
            return
        }
        // This view is not flipped, so the y axis runs opposite to the scroll
        // delta; the content should travel with the fingers.
        offset.x += event.scrollingDeltaX
        offset.y -= event.scrollingDeltaY
        applyLayout()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        onMouseMove?()
        guard zoom > 1.001 else { return }
        offset.x += event.deltaX
        offset.y -= event.deltaY
        applyLayout()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onMouseMove?() }

    /// The arrow keys step through photos whether or not the photo is zoomed —
    /// stepping simply lands on the next photo fitted to the window. (They are
    /// also menu commands; this covers the case where the menu doesn't see the
    /// key first.)
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {          // Escape
            onEscape?()
            return
        }
        switch event.specialKey {
        case .leftArrow?: onStep?(-1)
        case .rightArrow?: onStep?(1)
        default: super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard onShowInLibrary != nil || onAddToAlbum != nil else { return nil }
        let menu = NSMenu()
        if onAddToAlbum != nil {
            let add = NSMenuItem(title: "Add to Album", action: nil, keyEquivalent: "")
            let albumsMenu = NSMenu()
            let new = NSMenuItem(title: "New Album…", action: #selector(addToAlbumChosen(_:)), keyEquivalent: "")
            new.target = self
            albumsMenu.addItem(new)
            if !albums.isEmpty { albumsMenu.addItem(.separator()) }
            for album in albums {
                let item = NSMenuItem(title: album.name, action: #selector(addToAlbumChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = NSNumber(value: album.id)
                albumsMenu.addItem(item)
            }
            add.submenu = albumsMenu
            menu.addItem(add)
        }
        if onShowInLibrary != nil {
            let item = NSMenuItem(title: "Show in Library", action: #selector(showInLibraryChosen), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func showInLibraryChosen() { onShowInLibrary?() }

    @objc private func addToAlbumChosen(_ sender: NSMenuItem) {
        onAddToAlbum?((sender.representedObject as? NSNumber)?.int64Value)
    }

    /// Escape arrives as `cancelOperation:` when this view is first responder.
    override func cancelOperation(_ sender: Any?) { onEscape?() }

    override func resetCursorRects() {
        // A grabbable cursor only while there is somewhere to grab to.
        if zoom > 1.001 {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

struct ZoomableImage: NSViewRepresentable {
    let image: CGImage?
    let imageKey: String
    var onMouseMove: (() -> Void)?
    var onEscape: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var onShowInLibrary: (() -> Void)?
    var onAddToAlbum: ((Int64?) -> Void)?
    var albums: [(id: Int64, name: String)] = []

    func makeNSView(context: Context) -> ZoomableImageNSView {
        let view = ZoomableImageNSView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ZoomableImageNSView, context: Context) {
        view.onMouseMove = onMouseMove
        view.onEscape = onEscape
        view.onStep = onStep
        view.onShowInLibrary = onShowInLibrary
        view.onAddToAlbum = onAddToAlbum
        view.albums = albums
        view.show(image, key: imageKey)
    }
}

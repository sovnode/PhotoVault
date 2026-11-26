import SwiftUI
import AppKit
import Combine
import PhotoVaultCore

/// The view's photos on a map of where they were taken. Drawn by PhotoVault
/// itself, over the world outline that comes with the app: no MapKit, and
/// nothing fetched from anywhere. Nearby photos gather into circles with a
/// count; a single photo is a dot, and from about street level (zoom 13) a
/// thumbnail. Clicking a photo shows it in the library, as Show in Library
/// does; clicking a circle zooms in to it.
struct MapScreen: View {
    @EnvironmentObject var model: LibraryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var controller = MapController()

    var body: some View {
        MapCanvasView(controller: controller, dark: colorScheme == .dark)
            .overlay(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    mapButton("plus", help: "Zoom In (+)") { controller.zoom(by: 1) }
                    Divider().frame(width: 28)
                    mapButton("minus", help: "Zoom Out (−)") { controller.zoom(by: -1) }
                    Divider().frame(width: 28)
                    mapButton("arrow.up.left.and.arrow.down.right", help: "Show All the Photos on the Map") { controller.fitAll() }
                        .disabled(model.mapPoints.isEmpty)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                .padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                Text(locatedSummary)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(10)
            }
            .overlay(alignment: .bottomTrailing) {
                Text("Map data: Natural Earth")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(10)
                    .help("The map is drawn from Natural Earth's public-domain data, which comes with PhotoVault. Nothing is downloaded, and no location is sent anywhere.")
            }
    }

    private func mapButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var locatedSummary: String {
        let located = model.mapPoints.count, all = model.items.count
        if all == 0 { return "Nothing to show here" }
        if located == 0 { return all == 1 ? "This item doesn't record where it was taken" : "None of these \(all) items record where they were taken" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        let a = f.string(from: NSNumber(value: located)) ?? "\(located)", b = f.string(from: NSNumber(value: all)) ?? "\(all)"
        return located == all ? "\(a) on the map" : "\(a) of \(b) on the map; the others don't record where they were taken"
    }
}

/// Lets the buttons over the map reach it.
@MainActor final class MapController {
    weak var canvas: MapCanvas?
    func zoom(by delta: Double) { canvas?.zoomAnimated(by: delta) }
    func fitAll() { canvas?.fitAll(animated: true) }
}

struct MapCanvasView: NSViewRepresentable {
    @EnvironmentObject var model: LibraryModel
    let controller: MapController
    let dark: Bool

    func makeNSView(context: Context) -> MapCanvas {
        let canvas = MapCanvas(model: model)
        controller.canvas = canvas
        return canvas
    }

    func updateNSView(_ canvas: MapCanvas, context: Context) {
        controller.canvas = canvas
        canvas.update(points: model.mapPoints, view: model.mapView, camera: model.mapCamera, dark: dark)
    }
}

// MARK: - The canvas

/// Map tiles in a layer of their own underneath, markers and place names
/// drawn over them, and the mouse, trackpad and keys handled here. Nothing
/// moves unless asked: no timers run while the map is still.
final class MapCanvas: NSView {
    private weak var model: LibraryModel?
    private let tiles = TileView()
    private let marks = MarkView()
    private var thumbsChanged: AnyCancellable?

    private var world: WorldMap?
    private var clusters: MapClusters?
    private var points: [MapPoint] = []
    private var clustering = 0
    private(set) var camera = MapCamera(center: CGPoint(x: 0.5, y: 0.45), zoom: 2)
    /// The view whose map this is (`LibraryScope.storageValue`).
    private var shownView: String?
    /// A view newly shown, waiting for its photos (or its size) to be placed.
    private var placing = true
    private var style = MapTileRenderer.Style.light
    private var dark = false

    /// The map on show, for the smoke test to ask what it drew.
    static weak var smokeLatest: MapCanvas?
    /// A photo clicked: shown in the library, as Show in Library does.
    var openPhoto: (Int64) -> Void
    /// Whether the photos have been gathered into clusters yet.
    var isReady: Bool { clusters != nil || points.isEmpty }
    var tilesClipped: Bool { tiles.clipsToBounds && clipsToBounds }

    init(model: LibraryModel) {
        self.model = model
        openPhoto = { [weak model] id in model?.showFromMap(id) }
        super.init(frame: .zero)
        Self.smokeLatest = self
        wantsLayer = true
        // Tiles reach past the edges; they mustn't be drawn over the toolbar.
        // (macOS 14 no longer clips a view to its bounds by default.)
        clipsToBounds = true
        for sub in [tiles, marks] as [NSView] {
            sub.frame = bounds
            sub.autoresizingMask = [.width, .height]
            addSubview(sub)
        }
        marks.model = model
        tiles.style = style
        // A thumbnail landing in the cache: the markers draw it.
        thumbsChanged = model.thumbs.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.marks.needsDisplay = true }
        }
        Task.detached(priority: .userInitiated) {
            let world = WorldMap.bundled
            let relief = WorldRelief.bundled
            await MainActor.run { [weak self] in
                self?.tiles.relief = relief
                self?.world = world
                self?.tiles.world = world
                self?.marks.world = world
                self?.refresh()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func update(points newPoints: [MapPoint], view newView: String?, camera saved: MapCamera?, dark: Bool) {
        if dark != self.dark {
            self.dark = dark
            style = dark ? .dark : .light
            tiles.style = style
            marks.dark = dark
        }
        if newView != shownView {
            shownView = newView
            placing = true
            if let saved { setCamera(saved, note: false); placing = false }
        }
        if newPoints != points {
            points = newPoints
            clustering += 1
            let generation = clustering
            Task.detached(priority: .userInitiated) { [newPoints] in
                let built = MapClusters(newPoints)
                await MainActor.run { [weak self] in
                    guard let self, self.clustering == generation else { return }
                    self.clusters = built
                    self.marks.clusters = built
                    if self.placing { self.placeFirst() }
                    self.refresh()
                }
            }
        } else if placing, clusters != nil {
            placeFirst()
        }
        refresh()
    }

    /// A view shown for the first time as a map: all its photos in view.
    private func placeFirst() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        placing = false
        fitAll(animated: false)
    }

    override func layout() {
        super.layout()
        if placing, clusters != nil { placeFirst() }
        setCamera(camera, note: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tiles.scale = window?.backingScaleFactor ?? 2
        refresh()
    }

    // MARK: Moving

    private func setCamera(_ c: MapCamera, note: Bool = true) {
        camera = bounds.width > 0 ? c.clamped(in: bounds.size) : c
        refresh()
        if note { model?.noteMapCamera(camera) }
    }

    private func refresh() {
        tiles.camera = camera
        marks.camera = camera
        tiles.layoutTiles()
        marks.needsDisplay = true
    }

    func fitAll(animated: Bool) {
        guard bounds.width > 0 else { return }
        let target: MapCamera
        if let box = clusters?.bounds {
            target = MapCamera.fitting(box, in: bounds.size)
        } else {
            target = MapCamera(center: CGPoint(x: 0.5, y: 0.45), zoom: 0).clamped(in: bounds.size)
        }
        animated ? animate(to: target) : setCamera(target)
    }

    func zoomAnimated(by delta: Double, around anchor: CGPoint? = nil) {
        let at = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        animate(to: camera.zoomed(by: delta, around: at, in: bounds.size))
    }

    private var animation: Timer?

    /// A quarter of a second from here to there, then nothing runs.
    private func animate(to target: MapCamera) {
        animation?.invalidate()
        let start = camera, began = Date(), length = 0.25
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let t = min(1, Date().timeIntervalSince(began) / length)
                let e = t * t * (3 - 2 * t)
                let zoom = start.zoom + (target.zoom - start.zoom) * e
                let center = CGPoint(x: start.center.x + (target.center.x - start.center.x) * e,
                                     y: start.center.y + (target.center.y - start.center.y) * e)
                self.setCamera(MapCamera(center: center, zoom: zoom), note: t >= 1)
                if t >= 1 {
                    timer.invalidate()
                    self.animation = nil
                }
            }
        }
    }

    // MARK: Mouse, trackpad and keys

    private var dragStart: (point: CGPoint, camera: MapCamera)?
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        animation?.invalidate()
        dragStart = (convert(event.locationInWindow, from: nil), camera)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        let d = CGSize(width: p.x - start.point.x, height: p.y - start.point.y)
        if !dragged, hypot(d.width, d.height) < 3 { return }
        if !dragged { NSCursor.closedHand.push() }
        dragged = true
        setCamera(start.camera.panned(by: d, in: bounds.size))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if dragged {
            NSCursor.pop()
            dragged = false
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if let hit = marks.marker(at: p) {
            // A click lists the photos and leaves the map where it is; a
            // double-click zooms in to them.
            if event.clickCount >= 2 {
                popover?.close()
                zoomIn(to: hit, around: p)
            } else {
                showList(hit, from: marks.rect(of: hit) ?? CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            }
        } else if event.clickCount == 2 {
            zoomAnimated(by: event.modifierFlags.contains(.option) ? -1 : 1, around: p)
        }
    }

    /// Trackpad points of a two-finger swipe for one level of zoom.
    static let swipePerLevel = 90.0

    /// Scrolling zooms, about where the pointer is, as web maps do: a
    /// two-finger swipe up or down on a trackpad, smoothly, or a mouse wheel,
    /// half a level a notch. The direction follows the Mac's own scroll
    /// setting the way a web map's does: with natural scrolling, fingers
    /// drawn towards you zoom in. Sideways does nothing; dragging moves the map.
    override func scrollWheel(with event: NSEvent) {
        animation?.invalidate()
        let p = convert(event.locationInWindow, from: nil)
        let step: Double
        if event.hasPreciseScrollingDeltas {
            step = Double(event.scrollingDeltaY) / Self.swipePerLevel
        } else {
            step = event.scrollingDeltaY > 0 ? 0.5 : event.scrollingDeltaY < 0 ? -0.5 : 0
        }
        if step != 0 { setCamera(camera.zoomed(by: step, around: p, in: bounds.size)) }
    }

    override func magnify(with event: NSEvent) {
        animation?.invalidate()
        let p = convert(event.locationInWindow, from: nil)
        setCamera(camera.zoomed(by: log2(max(0.1, 1 + event.magnification)), around: p, in: bounds.size))
    }

    override func smartMagnify(with event: NSEvent) {
        zoomAnimated(by: 1, around: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        let step: CGFloat = 120
        switch event.keyCode {
        case 123: setCamera(camera.panned(by: CGSize(width: step, height: 0), in: bounds.size))
        case 124: setCamera(camera.panned(by: CGSize(width: -step, height: 0), in: bounds.size))
        case 125: setCamera(camera.panned(by: CGSize(width: 0, height: -step), in: bounds.size))
        case 126: setCamera(camera.panned(by: CGSize(width: 0, height: step), in: bounds.size))
        default:
            switch event.charactersIgnoringModifiers {
            case "+", "=": zoomAnimated(by: 1)
            case "-", "_": zoomAnimated(by: -1)
            default: super.keyDown(with: event)
            }
        }
    }

    // A pointing hand over anything that can be clicked.
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragStart == nil else { return }
        (marks.marker(at: convert(event.locationInWindow, from: nil)) != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    // MARK: Clicking a marker

    /// Close enough for a circle's photos to part, or two levels in on a
    /// single photo or a few taken at one spot.
    private func zoomIn(to cluster: MapCluster, around point: CGPoint) {
        let target = MapCamera.fitting(cluster.bounds, in: bounds.size, margin: 80, closest: MapCamera.maxZoom)
        if cluster.bounds.width == 0 && cluster.bounds.height == 0 || target.zoom <= camera.zoom + 0.05 {
            zoomAnimated(by: 2, around: point)
        } else {
            animate(to: target)
        }
    }

    private var popover: NSPopover?

    /// A marker's photos in a panel beside it, which scrolls when they're
    /// many. The map stays as it is.
    private func showList(_ cluster: MapCluster, from rect: CGRect) {
        guard let model, let clusters else { return }
        let ids = clusters.photos(in: cluster, atZoom: camera.zoom).map(\.id)
        listed = ids
        popover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        let list = MapPhotoList(items: model.mapItems(ids)) { [weak pop, weak self] id in
            pop?.performClose(nil)
            self?.openPhoto(id)
        }
        pop.contentViewController = NSHostingController(rootView: list.environmentObject(model).environmentObject(model.thumbs))
        // Beside the marker, not over it: the map behind stays in view.
        pop.show(relativeTo: rect, of: self, preferredEdge: rect.midX > bounds.midX ? .minX : .maxX)
        popover = pop
    }

    /// Smoke test only: lists the marker nearest the middle, as a click would.
    func smokeListMiddle() {
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        guard let hit = marks.drawn.min(by: { hypot($0.rect.midX - middle.x, $0.rect.midY - middle.y)
                                            < hypot($1.rect.midX - middle.x, $1.rect.midY - middle.y) }) else { return }
        showList(hit.cluster, from: hit.rect)
    }

    /// The photos the last list showed.
    private(set) var listed: [Int64] = []
    /// Where the first cluster of more than one photo is drawn, if any.
    var smokeClusterPoint: CGPoint? { marks.drawn.first { !$0.cluster.isSingle }?.cluster.point }

    // MARK: Smoke test

    /// Everything loaded and drawn: from here on the map does nothing until
    /// it's moved. For the smoke test's idle check.
    var isSettled: Bool { world != nil && isReady && !tiles.isBusy && tiles.shownCount > 0 }

    /// What's on the map now: markers, and photos in them. For the smoke test.
    var smokeSummary: (markers: Int, photos: Int, tiles: Int) {
        let shown = marks.drawn
        return (shown.count, shown.reduce(0) { $0 + $1.cluster.count }, tiles.shownCount)
    }
}

// MARK: - Tiles

/// The world outline, as square tiles rendered off the main thread and kept
/// for a while: panning back over them costs nothing. While a tile is being
/// drawn, a larger one already drawn stands in, stretched.
private final class TileView: NSView {
    var world: WorldMap? { didSet { layoutTiles() } }
    var relief: WorldRelief?
    var camera = MapCamera(center: CGPoint(x: 0.5, y: 0.5), zoom: 2)
    var style = MapTileRenderer.Style.light {
        didSet {
            guard style != oldValue else { return }
            cache.removeAll()
            order.removeAll()
            root.backgroundColor = style.water
            layoutTiles()
        }
    }
    var scale: CGFloat = 2 { didSet { if scale != oldValue { cache.removeAll(); order.removeAll() } } }

    private struct Key: Hashable { let z, x, y: Int }

    private let root = CALayer()
    private var cache: [Key: CGImage] = [:]
    private var order: [Key] = []
    private let capacity = 96
    private var shown: [Key: CALayer] = [:]
    private var pending: [Key: Operation] = [:]
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        q.qualityOfService = .userInitiated
        return q
    }()

    var shownCount: Int { shown.count }
    /// Tiles still being drawn.
    var isBusy: Bool { !pending.isEmpty }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: the layers are this view's own to arrange.
        root.isGeometryFlipped = true
        root.backgroundColor = style.water
        layer = root
        wantsLayer = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func layoutTiles() {
        guard let world, bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let z = max(0, min(Int(MapCamera.maxZoom), Int(camera.zoom.rounded())))
        let n = 1 << z
        let view = camera.worldRect(in: bounds.size)
        let x0 = max(0, Int((view.minX * Double(n)).rounded(.down))), x1 = min(n - 1, Int((view.maxX * Double(n)).rounded(.down)))
        let y0 = max(0, Int((view.minY * Double(n)).rounded(.down))), y1 = min(n - 1, Int((view.maxY * Double(n)).rounded(.down)))
        var wanted = Set<Key>()
        if x0 <= x1, y0 <= y1 {
            for x in x0...x1 { for y in y0...y1 { wanted.insert(Key(z: z, x: x, y: y)) } }
        }

        // Drawing that's no longer wanted is dropped before it starts.
        for (key, op) in pending where !wanted.contains(key) { op.cancel(); pending[key] = nil }

        for key in wanted {
            let layer = shown[key] ?? {
                let l = CALayer()
                l.contentsGravity = .resize
                l.magnificationFilter = .linear
                root.addSublayer(l)
                shown[key] = l
                return l
            }()
            let tileWorld = 1 / Double(n)
            let origin = camera.screenPoint(CGPoint(x: Double(key.x) * tileWorld, y: Double(key.y) * tileWorld), in: bounds.size)
            let side = tileWorld * WebMercator.worldSize(atZoom: camera.zoom)
            // Rounded out to whole points: tiles meeting at fractions leave hairlines.
            layer.frame = CGRect(x: origin.x.rounded(.down), y: origin.y.rounded(.down),
                                 width: (origin.x + side).rounded(.up) - origin.x.rounded(.down),
                                 height: (origin.y + side).rounded(.up) - origin.y.rounded(.down))
            if let image = cache[key] {
                if (layer.contents as AnyObject?) !== image {
                    layer.contents = image
                    layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                }
                touch(key)
            } else {
                if let (image, rect) = standIn(for: key) {
                    layer.contents = image
                    layer.contentsRect = rect
                } else {
                    layer.contents = nil
                }
                render(key, world: world)
            }
        }
        for (key, layer) in shown where !wanted.contains(key) {
            layer.removeFromSuperlayer()
            shown[key] = nil
        }
    }

    /// A drawn tile further out that covers `key`, and the part of it that does.
    private func standIn(for key: Key) -> (CGImage, CGRect)? {
        guard key.z > 0 else { return nil }
        for up in 1...min(5, key.z) {
            let parent = Key(z: key.z - up, x: key.x >> up, y: key.y >> up)
            guard let image = cache[parent] else { continue }
            let span = 1 / Double(1 << up)
            let fx = Double(key.x - (parent.x << up)) * span, fy = Double(key.y - (parent.y << up)) * span
            // contentsRect counts from the image's bottom.
            return (image, CGRect(x: fx, y: 1 - fy - span, width: span, height: span))
        }
        return nil
    }

    private func render(_ key: Key, world: WorldMap) {
        guard pending[key] == nil else { return }
        let pixels = Int(256 * scale), style = self.style, relief = self.relief
        let op = BlockOperation()
        op.addExecutionBlock { [weak op, weak self] in
            guard op?.isCancelled == false,
                  let image = MapTileRenderer.tile(world, relief: relief, z: key.z, x: key.x, y: key.y, pixels: pixels,
                                                   style: style) else { return }
            DispatchQueue.main.async { self?.drawn(image, for: key, style: style) }
        }
        pending[key] = op
        queue.addOperation(op)
    }

    private func drawn(_ image: CGImage, for key: Key, style: MapTileRenderer.Style) {
        pending[key] = nil
        guard self.style == style else { return }
        cache[key] = image
        touch(key)
        if let layer = shown[key] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = image
            layer.contentsRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            CATransaction.commit()
        }
    }

    private func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
        while order.count > capacity {
            let old = order.removeFirst()
            if shown[old] == nil { cache[old] = nil } else { order.append(old); break }
        }
    }
}

// MARK: - Markers and place names

private final class MarkView: NSView {
    weak var model: LibraryModel?
    var world: WorldMap?
    var clusters: MapClusters?
    var camera = MapCamera(center: CGPoint(x: 0.5, y: 0.5), zoom: 2)
    var dark = false { didSet { needsDisplay = true } }
    /// What the last draw put where, top-most last.
    private(set) var drawn: [(rect: CGRect, cluster: MapCluster)] = []

    /// From this zoom a single photo shows as its thumbnail.
    static let thumbnailZoom = 13.0
    static let thumbSide: CGFloat = 52

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func marker(at p: CGPoint) -> MapCluster? {
        drawn.last { $0.rect.insetBy(dx: -3, dy: -3).contains(p) }?.cluster
    }

    func rect(of cluster: MapCluster) -> CGRect? {
        drawn.last { $0.cluster == cluster }?.rect
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Markers are placed first so names keep clear of them, then drawn
        // over the names.
        let markers = placeMarkers()
        drawPlaces(ctx, avoiding: markers.map(\.rect))
        drawMarkers(markers, ctx)
    }

    // Names of towns and cities: the more important first, and none over
    // another.
    private var labelSizes: [String: CGSize] = [:]

    private func drawPlaces(_ ctx: CGContext, avoiding markers: [CGRect]) {
        guard let world else { return }
        let view = camera.worldRect(in: bounds.size)
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let text: NSColor = dark ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.25, alpha: 1)
        let halo: NSColor = dark ? NSColor(white: 0, alpha: 0.75) : NSColor(white: 1, alpha: 0.85)
        var taken = markers.map { $0.insetBy(dx: -2, dy: -2) }
        let names = markers.count
        let inside = bounds.insetBy(dx: 4, dy: 4)
        for place in world.places where place.minZoom <= camera.zoom {
            guard view.contains(place.point) else { continue }
            let p = camera.screenPoint(place.point, in: bounds.size)
            let size = labelSizes[place.name] ?? {
                let s = (place.name as NSString).size(withAttributes: [.font: font])
                labelSizes[place.name] = s
                return s
            }()
            let rect = CGRect(x: p.x + 5, y: p.y - size.height / 2, width: size.width, height: size.height)
            let room = rect.union(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).insetBy(dx: -4, dy: -2)
            guard inside.contains(rect), !taken.contains(where: { $0.intersects(room) }) else { continue }
            taken.append(room)
            if taken.count - names > 80 { break }
            ctx.setFillColor(text.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
            let name = place.name as NSString
            name.draw(at: rect.origin, withAttributes: [.font: font, .strokeColor: halo, .strokeWidth: 4])
            name.draw(at: rect.origin, withAttributes: [.font: font, .foregroundColor: text])
        }
    }

    /// Where each marker in view goes, singles first so a count is never
    /// hidden under one.
    private func placeMarkers() -> [(rect: CGRect, cluster: MapCluster)] {
        guard let clusters else { return [] }
        let margin = 60 / WebMercator.worldSize(atZoom: camera.zoom)
        let view = camera.worldRect(in: bounds.size).insetBy(dx: -margin, dy: -margin)
        let thumbs = camera.zoom >= Self.thumbnailZoom
        return clusters.clusters(atZoom: camera.zoom, in: view)
            .sorted { ($0.count, $0.photoID) < ($1.count, $1.photoID) }
            .map { c in
                let p = camera.screenPoint(c.point, in: bounds.size)
                let r: CGFloat = c.isSingle ? (thumbs ? Self.thumbSide / 2 : 6) : 13 + min(10, 3.5 * log10(Double(c.count)))
                return (CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r), c)
            }
    }

    private func drawMarkers(_ markers: [(rect: CGRect, cluster: MapCluster)], _ ctx: CGContext) {
        drawn = markers
        guard let model else { return }
        let accent = NSColor.controlAccentColor
        let thumbs = camera.zoom >= Self.thumbnailZoom
        for (rect, c) in markers {
            let p = CGPoint(x: rect.midX, y: rect.midY)
            if c.isSingle, thumbs {
                drawThumbnail(c, in: rect, model: model, ctx: ctx)
            } else if c.isSingle {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: rect)
                ctx.setFillColor(accent.cgColor)
                ctx.fillEllipse(in: rect.insetBy(dx: 2, dy: 2))
            } else {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: rect)
                ctx.setFillColor(accent.withAlphaComponent(0.92).cgColor)
                ctx.fillEllipse(in: rect.insetBy(dx: 2.5, dy: 2.5))
                let label = Self.countLabel(c.count) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                                                            .foregroundColor: NSColor.white]
                let size = label.size(withAttributes: attrs)
                label.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y - size.height / 2), withAttributes: attrs)
            }
        }
    }

    private func drawThumbnail(_ c: MapCluster, in rect: CGRect, model: LibraryModel, ctx: CGContext) {
        let frame = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        frame.fill()
        let inner = rect.insetBy(dx: 2.5, dy: 2.5)
        if let item = model.item(id: c.photoID), let image = model.cachedThumb(item) {
            ctx.saveGState()
            NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4).addClip()
            // Filling the square, as the grid's cells do.
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let k = max(inner.width / w, inner.height / h)
            let draw = CGRect(x: inner.midX - w * k / 2, y: inner.midY - h * k / 2, width: w * k, height: h * k)
            // The view is flipped; the image isn't.
            ctx.translateBy(x: 0, y: draw.midY * 2)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: draw)
            ctx.restoreGState()
        } else {
            NSColor.gray.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: inner, xRadius: 4, yRadius: 4).fill()
            if let item = model.item(id: c.photoID) { model.loadThumb(item) }
        }
        if c.mediaType == .video {
            let badge = CGRect(x: inner.minX + 3, y: inner.maxY - 15, width: 12, height: 12)
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let play = NSBezierPath()
            play.move(to: CGPoint(x: badge.minX + 4.5, y: badge.minY + 3))
            play.line(to: CGPoint(x: badge.minX + 4.5, y: badge.maxY - 3))
            play.line(to: CGPoint(x: badge.maxX - 3, y: badge.midY))
            play.close()
            NSColor.white.setFill()
            play.fill()
        }
    }

    static func countLabel(_ n: Int) -> String {
        n < 1000 ? "\(n)" : n < 10_000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n / 1000)k"
    }
}

// MARK: - A marker's photos

/// What a marker holds, beside it: its photos in the view's order, with what
/// and when. Scrolls — two fingers on a trackpad — when there are more than a
/// few rows. Clicking one shows it in the library.
struct MapPhotoList: View {
    @EnvironmentObject var model: LibraryModel
    @EnvironmentObject var thumbs: ThumbnailSignal
    let items: [PhotoItem]
    let open: (Int64) -> Void

    static let side: CGFloat = 84, spacing: CGFloat = 6, columns = 5, maxRows = 5

    private var single: Bool { items.count == 1 }
    private var side: CGFloat { single ? 220 : Self.side }
    private var gridWidth: CGFloat {
        single ? side : CGFloat(Self.columns) * Self.side + CGFloat(Self.columns - 1) * Self.spacing
    }
    private var gridHeight: CGFloat {
        let rows = single ? 1 : (items.count + Self.columns - 1) / Self.columns
        let shown = min(rows, Self.maxRows)
        // Part of the next row shows when there's more: plainly a list that scrolls.
        let peek: CGFloat = rows > Self.maxRows ? side * 0.4 : 0
        return CGFloat(shown) * side + CGFloat(max(0, shown - 1)) * Self.spacing + peek
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.heading(items)).font(.headline)
                if let when = Self.when(items) {
                    Text(when).font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView(.vertical) {
                LazyVGrid(columns: [GridItem(.fixed(side), spacing: Self.spacing)]
                            .repeated(single ? 1 : Self.columns), spacing: Self.spacing) {
                    ForEach(items) { item in
                        tile(item)
                    }
                }
            }
            .frame(width: gridWidth, height: gridHeight)
            Text(single ? "Click it to show it in the library." : "Click one to show it in the library.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func tile(_ item: PhotoItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let cg = model.cachedThumb(item) {
                Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: side, height: side)
            } else {
                Color.gray.opacity(0.3).frame(width: side, height: side)
                    .onAppear { model.loadThumb(item) }
            }
            if item.mediaType == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.5), in: Circle())
                    .padding(4)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { open(item.id) }
        .help(item.displayName)
    }

    /// "48 photos", "3 photos and 1 video".
    static func heading(_ items: [PhotoItem]) -> String {
        let videos = items.filter { $0.mediaType == .video }.count, photos = items.count - videos
        func n(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
        switch (photos, videos) {
        case (_, 0): return n(photos, "photo")
        case (0, _): return n(videos, "video")
        default: return n(photos, "photo") + " and " + n(videos, "video")
        }
    }

    /// When they were taken: one day, or the first and last, from the dates
    /// the files carry. Nil when none does.
    static func when(_ items: [PhotoItem]) -> String? {
        let dates = items.filter(\.hasDate).compactMap(\.capturedAt)
        guard let first = dates.min(), let last = dates.max() else { return nil }
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: first), to: Date(timeIntervalSince1970: last))
    }
}

private extension Array where Element == GridItem {
    func repeated(_ n: Int) -> [GridItem] { Array(repeating: self[0], count: n) }
}

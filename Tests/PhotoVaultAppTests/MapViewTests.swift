import Testing
import AppKit
import CoreGraphics
@testable import PhotoVault
import PhotoVaultCore

/// The map's handling of the mouse and trackpad, with events made here: no
/// screen needed, and nothing to grant.
@MainActor
@Suite("Map view", .serialized)
struct MapViewTests {
    /// The map holds its model weakly, as the app's views do; the app keeps
    /// it for good, and so must the test.
    private let model = LibraryModel()

    // Public landmarks, never anyone's photos.
    private let bigBen = GeoPoint(latitude: 51.5007, longitude: -0.1246)
    private let eiffel = GeoPoint(latitude: 48.8584, longitude: 2.2945)

    private func makeMap(_ points: [MapPoint], camera: MapCamera) async throws -> (MapCanvas, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let canvas = MapCanvas(model: model)
        window.contentView = canvas
        canvas.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        canvas.layoutSubtreeIfNeeded()
        canvas.update(points: points, view: "all", camera: camera, dark: false)
        // Clusters are gathered off the main thread: wait for them, letting
        // the main actor run meanwhile.
        let deadline = Date().addingTimeInterval(5)
        while !canvas.isReady, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try #require(canvas.isReady, "clusters built")
        canvas.display()
        return (canvas, window)
    }

    /// A point in the canvas (top-left origin) as the window's own.
    private func mouse(_ type: NSEvent.EventType, at p: CGPoint, in window: NSWindow, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: 700 - p.y), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func wait(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }
    /// The zoom is animated on a run-loop timer, which waiting with `await`
    /// doesn't drive: this runs it.
    private func runTimers(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private func near(_ a: CGPoint, _ b: CGPoint, _ tolerance: Double = 0.5) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    @Test func draggingCarriesTheMapWithThePointer() async throws {
        let start = MapCamera(center: WebMercator.project(bigBen), zoom: 8)
        let (map, window) = try await makeMap([], camera: start)
        let size = map.bounds.size
        let from = CGPoint(x: 300, y: 300), to = CGPoint(x: 450, y: 220)
        let grabbed = map.camera.worldPoint(from, in: size)
        map.mouseDown(with: mouse(.leftMouseDown, at: from, in: window))
        map.mouseDragged(with: mouse(.leftMouseDragged, at: to, in: window))
        map.mouseUp(with: mouse(.leftMouseUp, at: to, in: window))
        #expect(near(map.camera.screenPoint(grabbed, in: size), to), "the place grabbed is under the pointer where it was let go")
        #expect(map.camera.zoom == 8)
    }

    /// As web maps do: a two-finger swipe up or down zooms, smoothly, and
    /// sideways does nothing; dragging is what moves the map.
    @Test func twoFingerSwipesAndTheWheelZoom() async throws {
        let start = MapCamera(center: WebMercator.project(bigBen), zoom: 8)
        let (map, _) = try await makeMap([], camera: start)
        func scroll(_ units: CGScrollEventUnit, vertical: Int32, sideways: Int32 = 0) throws {
            let e = try #require(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                         wheel1: vertical, wheel2: sideways, wheel3: 0))
            map.scrollWheel(with: try #require(NSEvent(cgEvent: e)))
        }
        try scroll(.pixel, vertical: 45)
        #expect(abs(map.camera.zoom - (start.zoom + 45 / MapCanvas.swipePerLevel)) < 1e-9, "zoomed in by part of a level")
        try scroll(.pixel, vertical: -45)
        #expect(abs(map.camera.zoom - start.zoom) < 1e-9, "and the other way, out again")
        let before = map.camera
        try scroll(.pixel, vertical: 0, sideways: 60)
        #expect(map.camera == before, "a sideways swipe neither zooms nor moves")

        try scroll(.line, vertical: 3)
        #expect(abs(map.camera.zoom - (before.zoom + 0.5)) < 1e-9, "a mouse wheel's notch zooms half a level")
    }

    @Test func clickingAMarkerListsItsPhotosAndLeavesTheMapAlone() async throws {
        let points = [MapPoint(id: 7, point: bigBen, mediaType: .photo), MapPoint(id: 8, point: eiffel, mediaType: .photo)]
        // Close in on London: Big Ben alone, as a thumbnail.
        let close = MapCamera(center: WebMercator.project(bigBen), zoom: 14)
        let (map, window) = try await makeMap(points, camera: close)
        var opened: [Int64] = []
        map.openPhoto = { opened.append($0) }
        let middle = CGPoint(x: 500, y: 350)
        map.mouseDown(with: mouse(.leftMouseDown, at: middle, in: window))
        map.mouseUp(with: mouse(.leftMouseUp, at: middle, in: window))
        #expect(map.listed == [7], "a single photo is listed too")
        #expect(map.camera == close, "the map stays where it was")
        #expect(opened.isEmpty, "nothing opens until a photo in the list is chosen")

        // Out where London and Paris are one circle: its photos, and the map
        // still where it was.
        let far = MapCamera(center: WebMercator.project(bigBen), zoom: 3)
        map.update(points: points, view: "all-out", camera: far, dark: false)
        try await wait(0.1)   // drawn at the new zoom, as a person would see it before clicking
        let circle = map.camera.screenPoint(map.smokeClusterPoint ?? .zero, in: map.bounds.size)
        map.mouseDown(with: mouse(.leftMouseDown, at: circle, in: window))
        map.mouseUp(with: mouse(.leftMouseUp, at: circle, in: window))
        runTimers(0.4)
        #expect(Set(map.listed) == [7, 8])
        #expect(map.camera == far, "neither zoomed nor moved")

        // A double-click on it zooms in to the two.
        map.mouseDown(with: mouse(.leftMouseDown, at: circle, in: window, clicks: 2))
        map.mouseUp(with: mouse(.leftMouseUp, at: circle, in: window, clicks: 2))
        runTimers(0.5)
        #expect(map.camera.zoom > 5, "zoomed in to the two (\(map.camera.zoom))")
    }

    @Test func theListSaysWhatAndWhen() {
        func item(_ id: Int64, _ type: MediaType, _ day: Double?) -> PhotoItem {
            var i = PhotoItem(relPath: "Photos/\(id).jpg", mediaType: type)
            i.id = id
            if let day { i.capturedAt = 1_775_000_000 + day * 86_400; i.hasDate = true }
            return i
        }
        let trip = [item(1, .photo, 0), item(2, .photo, 3), item(3, .video, 1)]
        #expect(MapPhotoList.heading(trip) == "2 photos and 1 video")
        #expect(MapPhotoList.heading([item(4, .photo, nil)]) == "1 photo")
        #expect(MapPhotoList.heading([item(5, .video, nil), item(6, .video, nil)]) == "2 videos")
        #expect(MapPhotoList.when([item(7, .photo, nil)]) == nil, "no dates, no line")
        #expect(MapPhotoList.when(trip)?.contains("2026") == true, "first to last day")
    }

    @Test func photosAtOneSpotAreListed() async throws {
        let points = (1...4).map { MapPoint(id: Int64($0), point: bigBen, mediaType: .photo) }
        let (map, window) = try await makeMap(points, camera: MapCamera(center: WebMercator.project(bigBen), zoom: 16))
        let middle = CGPoint(x: 500, y: 350)
        map.mouseDown(with: mouse(.leftMouseDown, at: middle, in: window))
        map.mouseUp(with: mouse(.leftMouseUp, at: middle, in: window))
        #expect(Set(map.listed) == [1, 2, 3, 4], "no zoom parts them: a list of them instead")
    }

    @Test func tilesNeverSpillOverTheToolbar() async throws {
        let (map, _) = try await makeMap([], camera: MapCamera(center: CGPoint(x: 0.5, y: 0.5), zoom: 3))
        #expect(map.tilesClipped)
        #expect(map.layer?.masksToBounds == true)
    }
}

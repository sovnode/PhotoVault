import Testing
import AppKit
import CoreGraphics
@testable import PhotoVault

/// The photo viewer's display layer. These pin down the two bugs reported
/// against it: photos stretching while cycling, and the arrow keys dying after
/// a pinch.
@MainActor
@Suite("Viewer")
struct ViewerTests {

    private func image(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.3, green: 0.6, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func makeView() -> ZoomableImageNSView {
        let view = ZoomableImageNSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        view.layout()
        return view
    }

    private func imageLayer(_ view: ZoomableImageNSView) throws -> CALayer {
        try #require(view.layer?.sublayers?.first)
    }

    private func zoomIn(_ view: ZoomableImageNSView) {
        // Same path a two-finger double-tap takes: snap to 2x.
        let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil,
                                       subtype: 0, data1: 0, data2: 0)!
        view.smartMagnify(with: event)
    }

    /// The stretch was Core Animation's implicit 0.25 s crossfade on `contents`,
    /// which drew the old photo into the new photo's frame. Swapping pictures
    /// must start no animation at all.
    @Test func switchingPhotosStartsNoAnimation() throws {
        // Host the view in a real (never shown) window, as the app does.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = makeView()
        window.contentView = view

        // Control: in this setting an ordinary sublayer *does* pick up an
        // implicit animation when its contents change. Without this, a pass
        // below could just mean animations never happen in tests.
        let plain = CALayer()
        view.layer?.addSublayer(plain)
        CATransaction.flush()
        plain.contents = image(10, 10)
        CATransaction.flush()
        let controlAnimated = plain.animationKeys()?.isEmpty == false

        view.show(image(300, 200), key: "1")
        CATransaction.flush()
        view.show(image(200, 300), key: "2")
        CATransaction.flush()
        let layer = try imageLayer(view)

        #expect(controlAnimated, "control: an ordinary sublayer animates a contents swap")
        #expect(layer.animationKeys() == nil, "an implicit animation would stretch one photo into the next")
        #expect(layer.contentsGravity == .resizeAspect, "if contents and frame ever disagree, letterbox — never stretch")
        plain.removeFromSuperlayer()
    }

    @Test func eachPhotoGetsAFrameOfItsOwnShape() throws {
        let view = makeView()
        view.show(image(300, 200), key: "landscape")
        let wide = try imageLayer(view).frame
        #expect(abs(wide.width / wide.height - 1.5) < 0.01)

        view.show(image(200, 300), key: "portrait")
        let tall = try imageLayer(view).frame
        #expect(abs(tall.width / tall.height - 2.0 / 3.0) < 0.01)
        #expect(tall.height <= 800 && tall.width <= 1000, "fitted inside the window")
    }

    /// The thumbnail is shown first and replaced by the full decode of the same
    /// picture. That upgrade must keep the user's zoom; a new picture resets it.
    @Test func upgradingToTheFullDecodeKeepsTheZoom() throws {
        let view = makeView()
        view.show(image(150, 100), key: "7")          // thumbnail
        zoomIn(view)
        let zoomed = try imageLayer(view).frame
        #expect(zoomed.width > 1000, "zoomed in past the window")

        view.show(image(3000, 2000), key: "7")        // same photo, full resolution
        #expect(abs(try imageLayer(view).frame.width - zoomed.width) < 1, "zoom survives the sharper image")

        view.show(image(3000, 2000), key: "8")        // next photo
        #expect(try imageLayer(view).frame.width <= 1000, "a new photo starts fitted")
    }

    /// After a pinch the arrow keys used to be ignored. They must always step.
    @Test func arrowKeysStepEvenWhenZoomedIn() throws {
        let view = makeView()
        view.show(image(300, 200), key: "1")
        zoomIn(view)
        var steps: [Int] = []
        view.onStep = { steps.append($0) }

        view.keyDown(with: key(NSEvent.SpecialKey.rightArrow.rawValue, code: 124))
        view.keyDown(with: key(NSEvent.SpecialKey.leftArrow.rawValue, code: 123))

        #expect(steps == [1, -1])
    }

    @Test func escapeLeavesTheViewer() {
        let view = makeView()
        var escaped = false
        view.onEscape = { escaped = true }
        view.keyDown(with: key(0x1B, code: 53))
        #expect(escaped)
    }

    @Test func noImageYetIsNotAnError() throws {
        let view = makeView()
        view.show(nil, key: "1")
        #expect(try imageLayer(view).frame == .zero)
        view.show(image(300, 200), key: "1")
        #expect(try imageLayer(view).frame.width > 0, "the thumbnail arriving later still appears")
    }

    private func key(_ scalar: Int, code: UInt16) -> NSEvent {
        let char = String(UnicodeScalar(UInt32(scalar))!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                windowNumber: 0, context: nil, characters: char,
                                charactersIgnoringModifiers: char, isARepeat: false, keyCode: code)!
    }
}

@MainActor
@Suite("Full-resolution cache")
struct FullResCacheTests {

    /// Decoded full-size pixels are what can page to swap, so the cache must
    /// never hold more than its cap.
    @Test func holdsAtMostItsCapacity() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pv-fullres-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for i in 0..<5 {
            let url = dir.appendingPathComponent("\(i).png")
            let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(dest)
            urls.append(url)
        }

        let cache = FullResCache(capacity: 3)
        for (i, url) in urls.enumerated() { _ = await cache.load(Int64(i), url: url) }

        let held = (0..<5).filter { cache.image(for: Int64($0)) != nil }
        #expect(held == [2, 3, 4], "the three most recent, oldest evicted first")
        cache.removeAll()
        #expect((0..<5).allSatisfy { cache.image(for: Int64($0)) == nil })
    }
}

/// The header appears only when the cursor really moves.
@Suite("Pointer motion")
struct PointerMotionTests {
    @Test func noBaselineIsNotMovement() {
        #expect(!PointerMotion.hasMoved(from: nil, to: CGPoint(x: 500, y: 500)),
                "the first event after opening a photo only sets the baseline")
    }

    /// The case behind the flicker: the picture changes under a still cursor
    /// and macOS reports "movement" at the same spot.
    @Test func aRepeatedPositionIsNotMovement() {
        let p = CGPoint(x: 812, y: 403)
        #expect(!PointerMotion.hasMoved(from: p, to: p))
    }

    @Test func jitterBelowTheThresholdIsIgnored() {
        #expect(!PointerMotion.hasMoved(from: .zero, to: CGPoint(x: 1, y: 1)))
    }

    @Test func realMovementCounts() {
        #expect(PointerMotion.hasMoved(from: .zero, to: CGPoint(x: 2, y: 0)))
        #expect(PointerMotion.hasMoved(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 60, y: 130)))
    }
}

/// Quitting during a scan asks — but only a person, never the system or
/// a script, which would hang waiting for an answer nobody sees.
@Suite("Quit policy")
struct QuitPolicyTests {
    @Test func asksWhenAPersonQuitsDuringAScan() {
        #expect(QuitPolicy.shouldAsk(scanRunning: true, reason: .user))
    }

    @Test func neverAsksTheSystemOrAScript() {
        #expect(!QuitPolicy.shouldAsk(scanRunning: true, reason: .signal))
        #expect(!QuitPolicy.shouldAsk(scanRunning: true, reason: .powerOff))
        #expect(!QuitPolicy.shouldAsk(scanRunning: true, reason: .confirmed))
    }

    @Test func neverAsksWhenNothingIsRunning() {
        #expect(!QuitPolicy.shouldAsk(scanRunning: false, reason: .user))
    }
}

/// Right-clicking the photo in the viewer offers Show in Library.
@MainActor
@Suite("Show in Library")
struct ShowInLibraryMenuTests {
    private func rightClick() -> NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func rightClickOffersShowInLibraryAndRunsIt() throws {
        let view = ZoomableImageNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var chosen = false
        view.onShowInLibrary = { chosen = true }

        let menu = try #require(view.menu(for: rightClick()))
        let item = try #require(menu.items.first)
        #expect(item.title == "Show in Library")
        _ = item.target?.perform(item.action)
        #expect(chosen)
    }

    /// A photo in the Trash isn't in the library, so there's nothing to show.
    @Test func noMenuWithoutATarget() {
        let view = ZoomableImageNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        #expect(view.menu(for: rightClick()) == nil)
    }
}

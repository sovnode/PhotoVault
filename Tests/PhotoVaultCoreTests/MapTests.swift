import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import PhotoVaultCore

// Public landmarks only, never anyone's photos.
private let bigBen = GeoPoint(latitude: 51.5007, longitude: -0.1246)
private let operaHouse = GeoPoint(latitude: -33.8568, longitude: 151.2153)
private let fuji = GeoPoint(latitude: 35.3606, longitude: 138.7274)

/// The outline as the app ships it, read from the source tree.
private let worldMapURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/World Map.pvmap")

@Suite("Map projection")
struct WebMercatorTests {
    @Test func placesLandWhereTheyShould() {
        let london = WebMercator.project(bigBen)
        #expect(abs(london.x - 0.49965) < 0.0001, "just west of the prime meridian, at the middle")
        #expect(london.y > 0.3 && london.y < 0.35, "north of the equator, which is at 0.5")
        #expect(WebMercator.project(operaHouse).y > 0.5, "south of it")
        #expect(WebMercator.project(GeoPoint(latitude: 89.9, longitude: 0)).y == 0, "the poles are cut off")
    }

    @Test func andBackAgain() {
        for p in [bigBen, operaHouse, fuji] {
            let back = WebMercator.unproject(WebMercator.project(p))
            #expect(abs(back.latitude - p.latitude) < 1e-9 && abs(back.longitude - p.longitude) < 1e-9)
        }
    }
}

@Suite("World outline")
struct WorldMapTests {
    let map: WorldMap

    init() throws { map = try WorldMap(contentsOf: worldMapURL) }

    @Test func holdsItsLayersAndPlaces() throws {
        #expect(map.credit.contains("Natural Earth"))
        for kind in [WorldMap.Kind.land, .lakes, .countryBorders, .stateBorders] {
            let layer = try #require(map.layer(kind), "\(kind)")
            #expect(!layer.levels.isEmpty)
        }
        #expect(map.layer(.land)?.level(atZoom: 0)?.fromZoom == 0)
        #expect(map.layer(.land)?.level(atZoom: 12)?.fromZoom == 6, "the most detailed level from 6 on")
        #expect(map.layer(.stateBorders)?.level(atZoom: 2) == nil, "state borders appear from zoom 3")
        #expect(map.places.count > 5_000)
        let london = try #require(map.places.first { $0.name == "London" })
        #expect(london.minZoom < 4, "a capital is named early")
        let w = WebMercator.project(bigBen)
        #expect(abs(london.point.x - w.x) < 0.001 && abs(london.point.y - w.y) < 0.001)
    }

    @Test func refusesAnythingElse() {
        #expect(throws: VaultError.self) { try WorldMap(data: Data("not a map".utf8)) }
        #expect(throws: VaultError.self) { try WorldMap(data: Data("PVMAP002".utf8)) }
    }

    /// The colour of the pixel at `place` in the tile holding it.
    private func pixel(at place: GeoPoint, zoom z: Int) throws -> (Int, Int, Int) {
        let w = WebMercator.project(place)
        let n = Double(1 << z)
        let tx = Int(w.x * n), ty = Int(w.y * n)
        let image = try #require(MapTileRenderer.tile(map, z: z, x: tx, y: ty, pixels: 256, style: .light))
        let px = min(255, Int((w.x * n - Double(tx)) * 256)), py = min(255, Int((w.y * n - Double(ty)) * 256))
        let ctx = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(image, in: CGRect(x: -px, y: py - 255, width: 256, height: 256))
        let d = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        return (Int(d[0]), Int(d[1]), Int(d[2]))
    }

    private func isLand(_ c: (Int, Int, Int)) -> Bool { c.0 > 230 && c.2 < 240 }   // pale sand
    private func isWater(_ c: (Int, Int, Int)) -> Bool { c.2 > c.0 + 15 }           // blue

    @Test func drawsLandAndSeaWhereTheyAre() throws {
        let paris = GeoPoint(latitude: 48.8566, longitude: 2.3522)
        let midAtlantic = GeoPoint(latitude: 40, longitude: -40)
        let lakeSuperior = GeoPoint(latitude: 47.7, longitude: -87.5)
        for z in [2, 5, 8, 12] {
            #expect(isLand(try pixel(at: paris, zoom: z)), "Paris is on land at zoom \(z)")
            #expect(isWater(try pixel(at: midAtlantic, zoom: z)), "mid-Atlantic is sea at zoom \(z)")
        }
        #expect(isWater(try pixel(at: lakeSuperior, zoom: 6)), "lakes are drawn as water")
    }

    @Test func aTileIsQuickToDraw() throws {
        // Western Europe at street-level zooms: the busiest coastlines.
        let start = Date()
        var tiles = 0
        for z in [6, 9, 12] {
            let w = WebMercator.project(bigBen)
            let n = Double(1 << z)
            for dx in -2...2 {
                for dy in -2...2 {
                    _ = MapTileRenderer.tile(map, z: z, x: Int(w.x * n) + dx, y: Int(w.y * n) + dy, pixels: 512, style: .dark)
                    tiles += 1
                }
            }
        }
        let each = Date().timeIntervalSince(start) / Double(tiles)
        #expect(each < 0.05, "\(Int(each * 1000)) ms a tile")
    }
}

@Suite("Map clusters")
struct MapClusterTests {
    private func points(_ places: [GeoPoint]) -> [MapPoint] {
        places.enumerated().map { MapPoint(id: Int64($0.offset + 1), point: $0.element, mediaType: .photo) }
    }

    private let everywhere = CGRect(x: -1, y: -1, width: 3, height: 3)

    @Test func everyPhotoIsCountedOnceAtEveryZoom() {
        var places: [GeoPoint] = []
        for i in 0..<300 {
            let t = Double(i)
            places.append(GeoPoint(latitude: 51.5 + sin(t) * 0.05 * (t / 300), longitude: -0.12 + cos(t) * 0.08 * (t / 300)))
        }
        places += [operaHouse, fuji]
        let clusters = MapClusters(points(places))
        for zoom in stride(from: 0.0, through: 18, by: 1.5) {
            let all = clusters.clusters(atZoom: zoom, in: everywhere)
            #expect(all.reduce(0) { $0 + $1.count } == places.count, "zoom \(zoom)")
            for c in all.prefix(20) {
                #expect(clusters.photos(in: c, atZoom: zoom).count == c.count)
            }
        }
        #expect(clusters.clusters(atZoom: 0, in: everywhere).count == 2, "the whole world is 256 points across: Sydney and Fuji are within 60")
        #expect(clusters.clusters(atZoom: 2, in: everywhere).count == 3, "London, Sydney and Fuji")
        #expect(clusters.clusters(atZoom: 17, in: everywhere).count > 100, "London spread out close in")
    }

    @Test func zoomingInSplitsAndPlacesStayPut() {
        let a = GeoPoint(latitude: 51.5007, longitude: -0.1246)
        let b = GeoPoint(latitude: 51.5014, longitude: -0.1419)   // about 1.2 km west
        let clusters = MapClusters(points([a, b]))
        #expect(clusters.clusters(atZoom: 10, in: everywhere).count == 1)
        #expect(clusters.clusters(atZoom: 16, in: everywhere).count == 2)
        let single = clusters.clusters(atZoom: 16, in: everywhere).first { $0.photoID == 1 }!
        #expect(single.isSingle && single.point == WebMercator.project(a))
        let both = clusters.clusters(atZoom: 10, in: everywhere)[0]
        #expect(both.bounds.contains(WebMercator.project(a)) || both.bounds.minX == WebMercator.project(b).x)
        #expect(both.bounds.width > 0)
    }

    @Test func photosTakenAtOneSpotNeverPart() {
        let clusters = MapClusters(points(Array(repeating: fuji, count: 5)))
        let top = clusters.clusters(atZoom: 18, in: everywhere)
        #expect(top.count == 1 && top[0].count == 5)
        #expect(top[0].bounds.width == 0 && top[0].bounds.height == 0, "so the map shows them as a list")
        #expect(Set(clusters.photos(in: top[0], atZoom: 18).map(\.id)) == [1, 2, 3, 4, 5])
    }

    @Test func onlyWhatsInTheWindow() {
        let clusters = MapClusters(points([bigBen, operaHouse]))
        let london = WebMercator.project(bigBen)
        let window = CGRect(x: london.x - 0.01, y: london.y - 0.01, width: 0.02, height: 0.02)
        #expect(clusters.clusters(atZoom: 8, in: window).map(\.photoID) == [1])
        #expect(clusters.bounds?.contains(london) == true)
        #expect(MapClusters([]).bounds == nil)
    }

    @Test func aHundredThousandPhotosClusterInSeconds() {
        var rng = SystemRandomNumberGenerator()
        var places: [GeoPoint] = []
        // Spread over a few hundred kilometres of England, as a big library would be.
        for _ in 0..<100_000 {
            places.append(GeoPoint(latitude: Double.random(in: 50...54, using: &rng), longitude: Double.random(in: -4...1, using: &rng)))
        }
        let start = Date()
        let clusters = MapClusters(points(places))
        let built = Date().timeIntervalSince(start)
        #expect(built < 5, "\(built) s to build")
        let lookup = Date()
        for zoom in 0...17 { _ = clusters.clusters(atZoom: Double(zoom), in: everywhere) }
        #expect(Date().timeIntervalSince(lookup) / 18 < 0.05, "a look-up per frame stays well under a frame's time")
    }
}

@Suite("Map camera")
struct MapCameraTests {
    let size = CGSize(width: 1000, height: 600)

    @Test func screenAndWorldAgree() {
        let c = MapCamera(center: CGPoint(x: 0.5, y: 0.4), zoom: 5)
        let w = CGPoint(x: 0.501, y: 0.399)
        let s = c.screenPoint(w, in: size)
        let back = c.worldPoint(s, in: size)
        #expect(abs(back.x - w.x) < 1e-12 && abs(back.y - w.y) < 1e-12)
        #expect(c.screenPoint(c.center, in: size) == CGPoint(x: 500, y: 300), "the centre is in the middle")
        #expect(abs(c.worldRect(in: size).width - 1000 / (256 * 32)) < 1e-12)
    }

    @Test func zoomingKeepsThePointUnderThePointer() {
        let c = MapCamera(center: CGPoint(x: 0.5, y: 0.4), zoom: 5)
        let anchor = CGPoint(x: 800, y: 100)
        let under = c.worldPoint(anchor, in: size)
        let z = c.zoomed(by: 1.5, around: anchor, in: size)
        #expect(z.zoom == 6.5)
        let after = z.worldPoint(anchor, in: size)
        #expect(abs(after.x - under.x) < 1e-12 && abs(after.y - under.y) < 1e-12)
        #expect(c.zoomed(by: 40, around: anchor, in: size).zoom == MapCamera.maxZoom)
    }

    @Test func theWorldAlwaysFillsTheView() {
        let out = MapCamera(center: CGPoint(x: 0.5, y: 0.5), zoom: 0).clamped(in: size)
        #expect(abs(out.zoom - log2(1000 / 256)) < 1e-9, "no smaller than the view is wide")
        let edge = MapCamera(center: CGPoint(x: 0.99, y: 0.01), zoom: 6).clamped(in: size)
        let r = edge.worldRect(in: size)
        #expect(r.maxX <= 1 + 1e-12 && r.minY >= -1e-12, "not panned past the world's edge")
        let dragged = MapCamera(center: CGPoint(x: 0.5, y: 0.5), zoom: 6).panned(by: CGSize(width: 100, height: 0), in: size)
        #expect(dragged.center.x < 0.5, "dragging right shows what's to the west")
    }

    @Test func fittingShowsEverythingWithoutGoingTooClose() {
        let london = WebMercator.project(bigBen), sydney = WebMercator.project(operaHouse)
        let both = CGRect(x: min(london.x, sydney.x), y: min(london.y, sydney.y),
                          width: abs(london.x - sydney.x), height: abs(london.y - sydney.y))
        let c = MapCamera.fitting(both, in: size)
        let r = c.worldRect(in: size)
        #expect(r.contains(london) && r.contains(sydney))
        let one = MapCamera.fitting(CGRect(origin: london, size: .zero), in: size)
        #expect(one.zoom == 14 && one.center == london, "one photo: its neighbourhood")
    }

    @Test func keptInTheCatalogAsText() {
        let c = MapCamera(center: CGPoint(x: 0.25, y: 0.75), zoom: 7.5)
        #expect(MapCamera(storageValue: c.storageValue) == c)
        #expect(MapCamera(storageValue: "nonsense") == nil)
        #expect(MapCamera(storageValue: "1 2") == nil)
    }
}

@Suite("Terrain shading")
struct WorldReliefTests {
    private let reliefURL = worldMapURL.deletingLastPathComponent().appendingPathComponent("World Relief.pvrelief")

    @Test func holdsMountainsAndLeavesOutFlatGround() throws {
        let relief = try WorldRelief(contentsOf: reliefURL)
        #expect(relief.credit.contains("Natural Earth"))
        #expect(relief.maxZoom == 6)
        func tile(_ p: GeoPoint, _ z: Int) -> (Int, Int) {
            let w = WebMercator.project(p), n = Double(1 << z)
            return (Int(w.x * n), Int(w.y * n))
        }
        let sierra = tile(GeoPoint(latitude: 37.7, longitude: -119.2), 6)
        let atlantic = tile(GeoPoint(latitude: 30, longitude: -40), 6)
        #expect(relief.image(z: 6, x: sierra.0, y: sierra.1) != nil, "the Sierra Nevada has slopes")
        #expect(relief.image(z: 6, x: atlantic.0, y: atlantic.1) == nil, "the open sea isn't stored")
        // Closer in than it's stored, the tile above stands in.
        let close = tile(GeoPoint(latitude: 37.7, longitude: -119.2), 10)
        let (_, area) = try #require(relief.shading(z: 10, x: close.0, y: close.1))
        #expect(abs(area.width - 1.0 / 64) < 1e-12)
        #expect(throws: VaultError.self) { try WorldRelief(data: Data("PVRELF01".utf8)) }
    }

    /// The colour at `place` in its tile, drawn with or without shading.
    private func pixel(_ place: GeoPoint, zoom z: Int, relief: WorldRelief?, style: MapTileRenderer.Style) throws -> Int {
        let map = try WorldMap(contentsOf: worldMapURL)
        let w = WebMercator.project(place), n = Double(1 << z)
        let tx = Int(w.x * n), ty = Int(w.y * n)
        let image = try #require(MapTileRenderer.tile(map, relief: relief, z: z, x: tx, y: ty, pixels: 256, style: style))
        let ctx = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let px = min(255, Int((w.x * n - Double(tx)) * 256)), py = min(255, Int((w.y * n - Double(ty)) * 256))
        ctx.draw(image, in: CGRect(x: -px, y: py - 255, width: 256, height: 256))
        let d = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        return Int(d[0]) + Int(d[1]) + Int(d[2])
    }

    @Test func shadesSlopesAndLeavesFlatGroundAlone() throws {
        let relief = try WorldRelief(contentsOf: reliefURL)
        // A shadowed slope east of Yosemite, and the middle of Kansas.
        var darker = 0
        for dx in stride(from: -0.3, through: 0.3, by: 0.1) {
            let slope = GeoPoint(latitude: 37.75, longitude: -119.3 + dx)
            if try pixel(slope, zoom: 8, relief: relief, style: .light) < pixel(slope, zoom: 8, relief: nil, style: .light) - 6 { darker += 1 }
        }
        #expect(darker >= 2, "some of the Sierra comes out darker (\(darker) of 7 points)")
        let kansas = GeoPoint(latitude: 38.5, longitude: -98)
        #expect(abs(try pixel(kansas, zoom: 8, relief: relief, style: .light) - pixel(kansas, zoom: 8, relief: nil, style: .light)) <= 9,
                "flat ground keeps its colour")
    }

    @Test func stretchedCloseInItStaysSmooth() throws {
        // One stored tile of single-pixel stripes, stretched eight times. Core
        // Graphics' own enlarging held each pixel flat for half its width —
        // runs of four or more equal values here — which showed as squares.
        var bytes = [UInt8](repeating: 0, count: 256 * 256)
        for y in 0..<256 { for x in 0..<256 { bytes[y * 256 + x] = x % 2 == 0 ? 64 : 192 } }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: 256, height: 256, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 256,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let png = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        // A file holding just that tile, at zoom 0.
        var file = Data("PVRELF01".utf8)
        file.append(contentsOf: [4, 0]); file.append(Data("test".utf8))
        file.append(0)                                   // most detailed zoom: 0
        file.append(contentsOf: [1, 0, 0, 0])            // one tile
        file.append(contentsOf: [0, 0, 0, 0, 0])         // z, x, y
        file.append(contentsOf: [0, 0, 0, 0])            // offset
        withUnsafeBytes(of: UInt32(png.length).littleEndian) { file.append(contentsOf: $0) }
        file.append(png as Data)
        let relief = try WorldRelief(data: file)

        let z = 3, n = 8.0
        let tile = CGRect(x: 3 / n, y: 3 / n, width: 1 / n, height: 1 / n)
        let shade = try #require(MapTileRenderer.shading(relief, z: z, x: 3, y: 3, tile: tile, pixels: 256, darkens: false))
        let ctx = try #require(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        ctx.draw(shade, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        let row = Array(UnsafeBufferPointer(start: try #require(ctx.data).assumingMemoryBound(to: UInt8.self).advanced(by: 128 * 256), count: 256))
        var longest = 1, run = 1
        for i in 1..<row.count { run = row[i] == row[i - 1] ? run + 1 : 1; longest = max(longest, run) }
        #expect(longest < 4, "no flat runs (longest \(longest))")
        // A wave through several values (107 up to 149 and back), not two.
        #expect(Set(row).count >= 6 && Int(row.max()!) - Int(row.min()!) > 20)
    }
}

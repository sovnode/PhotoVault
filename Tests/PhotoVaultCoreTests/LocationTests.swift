import Testing
import Foundation
import SQLite3
import CoreGraphics
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
@testable import PhotoVaultCore

// Every place in these tests is a public landmark, never anyone's photo.
private let bigBen = GeoPoint(latitude: 51.5007, longitude: -0.1246)
private let operaHouse = GeoPoint(latitude: -33.8568, longitude: 151.2153)
private let everestISO = "+27.9881+086.9250+8848.000/"

private func near(_ a: GeoPoint?, _ b: GeoPoint, within: Double = 0.0001) -> Bool {
    guard let a else { return false }
    return abs(a.latitude - b.latitude) < within && abs(a.longitude - b.longitude) < within
}

extension TestVault {
    /// A real JPEG carrying `properties` (EXIF, GPS…) in its header.
    @discardableResult
    func writeImage(_ relPath: String, properties: [CFString: Any], seed: Double = 0.5) throws -> URL {
        let url = photos.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: seed, green: 1 - seed, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw VaultError.packCorrupt("couldn't write \(relPath)") }
        return url
    }

    /// EXIF GPS as cameras write it: unsigned degrees and a hemisphere.
    static func gps(_ p: GeoPoint) -> [CFString: Any] {
        [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: abs(p.latitude), kCGImagePropertyGPSLatitudeRef: p.latitude < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude: abs(p.longitude), kCGImagePropertyGPSLongitudeRef: p.longitude < 0 ? "W" : "E",
        ]]
    }

    static func locationItem(_ iso6709: String, _ identifier: AVMetadataIdentifier = .quickTimeMetadataLocationISO6709) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = iso6709 as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }
}

@Suite("Location reading")
struct LocationReaderTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    @Test func iso6709InDecimalDegrees() {
        #expect(near(LocationReader.iso6709(everestISO), GeoPoint(latitude: 27.9881, longitude: 86.925)))
        #expect(near(LocationReader.iso6709("+51.5007-000.1246/"), bigBen), "no altitude")
        #expect(near(LocationReader.iso6709("-33.8568+151.2153+004.000/"), operaHouse), "south and east")
        #expect(near(LocationReader.iso6709("+27.9881+086.9250+8848CRSWGS_84/"), GeoPoint(latitude: 27.9881, longitude: 86.925)),
                "a coordinate system after the altitude")
        #expect(near(LocationReader.iso6709("+51.5007-0.1246"), bigBen), "no slash, and fewer longitude digits than the standard's three")
    }

    @Test func iso6709InDegreesAndMinutesOrSeconds() {
        // 51° 30.042′ N, 0° 7.476′ W, then the same in seconds.
        #expect(near(LocationReader.iso6709("+5130.042-00007.476/"), bigBen))
        #expect(near(LocationReader.iso6709("+513002.52-0000728.56/"), bigBen))
    }

    @Test func iso6709RejectsWhatIsntAPlace() {
        #expect(LocationReader.iso6709("") == nil)
        #expect(LocationReader.iso6709("Big Ben") == nil)
        #expect(LocationReader.iso6709("+51.5007/") == nil, "a latitude alone")
        #expect(LocationReader.iso6709("+00.0000+000.0000/") == nil, "0° 0° is no fix, not the Gulf of Guinea")
        #expect(LocationReader.iso6709("+95.0000+010.0000/") == nil, "beyond the pole")
        #expect(LocationReader.iso6709("+5170.000+00000.000/") == nil, "70 minutes")
        #expect(LocationReader.iso6709("+51.5.007-000.1246/") == nil)
    }

    @Test func xmpCoordinates() {
        #expect(abs(LocationReader.xmpCoordinate("51,30.042N")! - 51.5007) < 0.0001)
        #expect(abs(LocationReader.xmpCoordinate("0,7,28.56W")! - -0.1246) < 0.0001)
        #expect(LocationReader.xmpCoordinate("33,51.408S")! < 0)
        #expect(LocationReader.xmpCoordinate("51.5007") == nil, "no hemisphere")
        #expect(LocationReader.xmpCoordinate("51,75N") == nil)
        #expect(LocationReader.xmpCoordinate("N") == nil)
    }

    @Test func xmpGPSWhenThereIsNoEXIF() throws {
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSLatitude" as CFString, "51,30.042N" as CFString))
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "exif:GPSLongitude" as CFString, "0,7.476W" as CFString))
        #expect(near(LocationReader.xmp(metadata), bigBen))
    }

    @Test func exifGPSWithEachHemisphere() throws {
        let london = try vault.writeImage("london.jpg", properties: TestVault.gps(bigBen))
        let sydney = try vault.writeImage("sydney.jpg", properties: TestVault.gps(operaHouse))
        let a = try #require(LocationReader.photo(url: london))
        #expect(near(a.point, bigBen), "west is negative")
        #expect(a.source == .exif)
        #expect(near(LocationReader.photo(url: sydney)?.point, operaHouse), "south is negative")
    }

    @Test func noHemisphereLeavesTheNumberAsItIs() throws {
        let url = try vault.writeImage("noref.jpg", properties: [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLongitude: 0.1246,
        ]])
        #expect(near(LocationReader.photo(url: url)?.point, GeoPoint(latitude: 51.5007, longitude: 0.1246)))
    }

    @Test func noFixIsNoLocation() throws {
        let zero = try vault.writeImage("zero.jpg", properties: TestVault.gps(GeoPoint(latitude: 0, longitude: 0)))
        let plain = try vault.writeImage("plain.jpg", properties: [:])
        let junk = try vault.writeJunk("junk.jpg")
        #expect(LocationReader.photo(url: zero) == nil)
        #expect(LocationReader.photo(url: plain) == nil)
        #expect(LocationReader.photo(url: junk) == nil)
    }

    @Test func thePropertiesPanelReadsTheSamePlace() throws {
        let zero = try vault.writeImage("zero.jpg", properties: TestVault.gps(GeoPoint(latitude: 0, longitude: 0)))
        #expect(PhotoMetadata.read(url: zero).coordinatesDescription == nil, "no fix shows no coordinates")
    }

    @Test func aQuickTimeMovieLocation() async throws {
        let url = vault.photos.appendingPathComponent("clip.mov")
        try await VideoFixture.write(to: url, seconds: 1, metadata: [TestVault.locationItem(everestISO)])
        let found = try #require(await LocationReader.video(url: url))
        #expect(near(found.point, GeoPoint(latitude: 27.9881, longitude: 86.925)))
        #expect(found.source == .quickTime)
    }

    @Test func anMP4LocationInUserData() async throws {
        let url = vault.photos.appendingPathComponent("clip.mp4")
        try await VideoFixture.write(to: url, seconds: 1,
                                     metadata: [TestVault.locationItem("-33.8568+151.2153/", .quickTimeUserDataLocationISO6709)])
        #expect(near(await LocationReader.video(url: url)?.point, operaHouse))
    }

    @Test func aMovieWithoutALocation() async throws {
        let url = vault.photos.appendingPathComponent("plain.mp4")
        try await VideoFixture.write(to: url, seconds: 1)
        #expect(await LocationReader.video(url: url) == nil)
        #expect(await LocationReader.video(url: try vault.writeJunk("junk.mov")) == nil)
    }
}

@Suite("Locations in the catalog", .serialized)
struct CatalogLocationTests {
    let vault: TestVault
    let catalog: Catalog

    init() throws {
        vault = try TestVault()
        catalog = try Catalog(url: vault.catalogFile, tmpDir: vault.catalogDir.appendingPathComponent("tmp"))
    }

    @Test func aLocationIsKeptWithTheMtimeItWasReadAt() throws {
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", fileSize: 10, mtime: 100))
        #expect(try catalog.photosNeedingLocation().map(\.id) == [id], "never read")

        try catalog.setLocation(photoID: id, FileLocation(point: bigBen, source: .exif), fileMtime: 100)
        #expect(try catalog.location(photoID: id) == FileLocation(point: bigBen, source: .exif))
        #expect(try catalog.photosNeedingLocation().isEmpty)

        // The file changes: read again, and this time it has none.
        try catalog.upsertPhoto(PhotoItem(relPath: "Photos/a.jpg", fileSize: 10, mtime: 200))
        #expect(try catalog.photosNeedingLocation().map(\.id) == [id])
        try catalog.setLocation(photoID: id, nil, fileMtime: 200)
        #expect(try catalog.location(photoID: id) == nil)
        #expect(try catalog.photosNeedingLocation().isEmpty, "no location is an answer too, not asked again")
    }

    @Test func neitherTheTrashNorMissingFilesAreRead() throws {
        let trashed = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/t.jpg", mtime: 1))
        let gone = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/g.jpg", mtime: 1))
        let video = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/v.mov", mtime: 1, mediaType: .video))
        try catalog.trash(ids: [trashed])
        try catalog.markMissing(ids: [gone])
        let pending = try catalog.photosNeedingLocation()
        #expect(pending.map(\.id) == [video])
        #expect(pending.first?.mediaType == .video)
    }

    /// The map shows what the grid shows — every view, filter and the
    /// sub-folders switch — less what records no place.
    @Test func eachViewsLocationsAreItsItemsThatHaveOne() throws {
        func add(_ path: String, _ type: MediaType = .photo, at place: GeoPoint?) throws -> Int64 {
            let id = try catalog.upsertPhoto(PhotoItem(relPath: path, mtime: 1, mediaType: type))
            try catalog.setLocation(photoID: id, place.map { FileLocation(point: $0, source: .exif) }, fileMtime: 1)
            return id
        }
        let a = try add("Photos/2019/a.jpg", at: bigBen)
        _ = try add("Photos/2019/b.jpg", at: nil)
        let c = try add("Photos/2019/Summer/c.jpg", at: operaHouse)
        let v = try add("Photos/2019/Summer/v.mov", .video, at: bigBen)
        _ = try add("Photos/2019b/d.jpg", at: bigBen)
        let t = try add("Photos/2019/t.jpg", at: bigBen)
        let m = try add("Photos/2019/m.jpg", at: bigBen)
        try catalog.trash(ids: [t])
        try catalog.markMissing(ids: [m])
        try catalog.setFavorite(photoID: a, true)
        try catalog.setFavorite(photoID: c, true)
        let album = try catalog.createAlbum(name: "Trip")
        try catalog.addToAlbum(albumID: album, photoIDs: [a, c, v])
        let smart = try catalog.createSmartAlbum(name: "Videos", predicate: "p.media_type = 1")

        let scopes: [LibraryScope] = [.all, .favorites, .album(album), .smart(smart), .trash,
                                      .folder("Photos/2019"), .folder("Photos/2019/Summer"), .smart(999)]
        for scope in scopes {
            for filter in MediaFilter.allCases {
                for subfolders in [true, false] {
                    let expected = try catalog.items(scope: scope, filter: filter, subfolders: subfolders)
                        .filter { try catalog.location(photoID: $0.id) != nil }.map(\.id)
                    let got = try catalog.locations(scope: scope, filter: filter, subfolders: subfolders).map(\.id)
                    #expect(Set(got) == Set(expected), "\(scope), \(filter), sub-folders \(subfolders)")
                    #expect(got.count == Set(got).count, "each once — an album's join mustn't repeat one")
                }
            }
        }
        #expect(try catalog.locations(scope: .all, filter: .all).count == 4, "a, c, v and 2019b's d")
        #expect(try catalog.locations(scope: .folder("Photos/2019"), filter: .all, subfolders: false).map(\.id) == [a])
        let video = try #require(try catalog.locations(scope: .all, filter: .videos).first)
        #expect(video.id == v && video.mediaType == .video && near(video.point, bigBen))
    }

    @Test func aCatalogFromVersion6GainsLocationsAfterABackup() throws {
        let id = try catalog.upsertPhoto(PhotoItem(relPath: "Photos/old.jpg", mtime: 1))
        try catalog.setFavorite(photoID: id, true)
        catalog.closeCleanly()
        // As 1.8.0 left it: no location columns.
        var db: OpaquePointer?
        try #require(sqlite3_open(vault.catalogFile.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, TestVault.dropLocationColumns + "PRAGMA user_version = 6;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let upgraded = try Catalog(url: vault.catalogFile)
        defer { upgraded.closeCleanly() }
        #expect(try upgraded.userVersion() == 7)
        let backups = try FileManager.default.contentsOfDirectory(atPath: vault.catalogDir.appendingPathComponent("backups").path)
        #expect(backups.contains { $0.hasPrefix("catalog-v6-") }, "the catalog as it was is kept first")
        let row = try #require(try upgraded.items(scope: .all, filter: .all).first)
        #expect(row.relPath == "Photos/old.jpg" && row.favorite)
        #expect(try upgraded.photosNeedingLocation().map(\.id) == [id], "read by the next scan, not while opening")
        #expect(try upgraded.locations(scope: .all, filter: .all).isEmpty)
    }
}

/// The largest count the scan's "Reading locations…" step announced: how
/// many files the location pass itself had to read.
private final class LocationPassCount: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    var value: Int { lock.withLock { total } }
    func note(_ p: ScanProgress) {
        guard p.phase == "Reading locations…" else { return }
        lock.withLock { total = max(total, p.total) }
    }
}

@Suite("Reading locations in a scan", .serialized)
struct ScanLocationTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    private func location(_ store: Store, _ name: String) async throws -> FileLocation? {
        let items = try await store.items(scope: .all, filter: .all)
        let item = try #require(items.first { $0.relPath.hasSuffix("/" + name) })
        return try await store.location(for: item.id)
    }

    @Test func newFilesAreLocatedAsTheyAreThumbnailed() async throws {
        try vault.writeImage("london.jpg", properties: TestVault.gps(bigBen))
        try vault.writeImage("plain.jpg", properties: [:])
        try await VideoFixture.write(to: vault.photos.appendingPathComponent("everest.mov"), seconds: 1,
                                     metadata: [TestVault.locationItem(everestISO)])
        try vault.writeJunk("broken.jpg")
        let store = try Store(root: vault.root)
        let pass = LocationPassCount()
        try await store.scan(full: true, progress: pass.note)

        #expect(pass.value == 1, "only the file with no thumbnail needs reading again; the rest were read with theirs")
        #expect(near(try await location(store, "london.jpg")?.point, bigBen))
        #expect(try await location(store, "plain.jpg") == nil)
        let movie = try #require(try await location(store, "everest.mov"))
        #expect(movie.source == .quickTime)
        #expect(try await store.locations(scope: .all, filter: .all).count == 2)
        await store.close()

        let catalog = try Catalog(url: vault.catalogFile)
        #expect(try catalog.photosNeedingLocation().isEmpty, "all four read once, the broken one included")
        catalog.closeCleanly(markingClean: false)
    }

    @Test func anUpgradedVaultIsReadWithoutRemakingThumbnails() async throws {
        try vault.writeImage("london.jpg", properties: TestVault.gps(bigBen))
        try vault.writeImage("sydney.jpg", properties: TestVault.gps(operaHouse))
        let first = try Store(root: vault.root)
        try await first.scan(full: true)
        await first.close()
        let pack = vault.fileSize(vault.packFile)

        // As a vault from before catalog version 7 is, once upgraded.
        var db: OpaquePointer?
        try #require(sqlite3_open(vault.catalogFile.path, &db) == SQLITE_OK)
        try #require(sqlite3_exec(db, "UPDATE photo SET latitude = NULL, longitude = NULL, location_source = NULL, location_read = NULL;",
                                  nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let store = try Store(root: vault.root)
        let pass = LocationPassCount()
        try await store.scan(full: false, progress: pass.note)
        #expect(pass.value == 2)
        #expect(near(try await location(store, "london.jpg")?.point, bigBen))
        #expect(near(try await location(store, "sydney.jpg")?.point, operaHouse))
        #expect(vault.fileSize(vault.packFile) == pack, "reading locations remakes no thumbnail")
        await store.close()
    }

    @Test func aChangedFileIsReadAgain() async throws {
        let url = try vault.writeImage("moved.jpg", properties: TestVault.gps(bigBen))
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        #expect(near(try await location(store, "moved.jpg")?.point, bigBen))

        try vault.writeImage("moved.jpg", properties: TestVault.gps(operaHouse), seed: 0.9)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: url.path)
        try await store.scan(full: true)
        #expect(near(try await location(store, "moved.jpg")?.point, operaHouse))
        await store.close()
    }
}

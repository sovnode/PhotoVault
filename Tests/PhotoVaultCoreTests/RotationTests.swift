import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoVaultCore

@Suite("Rotation", .serialized)
struct RotationTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    /// A 300x200 image whose top-left quadrant is red and the rest blue, so a
    /// rotation can be checked by where the red ends up.
    private func writeMarked(_ name: String, type: UTType = .jpeg) throws -> URL {
        let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 100, width: 150, height: 100))   // CG origin is bottom-left
        let url = vault.photos.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// The image as it should appear on screen, orientation applied.
    private func displayed(_ url: URL) throws -> CGImage {
        let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1000,
        ] as CFDictionary))
    }

    /// Is the pixel `fromLeft`, `fromTop` points in mostly red?
    private func isRed(_ image: CGImage, _ fromLeft: Int, _ fromTop: Int) -> Bool {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (fromTop * w + fromLeft) * 4    // bitmap memory runs top row first
        return px[i] > 180 && px[i + 2] < 80
    }

    @Test func orientationTableIsAProperQuarterTurn() {
        for o in 1...8 {
            var x = o
            for _ in 0..<4 { x = Rotation.rotated(x, clockwise: true) }
            #expect(x == o, "four clockwise turns must come back to \(o)")
            #expect(Rotation.rotated(Rotation.rotated(o, clockwise: true), clockwise: false) == o)
        }
        #expect(Rotation.rotated(1, clockwise: true) == 6)
        #expect(Rotation.rotated(1, clockwise: false) == 8)
        #expect(Rotation.rotated(2, clockwise: true) == 7, "a mirrored image stays mirrored")
    }

    @Test func clockwiseMovesTopLeftToTopRight() throws {
        let url = try writeMarked("a.jpg")
        #expect(isRed(try displayed(url), 20, 20), "fixture: red starts top-left")

        #expect(try Rotation.rotateOriginal(at: url, clockwise: true) == 6)

        let after = try displayed(url)
        #expect(after.width == 200 && after.height == 300, "portrait now")
        #expect(isRed(after, 180, 20), "the red corner turned to the top right")
        #expect(!isRed(after, 20, 20))
    }

    @Test func counterClockwiseMovesTopLeftToBottomLeft() throws {
        let url = try writeMarked("a.jpg")
        try Rotation.rotateOriginal(at: url, clockwise: false)
        let after = try displayed(url)
        #expect(isRed(after, 20, 280), "the red corner turned to the bottom left")
        #expect(!isRed(after, 20, 20))
    }

    /// Lossless means the compressed pixels are untouched: decoding without the
    /// orientation transform must give exactly the same bytes as before.
    @Test func rotationDoesNotReencodeThePixels() throws {
        let url = try writeMarked("a.jpg")
        func rawPixels() throws -> Data {
            let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            return try #require(img.dataProvider?.data as Data?)
        }
        let before = try rawPixels()
        try Rotation.rotateOriginal(at: url, clockwise: true)
        try Rotation.rotateOriginal(at: url, clockwise: true)
        #expect(try rawPixels() == before, "a re-encode would have shifted the JPEG data")
    }

    @Test func fourTurnsRestoreTheOriginalOrientation() throws {
        let url = try writeMarked("a.jpg")
        var o = 0
        for _ in 0..<4 { o = try Rotation.rotateOriginal(at: url, clockwise: true) }
        #expect(o == 1)
        let img = try displayed(url)
        #expect(img.width == 300 && img.height == 200)
        #expect(isRed(img, 20, 20))
    }

    /// Only JPEG can be turned without risking the rest of the file; the
    /// others are refused and left exactly as they were.
    @Test(arguments: [("png", UTType.png), ("heic", UTType.heic), ("tiff", UTType.tiff), ("gif", UTType.gif)])
    func otherFormatsAreRefusedAndLeftAlone(ext: String, type: UTType) throws {
        let url = try writeMarked("a.\(ext)", type: type)
        let before = try Data(contentsOf: url)
        #expect(!Rotation.canRotate(PhotoItem(relPath: "Photos/a.\(ext)", mtime: 0)))
        #expect(throws: VaultError.self) { try Rotation.rotateOriginal(at: url, clockwise: true) }
        #expect(try Data(contentsOf: url) == before)
    }

    func orientation(_ url: URL) throws -> Int? {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int
    }

    /// The phone photo of the tag-writer tests: EXIF with the maker's notes,
    /// interoperability block, Software, DateTime and GPS processing method,
    /// but no orientation entry; IPTC, XMP, an unknown segment, and a video
    /// after the picture.
    @Test func rotationChangesNothingButTheOrientation() throws {
        let url = vault.photos.appendingPathComponent("MVIMG_phone.jpg")
        let original = try TagWriterTests.phonePhoto()
        try original.write(to: url)

        // First turn: an orientation entry is added; nothing in EXIF moves.
        #expect(try Rotation.rotateOriginal(at: url, clockwise: true) == 6)
        let once = try Data(contentsOf: url)
        let a = try #require(JPEGFile(original)), b = try #require(JPEGFile(once))
        #expect(b.image == a.image, "the picture and the video after it")
        #expect(b.segments.filter { !$0.isExif } == a.segments.filter { !$0.isExif }, "XMP, IPTC and the unknown segment")
        let foundA = a.segments.first { $0.isExif }, foundB = b.segments.first { $0.isExif }
        let segmentA = try #require(foundA)
        let segmentB = try #require(foundB)
        let exifA = segmentA.body, exifB = segmentB.body
        var head = exifB.prefix(exifA.count)
        head.replaceSubrange((head.startIndex + 10)..<(head.startIndex + 14), with: exifA[(exifA.startIndex + 10)..<(exifA.startIndex + 14)])
        #expect(head == exifA, "the old EXIF block is all still there, maker's notes and all; only its first pointer moved")
        #expect(try orientation(url) == 6)

        // Second turn: two bytes, in place.
        #expect(try Rotation.rotateOriginal(at: url, clockwise: true) == 3)
        let twice = try Data(contentsOf: url)
        #expect(twice.count == once.count)
        #expect(zip(once, twice).filter { $0 != $1 }.count <= 2, "only the orientation value changed")
        #expect(try orientation(url) == 3)
    }

    /// PhotoVault never changes a photo's dates: rotating — adding the
    /// orientation entry, then changing it in place — leaves the capture,
    /// digitised and modified dates exactly as they were.
    @Test func rotatingNeverChangesThePhotosDates() throws {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = vault.photos.appendingPathComponent("dated.jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "1987:06:05 14:30:00",
                                             kCGImagePropertyExifDateTimeDigitized: "2003:01:02 03:04:05"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFDateTime: "2010:11:12 13:14:15"],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        // ImageIO reports the TIFF block's modified date only once the photo
        // has an orientation entry, so that one is checked in the bytes.
        let before = try exifDates(url).prefix(2)
        #expect(Array(before) == ["1987:06:05 14:30:00", "2003:01:02 03:04:05"])
        let modified = Data("2010:11:12 13:14:15".utf8)
        func count(_ data: Data) -> Int {
            var n = 0, from = data.startIndex
            while let r = data.range(of: modified, in: from..<data.endIndex) { n += 1; from = r.upperBound }
            return n
        }
        let modifiedCount = count(try Data(contentsOf: url))
        #expect(modifiedCount >= 1, "fixture: the modified date is in the file")
        for turn in 1...5 {
            try Rotation.rotateOriginal(at: url, clockwise: turn % 2 == 0)
            #expect(try exifDates(url).prefix(2) == before, "after turn \(turn)")
            #expect(count(try Data(contentsOf: url)) == modifiedCount, "after turn \(turn): the modified date still there, once")
        }
    }

    /// Every date ImageIO reads from a photo's EXIF and TIFF blocks.
    func exifDates(_ url: URL) throws -> [String] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return [exif[kCGImagePropertyExifDateTimeOriginal], exif[kCGImagePropertyExifDateTimeDigitized],
                tiff[kCGImagePropertyTIFFDateTime]].map { "\($0 ?? "none")" }
    }

    @Test func aJPEGWithoutEXIFGetsOneForTheOrientation() throws {
        var file = try #require(JPEGFile(try TestVault.jpegData(size: 64, seed: 0.3)))
        file.segments.removeAll(where: \.isExif)
        let url = vault.photos.appendingPathComponent("bare.jpg")
        try file.assembled().write(to: url)

        #expect(try Rotation.rotateOriginal(at: url, clockwise: false) == 8)
        let after = try #require(JPEGFile(try Data(contentsOf: url)))
        #expect(after.image == file.image)
        #expect(after.segments.filter { !$0.isExif } == file.segments)
        #expect(try orientation(url) == 8)
    }

    /// An XMP orientation, as ExifTool writes it, follows the EXIF one, in
    /// place: the file keeps its length and every other byte.
    @Test func theXMPOrientationFollows() throws {
        var file = try #require(JPEGFile(try TestVault.jpegData(size: 64, seed: 0.6)))
        file.segments.removeAll(where: \.isExif)
        file.segments.insert(JPEGFile.Segment(marker: 0xE1, body: ExifOrientation.block(1)), at: 1)
        file.setXMP(Data("""
            <x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>\
            <rdf:Description rdf:about='' xmlns:tiff='http://ns.adobe.com/tiff/1.0/' tiff:Orientation='1'/></rdf:RDF></x:xmpmeta>
            """.utf8))
        let url = vault.photos.appendingPathComponent("xmp.jpg")
        let before = file.assembled()
        try before.write(to: url)

        #expect(try Rotation.rotateOriginal(at: url, clockwise: true) == 6)
        let after = try Data(contentsOf: url)
        #expect(after.count == before.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 2, "one byte of EXIF's value and the XMP digit")
        let packet = try #require(JPEGFile(after)?.xmpPacket)
        #expect(String(decoding: packet, as: UTF8.self).contains("tiff:Orientation='6'"))
        #expect(try orientation(url) == 6)
    }

    @Test func noTemporaryFilesAreLeftBehindAnywhere() throws {
        let url = try writeMarked("a.jpg")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])

        try Rotation.rotateOriginal(at: url, clockwise: true)
        _ = try? Rotation.rotateOriginal(at: try writeMarked("b.gif", type: .gif), clockwise: true)

        let folder = try FileManager.default.contentsOfDirectory(atPath: vault.photos.path)
        #expect(folder.filter { $0.hasPrefix(".photovault-rotate") }.isEmpty, "no hidden temp file beside the original")
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [])
        #expect(after.subtracting(before).subtracting(["photovault-tests"]).isEmpty,
                "nothing written to the system temp directory")
    }

    @Test func storeRotationRebuildsTheThumbnailAndFileStats() async throws {
        _ = try writeMarked("a.jpg")
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let before = try #require(await store.items(scope: .all, filter: .all).first)

        let failures = try await store.rotate([before.id], clockwise: true)
        #expect(failures.isEmpty)

        let after = try #require(await store.photo(id: before.id))
        #expect(after.orientation == 6)
        #expect(after.thumbOff != before.thumbOff, "a new thumbnail was appended and the row repointed")
        let data = try #require(await store.thumbnailData(for: after))
        let src = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let thumb = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        #expect(thumb.height > thumb.width, "the thumbnail shows it portrait")
        #expect(after.contentKey != before.contentKey, "the content key follows the rewritten file")

        // A rescan afterwards sees nothing new: no duplicate row, nothing missing.
        try await store.scan(full: true)
        #expect(try await store.photoCount() == 1)
        #expect(try await store.photo(id: before.id)?.missing == false)
        await store.close()
    }

    @Test func rotatingAVideoIsRefusedAndLeavesItAlone() async throws {
        try await VideoFixture.write(to: vault.photos.appendingPathComponent("clip.mp4"), seconds: 1)
        let store = try Store(root: vault.root)
        try await store.scan(full: true)
        let video = try #require(await store.items(scope: .all, filter: .videos).first)
        let bytes = try Data(contentsOf: vault.photos.appendingPathComponent("clip.mp4"))

        let failures = try await store.rotate([video.id], clockwise: true)

        #expect(failures.count == 1)
        #expect(try Data(contentsOf: vault.photos.appendingPathComponent("clip.mp4")) == bytes)
        await store.close()
    }
}

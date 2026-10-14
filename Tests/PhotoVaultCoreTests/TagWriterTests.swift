import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoVaultCore

@Suite("Writing tags into photos")
final class TagWriterTests {
    let vault: TestVault
    init() throws { vault = try TestVault() }

    static let joyTag = ToolRecord(prefix: "jt", tool: "JoyTag", version: "6b7f163",
                                   date: ISO8601DateFormatter().date(from: "2026-10-14T00:00:00Z"))
    static let otherRecord = "prefix=ext; tool=OtherTagger; date=2026-10-01T00:00:00Z"

    /// A photo with a capture date, a place, a camera and a sideways
    /// orientation, so the tests can see that all of them come through.
    func photo(_ name: String, keywords: [String] = [], recordLines: [String] = [], iptc: [String]? = nil) throws -> URL {
        let url = vault.photos.appendingPathComponent(name)
        let type = UTType(filenameExtension: url.pathExtension)!
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<8 {
            ctx.setFillColor(red: CGFloat(i) / 8, green: 1 - CGFloat(i) / 8, blue: 0.4, alpha: 1)
            ctx.fill(CGRect(x: i * 8, y: 0, width: 8, height: 48))
        }
        let image = ctx.makeImage()!
        var props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.25, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "One"],
        ]
        if let iptc { props[kCGImagePropertyIPTCDictionary] = [kCGImagePropertyIPTCKeywords: iptc] }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))

        // The keywords and records go on in a second step, as another app would.
        if keywords.isEmpty && recordLines.isEmpty {
            try (data as Data).write(to: url)
        } else {
            let source = CGImageSourceCreateWithData(data, nil)!
            let metadata = CGImageMetadataCreateMutableCopy(CGImageSourceCopyMetadataAtIndex(source, 0, nil)!)!
            var error: Unmanaged<CFError>?
            CGImageMetadataRegisterNamespaceForPrefix(metadata, PhotoVaultXMP.namespace as CFString, "pv" as CFString, &error)
            if !keywords.isEmpty {
                let tag = CGImageMetadataTagCreate(kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore,
                                                   "subject" as CFString, .arrayUnordered, keywords as CFArray)!
                CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, tag)
            }
            if !recordLines.isEmpty {
                let tag = CGImageMetadataTagCreate(PhotoVaultXMP.namespace as CFString, "pv" as CFString,
                                                   "classifications" as CFString, .arrayUnordered, recordLines as CFArray)!
                CGImageMetadataSetTagWithPath(metadata, nil, "pv:classifications" as CFString, tag)
            }
            let out = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            #expect(CGImageDestinationCopyImageSource(out, source, [kCGImageDestinationMetadata: metadata,
                                                                    kCGImageDestinationMergeMetadata: false] as CFDictionary, nil))
        }
        return url
    }

    func properties(_ url: URL) -> [CFString: Any] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
    }

    func lines(_ url: URL) -> [String] {
        TagReader.readRaw(CGImageSourceCreateWithURL(url as CFURL, nil)!).recordLines
    }

    @Test func addsJoyTagsAndKeepsEverythingElse() throws {
        let url = try photo("a.jpg", keywords: ["Grandma", "beach", "Paris: Eiffel"], recordLines: [Self.otherRecord])
        let before = try Data(contentsOf: url)
        let propsBefore = properties(url)

        try TagWriter.writeTags(["long hair", "smile"], record: Self.joyTag, to: url)

        let read = try #require(TagReader.read(url: url))
        #expect(read.keywords == ["Grandma", "beach", "Paris: Eiffel", "jt:long hair", "jt:smile"])
        #expect(Set(read.records) == [ToolRecord(parsing: Self.otherRecord)!, Self.joyTag])
        let after = try Data(contentsOf: url)
        #expect(TagWriter.jpegImageData(after) == TagWriter.jpegImageData(before), "the coded image is untouched")
        let propsAfter = properties(url)
        #expect(propsAfter[kCGImagePropertyOrientation] as? Int == 6)
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary] {
            #expect((propsAfter[key] as AnyObject).isEqual(propsBefore[key] as AnyObject), "\(key)")
        }
        #expect((propsAfter[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] as? String
                == "2001:02:03 04:05:06")
    }

    @Test func reclassifyingReplacesOnlyJoyTags() throws {
        let url = try photo("b.jpg", keywords: ["beach", "jt:old", "JT:Older", "ext:child", "jt:", "sunset"],
                            recordLines: [Self.otherRecord, "prefix=jt; tool=JoyTag; version=0"])
        try TagWriter.writeTags(["new tag"], record: Self.joyTag, to: url)
        let read = try #require(TagReader.read(url: url))
        // "jt:" with nothing after it was never a JoyTag tag: someone typed it.
        #expect(read.keywords == ["beach", "ext:child", "jt:", "sunset", "jt:new tag"])
        #expect(Set(read.records) == [ToolRecord(parsing: Self.otherRecord)!, Self.joyTag])
    }

    @Test func keepsRecordsItCannotParse() throws {
        let url = try photo("c.jpg", keywords: ["dog"], recordLines: ["some future format, not key=value", Self.otherRecord])
        try TagWriter.writeTags(["dog"], record: Self.joyTag, to: url)
        #expect(Set(lines(url)) == ["some future format, not key=value", Self.otherRecord, Self.joyTag.line])
    }

    @Test func keepsKeywordsThatAreOnlyInIPTC() throws {
        let url = try photo("d.jpg", iptc: ["lake", "dog"])
        #expect(TagReader.read(url: url)?.keywords == ["lake", "dog"])
        try TagWriter.writeTags(["water"], record: Self.joyTag, to: url)
        #expect(TagReader.read(url: url)?.keywords == ["lake", "dog", "jt:water"])
        let iptc = properties(url)[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCKeywords] as? [String] == ["lake", "dog", "jt:water"],
                "other apps reading IPTC see the same list")
    }

    @Test func noTagsLeavesNoneBehind() throws {
        let url = try photo("e.jpg")
        try TagWriter.writeTags(["cat", "sofa"], record: Self.joyTag, to: url)
        #expect(TagReader.read(url: url)?.keywords == ["jt:cat", "jt:sofa"])
        try TagWriter.writeTags([], record: Self.joyTag, to: url)
        let read = try #require(TagReader.read(url: url))
        #expect(read.keywords.isEmpty, "no JoyTag tag left in XMP or IPTC: \(read.keywords)")
        #expect(read.records == [Self.joyTag], "still marked as classified, so it isn't redone")
    }

    @Test func keepsTheFileItself() throws {
        let url = try photo("f.jpg", keywords: ["beach"])
        let old = Date(timeIntervalSince1970: 1_000_000_000.123456)
        let older = Date(timeIntervalSince1970: 900_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.creationDate: older], ofItemAtPath: url.path)
        #expect(chmod(url.path, 0o640) == 0)
        #expect(setxattr(url.path, "com.photovault.test", "kept", 4, 0, 0) == 0)
        var before = stat()
        stat(url.path, &before)

        let written = try TagWriter.writeTags(["sand"], record: Self.joyTag, to: url)

        var after = stat()
        stat(url.path, &after)
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
        #expect(after.st_birthtimespec.tv_sec == before.st_birthtimespec.tv_sec)
        #expect(after.st_mode & 0o7777 == 0o640)
        var buffer = [UInt8](repeating: 0, count: 16)
        let n = getxattr(url.path, "com.photovault.test", &buffer, 16, 0, 0)
        #expect(n == 4 && String(decoding: buffer[0..<4], as: UTF8.self) == "kept")
        #expect(written.size == Int64(after.st_size))
        #expect(written.mtime == (try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as! Date).timeIntervalSince1970)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: vault.photos.path).filter { $0.hasPrefix(".photovault") }
        #expect(leftovers.isEmpty)
    }

    @Test(arguments: ["png", "heic", "tiff", "gif", "bmp"])
    func otherFormatsKeepTheirTagsInTheCatalog(_ ext: String) throws {
        let url = try photo("h.\(ext)", keywords: ext == "gif" || ext == "bmp" ? [] : ["mine"])
        let before = try Data(contentsOf: url)
        #expect(!TagWriter.canWrite(PhotoItem(relPath: "Photos/h.\(ext)", mtime: 0)))
        #expect(throws: VaultError.self) { try TagWriter.writeTags(["x"], record: Self.joyTag, to: url) }
        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: - Every other byte

    /// A phone photo as phones write them: EXIF with the maker's notes,
    /// an interoperability block, Software, DateTime and a GPS processing
    /// method — all things ImageIO's rewrite drops — plus an IPTC copy of the
    /// keywords with a caption and a digest, custom XMP, an unknown segment,
    /// and a video stored after the picture, as in a Motion Photo.
    static func phonePhoto(keywords: [String] = ["child", "sea"]) throws -> Data {
        var file = try #require(JPEGFile(try TestVault.jpegData(size: 64, seed: 0.4)))
        file.segments.removeAll { $0.marker == 0xE1 || $0.marker == 0xED }
        let at = (file.segments.firstIndex { $0.marker == 0xE0 } ?? -1) + 1
        file.segments.insert(JPEGFile.Segment(marker: 0xE1, body: Data("Exif\0\0".utf8) + exif()), at: at)
        file.segments.insert(JPEGFile.Segment(marker: 0xE3, body: Data("Opaque maker block, kept as is".utf8)), at: at + 1)
        let xmp = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?><x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF \
        xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" \
        xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" xmp:CreatorTool="Pixel" GCamera:MicroVideo="1" \
        GCamera:MicroVideoOffset="40"><dc:subject><rdf:Bag>\(keywords.map { "<rdf:li>\($0)</rdf:li>" }.joined())</rdf:Bag></dc:subject>\
        <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Beach day</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF>\
        </x:xmpmeta><?xpacket end="w"?>
        """
        file.setXMP(Data(xmp.utf8))
        var iptc = Data([0x1C, 2, 0, 0, 2, 0, 4])
        for k in keywords { iptc += Data([0x1C, 2, 25, 0, UInt8(k.utf8.count)]) + Data(k.utf8) }
        iptc += Data([0x1C, 2, 120, 0, 9]) + Data("A day out".utf8)
        let resources = PhotoshopResources(JPEGFile.photoshopHeader + resource(0x03ED, Data(repeating: 7, count: 16))
                                           + resource(0x0404, iptc) + resource(0x0425, IPTCBlock.digest(iptc)))!
        file.segments.insert(JPEGFile.Segment(marker: 0xED, body: resources.serialized()), at: at + 2)
        file.image += Data("....a Motion Photo's video, 40 bytes...".utf8)
        return file.assembled()
    }

    static func resource(_ id: UInt16, _ data: Data) -> Data {
        var r = Data("8BIM".utf8) + Data([UInt8(id >> 8), UInt8(id & 0xFF), 0, 0])
        r += Data([UInt8(data.count >> 24), UInt8(data.count >> 16 & 0xFF), UInt8(data.count >> 8 & 0xFF), UInt8(data.count & 0xFF)])
        r += data
        if data.count % 2 == 1 { r.append(0) }
        return r
    }

    /// TIFF, big-endian: IFD0 (Software, DateTime, EXIF and GPS pointers), the
    /// EXIF IFD (maker's notes, interoperability pointer), the
    /// interoperability IFD, and the GPS IFD (processing method).
    static func exif() -> Data {
        func u16(_ v: Int) -> Data { Data([UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func u32(_ v: Int) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        func entry(_ tag: Int, _ type: Int, _ count: Int, _ value: Data) -> Data {
            u16(tag) + u16(type) + u32(count) + (value + Data(count: max(0, 4 - value.count))).prefix(4)
        }
        var t = Data("MM".utf8) + u16(42) + u32(8)
        // IFD0 at 8: 4 entries, ends at 62; Software at 62 (13, padded to 14); DateTime at 76 (20).
        t += u16(4) + entry(0x0131, 2, 13, u32(62)) + entry(0x0132, 2, 20, u32(76))
            + entry(0x8769, 4, 1, u32(96)) + entry(0x8825, 4, 1, u32(176)) + u32(0)
        t += Data("Scanner 2000\0".utf8) + Data([0]) + Data("2001:02:03 04:05:06\0".utf8)
        // EXIF IFD at 96: maker's notes (32 bytes at 126), interoperability IFD at 158.
        t += u16(2) + entry(0x927C, 7, 32, u32(126)) + entry(0xA005, 4, 1, u32(158)) + u32(0)
        t += Data((0..<32).map { UInt8($0 * 3) })
        // Interoperability IFD at 158: "R98".
        t += u16(1) + entry(0x0001, 2, 4, Data("R98\0".utf8)) + u32(0)
        // GPS IFD at 176: processing method (13 bytes at 194).
        t += u16(1) + entry(0x001B, 7, 13, u32(194)) + u32(0)
        t += Data("ASCII\0\0\0GPS\0\0".utf8)
        return t
    }

    @Test func keepsEveryOtherByte() throws {
        let url = vault.photos.appendingPathComponent("MVIMG_phone.jpg")
        let original = try Self.phonePhoto()
        try original.write(to: url)
        #expect(TagReader.read(url: url)?.keywords == ["child", "sea"])

        try TagWriter.writeTags(["smile", "outdoors"], record: Self.joyTag, to: url)

        let before = try #require(JPEGFile(original)), after = try #require(JPEGFile(try Data(contentsOf: url)))
        #expect(after.untouched == before.untouched, "EXIF (maker's notes and all), the unknown segment and the tables, byte for byte")
        #expect(after.image == before.image, "the picture and the video after it, byte for byte")
        #expect(TagReader.read(url: url)?.keywords == ["child", "sea", "jt:smile", "jt:outdoors"])

        // The IPTC copy follows; its caption, the other resource and the
        // digest's agreement are kept.
        let ps = try #require(after.segments.first(where: \.isPhotoshop).flatMap { PhotoshopResources($0.body) })
        let iptc = try #require(ps.resources.first { $0.id == PhotoshopResources.iptc })
        let block = try #require(IPTCBlock(iptc.data))
        #expect(block.keywords == ["child", "sea", "jt:smile", "jt:outdoors"])
        #expect(block.datasets.contains { $0.record == 2 && $0.number == 120 && $0.value == Data("A day out".utf8) })
        #expect(ps.resources.first { $0.id == PhotoshopResources.iptcDigest }?.data == IPTCBlock.digest(iptc.data))
        #expect(ps.resources.first { $0.id == 0x03ED }?.data == Data(repeating: 7, count: 16))

        // The XMP's other properties come through, the Motion Photo's among them.
        let xmp = try #require(after.xmpPacket.flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) })
        #expect(CGImageMetadataCopyStringValueWithPath(xmp, nil, "GCamera:MicroVideoOffset" as CFString) as String? == "40")
        #expect(CGImageMetadataCopyStringValueWithPath(xmp, nil, "xmp:CreatorTool" as CFString) as String? == "Pixel")
    }

    @Test func keywordsOutsideASCIIAreDeclaredUTF8InIPTC() throws {
        let url = vault.photos.appendingPathComponent("accent.jpg")
        try Self.phonePhoto().write(to: url)
        try TagWriter.writeTags(["café"], record: Self.joyTag, to: url)
        let after = try #require(JPEGFile(try Data(contentsOf: url)))
        let ps = try #require(after.segments.first(where: \.isPhotoshop).flatMap { PhotoshopResources($0.body) })
        let block = try #require(ps.resources.first { $0.id == PhotoshopResources.iptc }.flatMap { IPTCBlock($0.data) })
        #expect(block.datasets.first == IPTCBlock.DataSet(record: 1, number: 90, value: Data([0x1B, 0x25, 0x47])))
        #expect(block.keywords.last == "jt:café")
        #expect(TagReader.read(url: url)?.keywords.last == "jt:café")
    }

    @Test func refusesAPhotoWhoseXMPCantBeRead() throws {
        var file = try #require(JPEGFile(try Self.phonePhoto()))
        file.setXMP(Data("<x:xmpmeta><rdf:RDF><broken".utf8))
        let url = vault.photos.appendingPathComponent("broken.jpg")
        let bytes = file.assembled()
        try bytes.write(to: url)
        #expect(throws: VaultError.self) { try TagWriter.writeTags(["x"], record: Self.joyTag, to: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func refusesReadOnlyFiles() throws {
        let url = try photo("i.jpg", keywords: ["mine"])
        let before = try Data(contentsOf: url)
        #expect(chmod(url.path, 0o444) == 0)
        #expect(throws: VaultError.self) { try TagWriter.writeTags(["x"], record: Self.joyTag, to: url) }
        #expect(try Data(contentsOf: url) == before)
        chmod(url.path, 0o644)
    }

    @Test func imageDataLeavesMetadataOut() {
        // SOI, an APP1 and a COM (metadata), a DQT, then a scan through to EOI.
        let jpeg: [UInt8] = [0xFF, 0xD8,
                             0xFF, 0xE1, 0x00, 0x04, 0xAA, 0xBB,
                             0xFF, 0xFE, 0x00, 0x03, 0x01,
                             0xFF, 0xDB, 0x00, 0x03, 0x07,
                             0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]
        let changedMetadata = [UInt8](jpeg[0..<6]) + [0xCC, 0xDD] + [UInt8](jpeg[8...])
        #expect(TagWriter.jpegImageData(Data(jpeg)) == Data([0xFF, 0xDB, 0x00, 0x03, 0x07, 0xFF, 0xDA, 0x00, 0x02, 0x11, 0x22, 0xFF, 0xD9]))
        #expect(TagWriter.jpegImageData(Data(changedMetadata)) == TagWriter.jpegImageData(Data(jpeg)))
        #expect(TagWriter.jpegImageData(Data([0x89, 0x50])) == nil)
    }

    /// On a real photo, only when asked:
    /// `PHOTOVAULT_REAL_PHOTO=<a copy inside a vault> swift test --filter realPhoto`.
    /// Prints counts and timings, never the photo.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PHOTOVAULT_REAL_PHOTO"] != nil))
    func realPhoto() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTOVAULT_REAL_PHOTO"]!)
        let before = try #require(TagReader.read(url: url))
        let size = try Data(contentsOf: url).count
        let start = Date()
        try TagWriter.writeTags(["long hair", "smile", "outdoors"], record: Self.joyTag, to: url)
        let first = Date().timeIntervalSince(start)
        let after = try #require(TagReader.read(url: url))
        #expect(Array(after.keywords.prefix(before.keywords.count)) == before.keywords)
        #expect(after.keywords.suffix(3) == ["jt:long hair", "jt:smile", "jt:outdoors"])
        let again = Date()
        try TagWriter.writeTags(["smile"], record: Self.joyTag, to: url)
        let second = Date().timeIntervalSince(again)
        #expect(TagReader.read(url: url)?.keywords == before.keywords + ["jt:smile"])
        print("real photo: \(size) bytes, \(before.keywords.count) keywords kept; first write \(Int(first * 1000)) ms, "
              + "re-tag \(Int(second * 1000)) ms; size now \(try Data(contentsOf: url).count) bytes")
    }

    @Test func listsFollowTheReadingRules() {
        #expect(TagWriter.replacingTags(in: ["a", "jt:b", "Jt: c", "x:y"], prefix: "jt", with: ["d", "D", "e"])
                == ["a", "x:y", "jt:d", "jt:e"])
        #expect(TagWriter.replacingRecord(in: ["prefix=jt; tool=JoyTag", "prefix=ext; tool=OtherTagger", "junk"], with: Self.joyTag)
                == ["prefix=ext; tool=OtherTagger", "junk", Self.joyTag.line])
    }
}

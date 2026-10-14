import Foundation
import ImageIO

/// Rotates JPEG originals by changing their orientation value and nothing
/// else.
///
/// The pixels are never re-encoded, and no other byte of the file changes.
/// ImageIO's rewrite isn't used: it rebuilds the EXIF block from its own model
/// and drops what it doesn't model — the maker's notes, the interoperability
/// block, Software (found in October 2026, while building tagging).
///
/// - A photo whose EXIF has an orientation entry has those two bytes changed
///   in place, and the matching digit of its XMP if it has one: nothing in
///   the file moves, so the vault's disk image doesn't grow.
/// - Without one, a copy of the EXIF block's first directory with the entry
///   added is put at the end of the block, and the block pointed at it, so
///   nothing in the block moves; without EXIF at all, a small EXIF block
///   holding just the orientation is added. These are written to a hidden
///   file beside the original, flushed to the device and renamed over it, so
///   a crash leaves the old file or the new one, never half of each.
///
/// Either way the result is checked before it replaces anything: every other
/// segment, the image data and anything after it byte-identical, and ImageIO
/// reading the new orientation. PNG, HEIC and TIFF can't be rotated this way
/// yet, so they're refused rather than risk their metadata; GIF and BMP have
/// no orientation to change.
public enum Rotation {

    /// Orientation after one quarter turn, for all eight EXIF orientations.
    /// Mirrored orientations stay mirrored: 2→7→4→5 and back.
    public static func rotated(_ orientation: Int, clockwise: Bool) -> Int {
        let cw: [Int: Int] = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
        let o = (1...8).contains(orientation) ? orientation : 1
        if clockwise { return cw[o]! }
        return cw.first { $0.value == o }!.key
    }

    public static let losslessTypes: Set<String> = ["jpg", "jpeg"]

    public static func canRotate(_ item: PhotoItem) -> Bool {
        item.mediaType == .photo
            && losslessTypes.contains((item.relPath as NSString).pathExtension.lowercased())
    }

    /// Turns the photo at `url` a quarter turn. Returns the new orientation.
    @discardableResult
    public static func rotateOriginal(at url: URL, clockwise: Bool) throws -> Int {
        let name = url.lastPathComponent
        func refuse(_ why: String) -> VaultError { .cannotRotate("\(name): \(why)") }
        guard losslessTypes.contains(url.pathExtension.lowercased()) else {
            throw refuse("only JPEG photos can be rotated without changing anything else in the file.")
        }
        guard access(url.path, W_OK) == 0 else { throw refuse("the file is read-only.") }
        guard let original = try? Data(contentsOf: url), let file = JPEGFile(original),
              let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else {
            throw refuse("couldn't read the image.")
        }
        guard file.segments.filter(\.isExif).count <= 1, file.segments.filter(\.isXMP).count <= 1 else {
            throw refuse("it has more than one EXIF or XMP block.")
        }

        let xmpDigit: Int?
        do { xmpDigit = try XMPOrientation.digitOffset(in: file) } catch { throw refuse("its XMP states the orientation more than once.") }

        // Two bytes in place, when the EXIF has the entry.
        if let spot = try ExifOrientation.locate(in: file) {
            let next = rotated(spot.value, clockwise: clockwise)
            var patched = original
            var changes: [Range<Int>] = []
            if let d = xmpDigit {
                patched[d] = UInt8(ascii: "0") + UInt8(next)
                changes.append(d..<(d + 1))
            }
            patched.replaceSubrange(spot.offset..<(spot.offset + 2), with: spot.bytes(next))
            changes.append(spot.offset..<(spot.offset + 2))
            try verify(original: original, rewritten: patched, orientation: next, name: name)
            try writeInPlace(patched, changes: changes, to: url, name: name)
            return next
        }

        // Otherwise an entry, or a whole EXIF block, is added.
        let shown = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int ?? 1
        let next = rotated(shown, clockwise: clockwise)
        var changed = file
        if let i = changed.segments.firstIndex(where: \.isExif) {
            changed.segments[i].body = try ExifOrientation.adding(next, to: changed.segments[i].body, name: name)
        } else {
            let at = (changed.segments.lastIndex { $0.marker == 0xE0 } ?? -1) + 1
            changed.segments.insert(JPEGFile.Segment(marker: 0xE1, body: ExifOrientation.block(next)), at: at)
        }
        if let d = xmpDigit, let x = file.segments.firstIndex(where: \.isXMP), let y = changed.segments.firstIndex(where: \.isXMP) {
            changed.segments[y].body[changed.segments[y].body.startIndex + (d - file.offsets[x])] = UInt8(ascii: "0") + UInt8(next)
        }
        let rewritten = changed.assembled()
        try verify(original: original, rewritten: rewritten, orientation: next, name: name)

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".photovault-rotate-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }   // no-op after a successful rename
        guard FileManager.default.createFile(atPath: temp.path, contents: rewritten) else {
            throw refuse("couldn't write the rotated file.")
        }
        try TagWriter.carryOver(from: url, to: temp, dates: false)
        // Durable before visible: flush the new bytes to the device, then swap.
        let fd = open(temp.path, O_RDONLY)
        if fd >= 0 {
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        }
        guard rename(temp.path, url.path) == 0 else {
            throw refuse("couldn't replace the original (\(String(cString: strerror(errno)))).")
        }
        return next
    }

    /// Before anything is written: everything but the EXIF and XMP segments
    /// byte-identical, the image data too, and ImageIO reading `orientation`.
    static func verify(original: Data, rewritten: Data, orientation: Int, name: String) throws {
        func refuse(_ why: String) -> VaultError {
            .cannotRotate("\(name): \(why), so the original was left alone.")
        }
        guard let a = JPEGFile(original), let b = JPEGFile(rewritten) else { throw refuse("the rotated file didn't read back") }
        guard a.image == b.image else { throw refuse("its image data changed") }
        let others: (JPEGFile) -> [JPEGFile.Segment] = { $0.segments.filter { !$0.isExif && !$0.isXMP } }
        guard others(a) == others(b) else { throw refuse("a segment other than its orientation changed") }
        guard let source = CGImageSourceCreateWithData(rewritten as CFData, nil), CGImageSourceGetCount(source) == 1,
              (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation] as? Int == orientation,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw refuse("the rotated file didn't read back with the new orientation")
        }
    }

    /// Writes only `changes` into the file, flushes it, and reads it back.
    private static func writeInPlace(_ patched: Data, changes: [Range<Int>], to url: URL, name: String) throws {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw VaultError.cannotRotate("\(name): couldn't open the file to change it.") }
        var ok = true
        patched.withUnsafeBytes { bytes in
            for range in changes {
                let written = pwrite(fd, bytes.baseAddress! + range.lowerBound, range.count, off_t(range.lowerBound))
                if written != range.count { ok = false }
            }
        }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
        guard ok, (try? Data(contentsOf: url)) == patched else {
            throw VaultError.cannotRotate("\(name): the change didn't read back as written.")
        }
    }
}

/// The orientation entry in a JPEG's EXIF block (IFD0, tag 0x0112).
enum ExifOrientation {
    struct Spot {
        /// Where the entry's two value bytes sit in the file.
        let offset: Int
        let bigEndian: Bool
        let value: Int

        func bytes(_ v: Int) -> Data {
            bigEndian ? Data([UInt8(v >> 8), UInt8(v & 0xFF)]) : Data([UInt8(v & 0xFF), UInt8(v >> 8)])
        }
    }

    /// The TIFF data in an EXIF body starts after "Exif\0\0".
    static let tiffStart = 6

    /// The entry, if the photo's EXIF has one. Throws on an EXIF block it
    /// can't read, or an entry in an unusual form.
    static func locate(in file: JPEGFile) throws -> Spot? {
        guard let i = file.segments.firstIndex(where: \.isExif) else { return nil }
        let body = [UInt8](file.segments[i].body)
        let tiff = try TIFFHeader(body)
        guard let entry = try tiff.entry(0x0112, in: body) else { return nil }
        let type = tiff.u16(body, entry + 2), count = tiff.u32(body, entry + 4)
        guard type == 3, count == 1 else { throw VaultError.cannotRotate("its orientation is stored in an unusual form.") }
        return Spot(offset: file.offsets[i] + entry + 8, bigEndian: tiff.bigEndian, value: tiff.u16(body, entry + 8))
    }

    /// The EXIF body with IFD0 copied to its end, the orientation entry added,
    /// and the header pointed at the copy. Nothing else in the block moves,
    /// so every offset in it — the maker's notes' among them — stays valid.
    static func adding(_ orientation: Int, to bodyData: Data, name: String) throws -> Data {
        let body = [UInt8](bodyData)
        let tiff = try TIFFHeader(body)
        let ifd0 = tiffStart + tiff.ifd0
        let n = tiff.u16(body, ifd0)
        let entriesEnd = ifd0 + 2 + 12 * n
        guard entriesEnd + 4 <= body.count else { throw VaultError.cannotRotate("\(name): its EXIF block couldn't be read.") }
        var entries = (0..<n).map { Array(body[(ifd0 + 2 + 12 * $0)..<(ifd0 + 14 + 12 * $0)]) }
        let value = tiff.bigEndian ? [UInt8(orientation >> 8), UInt8(orientation & 0xFF), 0, 0] : [UInt8(orientation & 0xFF), UInt8(orientation >> 8), 0, 0]
        entries.append(tiff.encode16(0x0112) + tiff.encode16(3) + tiff.encode32(1) + value)
        entries.sort { tiff.u16($0, 0) < tiff.u16($1, 0) }
        var out = body
        if (out.count - tiffStart) % 2 == 1 { out.append(0) }            // IFDs start on a word boundary
        let newIFD0 = out.count - tiffStart
        out += tiff.encode16(n + 1) + entries.flatMap { $0 } + Array(body[entriesEnd..<(entriesEnd + 4)])
        out.replaceSubrange((tiffStart + 4)..<(tiffStart + 8), with: tiff.encode32(newIFD0))
        guard out.count <= JPEGFile.maxBody else { throw VaultError.cannotRotate("\(name): its EXIF block is full.") }
        return Data(out)
    }

    /// A minimal EXIF block holding only the orientation.
    static func block(_ orientation: Int) -> Data {
        Data("Exif\0\0MM".utf8) + Data([0, 42, 0, 0, 0, 8, 0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, UInt8(orientation), 0, 0, 0, 0, 0, 0])
    }

    struct TIFFHeader {
        let bigEndian: Bool
        let ifd0: Int

        init(_ body: [UInt8]) throws {
            let t = ExifOrientation.tiffStart
            guard body.count >= t + 8 else { throw VaultError.cannotRotate("its EXIF block couldn't be read.") }
            if body[t] == 0x4D, body[t + 1] == 0x4D { bigEndian = true }
            else if body[t] == 0x49, body[t + 1] == 0x49 { bigEndian = false }
            else { throw VaultError.cannotRotate("its EXIF block couldn't be read.") }
            let le = !bigEndian
            func u16(_ o: Int) -> Int { le ? Int(body[o]) | Int(body[o + 1]) << 8 : Int(body[o]) << 8 | Int(body[o + 1]) }
            guard u16(t + 2) == 42 else { throw VaultError.cannotRotate("its EXIF block couldn't be read.") }
            ifd0 = le ? u16(t + 4) | u16(t + 6) << 16 : u16(t + 4) << 16 | u16(t + 6)
            guard t + ifd0 + 2 <= body.count else { throw VaultError.cannotRotate("its EXIF block couldn't be read.") }
        }

        func u16(_ b: [UInt8], _ o: Int) -> Int { bigEndian ? Int(b[o]) << 8 | Int(b[o + 1]) : Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ b: [UInt8], _ o: Int) -> Int { bigEndian ? u16(b, o) << 16 | u16(b, o + 2) : u16(b, o) | u16(b, o + 2) << 16 }
        func encode16(_ v: Int) -> [UInt8] { bigEndian ? [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] : [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func encode32(_ v: Int) -> [UInt8] { bigEndian ? encode16(v >> 16) + encode16(v) : encode16(v) + encode16(v >> 16) }

        /// Where IFD0's entry for `tag` starts in the body, if there is one.
        func entry(_ tag: Int, in body: [UInt8]) throws -> Int? {
            let start = ExifOrientation.tiffStart + ifd0
            let n = u16(body, start)
            guard start + 2 + 12 * n <= body.count else { throw VaultError.cannotRotate("its EXIF block couldn't be read.") }
            for i in 0..<n where u16(body, start + 2 + 12 * i) == tag { return start + 2 + 12 * i }
            return nil
        }
    }
}

/// The orientation an XMP packet states (`tiff:Orientation`), if any, as the
/// offset of its single digit in the file — changed in place, so the packet
/// keeps its length and every other byte.
enum XMPOrientation {
    static func digitOffset(in file: JPEGFile) throws -> Int? {
        guard let i = file.segments.firstIndex(where: \.isXMP) else { return nil }
        let body = file.segments[i].body
        // One character a byte, so string positions are byte positions.
        guard let text = String(data: body, encoding: .isoLatin1) else { return nil }
        let ns = text as NSString
        guard let declaration = try? NSRegularExpression(pattern: #"xmlns:([A-Za-z_][\w.-]*)\s*=\s*["']http://ns\.adobe\.com/tiff/1\.0/["']"#),
              let match = declaration.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let prefix = NSRegularExpression.escapedPattern(for: ns.substring(with: match.range(at: 1)))
        let forms = [#"\b\#(prefix):Orientation\s*=\s*["']([1-8])["']"#,
                     #"<\#(prefix):Orientation>\s*([1-8])\s*</\#(prefix):Orientation>"#]
        var found: [Int] = []
        for form in forms {
            let re = try NSRegularExpression(pattern: form)
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) { found.append(m.range(at: 1).location) }
        }
        guard found.count <= 1 else { throw VaultError.cannotRotate("its XMP states the orientation more than once.") }
        return found.first.map { file.offsets[i] + $0 }
    }
}

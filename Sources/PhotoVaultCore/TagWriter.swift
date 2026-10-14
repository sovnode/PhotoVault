import Foundation
import ImageIO

/// Writes tags into photo files, losslessly: JPEG only, byte by byte.
///
/// Only two things change: the XMP segment (the keyword list, `dc:subject`,
/// and PhotoVault's own field) and, where the photo keeps an IPTC copy of its
/// keywords, those IPTC entries and their digest. Every other byte is copied
/// through: the EXIF block with the maker's notes and thumbnail, the colour
/// profile, the tables, the image, and anything stored after it (a Motion
/// Photo's video). ImageIO's own rewrite isn't used: it rebuilds EXIF from its
/// own model and drops what it doesn't model — maker's notes, the
/// interoperability block, Software, DateTime — as a test on real phone
/// photos showed.
///
/// The rewrite is checked before it replaces anything — every untouched
/// segment byte-identical, the XMP's other properties as they were, the IPTC
/// copy matching, the keywords and record reading back — then written beside
/// the original, flushed to the device and renamed over it, so a crash leaves
/// the old file or the new one, never half of each. The file keeps its dates,
/// permissions and extended attributes (Finder tags among them): for a photo
/// with no capture date the file date is the only date it has.
public enum TagWriter {
    /// JPEG. PNG, HEIC and TIFF would need writers of their own to be as
    /// careful; until then their tags stay in the catalog, as GIF, BMP, WebP
    /// and videos' do.
    public static let writableTypes: Set<String> = ["jpg", "jpeg"]

    public static func canWrite(_ item: PhotoItem) -> Bool {
        item.mediaType == .photo && writableTypes.contains((item.relPath as NSString).pathExtension.lowercased())
    }

    /// What a write left in the file, for the catalog to mirror: its size and
    /// modification time, and its keywords and records.
    public struct Written: Sendable, Equatable {
        public var size: Int64
        public var mtime: Double
        public var keywords: [String]
        public var recordLines: [String]

        public var fileTags: FileTags {
            FileTags(keywords: keywords, records: recordLines.compactMap(ToolRecord.init(parsing:)))
        }
    }

    /// Replaces a classifier's tags and record in the file — JoyTag's, as
    /// `record.prefix` says. Every other keyword stays exactly as written, in
    /// its place; other tools' records stay too.
    @discardableResult
    public static func writeTags(_ names: [String], record: ToolRecord, to url: URL) throws -> Written {
        try rewrite(url) { keywords, lines in
            (replacingTags(in: keywords, prefix: record.prefix, with: names), replacingRecord(in: lines, with: record))
        }
    }

    /// The general rewrite. `change` is given the file's keywords and record
    /// lines and returns the ones to write.
    @discardableResult
    public static func rewrite(_ url: URL,
                               _ change: (_ keywords: [String], _ recordLines: [String]) throws -> ([String], [String])) throws -> Written {
        let name = url.lastPathComponent
        func refuse(_ why: String) -> VaultError { .cannotWriteTags("\(name): \(why).") }
        guard writableTypes.contains(url.pathExtension.lowercased()) else {
            throw refuse("PhotoVault writes tags into JPEG photos only; this one's stay in the catalog")
        }
        // Renaming over a read-only file would work, but read-only means hands off.
        guard access(url.path, W_OK) == 0 else { throw refuse("the file is read-only") }
        guard let original = try? Data(contentsOf: url), var file = JPEGFile(original) else {
            throw refuse("couldn't read it as a JPEG")
        }
        guard file.segments.filter(\.isXMP).count <= 1, file.segments.filter(\.isPhotoshop).count <= 1 else {
            throw refuse("it has more than one XMP or Photoshop block")
        }
        guard let source = CGImageSourceCreateWithData(original as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else { throw refuse("couldn't read the image") }

        let current = TagReader.readRaw(source)
        let (keywords, lines) = try change(current.keywords, current.recordLines)

        // XMP: the file's own packet, with only the keyword list and
        // PhotoVault's field changed.
        let packet: Data
        do {
            packet = try XMPEditor.edited(file.xmpPacket, keywords: keywords, recordLines: lines)
        } catch VaultError.cannotWriteTags(let why) {
            throw refuse(why)
        } catch {
            throw refuse("its XMP couldn't be read")
        }
        guard JPEGFile.xmpHeader.count + packet.count <= JPEGFile.maxBody else { throw refuse("its XMP would outgrow one segment") }
        file.setXMP(packet)

        // The IPTC copy of the keywords, where the photo keeps one, so apps
        // that read IPTC see the same list.
        if let i = file.segments.firstIndex(where: \.isPhotoshop) {
            guard let resources = PhotoshopResources(file.segments[i].body) else { throw refuse("its Photoshop block couldn't be read") }
            let body: Data
            do {
                body = try withKeywords(keywords, in: resources).serialized()
            } catch VaultError.cannotWriteTags(let why) {
                throw refuse(why)
            }
            guard body.count <= JPEGFile.maxBody else { throw refuse("its IPTC block would outgrow one segment") }
            file.segments[i].body = body
        }

        let rewritten = file.assembled()
        try verify(original: original, rewritten: rewritten, keywords: keywords, lines: lines, name: name)

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".photovault-tags-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }   // no-op after a successful rename
        guard FileManager.default.createFile(atPath: temp.path, contents: rewritten) else {
            throw refuse("couldn't write beside the original")
        }
        try carryOver(from: url, to: temp)

        // Durable before visible: flush the new bytes to the device, then swap.
        let fd = open(temp.path, O_RDONLY)
        if fd >= 0 {
            _ = fcntl(fd, F_FULLFSYNC)
            close(fd)
        }
        guard rename(temp.path, url.path) == 0 else {
            throw refuse("couldn't replace the original (\(String(cString: strerror(errno))))")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return Written(size: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
                       mtime: (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                       keywords: keywords, recordLines: lines)
    }

    /// Every IPTC block holding keywords — or the only one — with the new list.
    /// A digest that matched a block before matches it again after. (ImageIO
    /// writes an empty block and its digest ahead of the real one.)
    static func withKeywords(_ keywords: [String], in resources: PhotoshopResources) throws -> PhotoshopResources {
        var out = resources
        let blocks = out.resources.indices.filter { out.resources[$0].id == PhotoshopResources.iptc }
        let digest = out.resources.firstIndex { $0.id == PhotoshopResources.iptcDigest }
        let digested = digest.flatMap { d in blocks.first { IPTCBlock.digest(out.resources[$0].data) == out.resources[d].data } }
        for r in blocks where blocks.count == 1 || !out.resources[r].data.isEmpty {
            guard var iptc = IPTCBlock(out.resources[r].data) else {
                throw VaultError.cannotWriteTags("its IPTC block couldn't be read")
            }
            try iptc.setKeywords(keywords)
            out.resources[r].data = iptc.serialized()
        }
        if let d = digest, let r = digested { out.resources[d].data = IPTCBlock.digest(out.resources[r].data) }
        return out
    }

    // MARK: - The lists

    /// `keywords` without its `prefix:` tags, then `names` with the prefix.
    /// Which keywords count as prefixed follows `TagSources`, so what's removed
    /// is exactly what PhotoVault shows as that tool's.
    public static func replacingTags(in keywords: [String], prefix: String, with names: [String]) -> [String] {
        let kept = keywords.filter { TagSources.prefixed($0)?.prefix != prefix }
        var seen = Set<String>()
        let added = names.compactMap { name -> String? in
            let key = TagKey.key(name)
            guard !key.isEmpty, seen.insert(key).inserted else { return nil }
            return "\(prefix):\(name)"
        }
        return kept + added
    }

    /// `lines` without the record for `record`'s prefix, then `record`. Lines
    /// that don't parse belong to someone else and are kept.
    public static func replacingRecord(in lines: [String], with record: ToolRecord) -> [String] {
        lines.filter { ToolRecord(parsing: $0)?.prefix != record.prefix } + [record.line]
    }

    // MARK: - Checks

    /// Reads the rewrite back before it replaces anything.
    static func verify(original: Data, rewritten: Data, keywords: [String], lines: [String], name: String) throws {
        func refuse(_ why: String) -> VaultError {
            .cannotWriteTags("\(name): \(why), so the original was left alone.")
        }
        guard let a = JPEGFile(original), let b = JPEGFile(rewritten) else { throw refuse("the rewrite didn't read back") }
        // Everything but the keyword segments, byte for byte.
        guard a.image == b.image else { throw refuse("its image data changed") }
        guard a.untouched == b.untouched else { throw refuse("a segment other than its keywords changed") }

        // Every other element, attribute and value in the XMP as it was.
        guard let packet = b.xmpPacket, let now = try? XMPEditor.content(packet) else {
            throw refuse("its new XMP didn't read back")
        }
        if let old = a.xmpPacket {
            guard let was = try? XMPEditor.content(old), was == now else {
                throw refuse("its other XMP properties didn't come through")
            }
        }

        // The Photoshop block: only the IPTC keywords, and their digest.
        let psA = a.segments.first(where: \.isPhotoshop), psB = b.segments.first(where: \.isPhotoshop)
        if let psA {
            guard let psB, let ra = PhotoshopResources(psA.body), let rb = PhotoshopResources(psB.body) else {
                throw refuse("its Photoshop block didn't read back")
            }
            let isIPTC: (PhotoshopResources.Resource) -> Bool = {
                $0.id == PhotoshopResources.iptc || $0.id == PhotoshopResources.iptcDigest
            }
            guard ra.resources.filter({ !isIPTC($0) }) == rb.resources.filter({ !isIPTC($0) }) else {
                throw refuse("its Photoshop block changed")
            }
            let blocksA = ra.resources.filter { $0.id == PhotoshopResources.iptc }
            let blocksB = rb.resources.filter { $0.id == PhotoshopResources.iptc }
            guard blocksA.count == blocksB.count else { throw refuse("its IPTC blocks changed") }
            for (x, y) in zip(blocksA, blocksB) {
                guard blocksA.count == 1 || !x.data.isEmpty else {
                    guard x == y else { throw refuse("its IPTC blocks changed") }
                    continue
                }
                guard let ia = IPTCBlock(x.data), let ib = IPTCBlock(y.data) else { throw refuse("its IPTC block didn't read back") }
                let added90 = !ia.datasets.contains { $0.record == 1 && $0.number == 90 }
                let other: (IPTCBlock.DataSet) -> Bool = { !$0.isKeyword && !(added90 && $0.record == 1 && $0.number == 90) }
                guard ia.datasets.filter(other) == ib.datasets.filter(other), ia.trailing == ib.trailing,
                      ib.keywords == keywords else { throw refuse("its IPTC keywords didn't come out as intended") }
            }
            if let da = ra.resources.first(where: { $0.id == PhotoshopResources.iptcDigest }),
               let db = rb.resources.first(where: { $0.id == PhotoshopResources.iptcDigest }) {
                if let k = blocksA.firstIndex(where: { IPTCBlock.digest($0.data) == da.data }) {
                    guard db.data == IPTCBlock.digest(blocksB[k].data) else { throw refuse("its IPTC digest is wrong") }
                } else {
                    guard db == da else { throw refuse("its IPTC digest changed") }
                }
            }
        } else {
            guard psB == nil else { throw refuse("a Photoshop block appeared") }
        }

        // And what PhotoVault will read back.
        guard let source = CGImageSourceCreateWithData(rewritten as CFData, nil), CGImageSourceGetCount(source) == 1 else {
            throw refuse("the rewrite didn't read back as an image")
        }
        let back = TagReader.readRaw(source)
        guard back.keywords == keywords else { throw refuse("its keywords didn't read back as written") }
        guard back.recordLines.sorted() == lines.sorted() else { throw refuse("PhotoVault's record didn't read back as written") }
    }

    /// The parts of a JPEG that make the picture: its frame header, quantisation
    /// and Huffman tables, restart interval, the Adobe colour-transform marker,
    /// and everything from the first scan to the end of the file (later scans,
    /// and any images stored after the first, included). Metadata segments —
    /// EXIF, XMP, IPTC, comments — are left out. Nil if it isn't a JPEG.
    static func jpegImageData(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var out = Data()
        var i = 2
        while i + 1 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = bytes[i + 1]
            if marker == 0xFF { i += 1; continue }                       // fill byte
            if marker == 0xDA {                                          // start of scan
                out.append(contentsOf: bytes[i...])
                return out
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 { i += 2; continue }
            guard i + 3 < bytes.count else { return nil }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            guard length >= 2, i + 2 + length <= bytes.count else { return nil }
            let end = i + 2 + length
            let isFrame = (0xC0...0xCF).contains(marker)                 // SOFn, DHT, DAC
            if isFrame || marker == 0xDB || marker == 0xDD || marker == 0xEE {
                out.append(contentsOf: bytes[i..<end])
            }
            i = end
        }
        return nil
    }

    /// Dates, permissions, extended attributes and ACLs, from the original to
    /// its replacement. Dates last, the modification date to the nanosecond;
    /// `dates: false` leaves the replacement's own (a rotation is a change).
    static func carryOver(from original: URL, to temp: URL, dates: Bool = true) throws {
        var st = stat()
        guard stat(original.path, &st) == 0 else {
            throw VaultError.cannotWriteTags("\(original.lastPathComponent): couldn't read the file's details.")
        }
        _ = copyfile(original.path, temp.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL))
        _ = chmod(temp.path, st.st_mode & 0o7777)
        guard dates else { return }
        var times = [st.st_atimespec, st.st_mtimespec]
        _ = utimensat(AT_FDCWD, temp.path, &times, 0)
        // The creation date after the modification date: setting a modification
        // date earlier than the creation date drags the creation date back.
        var list = attrlist(bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0,
                            commonattr: attrgroup_t(ATTR_CMN_CRTIME), volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0)
        var created = st.st_birthtimespec
        _ = setattrlist(temp.path, &list, &created, MemoryLayout<timespec>.size, 0)
    }
}

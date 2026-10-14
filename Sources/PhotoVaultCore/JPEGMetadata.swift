import Foundation
import CryptoKit

/// A JPEG file as its segments — everything before the image data — and the
/// image data itself, from the first scan to the end of the file (later scans,
/// and anything stored after the picture, such as a Motion Photo's video,
/// included).
///
/// PhotoVault writes tags by swapping single segments and copying every other
/// byte through: unlike ImageIO's rewrite, which rebuilds the EXIF block from
/// its own model and drops what it doesn't model (the maker's notes, the
/// interoperability block, Software, some GPS fields).
struct JPEGFile: Equatable {
    struct Segment: Equatable {
        var marker: UInt8
        /// The bytes after the two-byte length.
        var body: Data

        var isXMP: Bool { marker == 0xE1 && body.starts(with: JPEGFile.xmpHeader) }
        var isExif: Bool { marker == 0xE1 && body.starts(with: Data("Exif\0".utf8)) }
        var isPhotoshop: Bool { marker == 0xED && body.starts(with: JPEGFile.photoshopHeader) }
    }

    static let xmpHeader = Data("http://ns.adobe.com/xap/1.0/\0".utf8)
    static let photoshopHeader = Data("Photoshop 3.0\0".utf8)
    /// The most a segment's body can hold: a 16-bit length, which counts itself.
    static let maxBody = 0xFFFF - 2

    var segments: [Segment]
    var image: Data
    /// Where each segment's body starts in the data it was read from — for
    /// editing a few bytes in place. Not kept up to date by changes.
    private(set) var offsets: [Int] = []

    /// Nil unless it parses cleanly up to the first scan.
    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var segments: [Segment] = [], offsets: [Int] = []
        var i = 2
        while i + 1 < b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF { i += 1; continue }                  // fill byte
            if marker == 0xDA {
                self.segments = segments
                self.offsets = offsets
                image = Data(b[i...])
                return
            }
            // A marker without a length before the first scan isn't a JPEG
            // PhotoVault should rewrite.
            if (0xD0...0xD9).contains(marker) || marker == 0x01 { return nil }
            guard i + 3 < b.count else { return nil }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2, i + 2 + length <= b.count else { return nil }
            segments.append(Segment(marker: marker, body: Data(b[(i + 4)..<(i + 2 + length)])))
            offsets.append(i + 4)
            i += 2 + length
        }
        return nil
    }

    static func == (a: JPEGFile, b: JPEGFile) -> Bool { a.segments == b.segments && a.image == b.image }

    func assembled() -> Data {
        var out = Data([0xFF, 0xD8])
        for s in segments {
            let length = s.body.count + 2
            out.append(contentsOf: [0xFF, s.marker, UInt8(length >> 8), UInt8(length & 0xFF)])
            out.append(s.body)
        }
        out.append(image)
        return out
    }

    /// The XMP packet, without its header.
    var xmpPacket: Data? {
        segments.first(where: \.isXMP).map { Data($0.body.dropFirst(JPEGFile.xmpHeader.count)) }
    }

    /// Puts an XMP segment in place of the old one, or after EXIF (or JFIF)
    /// if there wasn't one, where readers expect it.
    mutating func setXMP(_ packet: Data) {
        let segment = Segment(marker: 0xE1, body: JPEGFile.xmpHeader + packet)
        if let i = segments.firstIndex(where: \.isXMP) {
            segments[i] = segment
        } else if let i = segments.lastIndex(where: { $0.isExif || $0.marker == 0xE0 }) {
            segments.insert(segment, at: i + 1)
        } else {
            segments.insert(segment, at: 0)
        }
    }

    /// The segments a tag write leaves alone: all but XMP and Photoshop's.
    var untouched: [Segment] { segments.filter { !$0.isXMP && !$0.isPhotoshop } }
}

/// The image resources in a JPEG's Photoshop segment, kept byte for byte so
/// one can be replaced without disturbing the rest.
struct PhotoshopResources: Equatable {
    struct Resource: Equatable {
        var signature: Data      // "8BIM", rarely another four bytes
        var id: UInt16
        var name: Data           // Pascal string with its length byte and padding
        var data: Data
    }

    static let iptc: UInt16 = 0x0404
    static let iptcDigest: UInt16 = 0x0425

    var resources: [Resource]

    init?(_ body: Data) {
        let b = [UInt8](body)
        guard body.starts(with: JPEGFile.photoshopHeader) else { return nil }
        var i = JPEGFile.photoshopHeader.count
        var resources: [Resource] = []
        while i < b.count {
            // Trailing zero padding is allowed after the last resource.
            if b[i...].allSatisfy({ $0 == 0 }) { break }
            guard i + 12 <= b.count else { return nil }
            let signature = Data(b[i..<(i + 4)])
            guard ["8BIM", "MeSa", "PHUT", "AgHg", "DCSR"].contains(String(decoding: signature, as: UTF8.self)) else { return nil }
            let id = UInt16(b[i + 4]) << 8 | UInt16(b[i + 5])
            var j = i + 6
            let nameLength = Int(b[j])
            let nameBytes = (1 + nameLength) % 2 == 0 ? 1 + nameLength : 2 + nameLength
            guard j + nameBytes + 4 <= b.count else { return nil }
            let name = Data(b[j..<(j + nameBytes)])
            j += nameBytes
            let size = Int(b[j]) << 24 | Int(b[j + 1]) << 16 | Int(b[j + 2]) << 8 | Int(b[j + 3])
            j += 4
            guard size >= 0, j + size <= b.count else { return nil }
            resources.append(Resource(signature: signature, id: id, name: name, data: Data(b[j..<(j + size)])))
            j += size
            if size % 2 == 1 { j += 1 }
            i = j
        }
        self.resources = resources
    }

    func serialized() -> Data {
        var out = JPEGFile.photoshopHeader
        for r in resources {
            out.append(r.signature)
            out.append(contentsOf: [UInt8(r.id >> 8), UInt8(r.id & 0xFF)])
            out.append(r.name)
            let n = r.data.count
            out.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
            out.append(r.data)
            if n % 2 == 1 { out.append(0) }
        }
        return out
    }
}

/// An IPTC-IIM block: datasets in order, kept byte for byte. Keywords are
/// record 2, dataset 25, one per keyword.
struct IPTCBlock: Equatable {
    struct DataSet: Equatable {
        var record: UInt8
        var number: UInt8
        var value: Data
        var isKeyword: Bool { record == 2 && number == 25 }
    }

    var datasets: [DataSet]
    /// Bytes after the last dataset (padding), kept as they were.
    var trailing: Data

    init?(_ data: Data) {
        let b = [UInt8](data)
        var i = 0
        var datasets: [DataSet] = []
        while i < b.count, b[i] == 0x1C {
            guard i + 5 <= b.count else { return nil }
            let length = Int(b[i + 3]) << 8 | Int(b[i + 4])
            guard length & 0x8000 == 0, i + 5 + length <= b.count else { return nil }   // extended lengths: not here
            datasets.append(DataSet(record: b[i + 1], number: b[i + 2], value: Data(b[(i + 5)..<(i + 5 + length)])))
            i += 5 + length
        }
        guard b[i...].allSatisfy({ $0 == 0 }) else { return nil }
        self.datasets = datasets
        trailing = Data(b[i...])
    }

    var keywords: [String] { datasets.filter(\.isKeyword).map { String(decoding: $0.value, as: UTF8.self) } }

    /// The keyword datasets replaced by `keywords`, where the old ones were
    /// (or in IPTC order if there were none). A keyword that isn't plain ASCII
    /// is written as UTF-8, declared in dataset 1:90 if the block didn't
    /// declare it already.
    mutating func setKeywords(_ keywords: [String]) throws {
        let utf8 = Data([0x1B, 0x25, 0x47])   // ESC % G
        if !keywords.allSatisfy({ $0.utf8.allSatisfy { $0 < 0x80 } }),
           let declared = datasets.first(where: { $0.record == 1 && $0.number == 90 }), declared.value != utf8 {
            throw VaultError.cannotWriteTags("its IPTC block uses a character set other than UTF-8")
        }
        let first = datasets.firstIndex(where: \.isKeyword)
        datasets.removeAll(where: \.isKeyword)
        let at = first ?? datasets.lastIndex(where: { $0.record < 2 || ($0.record == 2 && $0.number < 25) }).map { $0 + 1 } ?? 0
        let values = keywords.map { Data($0.utf8) }
        guard values.allSatisfy({ $0.count < 0x8000 }) else { throw VaultError.cannotWriteTags("a keyword is too long for IPTC") }
        datasets.insert(contentsOf: values.map { DataSet(record: 2, number: 25, value: $0) }, at: at)
        if !keywords.allSatisfy({ $0.utf8.allSatisfy { $0 < 0x80 } }), !datasets.contains(where: { $0.record == 1 && $0.number == 90 }) {
            let i = datasets.lastIndex(where: { $0.record < 1 || ($0.record == 1 && $0.number < 90) }).map { $0 + 1 } ?? 0
            datasets.insert(DataSet(record: 1, number: 90, value: utf8), at: i)
        }
    }

    func serialized() -> Data {
        var out = Data()
        for d in datasets {
            out.append(contentsOf: [0x1C, d.record, d.number, UInt8(d.value.count >> 8), UInt8(d.value.count & 0xFF)])
            out.append(d.value)
        }
        out.append(trailing)
        return out
    }

    static func digest(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }
}

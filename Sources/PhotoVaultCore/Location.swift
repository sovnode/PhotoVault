import Foundation
import ImageIO
import AVFoundation

/// A place on the Earth, in degrees: north and east positive.
public struct GeoPoint: Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Nil for what can't be a real place: out of range, not a number, or
    /// exactly 0° 0° — what a camera without a fix often writes, and what
    /// Google Takeout puts in place of no location.
    public static func valid(latitude: Double, longitude: Double) -> GeoPoint? {
        guard latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0) else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }
}

/// Which part of the file a location came from. Stored in the catalog as
/// the raw value.
public enum LocationSource: Int, Sendable {
    case exif = 1
    case xmp = 2
    case quickTime = 3
}

public struct FileLocation: Sendable, Equatable {
    public var point: GeoPoint
    public var source: LocationSource

    public init(point: GeoPoint, source: LocationSource) {
        self.point = point
        self.source = source
    }
}

/// Where a photo or video was taken, as the file itself records it. Reads
/// headers only, never the picture, and never writes anything.
///
/// Locations are kept in the catalog for the map (planned, offline only:
/// nothing is ever sent anywhere to draw it). The properties panel reads
/// them through here too, so the two always agree.
public enum LocationReader {

    public static func read(url: URL, type: MediaType) async -> FileLocation? {
        switch type {
        case .photo: return photo(url: url)
        case .video: return await video(url: url)
        }
    }

    // MARK: - Photos

    /// EXIF GPS, or failing that the same in the photo's XMP. JPEG, HEIC and
    /// anything else ImageIO reads.
    public static func photo(url: URL) -> FileLocation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return photo(source: source, properties: props)
    }

    /// For a caller that has the header open already — the thumbnailer, the
    /// properties panel — so the file isn't read twice.
    public static func photo(source: CGImageSource, properties: [CFString: Any]) -> FileLocation? {
        if let point = exif(properties) { return FileLocation(point: point, source: .exif) }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let point = xmp(metadata) {
            return FileLocation(point: point, source: .xmp)
        }
        return nil
    }

    /// ImageIO gives degrees without a sign, and the hemisphere separately.
    /// A missing hemisphere leaves the number as it is.
    static func exif(_ properties: [CFString: Any]) -> GeoPoint? {
        guard let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue,
              let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased().hasPrefix("S") == true
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased().hasPrefix("W") == true
        return GeoPoint.valid(latitude: south ? -abs(lat) : lat, longitude: west ? -abs(lon) : lon)
    }

    /// XMP keeps GPS as text: "51,30.042N" (degrees, decimal minutes) or
    /// "51,30,2.52N" (degrees, minutes, seconds).
    static func xmp(_ metadata: CGImageMetadata) -> GeoPoint? {
        func value(_ path: String) -> String? {
            guard let tag = CGImageMetadataCopyTagWithPath(metadata, nil, path as CFString) else { return nil }
            return CGImageMetadataTagCopyValue(tag) as? String
        }
        guard let lat = value("exif:GPSLatitude").flatMap(xmpCoordinate),
              let lon = value("exif:GPSLongitude").flatMap(xmpCoordinate) else { return nil }
        return GeoPoint.valid(latitude: lat, longitude: lon)
    }

    static func xmpCoordinate(_ text: String) -> Double? {
        var body = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let ref = body.last, "NSEW".contains(ref) else { return nil }
        body.removeLast()
        let parts = body.split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
        let n = parts.map { $0! }
        guard n.allSatisfy({ $0 >= 0 }), n.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let degrees = n[0] + n[1] / 60 + (n.count == 3 ? n[2] / 3600 : 0)
        return ref == "S" || ref == "W" ? -degrees : degrees
    }

    // MARK: - Videos

    /// The ISO 6709 location in a movie's metadata: iPhone's
    /// `com.apple.quicktime.location.ISO6709`, or the `©xyz` user data most
    /// Android phones and cameras write.
    public static func video(url: URL) async -> FileLocation? {
        await video(asset: AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]))
    }

    public static func video(asset: AVAsset) async -> FileLocation? {
        if let common = try? await asset.load(.commonMetadata) {
            for item in common where item.commonKey == .commonKeyLocation {
                if let text = try? await item.load(.stringValue), let point = iso6709(text) {
                    return FileLocation(point: point, source: .quickTime)
                }
            }
        }
        // Not every file's location is mapped to the common key.
        let ids: Set<AVMetadataIdentifier> = [.quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709]
        if let all = try? await asset.load(.metadata) {
            for item in all where item.identifier.map(ids.contains) == true {
                if let text = try? await item.load(.stringValue), let point = iso6709(text) {
                    return FileLocation(point: point, source: .quickTime)
                }
            }
        }
        return nil
    }

    /// "+35.3606+138.7274+3776.000/": latitude, longitude, then an altitude
    /// and a coordinate system that are ignored. Each number may also be
    /// written as ±DDMM.M or ±DDMMSS.S (three degree digits for longitude),
    /// which ISO 6709 allows and a few cameras use.
    static func iso6709(_ text: String) -> GeoPoint? {
        var parts: [Substring] = []
        var start: String.Index?
        let s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var end = s.endIndex
        for i in s.indices {
            let c = s[i]
            if c == "+" || c == "-" {
                if let st = start { parts.append(s[st..<i]) }
                start = i
            } else if !(c.isASCII && (c.isNumber || c == ".")) {
                end = i   // the altitude's end, a coordinate system, or "/"
                break
            }
        }
        if let st = start, st < end { parts.append(s[st..<end]) }
        guard parts.count >= 2,
              let lat = degrees(parts[0], degreeDigits: 2),
              let lon = degrees(parts[1], degreeDigits: 3) else { return nil }
        return GeoPoint.valid(latitude: lat, longitude: lon)
    }

    private static func degrees(_ part: Substring, degreeDigits: Int) -> Double? {
        guard let sign = part.first, sign == "+" || sign == "-" else { return nil }
        let body = part.dropFirst()
        let whole = body.prefix { $0 != "." }
        let fraction = body.dropFirst(whole.count)
        guard !whole.isEmpty, whole.allSatisfy(\.isNumber),
              fraction.isEmpty || (fraction.count > 1 && fraction.dropFirst().allSatisfy(\.isNumber)) else { return nil }
        let value: Double?
        switch whole.count {
        case 1...degreeDigits + 1:
            // Degrees — some writers don't pad to the standard's width
            // ("-0.1246"), some pad latitude to three digits.
            value = Double(body)
        case degreeDigits + 2:
            let d = Double(whole.prefix(degreeDigits))!
            let m = Double(body.dropFirst(degreeDigits))!
            value = m < 60 ? d + m / 60 : nil
        case degreeDigits + 4:
            let d = Double(whole.prefix(degreeDigits))!
            let m = Double(whole.dropFirst(degreeDigits).prefix(2))!
            let sec = Double(body.dropFirst(degreeDigits + 2))!
            value = m < 60 && sec < 60 ? d + m / 60 + sec / 3600 : nil
        default:
            value = nil
        }
        return value.map { sign == "-" ? -$0 : $0 }
    }
}

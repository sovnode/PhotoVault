import Foundation
import ImageIO

/// What the properties panel shows beyond the catalog: camera, exposure and
/// location, read from the file's header (no decode, a millisecond or so).
///
/// Location is only ever turned into coordinate text here. Showing it on a map
/// would fetch map tiles from Apple's servers and reveal where the photo was
/// taken.
public struct PhotoMetadata: Sendable, Equatable {
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var iso: Int?
    public var focalLength: Double?
    public var latitude: Double?
    public var longitude: Double?

    public init() {}

    public static func read(url: URL) -> PhotoMetadata {
        var m = PhotoMetadata()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return m }
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        m.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        m.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        m.lens = exif[kCGImagePropertyExifLensModel] as? String
        m.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
        m.exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
        m.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        m.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        if let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            m.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            m.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
        return m
    }

    /// "Fujifilm X-T4" — without repeating the maker when the model already
    /// names it ("Canon EOS R5", not "Canon Canon EOS R5").
    public var cameraDescription: String? {
        switch (cameraMake, cameraModel) {
        case let (make?, model?):
            return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        case let (make?, nil): return make
        case let (nil, model?): return model
        default: return nil
        }
    }

    /// "ƒ/2.8 · 1/250 s · ISO 200 · 18.5 mm", with whatever parts exist.
    public var exposureDescription: String? {
        var parts: [String] = []
        if let f = fNumber { parts.append(String(format: "ƒ/%.1f", f)) }
        if let t = exposureTime {
            parts.append(t >= 1 ? String(format: "%.1f s", t) : "1/\(Int((1 / t).rounded())) s")
        }
        if let iso { parts.append("ISO \(iso)") }
        if let f = focalLength { parts.append(String(format: "%.1f mm", f)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "51.5007° N, 0.1246° W" — text only, never a map.
    public var coordinatesDescription: String? {
        guard let latitude, let longitude else { return nil }
        return String(format: "%.4f° %@, %.4f° %@",
                      abs(latitude), latitude >= 0 ? "N" : "S",
                      abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

extension PhotoItem {
    /// Width × height as the photo is seen, after its EXIF orientation: 5–8
    /// are quarter turns, so they swap the stored pixel dimensions.
    public var orientedSize: (width: Int, height: Int) {
        (5...8).contains(orientation) ? (height, width) : (width, height)
    }
}

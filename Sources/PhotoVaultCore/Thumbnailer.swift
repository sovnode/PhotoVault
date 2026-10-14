import Foundation
import ImageIO
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers

public struct ThumbResult: Sendable {
    public var jpeg: Data
    public var width: Int
    public var height: Int
    public var orientation: Int
    public var capturedAt: Double?
    public var duration: Double?
    public var posterTime: Double?
    public var playable: Bool
}

/// Produces the 512 px JPEGs that go into the pack.
///
/// Everything is encoded to memory and handed back as `Data`. Nothing here may
/// touch `FileManager.temporaryDirectory` — a thumbnail written to /var/folders
/// is a copy of the user's pixels outside the volume, which is the one thing
/// this app exists to avoid. For the same reason `QLThumbnailGenerator` is
/// never called: its documented behaviour is to populate the shared Quick Look
/// cache. ImageIO and AVFoundation do not.
public actor Thumbnailer {
    public static let maxPixel = 512
    public static let jpegQuality = 0.7

    private let photoLimiter: Limiter
    private let videoLimiter: Limiter
    /// Test-only: a pause before each thumbnail, so the smoke test can stop a
    /// scan part-way. Zero in normal use.
    private let testDelay: UInt64
    /// Test-only: CPU-bound work that holds its thread, like a real decode
    /// does — unlike `testDelay`, which an actor would let other calls overlap.
    private let testBusyWork: UInt32

    public init(photoConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
                videoConcurrency: Int = 3,
                testDelayNanoseconds: UInt64 = 0,
                testBusyMicroseconds: UInt32 = 0) {
        testDelay = testDelayNanoseconds
        testBusyWork = testBusyMicroseconds
        // Hardware decode sessions are a shared, limited resource: ten
        // concurrent generators make VideoToolbox serialize or outright fail.
        // Photos are pure CPU and scale with cores.
        photoLimiter = Limiter(limit: max(1, photoConcurrency))
        videoLimiter = Limiter(limit: max(1, videoConcurrency))
    }

    /// `nonisolated` so the decoding runs on the caller's thread, in parallel up
    /// to the limiter's count. Isolated to the actor, as it was until 1.2.0, the
    /// actor ran one decode at a time and the limit never mattered.
    nonisolated public func thumbnail(for url: URL, type: MediaType) async -> Result<ThumbResult, Error> {
        let limiter = type == .photo ? photoLimiter : videoLimiter
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        do {
            // A stopped scan shouldn't start work it will throw away.
            try Task.checkCancellation()
            if testDelay > 0 { try await Task.sleep(nanoseconds: testDelay) }
            if testBusyWork > 0 { usleep(testBusyWork) }
            switch type {
            case .photo: return .success(try Thumbnailer.makePhotoThumb(url: url))
            case .video: return .success(try await Thumbnailer.makeVideoThumb(url: url))
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Photos

    /// ImageIO, never `NSImage`: NSImage would decode the full original and
    /// then hand back something that needs decoding again at draw time.
    public static func makePhotoThumb(url: URL) throws -> ThumbResult {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw VaultError.packCorrupt("unreadable image: \(url.lastPathComponent)")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let details = Self.details(from: props)

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,  // bakes in EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw VaultError.packCorrupt("could not thumbnail \(url.lastPathComponent)")
        }
        let jpeg = try encodeJPEG(cg)
        return ThumbResult(
            jpeg: jpeg,
            width: details.width, height: details.height, orientation: details.orientation,
            capturedAt: details.capturedAt,
            duration: nil, posterTime: nil, playable: true
        )
    }

    public struct Details: Sendable {
        public var width: Int
        public var height: Int
        public var orientation: Int
        public var capturedAt: Double?
        public var duration: Double?
    }

    static func details(from props: [CFString: Any]) -> Details {
        Details(width: props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                height: props[kCGImagePropertyPixelHeight] as? Int ?? 0,
                orientation: props[kCGImagePropertyOrientation] as? Int ?? 1,
                capturedAt: captureDate(from: props),
                duration: nil)
    }

    /// Dimensions, orientation and capture date from the file's header alone —
    /// no decode, no thumbnail. A millisecond or two per photo.
    public static func photoDetails(url: URL) throws -> Details {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw VaultError.packCorrupt("unreadable image: \(url.lastPathComponent)")
        }
        return details(from: props)
    }

    /// The same for a video, from its track and container metadata.
    public static func videoDetails(url: URL) async throws -> Details {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let track = tracks.first else { throw VaultError.noVideoTrack }
        let size = (try? await track.load(.naturalSize)) ?? .zero
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let created = try? await asset.load(.creationDate)?.load(.dateValue)
        return Details(width: Int(abs(size.width)), height: Int(abs(size.height)), orientation: 1,
                       capturedAt: created?.timeIntervalSince1970,
                       duration: duration.isFinite ? duration : nil)
    }

    /// Straight to a `CFMutableData` — no intermediate file anywhere.
    public static func encodeJPEG(_ cg: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw VaultError.packCorrupt("no JPEG encoder")
        }
        CGImageDestinationAddImage(dest, cg, [
            kCGImageDestinationLossyCompressionQuality: jpegQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw VaultError.packCorrupt("JPEG encode failed")
        }
        return data as Data
    }

    static func captureDate(from props: [CFString: Any]) -> Double? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        fmt.timeZone = .current

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String,
           let d = fmt.date(from: s) {
            return d.timeIntervalSince1970
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let s = tiff[kCGImagePropertyTIFFDateTime] as? String,
           let d = fmt.date(from: s) {
            return d.timeIntervalSince1970
        }
        return nil
    }

    // MARK: - Videos

    public static func makeVideoThumb(url: URL) async throws -> ThumbResult {
        let asset = AVURLAsset(url: url, options: [
            // Skips a full index parse; we only need a rough duration to pick a
            // seek target, and precision here costs hundreds of milliseconds.
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])

        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard !tracks.isEmpty else { throw VaultError.noVideoTrack }

        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let naturalSize = (try? await tracks[0].load(.naturalSize)) ?? .zero

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true   // portrait phone video is rotated in metadata, not pixels
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        // Frame zero is black or mid-fade in a large fraction of real footage.
        let safeDuration = duration.isFinite && duration > 0 ? duration : 1
        let target = min(max(safeDuration * 0.1, 0.5), 10)

        // .zero tolerance forces a decode from the preceding keyframe to an
        // exact frame — up to 10x slower for a thumbnail nobody inspects. But a
        // flat 1s window reaches back past zero on any clip short enough to hit
        // the 0.5s floor, handing back exactly the black opening frame the seek
        // exists to avoid. Half the target is generous on long videos and still
        // safe on short ones.
        let toleranceBefore = min(1.0, target / 2)
        gen.requestedTimeToleranceBefore = CMTime(seconds: toleranceBefore, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let (cg, actual) = try await gen.image(at: CMTime(seconds: target, preferredTimescale: 600))

        let creation = try? await asset.load(.creationDate)?.load(.dateValue)
        return ThumbResult(
            jpeg: try encodeJPEG(cg),
            width: Int(abs(naturalSize.width)), height: Int(abs(naturalSize.height)),
            orientation: 1,
            capturedAt: creation?.timeIntervalSince1970,
            duration: duration.isFinite ? duration : nil,
            posterTime: actual.seconds.isFinite ? actual.seconds : target,
            playable: true
        )
    }
}

/// A plain counting semaphore over async/await. `DispatchSemaphore` would block
/// a cooperative-pool thread, which is exactly what must not happen here.
actor Limiter {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            active = max(0, active - 1)
        }
    }
}

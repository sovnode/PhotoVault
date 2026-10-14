import Testing
import Foundation
import ImageIO
import AVFoundation
@testable import PhotoVaultCore

@Suite("Thumbnailer")
struct ThumbnailerTests {
    let vault: TestVault

    init() throws { vault = try TestVault() }

    private func decodedSize(_ jpeg: Data) throws -> (width: Int, height: Int) {
        let src = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        return (cg.width, cg.height)
    }

    @Test func photoThumbIsCappedAt512AndDecodable() throws {
        let url = try vault.writeImage("big.jpg", size: 1400)
        let result = try Thumbnailer.makePhotoThumb(url: url)

        #expect(result.width == 1400, "the recorded dimensions are the original's, not the thumbnail's")
        #expect(result.height == 1400)

        let size = try decodedSize(result.jpeg)
        #expect(max(size.width, size.height) <= Thumbnailer.maxPixel)
        #expect(max(size.width, size.height) > 0)
    }

    @Test func smallPhotoIsNotUpscaled() throws {
        let url = try vault.writeImage("small.jpg", size: 80)
        let size = try decodedSize(try Thumbnailer.makePhotoThumb(url: url).jpeg)
        #expect(max(size.width, size.height) == 80)
    }

    @Test func thumbIsSubstantiallySmallerThanOriginal() throws {
        let url = try vault.writeImage("big.jpg", size: 2000)
        let result = try Thumbnailer.makePhotoThumb(url: url)
        #expect(result.jpeg.count < vault.fileSize(url))
    }

    @Test func encodedThumbIsActuallyAJPEG() throws {
        let url = try vault.writeImage("a.jpg", size: 300)
        #expect(TestVault.isJPEG(try Thumbnailer.makePhotoThumb(url: url).jpeg))
    }

    @Test func unreadableImageThrowsRatherThanProducingGarbage() throws {
        let url = try vault.writeJunk("broken.jpg")
        #expect(throws: (any Error).self) { _ = try Thumbnailer.makePhotoThumb(url: url) }
    }

    @Test func videoPosterIsSeekedPastTheOpeningFrame() async throws {
        let url = vault.photos.appendingPathComponent("clip.mp4")
        try FileManager.default.createDirectory(at: vault.photos, withIntermediateDirectories: true)
        try await VideoFixture.write(to: url, seconds: 4)

        let result = try await Thumbnailer.makeVideoThumb(url: url)

        #expect(result.width == 160)
        #expect(result.height == 120)
        #expect(result.playable)

        let duration = try #require(result.duration)
        #expect(abs(duration - 4) < 0.5, "duration was \(duration)")

        // ~10% in, clamped to [0.5, 10]. With a 1s tolerance either way the
        // exact frame isn't fixed, but it must not be frame zero.
        let poster = try #require(result.posterTime)
        #expect(poster > 0, "poster landed on frame zero, which is black in most real footage")
        #expect(poster < duration)
        #expect(TestVault.isJPEG(result.jpeg))
    }

    @Test func fileWithNoVideoTrackIsRejectedNotCrashed() async throws {
        let url = try vault.writeJunk("fake.mkv", bytes: 4096)
        await #expect(throws: (any Error).self) {
            _ = try await Thumbnailer.makeVideoThumb(url: url)
        }
    }

    /// The limiter is what keeps ten concurrent generators from making
    /// VideoToolbox serialize or fail outright.
    @Test func limiterNeverExceedsItsCeiling() async throws {
        let limiter = Limiter(limit: 3)
        let counter = ConcurrencyPeak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<25 {
                group.addTask {
                    await limiter.acquire()
                    await counter.enter()
                    try? await Task.sleep(nanoseconds: 2_000_000)
                    await counter.leave()
                    await limiter.release()
                }
            }
        }
        let peak = await counter.peak
        #expect(peak <= 3, "peak concurrency was \(peak)")
        #expect(peak > 1, "…but it should still actually run in parallel")
    }

    @Test func limiterReleasesEveryWaiter() async throws {
        let limiter = Limiter(limit: 2)
        let counter = ConcurrencyPeak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    await limiter.acquire()
                    await counter.enter()
                    await counter.leave()
                    await limiter.release()
                }
            }
        }
        // A limiter that leaked a permit would deadlock the group above rather
        // than reach this line.
        #expect(await counter.total == 50)
    }
}

actor ConcurrencyPeak {
    private(set) var peak = 0
    private(set) var total = 0
    private var current = 0
    func enter() { current += 1; total += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

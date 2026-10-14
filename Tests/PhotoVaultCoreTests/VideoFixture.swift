import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
@testable import PhotoVaultCore

/// Writes a short, real H.264 movie. Nothing about the AVFoundation path —
/// track loading, the preferred transform, the 10% seek — can be exercised with
/// a fake file, so the tests make one.
enum VideoFixture {
    static func write(to url: URL, seconds: Int = 2, size: CGSize = CGSize(width: 160, height: 120)) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let fps = 10
        let total = seconds * fps
        for frame in 0..<total {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { break }
            fill(buffer, brightness: Double(frame) / Double(total), size: size)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw writer.error ?? VaultError.packCorrupt("asset writer failed")
        }
    }

    private static func fill(_ buffer: CVPixelBuffer, brightness: Double, size: CGSize) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let ctx = CGContext(
                data: base,
                width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return }
        // Frame zero is deliberately black: the "seek 10% in" rule exists
        // because real footage opens on black or a fade more often than not,
        // and a test whose first frame is interesting wouldn't catch a regression.
        ctx.setFillColor(red: brightness, green: brightness * 0.5, blue: 1 - brightness, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
    }
}

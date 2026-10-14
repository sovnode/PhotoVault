// Generates a small, realistic set of test media.
//
// Usage: swift Scripts/make-test-media.swift <output-dir> [photo-count]
//
// Writes `photo-count` JPEGs (default 40) of assorted sizes across nested
// folders, two real H.264 clips, and one file in a container AVFoundation can't
// open — so a run exercises the photo path, the video path, and the
// "badge it, don't break" path. Prints a one-line summary the smoke test parses.
//
// Everything is synthetic: no personal photos are ever needed to test the app.

import Foundation
import CoreGraphics
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift Scripts/make-test-media.swift <output-dir> [photo-count]\n".data(using: .utf8)!)
    exit(64)
}
let out = URL(fileURLWithPath: args[1])
let photoCount = args.count >= 3 ? max(1, Int(args[2]) ?? 40) : 40

/// Some photos carry keywords, as photos from other apps do, so the smoke test
/// can check that a scan reads them.
func keywords(for i: Int) -> [String] {
    switch i % 4 {
    case 0: return ["beach", "Sky"]
    case 1: return ["child"]
    default: return []
    }
}

func jpeg(size: Int, hue: Double, keywords: [String] = []) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: hue, green: 1 - hue, blue: 0.4, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    for i in 0..<12 {
        ctx.setFillColor(red: Double(i) / 12, green: hue, blue: 1 - hue, alpha: 0.7)
        ctx.fillEllipse(in: CGRect(x: Double(i) * Double(size) / 12, y: hue * Double(size),
                                   width: Double(size) / 8, height: Double(size) / 8))
    }
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
    let metadata = CGImageMetadataCreateMutable()
    if !keywords.isEmpty {
        let subject = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString, "dc" as CFString,
                                               "subject" as CFString, .arrayUnordered, keywords as CFArray)!
        CGImageMetadataSetTagWithPath(metadata, nil, "dc:subject" as CFString, subject)
    }
    CGImageDestinationAddImageAndMetadata(dest, ctx.makeImage()!, metadata,
                                          [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func video(_ url: URL, seconds: Int, type: AVFileType) async throws {
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: type)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 480,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
        kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 480,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let fps = 24, total = seconds * fps
    for frame in 0..<total {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let c = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 480,
                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let t = Double(frame) / Double(total)
        // Opens on near-black, like a lot of real footage — the poster-frame
        // seek exists to skip exactly that.
        c.setFillColor(red: t, green: 0.2 * t, blue: 1 - t, alpha: 1)
        c.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        c.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        c.fillEllipse(in: CGRect(x: t * 540, y: 200, width: 80, height: 80))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
}

let folders = ["", "2019", "2019/summer", "2020", "2021/trip"]
for f in folders {
    try FileManager.default.createDirectory(at: out.appendingPathComponent(f), withIntermediateDirectories: true)
}
for i in 0..<photoCount {
    let folder = folders[i % folders.count]
    let size = [400, 800, 1600, 2400][i % 4]
    let url = out.appendingPathComponent(folder).appendingPathComponent(String(format: "IMG_%04d.jpg", 1000 + i))
    try jpeg(size: size, hue: Double((i * 37) % 100) / 100, keywords: keywords(for: i)).write(to: url)
}
try await video(out.appendingPathComponent("2021/trip/clip.mp4"), seconds: 6, type: .mp4)
try await video(out.appendingPathComponent("2020/short.mov"), seconds: 2, type: .mov)
// Plausible name, unplayable contents: the app must badge it, not choke on it.
try Data(repeating: 0x1A, count: 50_000).write(to: out.appendingPathComponent("2020/unsupported.mkv"))

let tagged = (0..<photoCount).filter { !keywords(for: $0).isEmpty }.count
let sky = (0..<photoCount).filter { keywords(for: $0).contains("Sky") }.count
print("photos=\(photoCount) videos=2 unsupported=1 tagged=\(tagged) sky=\(sky)")

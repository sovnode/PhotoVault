import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoVaultCore

/// A throwaway vault on local disk with the same shape as the real one.
final class TestVault {
    let root: URL

    init(name: String = UUID().uuidString) throws {
        root = TestVault.sandbox.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try VolumeLocator.ensureScaffolding(at: root)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Every test vault lives under this one directory, so the containment
    /// tests can tell "files the app wrote outside the volume" from "the test
    /// fixtures themselves".
    static let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
        .resolvingSymlinksInPath()
        .appendingPathComponent("photovault-tests")

    var photos: URL { VolumeLocator.mediaDir(root) }
    var catalogDir: URL { VolumeLocator.catalogDir(root) }
    var catalogFile: URL { catalogDir.appendingPathComponent("catalog.sqlite") }
    var packFile: URL { catalogDir.appendingPathComponent("thumbs.pack") }

    @discardableResult
    func writeImage(_ relPath: String, size: Int = 64, seed: Double = 0.5) throws -> URL {
        let url = photos.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try TestVault.jpegData(size: size, seed: seed).write(to: url)
        return url
    }

    @discardableResult
    func writeJunk(_ relPath: String, bytes: Int = 2048) throws -> URL {
        let url = photos.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data[0] = 0xFF
        try data.write(to: url)
        return url
    }

    func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) as? Int ?? 0
    }

    /// A real, decodable JPEG — the ImageIO path under test refuses anything less.
    static func jpegData(size: Int, seed: Double) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw VaultError.packCorrupt("no context")
        }
        ctx.setFillColor(red: seed, green: 1 - seed, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(red: 1 - seed, green: seed, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: size / 2))
        guard let cg = ctx.makeImage() else { throw VaultError.packCorrupt("no image") }
        return try Thumbnailer.encodeJPEG(cg)
    }

    static func isJPEG(_ data: Data) -> Bool {
        data.count > 3 && data[0] == 0xFF && data[1] == 0xD8
    }
}

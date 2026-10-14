import Testing
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoVaultCore

@Suite("JoyTag's input")
struct JoyTagInputTests {
    /// The test pattern, as `pil_fixtures.py` builds it in numpy.
    static func pattern(_ w: Int, _ h: Int) -> JoyTagInput.RGB8 {
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 3
                px[i] = UInt8((x * 7 + y * 13) & 255)
                px[i + 1] = UInt8((x * x + 3 * y) & 255)
                px[i + 2] = UInt8(((x ^ y) * 5) & 255)
            }
        }
        return JoyTagInput.RGB8(width: w, height: h, pixels: px)
    }

    static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(_ floats: [Float]) -> String {
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }   // little-endian on Apple silicon and Intel
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// From Pillow 12.3 and numpy 2.5: the padded, resized pixels, and the
    /// finished tensor. Landscape and portrait padding, shrinking, enlarging,
    /// a square, and one already 448 wide (padded, not resized).
    static let pillow: [(Int, Int, String, String)] = [
        (512, 369, "48c7c227330ed9cbf1bdeade058986be2694a81a7a7abba37450c883e5ef7f59", "e1f815caa25880a7910ded44178b7b59c8ea6cd4d027f7bc3048eb746e4beedc"),
        (300, 512, "6c42fa81fd4c6de065c48eafd92c06288917472ed4fc68df9ec0b761a7bac964", "339ff70a9d91558b970127ad086c8edc64b9877efa4dcd7dceda7b9c55c80bed"),
        (200, 150, "f6faceef5ab15bd4aae9da3311897e440fd28b145fd4e6099e6975c152115c47", "c5c80ec8a5c7d1f8c153039aa997839027b293e740539b2c91d4e49e99bb832f"),
        (512, 512, "6d67c3d3e506710f6ae0af0682d85bfe7a15468ffe221d19bcf3e3679fa3e465", "63b2109221d7bf046feeffc340cb6f6252941bd31a5119a85fa8fff9346a50f8"),
        (448, 300, "5b458338869947194158a0f8fa85c7550deefbb4946b833f4ccc74b905ba8de5", "d6cc61b67d0d4ab61d24f93da6a321af8561fde8fc7cfb5e70ec3d151ea27571"),
        (37, 91, "700a2ab5ab5ba2300bece5e64d92e204ca7e77ab43a70831f43574391415c8fe", "77485ddaf4edcc2da3ca88504d3cc4991aea89815df2d55f555048c07a807ac1"),
    ]

    @Test(arguments: pillow.indices)
    func matchesPillowExactly(_ i: Int) {
        let (w, h, pixels, tensor) = Self.pillow[i]
        let image = Self.pattern(w, h)
        var square = JoyTagInput.padToSquare(image)
        if square.width != JoyTagInput.size { square = JoyTagInput.resize(square, to: JoyTagInput.size) }
        #expect(square.width == 448 && square.height == 448)
        #expect(Self.sha256(square.pixels) == pixels, "pixels for \(w)×\(h)")
        #expect(Self.sha256(JoyTagInput.tensor(from: image)) == tensor, "tensor for \(w)×\(h)")
    }

    @Test func padsWithWhiteAndCentres() {
        let image = JoyTagInput.RGB8(width: 2, height: 1, pixels: [10, 20, 30, 40, 50, 60])
        let square = JoyTagInput.padToSquare(image)
        #expect(square.width == 2 && square.height == 2)
        // (2 − 1) / 2 = 0 rows above: the extra row goes below, as in Python.
        #expect(square.pixels == [10, 20, 30, 40, 50, 60, 255, 255, 255, 255, 255, 255])
    }

    /// PNG is lossless, so decoding must give back exactly the pixels written,
    /// with no colour conversion on the way.
    @Test func decodesWithoutColourConversion() throws {
        let image = Self.pattern(64, 40)
        for space in [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.adobeRGB1998] {
            let data = try Self.png(image, space: space)
            #expect(JoyTagInput.decode(data) == image, "colour space \(space)")
        }
    }

    @Test func greyBecomesRGB() throws {
        let grey: [UInt8] = (0..<(16 * 8)).map { UInt8($0 * 2) }
        let provider = CGDataProvider(data: Data(grey) as CFData)!
        let cg = CGImage(width: 16, height: 8, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 16,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let decoded = try #require(JoyTagInput.pixels(of: cg))
        #expect(decoded.pixels == grey.flatMap { [$0, $0, $0] })
    }

    static func png(_ image: JoyTagInput.RGB8, space: CFString) throws -> Data {
        var rgba = [UInt8]()
        for i in 0..<(image.width * image.height) {
            rgba += [image.pixels[i * 3], image.pixels[i * 3 + 1], image.pixels[i * 3 + 2], 255]
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: image.width * 4, space: CGColorSpace(name: space)!,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }
}

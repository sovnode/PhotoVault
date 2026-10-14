import Foundation
import ImageIO
import Accelerate

/// JoyTag's input, prepared exactly as JoyTag's own code prepares it: the image
/// padded to a white square, resized to 448 pixels with the bicubic filter of
/// Pillow (the Python imaging library JoyTag was trained with), scaled to 0–1,
/// normalised with CLIP's mean and standard deviation, channels first.
///
/// The resize is a line-for-line port of Pillow's, fixed-point arithmetic and
/// all, so the same pixels in give the same numbers out; the tests check that
/// against Pillow's own output. A different bicubic would shift scores near the
/// threshold and flip tags.
public enum JoyTagInput {
    public static let size = 448
    static let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
    static let std: [Float] = [0.26862954, 0.26130258, 0.27577711]

    /// An 8-bit RGB image, rows top to bottom, three bytes a pixel.
    public struct RGB8: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var pixels: [UInt8]

        public init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }
    }

    /// The model's input for a thumbnail from the pack: 3 × 448 × 448 floats.
    public static func tensor(fromImageData data: Data) -> [Float]? {
        decode(data).map { tensor(from: $0) }
    }

    public static func tensor(from image: RGB8) -> [Float] {
        var square = padToSquare(image)
        if square.width != size { square = resize(square, to: size) }
        let n = size * size
        var out = [Float](repeating: 0, count: 3 * n)
        for i in 0..<n {
            for c in 0..<3 {
                // As numpy does it: float32 divide, then subtract and divide.
                let x = Float(square.pixels[i * 3 + c]) / 255
                out[c * n + i] = (x - mean[c]) / std[c]
            }
        }
        return out
    }

    // MARK: - Decoding

    /// The pixels as stored, with no colour management — as Pillow reads them.
    /// Grey images become RGB by repeating the grey, as Pillow's `convert("RGB")`
    /// does.
    public static func decode(_ data: Data) -> RGB8? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return pixels(of: image)
    }

    static func pixels(of image: CGImage) -> RGB8? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let space = image.colorSpace
        switch space?.model {
        case .rgb?:
            // Same colour space in and out, so vImage only rearranges bytes.
            guard let space,
                  let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32, colorSpace: space,
                                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)),
                  let buffer = try? vImage_Buffer(cgImage: image, format: format)
            else { return nil }
            defer { buffer.free() }
            var out = [UInt8](repeating: 0, count: w * h * 3)
            for y in 0..<h {
                let row = buffer.data.advanced(by: y * buffer.rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    out[(y * w + x) * 3] = row[x * 4]
                    out[(y * w + x) * 3 + 1] = row[x * 4 + 1]
                    out[(y * w + x) * 3 + 2] = row[x * 4 + 2]
                }
            }
            return RGB8(width: w, height: h, pixels: out)
        case .monochrome?:
            guard let space,
                  let format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 8, colorSpace: space,
                                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)),
                  let buffer = try? vImage_Buffer(cgImage: image, format: format)
            else { return nil }
            defer { buffer.free() }
            var out = [UInt8](repeating: 0, count: w * h * 3)
            for y in 0..<h {
                let row = buffer.data.advanced(by: y * buffer.rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w {
                    let v = row[x]
                    out[(y * w + x) * 3] = v
                    out[(y * w + x) * 3 + 1] = v
                    out[(y * w + x) * 3 + 2] = v
                }
            }
            return RGB8(width: w, height: h, pixels: out)
        default:
            // CMYK and the like: thumbnails are never stored that way, but draw
            // into sRGB rather than refuse.
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }
            let p = data.assumingMemoryBound(to: UInt8.self)
            var out = [UInt8](repeating: 0, count: w * h * 3)
            for i in 0..<(w * h) {
                out[i * 3] = p[i * 4]
                out[i * 3 + 1] = p[i * 4 + 1]
                out[i * 3 + 2] = p[i * 4 + 2]
            }
            return RGB8(width: w, height: h, pixels: out)
        }
    }

    // MARK: - Pad and resize

    /// Centred on a white square as wide as its longer side, as JoyTag's
    /// `prepare_image` does (an odd margin puts the extra pixel after).
    public static func padToSquare(_ image: RGB8) -> RGB8 {
        let side = max(image.width, image.height)
        guard side != image.width || side != image.height else { return image }
        var out = [UInt8](repeating: 255, count: side * side * 3)
        let ox = (side - image.width) / 2, oy = (side - image.height) / 2
        for y in 0..<image.height {
            let src = y * image.width * 3
            let dst = ((y + oy) * side + ox) * 3
            out.replaceSubrange(dst..<(dst + image.width * 3), with: image.pixels[src..<(src + image.width * 3)])
        }
        return RGB8(width: side, height: side, pixels: out)
    }

    /// Pillow's `Image.resize(size, Image.BICUBIC)` for an 8-bit RGB image:
    /// separable passes, horizontal first, each rounded back to 8 bits, with
    /// the filter widened when shrinking so it averages rather than skips.
    public static func resize(_ image: RGB8, to size: Int) -> RGB8 {
        resize(image, width: size, height: size)
    }

    static func resize(_ image: RGB8, width outW: Int, height outH: Int) -> RGB8 {
        let horiz = Coefficients(inSize: image.width, outSize: outW)
        let vert = Coefficients(inSize: image.height, outSize: outH)
        // Only the rows the vertical pass reads are resized horizontally.
        let firstRow = vert.start[0]
        let lastRow = vert.start[outH - 1] + vert.count[outH - 1]

        var temp = image
        if outW != image.width {
            let rows = lastRow - firstRow
            var out = [UInt8](repeating: 0, count: outW * rows * 3)
            for y in 0..<rows {
                let src = (y + firstRow) * image.width * 3
                for x in 0..<outW {
                    let k = x * horiz.ksize, start = horiz.start[x]
                    var s0 = Coefficients.half, s1 = Coefficients.half, s2 = Coefficients.half
                    for i in 0..<horiz.count[x] {
                        let p = src + (start + i) * 3
                        let w = horiz.k[k + i]
                        s0 += Int(image.pixels[p]) * w
                        s1 += Int(image.pixels[p + 1]) * w
                        s2 += Int(image.pixels[p + 2]) * w
                    }
                    let d = (y * outW + x) * 3
                    out[d] = Coefficients.clip8(s0)
                    out[d + 1] = Coefficients.clip8(s1)
                    out[d + 2] = Coefficients.clip8(s2)
                }
            }
            temp = RGB8(width: outW, height: rows, pixels: out)
        } else if firstRow != 0 || lastRow != image.height {
            temp = RGB8(width: image.width, height: lastRow - firstRow,
                        pixels: Array(image.pixels[(firstRow * image.width * 3)..<(lastRow * image.width * 3)]))
        }

        guard outH != image.height else { return temp }
        var out = [UInt8](repeating: 0, count: temp.width * outH * 3)
        for y in 0..<outH {
            let k = y * vert.ksize, start = vert.start[y] - firstRow
            for x in 0..<temp.width {
                var s0 = Coefficients.half, s1 = Coefficients.half, s2 = Coefficients.half
                for i in 0..<vert.count[y] {
                    let p = ((start + i) * temp.width + x) * 3
                    let w = vert.k[k + i]
                    s0 += Int(temp.pixels[p]) * w
                    s1 += Int(temp.pixels[p + 1]) * w
                    s2 += Int(temp.pixels[p + 2]) * w
                }
                let d = (y * temp.width + x) * 3
                out[d] = Coefficients.clip8(s0)
                out[d + 1] = Coefficients.clip8(s1)
                out[d + 2] = Coefficients.clip8(s2)
            }
        }
        return RGB8(width: temp.width, height: outH, pixels: out)
    }

    /// One pass's filter weights, as Pillow's `precompute_coeffs` and
    /// `normalize_coeffs_8bpc` compute them.
    struct Coefficients {
        static let precisionBits = 32 - 8 - 2
        static let half = 1 << (precisionBits - 1)

        let ksize: Int
        /// The first input pixel each output pixel reads, and how many.
        var start: [Int]
        var count: [Int]
        /// Fixed-point weights, `ksize` per output pixel.
        var k: [Int]

        init(inSize: Int, outSize: Int) {
            let scale = Double(inSize) / Double(outSize)
            let filterScale = max(scale, 1)
            let support = 2 * filterScale   // bicubic's support is 2
            ksize = Int(support.rounded(.up)) * 2 + 1
            start = [Int](repeating: 0, count: outSize)
            count = [Int](repeating: 0, count: outSize)
            var weights = [Double](repeating: 0, count: outSize * ksize)
            for xx in 0..<outSize {
                let center = (Double(xx) + 0.5) * scale
                let ss = 1 / filterScale
                // C's (int) cast: truncation toward zero, as Swift's Int().
                var xmin = Int(center - support + 0.5)
                if xmin < 0 { xmin = 0 }
                var xmax = Int(center + support + 0.5)
                if xmax > inSize { xmax = inSize }
                xmax -= xmin
                var total = 0.0
                for x in 0..<xmax {
                    let w = Coefficients.bicubic((Double(x + xmin) - center + 0.5) * ss)
                    weights[xx * ksize + x] = w
                    total += w
                }
                if total != 0 {
                    for x in 0..<xmax { weights[xx * ksize + x] /= total }
                }
                start[xx] = xmin
                count[xx] = xmax
            }
            let one = Double(1 << Coefficients.precisionBits)
            k = weights.map { $0 < 0 ? Int(-0.5 + $0 * one) : Int(0.5 + $0 * one) }
        }

        static func bicubic(_ x: Double) -> Double {
            let a = -0.5
            let x = abs(x)
            if x < 1 { return ((a + 2) * x - (a + 3)) * x * x + 1 }
            if x < 2 { return (((x - 5) * x + 8) * x - 4) * a }
            return 0
        }

        static func clip8(_ v: Int) -> UInt8 {
            if v <= 0 { return 0 }
            let shifted = v >> precisionBits
            return shifted >= 255 ? 255 : UInt8(shifted)
        }
    }
}

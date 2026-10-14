import Testing
import Foundation
import SQLite3
@testable import PhotoVaultCore

@Suite("JoyTag classifier")
final class JoyTagClassifierTests {
    /// This test's stand-in model folders, removed when it ends.
    let models = TestVault.sandbox.appendingPathComponent("models-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: models) }

    /// The packaged model, if this checkout has built it
    /// (`Scripts/joytag/package.sh`; the downloads are git-ignored).
    static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/joytag/package/JoyTag")
    static var havePackage: Bool {
        FileManager.default.fileExists(atPath: package.appendingPathComponent(JoyTagFiles.manifestName).path)
    }

    static func manifest(prefix: String = "jt", tool: String = "JoyTag") -> String {
        """
        {"tool": "\(tool)", "prefix": "\(prefix)", "version": "abc1234", "model": "M.mlmodelc", "tags": "tags.txt",
         "input": "image", "output": "logits", "imageSize": 448, "threshold": 0.4}
        """
    }

    func folder(manifest: String?, tags: String? = "1girl\nsolo\n", model: Bool = true) throws -> URL {
        let dir = models.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest { try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8) }
        if let tags { try tags.write(to: dir.appendingPathComponent("tags.txt"), atomically: true, encoding: .utf8) }
        if model { try FileManager.default.createDirectory(at: dir.appendingPathComponent("M.mlmodelc"), withIntermediateDirectories: true) }
        return dir
    }

    @Test func findsAnInstalledModel() throws {
        let files = try JoyTagFiles.load(from: try folder(manifest: Self.manifest()))
        #expect(files.tags == ["1girl", "solo"])
        #expect(files.manifest.version == "abc1234")
    }

    @Test func saysWhyThereIsNoModel() throws {
        func reason(_ dir: URL) -> String? {
            do { _ = try JoyTagFiles.load(from: dir); return nil } catch { return error.localizedDescription }
        }
        #expect(reason(try folder(manifest: nil)) == "JoyTag isn't installed in this vault.")
        #expect(reason(try folder(manifest: "{")) == "JoyTag's manifest in this vault can't be read.")
        #expect(reason(try folder(manifest: Self.manifest(), tags: nil)) == "JoyTag's tag list is missing from this vault.")
        #expect(reason(try folder(manifest: Self.manifest(), model: false)) == "JoyTag's model is missing from this vault.")
    }

    /// A model claiming another prefix could rewrite another tool's tags.
    @Test func refusesAModelWithAnotherPrefix() throws {
        #expect(throws: VaultError.self) { try JoyTagFiles.load(from: try folder(manifest: Self.manifest(prefix: "ext"))) }
        #expect(throws: VaultError.self) { try JoyTagFiles.load(from: try folder(manifest: Self.manifest(tool: "OtherTagger"))) }
    }

    /// The same input the Core ML probe used on 14 October: Core ML's top
    /// logit was tag 51 at 0.65382797, on the CPU in 32-bit.
    @Test(.enabled(if: havePackage))
    func matchesCoreML() throws {
        guard #available(macOS 15.0, *) else { return }
        let classifier = try JoyTagClassifier(files: try JoyTagFiles.load(from: Self.package))
        let n = 448 * 448
        var input = [Float](repeating: 0, count: 3 * n)
        for c in 0..<3 {
            for i in 0..<n { input[c * n + i] = (Float(i % 448) / 447 - JoyTagInput.mean[c]) / JoyTagInput.std[c] }
        }
        let scores = try classifier.scores(input)
        let best = scores.indices.max { scores[$0] < scores[$1] }!
        #expect(best == 51)
        #expect(abs(scores[51] - 1 / (1 + exp(-0.65382797))) < 1e-6)
    }

    /// Two photos at once, as Tag faster runs them, give exactly the scores
    /// one at a time does.
    @Test(.enabled(if: havePackage))
    func twoAtOnceGiveTheSameScores() async throws {
        guard #available(macOS 15.0, *) else { return }
        let classifier = try JoyTagClassifier(files: try JoyTagFiles.load(from: Self.package))
        let pictures = [0.2, 0.7].map { seed -> Data in (try? TestVault.jpegData(size: 300, seed: seed)) ?? Data() }
        let alone = try pictures.map { try classifier.tags(thumbnail: $0) }
        async let a = classifier.classify(thumbnail: pictures[0], fast: true)
        async let b = classifier.classify(thumbnail: pictures[1], fast: true)
        let together = try await [a, b]
        #expect(together == alone)
    }

    /// The evaluation's photos, against the evaluation's own results (Python, onnxruntime,
    /// Pillow decoding the same thumbnails). Only when asked:
    /// `PHOTOVAULT_JOYTAG_CHECK=<vault> swift test --filter matchesTheEvaluation`.
    /// Opens the catalog read-only; prints tag names and scores only.
    @Test(.enabled(if: havePackage && ProcessInfo.processInfo.environment["PHOTOVAULT_JOYTAG_CHECK"] != nil))
    func matchesTheEvaluation() throws {
        guard #available(macOS 15.0, *) else { return }
        let vault = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PHOTOVAULT_JOYTAG_CHECK"]!)
        let results = Self.package.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("report/results.json")
        let json = try JSONSerialization.jsonObject(with: try Data(contentsOf: results)) as! [String: Any]
        let photos = json["results"] as! [[String: Any]]
        let classifier = try JoyTagClassifier(files: try JoyTagFiles.load(from: Self.package))

        var db: OpaquePointer?
        let catalog = VolumeLocator.catalogDir(vault).appendingPathComponent("catalog.sqlite").path
        try #require(sqlite3_open_v2(catalog, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let pack = try FileHandle(forReadingFrom: VolumeLocator.catalogDir(vault).appendingPathComponent("thumbs.pack"))
        defer { try? pack.close() }

        var maxDiff = 0.0, sumDiff = 0.0, compared = 0, identical = 0, flips: [String] = []
        var decoded = 0, pixelMax = 0, pixelSum = 0, pixelCount = 0, farFlips = 0
        let start = Date()
        for photo in photos {
            let rel = photo["file"] as! String
            let python = photo["thumbnail"] as! [String: Double]
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT thumb_off, thumb_len FROM photo WHERE rel_path = ?;", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, rel, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            try #require(sqlite3_step(stmt) == SQLITE_ROW)
            let off = UInt64(sqlite3_column_int64(stmt, 0)), len = Int(sqlite3_column_int64(stmt, 1))
            sqlite3_finalize(stmt)
            try pack.seek(toOffset: off)
            let data = try #require(try pack.read(upToCount: len))
            // With PHOTOVAULT_JOYTAG_PIL, the pixels Pillow decoded (saved as
            // lossless PNGs) instead of ImageIO's: everything but the decoder.
            var input = data
            if let pil = ProcessInfo.processInfo.environment["PHOTOVAULT_JOYTAG_PIL"] {
                input = try Data(contentsOf: URL(fileURLWithPath: pil).appendingPathComponent(String(format: "%02d.png", decoded)))
                let a = try #require(JoyTagInput.decode(data)), b = try #require(JoyTagInput.decode(input))
                if a.width == b.width, a.height == b.height {
                    for (x, y) in zip(a.pixels, b.pixels) { let d = abs(Int(x) - Int(y)); pixelMax = max(pixelMax, d); pixelSum += d }
                    pixelCount += a.pixels.count
                }
            }
            decoded += 1
            let scores = try classifier.scores(try #require(JoyTagInput.tensor(fromImageData: input)))
            var swift: [String: Double] = [:]
            for (i, s) in scores.enumerated() where s > 0.1 { swift[classifier.files.tags[i]] = s }
            for (tag, p) in python {
                let s = scores[classifier.files.tags.firstIndex(of: tag)!]
                maxDiff = max(maxDiff, abs(s - p)); sumDiff += abs(s - p); compared += 1
            }
            let a = Set(python.filter { $0.value > 0.4 }.keys), b = Set(swift.filter { $0.value > 0.4 }.keys)
            if a == b { identical += 1 }
            for tag in a.symmetricDifference(b) {
                let s = scores[classifier.files.tags.firstIndex(of: tag)!], p = python[tag] ?? 0
                flips.append("\(tag) python \(String(format: "%.4f", p)) swift \(String(format: "%.4f", s))")
                if abs(s - 0.4) >= 0.05 || abs(p - 0.4) >= 0.05 { farFlips += 1 }
            }
        }
        let seconds = Date().timeIntervalSince(start) / Double(photos.count)
        print("evaluation check: \(photos.count) photos, \(identical) with identical tags at 0.4; "
              + "largest score difference \(String(format: "%.4f", maxDiff)), mean \(String(format: "%.5f", sumDiff / Double(max(compared, 1)))); "
              + "\(String(format: "%.3f", seconds)) s a photo")
        if pixelCount > 0 {
            print("decoders: ImageIO against Pillow, largest pixel difference \(pixelMax), mean \(String(format: "%.3f", Double(pixelSum) / Double(pixelCount)))")
        }
        for f in flips { print("  flipped: \(f)") }
        if pixelCount > 0 {
            // Everything but the decoder: JoyTag exactly, as Core ML matched PyTorch.
            #expect(identical == photos.count)
            #expect(maxDiff < 0.001)
        } else {
            // ImageIO decodes JPEG a little differently from Pillow (0.33 of a
            // level per pixel on average, measured 14 October). That moves
            // scores by thousandths, so only tags right at the threshold change.
            #expect(maxDiff < 0.1)
            #expect(sumDiff / Double(max(compared, 1)) < 0.01)
            #expect(farFlips == 0, "every tag that differs from Python's is within 0.05 of the threshold")
        }
    }
}

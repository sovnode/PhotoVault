import Testing
import Foundation
@testable import PhotoVaultCore

@Suite("SigLIP 2")
final class SigLIPTests {
    let models = TestVault.sandbox.appendingPathComponent("siglip-\(UUID().uuidString)")
    deinit { try? FileManager.default.removeItem(at: models) }

    static let tools = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tools/siglip")
    /// The packaged model, if this checkout has built it (`Scripts/siglip/package.sh`).
    static let package = tools.appendingPathComponent("package/SigLIP2")
    static var havePackage: Bool {
        FileManager.default.fileExists(atPath: package.appendingPathComponent(SigLIPFiles.manifestName).path)
    }
    static var haveReference: Bool {
        havePackage && FileManager.default.fileExists(atPath: tools.appendingPathComponent("reference/pattern-embedding.f32").path)
    }

    // MARK: Input

    /// From Pillow 11.3 and numpy 2.0: `JoyTagInputTests.pattern` squashed to
    /// 256 × 256 with Pillow's bilinear filter, and the finished tensor.
    /// Shrinking landscape and portrait, enlarging, a square, and one already
    /// 256 (not resized).
    static let pillow: [(Int, Int, String, String)] = [
        (512, 369, "df275d3e5b3d40a0c900b4470cdf4b383a44c243dc728e3031222703fd4a7dbb", "4e23f160eb7231a4c2cd3fe7692c72331030c9daaa696ee30310493e99d08124"),
        (300, 512, "202e4a2342e3209a14c2142d3555a59bcd53289ce7d97abe6573aa2e03fdcd7a", "33d996b0cc9a1c38bcbb37417757cef0e6505eaad67542a13bca1be5481aa944"),
        (200, 150, "6bf45778eed72fb09c81b26b039369ce09d27b916ea6c3e3028dd5ce977285ac", "5e27b899e481fe5860e020270a2a0b733f24e8696d7ff00e4580fb3a4e302e29"),
        (512, 512, "c4b4d6d6843275f9602f1ff736cf43615b9eb8a705d4e50a85b5370805ec98dc", "571aa76fd05068b69082745efbd2ac23479b6f1f062b7baa56ab66eeb20aafed"),
        (256, 256, "dba79df679a9f6c592bc7460a9d3c83c27b65f2163d92c72ce8d033bed12d251", "4e8464e18ca6ce298ac79cc125f9baf5677cb23dabe46ba2de5594c19c853df9"),
        (37, 91, "433697bcab839e96301c845b311b9f8d1c5820074f2ecc880111d956cd371526", "e047d39154930b9c4cd6a32d6a252f7e3222210b27f5f533954ed58b36445314"),
    ]

    @Test(arguments: pillow.indices)
    func matchesPillowExactly(_ i: Int) {
        let (w, h, pixels, tensor) = Self.pillow[i]
        let image = JoyTagInputTests.pattern(w, h)
        let resized = w == 256 && h == 256 ? image : JoyTagInput.resize(image, width: 256, height: 256, filter: .bilinear)
        #expect(JoyTagInputTests.sha256(resized.pixels) == pixels, "pixels for \(w)×\(h)")
        #expect(JoyTagInputTests.sha256(SigLIPInput.tensor(from: image)) == tensor, "tensor for \(w)×\(h)")
    }

    // MARK: Files

    static func manifest(prefix: String = "sg", tool: String = "SigLIP 2", dim: Int = 4) -> String {
        """
        {"tool": "\(tool)", "prefix": "\(prefix)", "version": "abc1234-t1", "model": "M.mlmodelc", "tags": "tags.txt",
         "textEmbeddings": "text.f32", "input": "image", "output": "embedding", "imageSize": 256, "dim": \(dim),
         "logitScale": 100, "logitBias": -10, "scoreThreshold": 0.05, "relativeThreshold": 4, "relativeFloor": 0.002}
        """
    }

    func folder(manifest: String?, tags: String = "beach\nman\n", floats: Int = 8) throws -> URL {
        let dir = models.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("M.mlmodelc"), withIntermediateDirectories: true)
        if let manifest { try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8) }
        try tags.write(to: dir.appendingPathComponent("tags.txt"), atomically: true, encoding: .utf8)
        let values = (0..<floats).map(Float.init)
        try values.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dir.appendingPathComponent("text.f32"))
        return dir
    }

    @Test func findsAnInstalledModel() throws {
        let files = try SigLIPFiles.load(from: try folder(manifest: Self.manifest()))
        #expect(files.tags == ["beach", "man"])
        #expect(files.text == [0, 1, 2, 3, 4, 5, 6, 7])
    }

    @Test func refusesAnotherToolsPrefix() throws {
        #expect(throws: VaultError.self) { try SigLIPFiles.load(from: try self.folder(manifest: Self.manifest(prefix: "jt"))) }
    }

    @Test func refusesEmbeddingsThatDontMatchTheTags() throws {
        #expect(throws: VaultError.self) { try SigLIPFiles.load(from: try self.folder(manifest: Self.manifest(), floats: 6)) }
    }

    @Test func saysWhenItIsntInstalled() throws {
        #expect(throws: VaultError.self) { try SigLIPFiles.load(from: try self.folder(manifest: nil)) }
    }

    // MARK: Choosing tags

    static func decodedManifest() throws -> SigLIPFiles.Manifest {
        try JSONDecoder().decode(SigLIPFiles.Manifest.self, from: Data(manifest().utf8))
    }

    static func logit(_ p: Double) -> Float { Float(log(p / (1 - p))) }

    @Test func aHighScoreIsATag() throws {
        let tags = try SigLIPTagRule.select([Self.logit(0.6), Self.logit(0.04)], tags: ["beach", "man"],
                                               manifest: Self.decodedManifest(), calibration: nil)
        #expect(tags.map(\.name) == ["beach"])
    }

    @Test func aScoreUnusualForTheTagIsATagOnceCalibrated() throws {
        // "man" usually scores far lower in this vault: 0.01 is 5 spreads above.
        let median = Self.logit(0.01) - 5
        let cal = SigLIPCalibration(version: "abc1234-t1", photos: 100, median: [0, median], spread: [1, 1])
        let m = try Self.decodedManifest()
        let tags = SigLIPTagRule.select([Self.logit(0.04), Self.logit(0.01)], tags: ["beach", "man"], manifest: m, calibration: cal)
        #expect(tags.map(\.name) == ["man"])
        // …but not below the floor, however unusual.
        let faint = SigLIPTagRule.select([Self.logit(0.04), Self.logit(0.001)], tags: ["beach", "man"], manifest: m,
                                            calibration: SigLIPCalibration(version: "abc1234-t1", photos: 100,
                                                                           median: [0, Self.logit(0.001) - 9], spread: [1, 1]))
        #expect(faint.isEmpty)
    }

    @Test func calibrationIsMedianAndLowSpread() {
        let rows: [[Float]] = (0..<101).map { [Float($0), 7] }
        let cal = SigLIPCalibration(version: "v", logits: rows)
        #expect(cal.photos == 101)
        #expect(cal.median == [50, 7])
        #expect(cal.spread[0] == 34)                       // median − 16th percentile
        #expect(cal.spread[1] == SigLIPCalibration.minimumSpread)
    }

    // MARK: The real model

    @Test(.enabled(if: haveReference))
    func matchesPyTorchOnTheTestPattern() throws {
        guard #available(macOS 15.0, *) else { return }
        let classifier = try SigLIPClassifier(files: try SigLIPFiles.load(from: Self.package))
        let expected = try Data(contentsOf: Self.tools.appendingPathComponent("reference/pattern-embedding.f32"))
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let got = try classifier.embedding(SigLIPInput.tensor(from: JoyTagInputTests.pattern(512, 369)))
        let cosine = zip(got, expected).map(*).reduce(0, +)
        let worst = zip(got, expected).map { abs($0 - $1) }.max() ?? 1
        #expect(cosine > 0.99999, "cosine \(cosine)")
        #expect(worst < 1e-4, "largest difference \(worst)")
        #expect(classifier.logits(got).count == classifier.files.tags.count)
    }
}

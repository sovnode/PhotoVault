import Foundation
import Accelerate

/// SigLIP 2's identity in PhotoVault.
public enum SigLIP {
    public static let prefix = "sg"
    public static let tool = "SigLIP 2"
}

/// PhotoVault's own taggers. Their tags are kept in the catalog and are
/// theirs alone: no other tool may claim their prefixes, and a file re-read
/// never takes their tags away.
public enum OwnTaggers {
    public static let prefixes: Set<String> = [JoyTag.prefix, SigLIP.prefix]

    public static func tool(_ prefix: String) -> String {
        prefix == SigLIP.prefix ? SigLIP.tool : JoyTag.tool
    }
}

/// SigLIP 2's input, prepared as its own image processor prepares it: the
/// image squashed to 256 × 256 with Pillow's bilinear filter (the same port
/// of Pillow's resampling JoyTag's input uses), scaled to −1…1, channels
/// first. Not padded: SigLIP 2 was trained on squashed images.
public enum SigLIPInput {
    public static let size = 256

    public static func tensor(fromImageData data: Data) -> [Float]? {
        JoyTagInput.decode(data).map { tensor(from: $0) }
    }

    public static func tensor(from image: JoyTagInput.RGB8) -> [Float] {
        var image = image
        if image.width != size || image.height != size {
            image = JoyTagInput.resize(image, width: size, height: size, filter: .bilinear)
        }
        let n = size * size
        var out = [Float](repeating: 0, count: 3 * n)
        for i in 0..<n {
            for c in 0..<3 {
                // The processor's own arithmetic, step for step: x / 255, then (x − 0.5) / 0.5.
                out[c * n + i] = (Float(image.pixels[i * 3 + c]) / 255 - 0.5) / 0.5
            }
        }
        return out
    }
}

/// SigLIP 2 as installed in a vault, in `.catalog/models/SigLIP2/`: the
/// compiled image tower, the tag list, each tag's text embedding (computed
/// once when the package is made, so PhotoVault needs no text model), and a
/// manifest naming them with the model's scoring constants and thresholds.
public struct SigLIPFiles: Sendable {
    public struct Manifest: Codable, Sendable, Equatable {
        public var tool: String
        public var prefix: String
        /// The model revision and tag list revision, written into each
        /// photo's record.
        public var version: String
        public var model: String
        public var tags: String
        /// `tagCount × dim` 32-bit floats, little-endian, one row per tag.
        public var textEmbeddings: String
        public var input: String
        public var output: String
        public var imageSize: Int
        public var dim: Int
        /// SigLIP's own scoring: sigmoid(logitScale × cosine + logitBias).
        public var logitScale: Double
        public var logitBias: Double
        /// A tag whose score is above this is the photo's.
        public var scoreThreshold: Double
        /// Or, once the vault is calibrated: a tag whose logit is this many
        /// spreads above its median in the vault, with a score above
        /// `relativeFloor`.
        public var relativeThreshold: Double
        public var relativeFloor: Double
    }

    public let folder: URL
    public let manifest: Manifest
    public let tags: [String]
    /// Row-major, `tags.count × manifest.dim`.
    public let text: [Float]
    public var modelURL: URL { folder.appendingPathComponent(manifest.model) }

    public static let manifestName = "manifest.json"

    public static func folder(in root: URL) -> URL {
        VolumeLocator.catalogDir(root).appendingPathComponent("models/SigLIP2")
    }

    public static func load(from folder: URL) throws -> SigLIPFiles {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: folder.appendingPathComponent(manifestName).path) else {
            throw VaultError.classifierUnavailable("SigLIP 2 isn't installed in this vault.")
        }
        guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw VaultError.classifierUnavailable("SigLIP 2's manifest in this vault can't be read.")
        }
        guard m.tool == SigLIP.tool, m.prefix == SigLIP.prefix, m.imageSize == SigLIPInput.size, m.dim > 0,
              m.scoreThreshold > 0, m.scoreThreshold < 1, m.relativeFloor >= 0, m.relativeFloor < 1, m.relativeThreshold > 0 else {
            throw VaultError.classifierUnavailable("The model in this vault isn't SigLIP 2 as PhotoVault knows it.")
        }
        guard let text = try? String(contentsOf: folder.appendingPathComponent(m.tags), encoding: .utf8) else {
            throw VaultError.classifierUnavailable("SigLIP 2's tag list is missing from this vault.")
        }
        let tags = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let blob = fm.contents(atPath: folder.appendingPathComponent(m.textEmbeddings).path),
              !tags.isEmpty, blob.count == tags.count * m.dim * 4 else {
            throw VaultError.classifierUnavailable("SigLIP 2's tag list and its embeddings in this vault don't match.")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.appendingPathComponent(m.model).path, isDirectory: &isDir), isDir.boolValue else {
            throw VaultError.classifierUnavailable("SigLIP 2's model is missing from this vault.")
        }
        let floats = blob.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return SigLIPFiles(folder: folder, manifest: m, tags: tags, text: floats)
    }
}

/// How unusual a score is for each tag in this vault: each tag's median logit
/// over a sample of the vault's photos, and its spread (median minus the 16th
/// percentile — the low side, which the tag's own photos don't inflate).
///
/// SigLIP's scores aren't comparable across tags: "hiking trail" scores 0.5 on
/// a trail, "man" 0.01 on a photo with a man in it. A score far above what the
/// tag usually gets in this vault catches tags like these that no single
/// threshold would. Made once per vault and model version, from up to
/// `sampleSize` photos, and kept in the catalog: it describes the vault, so it
/// stays in it.
public struct SigLIPCalibration: Codable, Sendable, Equatable {
    public var version: String
    public var photos: Int
    public var median: [Float]
    public var spread: [Float]

    public static let settingKey = "siglip.calibration"
    public static let sampleSize = 400
    /// Fewer photos than this and the vault isn't calibrated: tags come from
    /// the score threshold alone until it has more.
    public static let minimumPhotos = 60
    static let minimumSpread: Float = 0.25

    public init(version: String, photos: Int, median: [Float], spread: [Float]) {
        self.version = version
        self.photos = photos
        self.median = median
        self.spread = spread
    }

    /// From each sampled photo's logits, one row per photo.
    public init(version: String, logits rows: [[Float]]) {
        self.version = version
        photos = rows.count
        let tags = rows.first?.count ?? 0
        median = []
        spread = []
        for t in 0..<tags {
            let column = rows.map { $0[t] }.sorted()
            let m = Self.percentile(column, 50)
            median.append(m)
            spread.append(max(m - Self.percentile(column, 16), Self.minimumSpread))
        }
    }

    /// numpy's default (linear) percentile of sorted values.
    static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let rank = p / 100 * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        let f = Float(rank - Double(lo))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * f
    }
}

/// How SigLIP 2's tags are chosen from a photo's logits (see `SigLIPClassifier.select`).
enum SigLIPTagRule {
    static func select(_ logits: [Float], tags: [String], manifest m: SigLIPFiles.Manifest,
                       calibration cal: SigLIPCalibration?) -> [ScoredTag] {
        var out: [ScoredTag] = []
        for (i, l) in logits.enumerated() {
            let score = 1 / (1 + exp(-Double(l)))
            var keep = score > m.scoreThreshold
            if !keep, let cal, score > m.relativeFloor {
                keep = Double((l - cal.median[i]) / cal.spread[i]) > m.relativeThreshold
            }
            if keep { out.append(ScoredTag(name: tags[i], score: score)) }
        }
        return out.sorted { $0.score > $1.score }
    }
}

/// A compiled model run by Accelerate's BNNS graph on the CPU, as JoyTag is
/// (see `JoyTagClassifier` for why not Core ML): one input tensor, one output.
@available(macOS 15.0, *)
final class BNNSModel: @unchecked Sendable {
    private struct Context {
        let context: bnns_graph_context_t
        let workspace: UnsafeMutableRawPointer
        let size: Int
    }
    private let graph: bnns_graph_t
    private let argumentCount: Int
    private let inputIndex: Int
    private let outputIndex: Int
    let inputCount: Int
    let outputCount: Int
    private let maxContexts: Int
    private let lock = NSLock()
    private var idle: [Context] = []
    private var all: [Context] = []

    /// Nil when the model can't be compiled or doesn't take `inputShape` and
    /// give `outputCount` floats.
    init?(url: URL, input: String, output: String, inputShape: [Int], outputCount: Int, maxContexts: Int) {
        let options = BNNSGraphCompileOptionsMakeDefault()
        defer { BNNSGraphCompileOptionsDestroy(options) }
        let graph = BNNSGraphCompileFromFile(url.path, nil, options)
        guard graph.data != nil else { return nil }
        guard let first = Self.makeContext(graph) else { free(graph.data); return nil }
        let count = BNNSGraphGetArgumentCount(graph, nil)
        let i = BNNSGraphGetArgumentPosition(graph, nil, input)
        let o = BNNSGraphGetArgumentPosition(graph, nil, output)
        guard count == 2, i < 2, o < 2, i != o,
              Self.shape(first.context, input) == inputShape,
              Self.shape(first.context, output)?.reduce(1, *) == outputCount else {
            BNNSGraphContextDestroy(first.context)
            first.workspace.deallocate()
            free(graph.data)
            return nil
        }
        self.graph = graph
        argumentCount = count
        inputIndex = i
        outputIndex = o
        inputCount = inputShape.reduce(1, *)
        self.outputCount = outputCount
        self.maxContexts = maxContexts
        idle = [first]
        all = [first]
    }

    private static func makeContext(_ graph: bnns_graph_t) -> Context? {
        let context = BNNSGraphContextMake(graph)
        guard context.data != nil else { return nil }
        _ = BNNSGraphContextSetArgumentType(context, BNNSGraphArgumentTypePointer)
        let size = BNNSGraphContextGetWorkspaceSize(context, nil)
        guard size != Int.max else { BNNSGraphContextDestroy(context); return nil }
        return Context(context: context, workspace: .allocate(byteCount: max(size, 1), alignment: Int(getpagesize())), size: size)
    }

    private static func shape(_ context: bnns_graph_context_t, _ name: String) -> [Int]? {
        var tensor = BNNSTensor()
        guard BNNSGraphContextGetTensor(context, nil, name, true, &tensor) == 0,
              tensor.data_type == .float else { return nil }
        return withUnsafeBytes(of: tensor.shape) { Array($0.bindMemory(to: Int.self).prefix(Int(tensor.rank))) }
    }

    private func take() -> Context? {
        lock.withLock {
            if let c = idle.popLast() { return c }
            guard all.count < maxContexts, let c = Self.makeContext(graph) else { return nil }
            all.append(c)
            return c
        }
    }

    deinit {
        for c in all {
            BNNSGraphContextDestroy(c.context)
            c.workspace.deallocate()
        }
        free(graph.data)
    }

    /// Runs the model once; nil if BNNS reports an error.
    func run(_ input: [Float]) -> [Float]? {
        precondition(input.count == inputCount)
        var context = take()
        while context == nil { usleep(2_000); context = take() }
        let c = context!
        defer { lock.withLock { idle.append(c) } }
        var input = input
        var out = [Float](repeating: 0, count: outputCount)
        let status = input.withUnsafeMutableBytes { inBytes in
            out.withUnsafeMutableBytes { outBytes -> Int32 in
                var args = [bnns_graph_argument_t](repeating: bnns_graph_argument_t(), count: argumentCount)
                args[inputIndex].data_ptr = inBytes.baseAddress
                args[inputIndex].data_ptr_size = inBytes.count
                args[outputIndex].data_ptr = outBytes.baseAddress
                args[outputIndex].data_ptr_size = outBytes.count
                return BNNSGraphContextExecute(c.context, nil, argumentCount, &args, c.size,
                                               c.workspace.assumingMemoryBound(to: CChar.self))
            }
        }
        return status == 0 ? out : nil
    }
}

/// SigLIP 2, run by Accelerate's BNNS graph on the CPU. The image tower gives
/// each photo an embedding; each tag's score is SigLIP's own,
/// sigmoid(scale × cosine + bias), against the tag's text embedding.
@available(macOS 15.0, *)
public final class SigLIPClassifier: TagClassifier, @unchecked Sendable {
    public let files: SigLIPFiles
    public var record: ToolRecord { ToolRecord(prefix: SigLIP.prefix, tool: SigLIP.tool, version: files.manifest.version) }
    public let parallelism = 2
    private let model: BNNSModel
    private let lock = NSLock()
    private var _calibration: SigLIPCalibration?

    /// The vault's calibration, if it has one for this version (see
    /// `SigLIPCalibration`). Without one, only the score threshold applies.
    public var calibration: SigLIPCalibration? {
        get { lock.withLock { _calibration } }
        set {
            let usable = newValue.flatMap {
                $0.version == files.manifest.version && $0.median.count == files.tags.count && $0.spread.count == files.tags.count ? $0 : nil
            }
            lock.withLock { _calibration = usable }
        }
    }

    public init(files: SigLIPFiles) throws {
        self.files = files
        let size = SigLIPInput.size
        guard let model = BNNSModel(url: files.modelURL, input: files.manifest.input, output: files.manifest.output,
                                    inputShape: [1, 3, size, size], outputCount: files.manifest.dim, maxContexts: 2) else {
            throw VaultError.classifierUnavailable("SigLIP 2's model in this vault couldn't be loaded, or doesn't match its tag list.")
        }
        self.model = model
    }

    public func classify(thumbnail: Data, fast: Bool) async throws -> [ScoredTag] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: fast ? .userInitiated : .utility).async {
                continuation.resume(with: Result { try self.tags(thumbnail: thumbnail) })
            }
        }
    }

    /// Each tag's logit for a thumbnail, in tag-list order (for calibration).
    public func logits(thumbnail: Data) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result { try self.logits(self.embedding(thumbnail: thumbnail)) })
            }
        }
    }

    func embedding(thumbnail: Data) throws -> [Float] {
        guard let input = SigLIPInput.tensor(fromImageData: thumbnail) else {
            throw VaultError.classifierUnavailable("The photo's thumbnail couldn't be read.")
        }
        return try embedding(input)
    }

    /// The image tower's output: the photo's embedding, length 1.
    public func embedding(_ input: [Float]) throws -> [Float] {
        guard let out = model.run(input) else {
            throw VaultError.classifierUnavailable("SigLIP 2 failed on a photo.")
        }
        return out
    }

    /// scale × (text · embedding) + bias, one per tag.
    public func logits(_ embedding: [Float]) -> [Float] {
        let n = files.tags.count, dim = files.manifest.dim
        var out = [Float](repeating: Float(files.manifest.logitBias), count: n)
        files.text.withUnsafeBufferPointer { text in
            embedding.withUnsafeBufferPointer { e in
                cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(dim), Float(files.manifest.logitScale),
                            text.baseAddress, Int32(dim), e.baseAddress, 1, 1, &out, 1)
            }
        }
        return out
    }

    func tags(thumbnail: Data) throws -> [ScoredTag] {
        select(logits(try embedding(thumbnail: thumbnail)))
    }

    /// The tags a photo gets from its logits: a score above the threshold, or
    /// — calibrated — a logit unusually high for that tag in this vault.
    /// Most confident first.
    public func select(_ logits: [Float]) -> [ScoredTag] {
        SigLIPTagRule.select(logits, tags: files.tags, manifest: files.manifest, calibration: calibration)
    }

}

@available(macOS 15.0, *)
extension Store {
    /// Gives `classifier` this vault's calibration: the one kept in the
    /// catalog, or a new one made from a sample of the vault's photos (and
    /// kept). Stoppable between photos. Without enough photos the vault stays
    /// uncalibrated, and is tried again next time.
    public func calibrate(_ classifier: SigLIPClassifier,
                          progress: (@Sendable (ScanProgress) -> Void)? = nil) async throws {
        let version = classifier.files.manifest.version
        if let json = setting(SigLIPCalibration.settingKey)?.data(using: .utf8),
           let saved = try? JSONDecoder().decode(SigLIPCalibration.self, from: json), saved.version == version {
            classifier.calibration = saved
            if classifier.calibration != nil { return }
        }
        var photos = try items(scope: .all, filter: .all).filter { !$0.missing && !$0.trashed && $0.hasThumb }
        guard photos.count >= SigLIPCalibration.minimumPhotos else { return }
        // The same photos each time for the same vault: no randomness needed
        // beyond spreading the sample across the library.
        if photos.count > SigLIPCalibration.sampleSize {
            let step = Double(photos.count) / Double(SigLIPCalibration.sampleSize)
            photos = (0..<SigLIPCalibration.sampleSize).map { photos[Int(Double($0) * step)] }
        }
        let phase = "Getting \(SigLIP.tool) ready for this vault…"
        var rows: [[Float]] = []
        for (n, item) in photos.enumerated() {
            try Task.checkCancellation()
            progress?(ScanProgress(phase: phase, done: n, total: photos.count))
            guard let thumb = try thumbnailData(for: item), let row = try? await classifier.logits(thumbnail: thumb) else { continue }
            rows.append(row)
        }
        guard rows.count >= SigLIPCalibration.minimumPhotos else { return }
        let made = SigLIPCalibration(version: version, logits: rows)
        if let data = try? JSONEncoder().encode(made), let json = String(data: data, encoding: .utf8) {
            setSetting(SigLIPCalibration.settingKey, json)
        }
        classifier.calibration = made
    }
}

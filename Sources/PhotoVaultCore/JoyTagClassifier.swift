import Foundation
import Accelerate

/// A tag a classifier found, with its score (0–1).
public struct ScoredTag: Sendable, Equatable {
    public var name: String
    public var score: Double

    public init(name: String, score: Double) {
        self.name = name
        self.score = score
    }
}

/// Something that tags photos from their thumbnails. JoyTag is the only one;
/// the tests use a stand-in.
public protocol TagClassifier: Sendable {
    /// Its record for each photo, without the date: each photo's record
    /// carries the time that photo was tagged.
    var record: ToolRecord { get }
    /// How many photos it can usefully work on at once when told to hurry.
    var parallelism: Int { get }
    /// The tags above its threshold, most confident first, in display form.
    /// `fast` runs it at a higher priority.
    func classify(thumbnail: Data, fast: Bool) async throws -> [ScoredTag]
}

/// How hard a tagging run works, changeable while it runs (Tag faster).
public final class TaggingPace: @unchecked Sendable {
    private let lock = NSLock()
    private var _fast = false
    public init() {}
    public var isFast: Bool {
        get { lock.withLock { _fast } }
        set { lock.withLock { _fast = newValue } }
    }
}

/// JoyTag as installed in a vault, in `.catalog/models/JoyTag/`: the compiled
/// model, its list of tags, and a manifest naming both. The vault scripts put
/// it there; it isn't part of the app, which keeps the app, its releases and
/// the git history small.
public struct JoyTagFiles: Sendable {
    public struct Manifest: Codable, Sendable, Equatable {
        public var tool: String
        public var prefix: String
        /// The model revision, written into each photo's record.
        public var version: String
        /// The compiled model and the tag list, relative to the folder.
        public var model: String
        public var tags: String
        /// The model's input and output names.
        public var input: String
        public var output: String
        public var imageSize: Int
        public var threshold: Double
    }

    public let folder: URL
    public let manifest: Manifest
    public let tags: [String]
    public var modelURL: URL { folder.appendingPathComponent(manifest.model) }

    public static let manifestName = "manifest.json"

    public static func folder(in root: URL) -> URL {
        VolumeLocator.catalogDir(root).appendingPathComponent("models/JoyTag")
    }

    /// The installed model, or an error saying why there isn't a usable one.
    public static func load(from folder: URL) throws -> JoyTagFiles {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: folder.appendingPathComponent(manifestName).path) else {
            throw VaultError.classifierUnavailable("JoyTag isn't installed in this vault.")
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            throw VaultError.classifierUnavailable("JoyTag's manifest in this vault can't be read.")
        }
        // PhotoVault writes only its own prefix. A model claiming any other
        // would rewrite another tool's tags, so it isn't used.
        guard manifest.tool == JoyTag.tool, manifest.prefix == JoyTag.prefix,
              manifest.imageSize == JoyTagInput.size, manifest.threshold > 0, manifest.threshold < 1 else {
            throw VaultError.classifierUnavailable("The model in this vault isn't JoyTag as PhotoVault knows it.")
        }
        guard let text = try? String(contentsOf: folder.appendingPathComponent(manifest.tags), encoding: .utf8) else {
            throw VaultError.classifierUnavailable("JoyTag's tag list is missing from this vault.")
        }
        let tags = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var isDir: ObjCBool = false
        guard !tags.isEmpty,
              fm.fileExists(atPath: folder.appendingPathComponent(manifest.model).path, isDirectory: &isDir), isDir.boolValue else {
            throw VaultError.classifierUnavailable("JoyTag's model is missing from this vault.")
        }
        return JoyTagFiles(folder: folder, manifest: manifest, tags: tags)
    }
}

/// JoyTag, run by Accelerate's BNNS graph on the CPU.
///
/// Core ML would run it on the same CPU code, but compiles the model into a
/// 351 MB cache in `~/Library/Caches` first — outside the vault. BNNS compiles
/// the same compiled model in memory, in under a second, and leaves nothing
/// behind. Only 32-bit maths keeps JoyTag's tags, so the Neural Engine
/// (16-bit) isn't an option anyway. BNNS graphs need macOS 15.
@available(macOS 15.0, *)
public final class JoyTagClassifier: TagClassifier, @unchecked Sendable {
    public let files: JoyTagFiles
    public var record: ToolRecord { ToolRecord(prefix: JoyTag.prefix, tool: JoyTag.tool, version: files.manifest.version) }

    /// Two at once measured about a quarter faster than one
    /// (14 October); more gained nothing, as BNNS already spreads each photo
    /// across most of the cores.
    public let parallelism = 2

    private let graph: bnns_graph_t
    private let argumentCount: Int
    private let inputIndex: Int
    private let outputIndex: Int
    /// One execution at a time per context. The first context is made with
    /// the classifier; a second, sharing the compiled graph, when a fast run
    /// first needs it (about 50 MB of workspace each).
    private struct Context {
        let context: bnns_graph_context_t
        let workspace: UnsafeMutableRawPointer
        let size: Int
    }
    private let lock = NSLock()
    private var idle: [Context] = []
    private var made = 0
    private var all: [Context] = []

    public init(files: JoyTagFiles) throws {
        self.files = files
        let options = BNNSGraphCompileOptionsMakeDefault()
        defer { BNNSGraphCompileOptionsDestroy(options) }
        let graph = BNNSGraphCompileFromFile(files.modelURL.path, nil, options)
        guard graph.data != nil else {
            throw VaultError.classifierUnavailable("JoyTag's model in this vault couldn't be loaded.")
        }
        guard let first = Self.makeContext(graph) else {
            free(graph.data)
            throw VaultError.classifierUnavailable("JoyTag's model in this vault couldn't be loaded.")
        }
        let context = first.context
        let count = BNNSGraphGetArgumentCount(graph, nil)
        let input = BNNSGraphGetArgumentPosition(graph, nil, files.manifest.input)
        let output = BNNSGraphGetArgumentPosition(graph, nil, files.manifest.output)

        // The model must take one 448-pixel RGB image and give one score per
        // tag in the list, or scores would be read against the wrong names.
        let shapeIn = Self.shape(context, files.manifest.input)
        let shapeOut = Self.shape(context, files.manifest.output)
        guard count == 2, input < 2, output < 2, input != output,
              shapeIn == [1, 3, JoyTagInput.size, JoyTagInput.size],
              shapeOut?.reduce(1, *) == files.tags.count else {
            BNNSGraphContextDestroy(context)
            first.workspace.deallocate()
            free(graph.data)
            throw VaultError.classifierUnavailable("JoyTag's model and tag list in this vault don't match.")
        }
        self.graph = graph
        argumentCount = count
        inputIndex = input
        outputIndex = output
        idle = [first]
        all = [first]
        made = 1
    }

    private static func makeContext(_ graph: bnns_graph_t) -> Context? {
        let context = BNNSGraphContextMake(graph)
        guard context.data != nil else { return nil }
        _ = BNNSGraphContextSetArgumentType(context, BNNSGraphArgumentTypePointer)
        let size = BNNSGraphContextGetWorkspaceSize(context, nil)
        guard size != Int.max else { BNNSGraphContextDestroy(context); return nil }
        return Context(context: context, workspace: .allocate(byteCount: max(size, 1), alignment: Int(getpagesize())), size: size)
    }

    /// A free context, a new one if there's room, or nil if all are busy.
    private func takeContext() -> Context? {
        lock.withLock {
            if let c = idle.popLast() { return c }
            guard made < parallelism, let c = Self.makeContext(graph) else { return nil }
            made += 1
            all.append(c)
            return c
        }
    }

    private func giveBack(_ c: Context) { lock.withLock { idle.append(c) } }

    /// An argument's shape, if it's 32-bit floats.
    private static func shape(_ context: bnns_graph_context_t, _ name: String) -> [Int]? {
        var tensor = BNNSTensor()
        guard BNNSGraphContextGetTensor(context, nil, name, true, &tensor) == 0,
              tensor.data_type == .float else { return nil }
        return withUnsafeBytes(of: tensor.shape) { Array($0.bindMemory(to: Int.self).prefix(Int(tensor.rank))) }
    }

    deinit {
        for c in all {
            BNNSGraphContextDestroy(c.context)
            c.workspace.deallocate()
        }
        free(graph.data)
    }

    public func classify(thumbnail: Data, fast: Bool) async throws -> [ScoredTag] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: fast ? .userInitiated : .utility).async {
                continuation.resume(with: Result { try self.tags(thumbnail: thumbnail) })
            }
        }
    }

    func tags(thumbnail: Data) throws -> [ScoredTag] {
        guard let input = JoyTagInput.tensor(fromImageData: thumbnail) else {
            throw VaultError.classifierUnavailable("The photo's thumbnail couldn't be read.")
        }
        let scores = try self.scores(input)
        let threshold = files.manifest.threshold
        return scores.indices
            .filter { scores[$0] > threshold }
            .sorted { scores[$0] > scores[$1] }
            .map { ScoredTag(name: TagKey.display(files.tags[$0]), score: scores[$0]) }
    }

    /// The sigmoid of each logit: one score per tag, in the tag list's order.
    public func scores(_ input: [Float]) throws -> [Double] {
        precondition(input.count == 3 * JoyTagInput.size * JoyTagInput.size)
        // The run never asks for more at once than there are contexts, but a
        // caller that did would simply wait its turn.
        var context = takeContext()
        while context == nil { usleep(2_000); context = takeContext() }
        let c = context!
        defer { giveBack(c) }
        var input = input
        var logits = [Float](repeating: 0, count: files.tags.count)
        let status = input.withUnsafeMutableBytes { inBytes in
            logits.withUnsafeMutableBytes { outBytes -> Int32 in
                var args = [bnns_graph_argument_t](repeating: bnns_graph_argument_t(), count: argumentCount)
                args[inputIndex].data_ptr = inBytes.baseAddress
                args[inputIndex].data_ptr_size = inBytes.count
                args[outputIndex].data_ptr = outBytes.baseAddress
                args[outputIndex].data_ptr_size = outBytes.count
                return BNNSGraphContextExecute(c.context, nil, argumentCount, &args, c.size,
                                               c.workspace.assumingMemoryBound(to: CChar.self))
            }
        }
        guard status == 0 else { throw VaultError.classifierUnavailable("JoyTag failed on a photo (error \(status)).") }
        return logits.map { 1 / (1 + exp(-Double($0))) }
    }
}

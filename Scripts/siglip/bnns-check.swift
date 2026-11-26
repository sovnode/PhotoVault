// Checks that SigLIP 2's compiled model runs on Accelerate's BNNS graph, as
// PhotoVault runs JoyTag, and gives PyTorch's embeddings for the reference
// inputs convert.py saved.
//
// Usage: swift Scripts/siglip/bnns-check.swift tools/siglip
//
// Prints the argument shapes, the compile and per-image times, and how far
// each embedding is from PyTorch's (largest difference, and cosine).
import Accelerate
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "tools/siglip")
let model = dir.appendingPathComponent("coreml/SigLIP2.mlmodelc").path
let ref = dir.appendingPathComponent("reference")
let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: ref.appendingPathComponent("reference.json"))) as! [String: Any]
let size = meta["size"] as! Int, dim = meta["dim"] as! Int, count = meta["count"] as! Int

func floats(_ name: String) throws -> [Float] {
    let d = try Data(contentsOf: ref.appendingPathComponent(name))
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}

var t = Date()
let options = BNNSGraphCompileOptionsMakeDefault()
let graph = BNNSGraphCompileFromFile(model, nil, options)
BNNSGraphCompileOptionsDestroy(options)
guard graph.data != nil else { print("FAIL: BNNS couldn't compile the model"); exit(1) }
print(String(format: "compiled in %.2f s", Date().timeIntervalSince(t)))

let context = BNNSGraphContextMake(graph)
guard context.data != nil else { print("FAIL: no context"); exit(1) }
_ = BNNSGraphContextSetArgumentType(context, BNNSGraphArgumentTypePointer)
let argc = BNNSGraphGetArgumentCount(graph, nil)
let inIdx = BNNSGraphGetArgumentPosition(graph, nil, "image")
let outIdx = BNNSGraphGetArgumentPosition(graph, nil, "embedding")
func shape(_ name: String) -> [Int] {
    var tensor = BNNSTensor()
    guard BNNSGraphContextGetTensor(context, nil, name, true, &tensor) == 0 else { return [] }
    return withUnsafeBytes(of: tensor.shape) { Array($0.bindMemory(to: Int.self).prefix(Int(tensor.rank))) }
}
print("arguments \(argc); image at \(inIdx) \(shape("image")); embedding at \(outIdx) \(shape("embedding"))")
guard argc == 2, shape("image") == [1, 3, size, size], shape("embedding").reduce(1, *) == dim else {
    print("FAIL: unexpected arguments"); exit(1)
}
let wsSize = BNNSGraphContextGetWorkspaceSize(context, nil)
let workspace = UnsafeMutableRawPointer.allocate(byteCount: max(wsSize, 1), alignment: Int(getpagesize()))
print("workspace \(wsSize / 1_000_000) MB")

var worst: Float = 0, worstCos: Float = 1, times: [Double] = []
for i in 0..<count {
    var input = try floats("input\(i).f32")
    let expected = try floats("embedding\(i).f32")
    var out = [Float](repeating: 0, count: dim)
    t = Date()
    let status = input.withUnsafeMutableBytes { inB in
        out.withUnsafeMutableBytes { outB -> Int32 in
            var args = [bnns_graph_argument_t](repeating: bnns_graph_argument_t(), count: argc)
            args[inIdx].data_ptr = inB.baseAddress; args[inIdx].data_ptr_size = inB.count
            args[outIdx].data_ptr = outB.baseAddress; args[outIdx].data_ptr_size = outB.count
            return BNNSGraphContextExecute(context, nil, argc, &args, wsSize, workspace.assumingMemoryBound(to: CChar.self))
        }
    }
    times.append(Date().timeIntervalSince(t))
    guard status == 0 else { print("FAIL: execute returned \(status)"); exit(1) }
    let diff = zip(out, expected).map { abs($0 - $1) }.max()!
    let cos = zip(out, expected).map(*).reduce(0, +)
    worst = max(worst, diff); worstCos = min(worstCos, cos)
    print(String(format: "input %d: max diff %.2e, cosine %.7f, %.3f s", i, diff, cos, times.last!))
}
let steady = times.dropFirst()
print(String(format: "PASS? max diff %.2e, min cosine %.7f, %.3f s per image after the first",
             worst, worstCos, steady.reduce(0, +) / Double(steady.count)))
exit(worst < 1e-3 && worstCos > 0.9999 ? 0 : 2)

import Foundation
import FluxCandidateResources

do {
    guard CommandLine.arguments.count == 2 else { throw FluxResourceError.unsafePath }
    let start = Date()
    let resources = try FluxResourceVerifier.verify(root: URL(fileURLWithPath: CommandLine.arguments[1]))
    try resources.assertUnchanged()
    let value: [String: Any] = ["status": "verified", "wholeSHAFileCount": 14,
        "seconds": Date().timeIntervalSince(start), "neuralWeightsLoaded": false,
        "neuralGenerations": 0, "MetalRuntimeUsed": false]
    print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
} catch {
    let value: [String: Any] = ["status": "rejected", "error": String(describing: error), "neuralGenerations": 0]
    if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: bytes, as: UTF8.self))
    }
    exit(1)
}

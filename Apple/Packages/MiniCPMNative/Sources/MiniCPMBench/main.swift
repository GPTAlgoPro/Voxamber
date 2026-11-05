import Foundation
import CreationCore
import MiniCPMNative

private struct BenchmarkCase {
    let id: String
    let prompt: String
    let current: BuildingSpec?
    let expected: [String: String]
}

private let cases: [BenchmarkCase] = [
    .init(id: "palace-default", prompt: "建一座金瓦朱柱的双重檐宫殿，尺寸用默认值。", current: nil,
          expected: ["kind": "palace", "roofColor": "gold", "columnColor": "vermilion", "roofTiers": "2", "floors": "1"]),
    .init(id: "pavilion-dimensions", prompt: "做一座青绿琉璃瓦、象牙白柱子的亭，宽0.9米深0.9米高0.8米，单层单檐。", current: nil,
          expected: ["kind": "pavilion", "roofColor": "jade", "columnColor": "ivory", "width": "0.9", "depth": "0.9", "height": "0.8", "floors": "1", "roofTiers": "1"]),
    .init(id: "tower-levels", prompt: "三层青灰瓦塔楼，木色柱子，宽0.65米深0.65米高1.5米，每层一重檐。", current: nil,
          expected: ["kind": "tower", "roofColor": "slate", "columnColor": "walnut", "width": "0.65", "depth": "0.65", "height": "1.5", "floors": "3", "roofTiers": "1"]),
    .init(id: "edit-preserve", prompt: "保持尺寸和所有其他参数，只把屋顶换成青灰色。", current: .palace,
          expected: ["kind": "palace", "roofColor": "slate", "width": "1.0", "depth": "0.8", "height": "0.6", "floors": "1", "roofTiers": "2", "eaveLift": "0.035", "detail": "standard"]),
    .init(id: "edit-dimensions", prompt: "宽改1.2米深0.8米高1米，金瓦朱红柱子，双重檐。", current: .pavilion,
          expected: ["kind": "pavilion", "roofColor": "gold", "columnColor": "vermilion", "width": "1.2", "depth": "0.8", "height": "1.0", "floors": "1", "roofTiers": "2"]),
    .init(id: "edit-combination", prompt: "把楼层改为二层，每层改双重檐，屋顶换成金色。保留其他参数。", current: .tower,
          expected: ["kind": "tower", "roofColor": "gold", "columnColor": "walnut", "width": "0.65", "depth": "0.65", "height": "1.1", "floors": "2", "roofTiers": "2"]),
]

@main
private struct MiniCPMBench {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("Usage: MiniCPMBench MODEL_FILE REPORT_JSON"); return
        }
        let engine = MiniCPMEngine()
        let loadStart = ContinuousClock.now
        try await engine.load(modelURL: URL(fileURLWithPath: arguments[1]))
        let loadSeconds = seconds(since: loadStart)
        var results: [[String: Any]] = []
        for item in cases {
            let started = ContinuousClock.now
            do {
                let output = try await engine.generateJSON(systemPrompt: BuildingPrompt.system,
                    prompt: BuildingPrompt.userRequest(item.prompt, currentSpec: item.current))
                let spec = try BuildingSpec.decodeModelResponse(output)
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as! [String: Any]
                var mismatches: [String] = []
                for (key, expected) in item.expected {
                    if let expectedNumber = Double(expected), let actual = object[key] as? NSNumber {
                        if abs(actual.doubleValue - expectedNumber) > 0.0001 { mismatches.append(key) }
                    } else if object[key] as? String != expected { mismatches.append(key) }
                }
                let result: [String: Any] = ["id": item.id, "prompt": item.prompt,
                    "validSchema": true, "exactParameters": mismatches.isEmpty,
                    "mismatches": mismatches, "seconds": seconds(since: started), "output": output]
                results.append(result)
                print("\(item.id): schema=PASS parameters=\(mismatches.isEmpty ? "PASS" : "FAIL") \(seconds(since: started))s", terminator: "\n")
            } catch {
                results.append(["id": item.id, "prompt": item.prompt, "validSchema": false,
                                "exactParameters": false, "seconds": seconds(since: started),
                                "error": error.localizedDescription])
                print("\(item.id): FAIL \(error.localizedDescription)")
            }
        }
        await engine.unload()
        let report: [String: Any] = ["modelDirectory": arguments[1], "runtime": "llama.cpp native C++ / Metal",
            "device": ProcessInfo.processInfo.hostName, "loadSeconds": loadSeconds,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "date": ISO8601DateFormatter().string(from: .now), "cases": results]
        let output = URL(fileURLWithPath: arguments[2])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }

    static func seconds(since started: ContinuousClock.Instant) -> Double {
        let elapsed = started.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

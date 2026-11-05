import Foundation
import CreationCore
import QwenNative
import ThreeLiveNative

private struct BenchmarkCase {
    let id: String
    let prompt: String
    let current: BuildingSpec?
    let expected: [String: String]
}

private final class ProgressMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    func update(_ progress: QwenGenerationProgress) {
        lock.withLock { first = progress.firstTokenSeconds }
    }
    var firstTokenSeconds: Double? { lock.withLock { first } }
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
private struct QwenBench {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            print("Usage: QwenBench MODEL_DIRECTORY REPORT_JSON"); return
        }
        let engine = QwenEngine()
        if arguments.contains("--lifecycle") {
            var cycles: [[String: Any]] = []
            for cycle in 1...3 {
                try await engine.load(modelDirectory: URL(fileURLWithPath: arguments[1]))
                _ = try await engine.generateJSON(systemPrompt: "只输出一个JSON对象，包含ok字段，值为true。", prompt: "请返回成功状态。", maxTokens: 64)
                let before = await engine.memorySnapshot()
                await engine.unload()
                let after = await engine.memorySnapshot()
                cycles.append(["cycle": cycle, "activeBeforeUnload": before.activeBytes,
                               "activeAfterUnload": after.activeBytes, "peakBytes": after.peakBytes])
                print("lifecycle \(cycle): activeBefore=\(before.activeBytes) after=\(after.activeBytes)")
            }
            try JSONSerialization.data(withJSONObject: ["cycles": cycles], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: arguments[2]))
            return
        }
        let loadStart = ContinuousClock.now
        try await engine.load(modelDirectory: URL(fileURLWithPath: arguments[1]))
        if arguments.contains("--attachments") {
            try await AttachmentBenchmark.run(engine: engine, reportURL: URL(fileURLWithPath: arguments[2]))
            return
        }
        let loadSeconds = seconds(since: loadStart)
        let loadedMemory = await engine.memorySnapshot()
        var results: [[String: Any]] = []
        for item in (arguments.contains("--scene-only") ? [] : cases) {
            let started = ContinuousClock.now
            do {
                let measurement = ProgressMeasurement()
                let output = try await engine.generateJSON(systemPrompt: BuildingPrompt.system,
                    prompt: BuildingPrompt.userRequest(item.prompt, currentSpec: item.current),
                    onProgress: { measurement.update($0) })
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
                    "firstTokenSeconds": measurement.firstTokenSeconds ?? -1,
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
        let scenePrompts = [
            ("chair", "一把简洁的棕色木椅，必须包含坐面、靠背和四条腿，地面Y=0，坐面高度约0.45米，不要增加底部平台。"),
            ("robot", "做一个站立的蓝色玩具机器人，包含立方体头、躯干、左右两条手臂和两条腿，以及两个球形黄色眼睛，底部在Y=0。"),
            ("lamp", "做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。"),
        ]
        var sceneResults: [[String: Any]] = []
        for (id, prompt) in scenePrompts {
            let started = ContinuousClock.now
            let measurement = ProgressMeasurement()
            do {
                let thinking = arguments.contains("--thinking")
                let instruction = try ScenePrompt.userRequest(prompt)
                    + (thinking ? "\n请在内部用100字以内核算几何中心、连接和正面方向，再给最终JSON。" : "")
                let initialOutput = try await engine.generateJSON(systemPrompt: ScenePrompt.system,
                    prompt: instruction, maxTokens: thinking ? 3072 : 1536, thinking: thinking,
                    onProgress: { measurement.update($0) })
                let initialScene = try SceneSpec.decodeModelResponse(initialOutput)
                let initialMeshes = try SceneGenerator.generate(for: initialScene)
                let initialIssues = spatialIssues(initialScene, meshes: initialMeshes)
                let initialSeconds = seconds(since: started)
                var output = initialOutput
                var repairSeconds: Double = 0
                if !initialIssues.isEmpty {
                    let repairStarted = ContinuousClock.now
                    output = try await engine.generateJSON(systemPrompt: ScenePrompt.system,
                        prompt: "原始创作要求：\n\(prompt)\n当前模型 JSON：\n\(initialOutput)\n原生几何检查发现：\n\(initialIssues.joined(separator: "\n"))\n请保持物体主题和颜色，修复上述空间关系，仅输出完整场景JSON。支架和板面的位置请算对，不要添加无关大平台。",
                        maxTokens: thinking ? 3072 : 1536, thinking: thinking)
                    repairSeconds = seconds(since: repairStarted)
                }
                let scene = try SceneSpec.decodeModelResponse(output)
                let meshes = try SceneGenerator.generate(for: scene)
                let triangleCount = meshes.reduce(0) { $0 + $1.indices.count / 3 }
                let vertexCount = meshes.reduce(0) { $0 + $1.positions.count / 3 }
                let finiteGeometry = meshes.allSatisfy { $0.positions.allSatisfy(\.isFinite) && $0.normals.allSatisfy(\.isFinite) }
                var minimum: [Float] = [.infinity, .infinity, .infinity]
                var maximum: [Float] = [-.infinity, -.infinity, -.infinity]
                for mesh in meshes {
                    for (index, value) in mesh.positions.enumerated() {
                        let axis = index % 3
                        minimum[axis] = min(minimum[axis], value)
                        maximum[axis] = max(maximum[axis], value)
                    }
                }
                var semanticChecks: [String: Bool]
                switch id {
                case "chair": semanticChecks = ["atLeastSixParts": scene.nodes.count >= 6,
                    "seatAndBack": scene.nodes.filter { $0.primitive == .box }.count >= 2,
                    "brownMaterial": scene.nodes.contains { rgb($0.color).0 > rgb($0.color).1 && rgb($0.color).1 > rgb($0.color).2 }]
                case "robot": semanticChecks = ["atLeastEightParts": scene.nodes.count >= 8,
                    "twoSphericalEyes": scene.nodes.filter { $0.primitive == .sphere }.count >= 2,
                    "blueMaterial": scene.nodes.contains { rgb($0.color).2 > rgb($0.color).0 && rgb($0.color).2 >= rgb($0.color).1 },
                    "yellowEyes": scene.nodes.filter { $0.primitive == .sphere && rgb($0.color).0 >= 180 && rgb($0.color).1 >= 150 && rgb($0.color).2 < 150 }.count >= 2]
                default: semanticChecks = ["coneShade": scene.nodes.contains { $0.primitive == .cone },
                    "cylinderBaseAndStem": scene.nodes.filter { $0.primitive == .cylinder }.count >= 2,
                    "redShade": scene.nodes.contains { $0.primitive == .cone && rgb($0.color).0 >= 180 && rgb($0.color).1 < 150 && rgb($0.color).2 < 150 }]
                }
                semanticChecks["groundContact"] = abs(minimum[1]) <= 0.03
                semanticChecks["connectedParts"] = isConnected(meshes)
                if id == "robot", let head = scene.nodes.first(where: { $0.id.lowercased().contains("head") }) {
                    let eyes = scene.nodes.filter { $0.id.lowercased().contains("eye") }
                    semanticChecks["eyesOnSameFrontFace"] = eyes.count >= 2
                        && eyes.allSatisfy { $0.position[2] + $0.size[2] / 2 > head.position[2] + head.size[2] / 2 }
                        && (eyes.map { $0.position[2] }.max()! - eyes.map { $0.position[2] }.min()! < 0.04)
                }
                let artifactDirectory = URL(fileURLWithPath: arguments[2]).deletingLastPathComponent().appendingPathComponent("model-generated-scenes")
                try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
                try Data(output.utf8).write(to: artifactDirectory.appendingPathComponent(id + ".json"))
                try ThreeLiveNative.exportUSDZ(meshes).write(to: artifactDirectory.appendingPathComponent(id + ".usdz"))
                try ThreeLiveNative.exportGLB(meshes).write(to: artifactDirectory.appendingPathComponent(id + ".glb"))
                sceneResults.append(["id": id, "prompt": prompt, "validSchema": true,
                    "semanticChecks": semanticChecks, "passesHeuristicChecks": semanticChecks.values.allSatisfy { $0 },
                    "initialSpatialIssues": initialIssues, "initialSeconds": initialSeconds,
                    "repairAttempted": !initialIssues.isEmpty, "repairSeconds": repairSeconds,
                    "initialOutput": initialOutput, "remainingSpatialIssues": spatialIssues(scene, meshes: meshes),
                    "nodeCount": scene.nodes.count, "firstTokenSeconds": measurement.firstTokenSeconds ?? -1,
                    "meshCount": meshes.count, "triangleCount": triangleCount, "vertexCount": vertexCount,
                    "finiteGeometry": finiteGeometry, "boundsMinimum": minimum, "boundsMaximum": maximum,
                    "seconds": seconds(since: started), "output": output])
                print("scene-\(id): schema=PASS parts=\(scene.nodes.count) \(seconds(since: started))s")
            } catch {
                sceneResults.append(["id": id, "prompt": prompt, "validSchema": false,
                                     "seconds": seconds(since: started), "error": error.localizedDescription])
                print("scene-\(id): FAIL \(error.localizedDescription)")
            }
        }
        let peakMemory = await engine.memorySnapshot()
        await engine.unload()
        let unloadedMemory = await engine.memorySnapshot()
        let report: [String: Any] = ["modelDirectory": arguments[1], "runtime": "MLX Swift / Metal",
            "device": ProcessInfo.processInfo.hostName, "loadSeconds": loadSeconds,
            "mlxActiveBytesAfterLoad": loadedMemory.activeBytes,
            "mlxActiveBytesBeforeUnload": peakMemory.activeBytes,
            "mlxPeakBytes": peakMemory.peakBytes,
            "mlxActiveBytesAfterUnload": unloadedMemory.activeBytes,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "date": ISO8601DateFormatter().string(from: .now), "cases": results, "sceneCases": sceneResults]
        let output = URL(fileURLWithPath: arguments[2])
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
    }

    static func seconds(since started: ContinuousClock.Instant) -> Double {
        let elapsed = started.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    static func rgb(_ color: String) -> (Int, Int, Int) {
        let number = Int(color.dropFirst(), radix: 16) ?? 0
        return ((number >> 16) & 255, (number >> 8) & 255, number & 255)
    }

    static func isConnected(_ meshes: [GeneratedMesh]) -> Bool {
        let bounds = meshes.map { mesh -> ([Float], [Float]) in
            var lo: [Float] = [.infinity, .infinity, .infinity]
            var hi: [Float] = [-.infinity, -.infinity, -.infinity]
            for (index, value) in mesh.positions.enumerated() {
                lo[index % 3] = min(lo[index % 3], value)
                hi[index % 3] = max(hi[index % 3], value)
            }
            return (lo, hi)
        }
        guard !bounds.isEmpty else { return false }
        var visited: Set<Int> = [0]
        var queue = [0]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for other in bounds.indices where !visited.contains(other) {
                var squaredGap: Float = 0
                for axis in 0..<3 {
                    let gap = max(0, max(bounds[current].0[axis] - bounds[other].1[axis],
                                         bounds[other].0[axis] - bounds[current].1[axis]))
                    squaredGap += gap * gap
                }
                if squaredGap <= 0.015 * 0.015 {
                    visited.insert(other)
                    queue.append(other)
                }
            }
        }
        return visited.count == bounds.count
    }

    static func spatialIssues(_ scene: SceneSpec, meshes: [GeneratedMesh]) -> [String] {
        var issues: [String] = []
        for node in scene.nodes where node.rotation.allSatisfy({ abs($0) < 0.01 }) {
            let bottom = node.position[1] - node.size[1] / 2
            if bottom < -0.02 {
                issues.append("\(node.id)底部Y=\(bottom)，低于地面。若该部件落地，其中心Y应为高度的一半=\(node.size[1]/2)。")
            }
        }
        if !isConnected(meshes) {
            issues.append("物体由互不接触的部件组构成。请用实际上下端点重新核算相接位置：上方件底Y=centerY-height/2，下方件顶Y=centerY+height/2，两者应相同或略交叠。支架水平位置应在其支撑板范围内。")
        }
        if let head = scene.nodes.first(where: { $0.id.lowercased().contains("head") }) {
            let front = head.position[2] + head.size[2] / 2
            let eyes = scene.nodes.filter { $0.id.lowercased().contains("eye") }
            if eyes.count >= 2,
               eyes.contains(where: { $0.position[2] + $0.size[2] / 2 <= front })
                || (eyes.count >= 2 && (eyes.map { $0.position[2] }.max()! - eyes.map { $0.position[2] }.min()! > 0.04)) {
                issues.append("左右眼必须在同一正面。头部正面Z=\(front)，两只眼的中心Z都应为\(front+0.01)，只让X一负一正，Y/Z相同。")
            }
        }
        if let back = scene.nodes.first(where: { $0.id.lowercased().contains("back") }),
           let seat = scene.nodes.first(where: { $0.id.lowercased().contains("seat") }) {
            if back.primitive != .box || back.size[2] >= seat.size[2] * 0.6 || back.position[2] >= seat.position[2] {
                issues.append("椅背应是后侧(-Z)竖立的薄盒子：厚度约0.05，中心Z约为\(seat.position[2]-seat.size[2]/2+0.025)，底端接坐面顶Y=\(seat.position[1]+seat.size[1]/2)。")
            }
        }
        return issues
    }
}

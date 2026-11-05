import Foundation
import CreationCore
import QwenNative
import ThreeLiveNative

/// Experiment: the model supplies a part graph; native code computes touching surfaces.
enum AttachmentBenchmark {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        private var first: Double?
        func update(_ value: BenchProgress) {
            lock.withLock { text = value.text; first = value.firstTokenSeconds }
        }
        var lastText: String { lock.withLock { text } }
        var firstTokenSeconds: Double? { lock.withLock { first } }
    }
    static let system = ScenePrompt.system

    static func run(engine: any BenchModel, reportURL: URL) async throws {
        let requests = [
            ("chair", "棕色木椅，包含坐面、薄靠背和四条腿，坐面约0.45米高，不要无关大平台。"),
            ("robot", "蓝色玩具机器人，立方体头和躯干、左右手臂和双腿、两个球形黄色眼睛，正面朝+Z。"),
            ("lamp", "一盏红色圆锥灯罩台灯，灰色圆柱底座和细圆柱支杆，可以加球形灯泡，整体约0.8米高。"),
            ("whale", "一条弯曲尾巴的蓝色小鲸鱼，流线型椭圆身体，左右鳍和分叉尾鳍，两个可见眼睛；尾鳍或侧鳍至少用一个extrusion自由轮廓。是独立海洋动物造型，不要平台。"),
            ("aircraft", "带后掠机翼的未来飞行器，银色流线机身、左右对称不规则机翼、两个推进器，机翼至少一个用extrusion自由轮廓，机身可用lathe。做一个整体，不要平台。"),
        ]
        var results: [[String: Any]] = []
        let loadedMemory = await engine.benchMemorySnapshot()
        for (id, request) in requests {
            let began = Date()
            let progress = ProgressRecorder()
            var raw = ""
            do {
                raw = try await engine.benchGenerate(systemPrompt: system,
                    prompt: ScenePrompt.userRequest(request), maxTokens: 3072,
                    onProgress: { progress.update($0) })
                let scene = try resolve(raw)
                let meshes = try SceneGenerator.generate(for: scene)
                let diagnostics = spatialDiagnostics(scene, meshes: meshes)
                let semantics = semanticDiagnostics(id, scene: scene)
                let artifactName = reportURL.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "-macos-benchmark", with: "-scenes")
                let artifacts = reportURL.deletingLastPathComponent().appendingPathComponent(artifactName)
                try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try Data(raw.utf8).write(to: artifacts.appendingPathComponent(id + "-relations.json"))
                try encoder.encode(scene).write(to: artifacts.appendingPathComponent(id + ".json"))
                try ThreeLiveNative.exportUSDZ(meshes).write(to: artifacts.appendingPathComponent(id + ".usdz"))
                try ThreeLiveNative.exportGLB(meshes).write(to: artifacts.appendingPathComponent(id + ".glb"))
                #if os(macOS)
                try await ModelPreview.write(usdzURL: artifacts.appendingPathComponent(id + ".usdz"), meshes: meshes,
                                             destination: artifacts.appendingPathComponent(id + ".png"))
                try await ModelPreview.write(usdzURL: artifacts.appendingPathComponent(id + ".usdz"), meshes: meshes,
                                             destination: artifacts.appendingPathComponent(id + "-front.png"), front: true)
                #endif
                results.append(["id": id, "prompt": request, "validSchema": true,
                    "nodeCount": scene.nodes.count, "triangleCount": meshes.reduce(0) { $0 + $1.indices.count / 3 },
                    "diagnostics": diagnostics, "spatialChecksPass": diagnostics.isEmpty,
                    "semanticDiagnostics": semantics, "semanticChecksPass": semantics.isEmpty,
                    "primitiveTypes": Array(Set(scene.nodes.map { $0.primitive.rawValue })).sorted(),
                    "firstTokenSeconds": progress.firstTokenSeconds ?? -1,
                    "seconds": Date().timeIntervalSince(began), "rawRelations": raw,
                    "resolvedScene": String(decoding: try encoder.encode(scene), as: UTF8.self)])
                print("attachment-\(id): parts=\(scene.nodes.count) spatial=\(diagnostics.isEmpty ? "PASS" : "FAIL") \(Date().timeIntervalSince(began))s")
            } catch {
                results.append(["id": id, "prompt": request, "validSchema": false,
                                "error": error.localizedDescription, "seconds": Date().timeIntervalSince(began),
                                "rejectedOrIncompleteOutput": raw.isEmpty ? progress.lastText : raw])
                print("attachment-\(id): FAIL \(error.localizedDescription)")
            }
        }
        let peakMemory = await engine.benchMemorySnapshot()
        await engine.unload()
        let releasedMemory = await engine.benchMemorySnapshot()
        try JSONSerialization.data(withJSONObject: ["method": "Native MLX direct named ScenePlan + production AABB attachment solver; no object template or generated code",
            "modelDirectory": CommandLine.arguments[1], "mlxActiveBytesAfterLoad": loadedMemory.activeBytes,
            "mlxPeakBytes": peakMemory.peakBytes, "mlxActiveBytesAfterUnload": releasedMemory.activeBytes,
            "cases": results], options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL)
    }

    static func resolve(_ text: String) throws -> SceneSpec {
        try SceneSpec.decodeModelResponse(text)
    }

    static func renderReport(_ input: URL, destination: URL) async throws {
        let report = try JSONSerialization.jsonObject(with: Data(contentsOf: input)) as! [String: Any]
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for record in report["cases"] as? [[String: Any]] ?? [] {
            guard let id = record["id"] as? String,
                  id.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  let json = record["resolvedScene"] as? String else { continue }
            let scene = try SceneSpec.decodeModelResponse(json)
            let meshes = try SceneGenerator.generate(for: scene)
            let asset = destination.appendingPathComponent(id + ".usdz")
            try ThreeLiveNative.exportUSDZ(meshes).write(to: asset)
            try ThreeLiveNative.exportGLB(meshes).write(to: destination.appendingPathComponent(id + ".glb"))
            try Data(json.utf8).write(to: destination.appendingPathComponent(id + ".json"))
            #if os(macOS)
            try await ModelPreview.write(usdzURL: asset, meshes: meshes, destination: destination.appendingPathComponent(id + ".png"))
            try await ModelPreview.write(usdzURL: asset, meshes: meshes, destination: destination.appendingPathComponent(id + "-front.png"), front: true)
            #endif
        }
    }

    private static func bounds(of mesh: GeneratedMesh) -> ([Float], [Float]) {
        var minimum: [Float] = [.infinity, .infinity, .infinity]
        var maximum: [Float] = [-.infinity, -.infinity, -.infinity]
        for (index, value) in mesh.positions.enumerated() {
            minimum[index % 3] = min(minimum[index % 3], value)
            maximum[index % 3] = max(maximum[index % 3], value)
        }
        return (minimum, maximum)
    }
    private static func spatialDiagnostics(_ scene: SceneSpec, meshes: [GeneratedMesh]) -> [String] {
        let boxes = meshes.map { bounds(of: $0) }
        var issues: [String] = []
        if abs(boxes.map { $0.0[1] }.min() ?? 0) > 0.02 { issues.append("not-grounded") }
        var visited: Set<Int> = [0]; var queue = [0]
        while !queue.isEmpty {
            let index = queue.removeFirst()
            for candidate in boxes.indices where !visited.contains(candidate) {
                let squaredGap = (0..<3).reduce(Float.zero) { total, axis in
                    let gap = max(0, max(boxes[index].0[axis] - boxes[candidate].1[axis], boxes[candidate].0[axis] - boxes[index].1[axis]))
                    return total + gap * gap
                }
                if squaredGap <= 0.015 * 0.015 { visited.insert(candidate); queue.append(candidate) }
            }
        }
        if visited.count != boxes.count { issues.append("disconnected-parts") }
        if let head = scene.nodes.first(where: { $0.id.lowercased().contains("head") }) {
            let eyes = scene.nodes.filter { $0.id.lowercased().contains("eye") }
            let front = head.position[2] + head.size[2] / 2
            if eyes.count >= 2, eyes.contains(where: { $0.position[2] + $0.size[2] / 2 <= front }) { issues.append("eyes-not-visible-on-front") }
            if eyes.count >= 2, eyes.map({ $0.position[2] }).max()! - eyes.map({ $0.position[2] }).min()! > 0.04 { issues.append("eyes-on-different-faces") }
        }
        return issues
    }

    private static func semanticDiagnostics(_ id: String, scene: SceneSpec) -> [String] {
        var issues: [String] = []
        if id == "chair" {
            let legs = scene.nodes.filter { $0.id.lowercased().contains("leg") }
            if legs.count < 4 { issues.append("chair-missing-four-legs") }
            if legs.contains(where: { $0.size[1] < max($0.size[0], $0.size[2]) * 2 }) { issues.append("chair-legs-not-vertical") }
            if let back = scene.nodes.first(where: { $0.id.lowercased().contains("back") }) {
                if back.size[1] <= back.size[2] * 2 { issues.append("chair-back-not-vertical-thin-panel") }
                if let seat = scene.nodes.first(where: { $0.id.lowercased().contains("seat") }) {
                    if back.size[0] < seat.size[0] * 0.6 { issues.append("chair-back-too-narrow") }
                    if back.position[2] >= seat.position[2] - seat.size[2] * 0.2 { issues.append("chair-back-not-at-rear-edge") }
                    if legs.count >= 4,
                       (legs.map { $0.position[2] }.max()! - legs.map { $0.position[2] }.min()!) < seat.size[2] * 0.45 {
                        issues.append("chair-front-rear-legs-too-close")
                    }
                }
            } else { issues.append("chair-no-back") }
        }
        if id == "robot" {
            let eyes = scene.nodes.filter { $0.id.lowercased().contains("eye") }
            if eyes.count < 2 { issues.append("robot-missing-two-eyes") }
            if eyes.count >= 2 {
                let separation = abs(eyes[0].position[0] - eyes[1].position[0])
                if separation < max(eyes[0].size[0], eyes[1].size[0]) { issues.append("robot-eyes-overlap") }
            }
            if let torso = scene.nodes.first(where: { $0.id.lowercased().contains("body") || $0.id.lowercased().contains("torso") || $0.id == "base" }) {
                let arms = scene.nodes.filter { $0.id.lowercased().contains("arm") }
                if arms.count < 2 { issues.append("robot-missing-arms") }
                if arms.contains(where: { abs($0.position[1] - torso.position[1]) > torso.size[1] / 2 + 0.04
                    || abs($0.position[0] - torso.position[0]) < torso.size[0] * 0.35 }) {
                    issues.append("robot-arms-not-at-torso-sides")
                }
            }
        }
        if id == "lamp" {
            if let stem = scene.nodes.first(where: { $0.id.lowercased().contains("stem") || $0.id.lowercased().contains("pole") || $0.id.lowercased().contains("rod") }) {
                if stem.size[1] < max(stem.size[0], stem.size[2]) * 3 { issues.append("lamp-stem-not-vertical") }
            } else { issues.append("lamp-no-stem") }
            if let shade = scene.nodes.first(where: { $0.id.lowercased().contains("shade") }) {
                if min(shade.size[0], shade.size[2]) < shade.size[1] * 0.75 { issues.append("lamp-shade-too-narrow") }
            }
        }
        if id == "whale" || id == "aircraft" {
            if !scene.nodes.contains(where: { [.extrusion, .mesh, .lathe].contains($0.primitive) }) { issues.append("requested-freeform-not-used") }
            if !scene.nodes.contains(where: { $0.primitive == .extrusion }) { issues.append("requested-extruded-fin-or-wing-not-used") }
        }
        return issues
    }
}

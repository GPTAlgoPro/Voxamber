import Foundation
import XCTest
import CryptoKit
import Darwin
import RealityKit
import CreationCore
import ThreeLiveNative
import QwenNative
@testable import ThreeLiveStudio

@MainActor
final class OnDeviceInferenceTests: XCTestCase {
    func testVerifiedLocalSceneWorkflowCancellationAndMemory() async throws {
        guard !Self.isSimulator else { throw XCTSkip("Real iPhone inference benchmark; simulator measurements are not accepted") }
        guard ProcessInfo.processInfo.physicalMemory >= 11 * 1_024 * 1_024 * 1_024 else {
            throw XCTSkip("This benchmark requires the intended 12GB-or-larger device")
        }
        executionTimeAllowance = 900
        let documents = URL.documentsDirectory
        let output = documents.appending(path: "Measurements/ai-device-benchmark.json")
        let temporary = FileManager.default.temporaryDirectory.appending(path: "DeviceAI-" + UUID().uuidString,
                                                                         directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let engine = QwenEngine()
        let footprints = DeviceFootprintCapture()
        let sampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                footprints.record(physicalBytes: Self.physicalFootprint(),
                                  mlx: await engine.memorySnapshot(),
                                  thermal: ProcessInfo.processInfo.thermalState.rawValue)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        var report = DeviceAIReport(modelID: ModelManager.modelID, hardware: Self.hardwareIdentifier(),
                                    os: ProcessInfo.processInfo.operatingSystemVersionString,
                                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        do {
            report.phase = "verifying_local_weights"
            try checkpoint(&report, footprints: footprints, output: output)
            let manifestURL = try XCTUnwrap(Bundle.main.url(forResource: "LanguageModel", withExtension: "json"))
            let manifestBytes = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(LocalModelManifest.self, from: manifestBytes)
            try require(manifest.id == ModelManager.modelID, "Bundled model identity differs from the benchmark identity")
            let store = VerifiedModelStore(root: documents.appending(path: "Models", directoryHint: .isDirectory))
            let verificationStart = ContinuousClock.now
            let directory = try await store.verifyInstalled(manifest: manifest)
            report.weightVerificationSeconds = Self.seconds(since: verificationStart)
            report.weightsVerified = true
            report.manifestSHA256 = SHA256.hash(data: manifestBytes).map { String(format: "%02x", $0) }.joined()
            report.verifiedFileCount = manifest.files.count
            report.verifiedWeightBytes = manifest.files.reduce(0) { $0 + $1.byteCount }
            report.memoryStates["before_first_load"] = await engine.memorySnapshot()
            report.footprintStates["before_first_load"] = Self.physicalFootprint()
            report.phase = "first_model_load_after_hash_verification"
            try checkpoint(&report, footprints: footprints, output: output)
            let loadStart = ContinuousClock.now
            try await engine.load(modelDirectory: directory)
            report.firstLoadSeconds = Self.seconds(since: loadStart)
            report.memoryStates["after_first_load"] = await engine.memorySnapshot()
            report.footprintStates["after_first_load"] = Self.physicalFootprint()
            try checkpoint(&report, footprints: footprints, output: output)

            for item in Self.cases {
                report.phase = "generating_" + item.id
                try checkpoint(&report, footprints: footprints, output: output)
                let result = try await runCase(item, engine: engine, projectsRoot: temporary)
                report.cases.append(result)
                try checkpoint(&report, footprints: footprints, output: output)
            }

            report.phase = "cancelling_after_first_generated_token"
            report.memoryStates["before_cancellation"] = await engine.memorySnapshot()
            report.footprintStates["before_cancellation"] = Self.physicalFootprint()
            try checkpoint(&report, footprints: footprints, output: output)
            let cancellation = DeviceGenerationCancellation()
            let cancellationPrompt = try ScenePrompt.userRequest("创作一个有圆形关节、双眼、天线、双臂双腿的站立机器人，用8到12个部件。")
            let cancelledGeneration = Task {
                try await engine.generateJSON(systemPrompt: ScenePrompt.system, prompt: cancellationPrompt,
                                              maxTokens: 3_072, onProgress: { value in
                    if value.firstTokenSeconds != nil { cancellation.cancelAfterFirstToken() }
                })
            }
            cancellation.assign(cancelledGeneration)
            defer { cancellation.clear() }
            do {
                _ = try await awaitGeneration(cancelledGeneration, timeoutSeconds: 120)
                throw DeviceBenchmarkError.requirement("A deliberately cancelled inference returned success")
            } catch is CancellationError {
                try require(cancellation.requestedAt != nil, "Cancellation did not reach a real generated token")
                report.cancellationObserved = true
                report.cancellationAfterFirstToken = true
                report.cancellationSettleSeconds = cancellation.requestedAt.map { Self.seconds(since: $0) }
            }
            report.memoryStates["after_cancellation_settled"] = await engine.memorySnapshot()
            report.footprintStates["after_cancellation_settled"] = Self.physicalFootprint()
            let beforeUnload = await engine.memorySnapshot()
            let unloadStart = ContinuousClock.now
            await engine.unload()
            report.cancellationUnloadSeconds = Self.seconds(since: unloadStart)
            try await Task.sleep(for: .milliseconds(300))
            let afterUnload = await engine.memorySnapshot()
            report.memoryStates["after_cancellation_unload"] = afterUnload
            report.footprintStates["after_cancellation_unload"] = Self.physicalFootprint()
            report.mlxActiveBytesReleasedAfterCancellation = beforeUnload.activeBytes - afterUnload.activeBytes
            try require(afterUnload.activeBytes < beforeUnload.activeBytes,
                        "Unloading after cancellation did not release measured MLX active memory")
            report.phase = "reload_after_cancel_and_unload"
            try checkpoint(&report, footprints: footprints, output: output)
            let reloadStart = ContinuousClock.now
            try await engine.load(modelDirectory: directory)
            report.reloadSeconds = Self.seconds(since: reloadStart)
            report.memoryStates["after_reload"] = await engine.memorySnapshot()
            let afterReload = try await runCase(.init(id: "chair_after_reload", prompt: Self.cases[0].prompt),
                                                engine: engine, projectsRoot: temporary)
            report.reloadCase = afterReload
            await engine.unload()
            try await Task.sleep(for: .milliseconds(300))
            report.memoryStates["after_final_unload"] = await engine.memorySnapshot()
            report.footprintStates["after_final_unload"] = Self.physicalFootprint()
            sampler.cancel()
            await sampler.value
            try require(footprints.summary.sampledPeakPhysicalFootprintBytes != nil,
                        "The process physical-footprint sampler could not collect evidence")
            report.phase = "complete"
            report.status = "passed"
            try checkpoint(&report, footprints: footprints, output: output)
        } catch {
            await engine.unload()
            sampler.cancel()
            await sampler.value
            report.status = "failed"
            report.failure = .init(kind: String(reflecting: type(of: error)),
                                   domain: (error as NSError).domain, code: (error as NSError).code)
            report.memoryStates["after_failure_cleanup"] = await engine.memorySnapshot()
            report.footprintStates["after_failure_cleanup"] = Self.physicalFootprint()
            try? checkpoint(&report, footprints: footprints, output: output)
            throw error
        }
    }

    private func runCase(_ item: DeviceSceneCase, engine: QwenEngine, projectsRoot: URL) async throws -> DeviceSceneResult {
        let measuredProgress = DeviceTokenMeasurement()
        let began = ContinuousClock.now
        let generation = Task {
            try await engine.generateJSON(systemPrompt: ScenePrompt.system,
                                          prompt: ScenePrompt.userRequest(item.prompt), maxTokens: 1_536,
                                          onProgress: { measuredProgress.record($0) })
        }
        let response = try await awaitGeneration(generation, timeoutSeconds: 120)
        let generationSeconds = Self.seconds(since: began)
        // Malformed JSON, duplicate keys, invalid ranges and incomplete scenes are hard failures.
        let scene = try SceneSpec.decodeModelResponse(response)
        try scene.validate()
        let firstToken = try XCTUnwrap(measuredProgress.firstTokenSeconds, "No real first-token timing was observed")
        let native = Task.detached(priority: .userInitiated) {
            let geometryStart = ContinuousClock.now
            let meshes = try SceneGenerator.generate(for: scene)
            let geometrySeconds = Self.seconds(since: geometryStart)
            let exportStart = ContinuousClock.now
            let glb = try ThreeLiveNative.exportGLB(meshes)
            let usdz = try ThreeLiveNative.exportUSDZ(meshes)
            return DeviceNativeArtifacts(glb: glb, usdz: usdz, meshCount: meshes.count,
                vertices: meshes.reduce(0) { $0 + $1.positions.count / 3 },
                triangles: meshes.reduce(0) { $0 + $1.indices.count / 3 },
                geometrySeconds: geometrySeconds, exportSeconds: Self.seconds(since: exportStart))
        }
        let files = try await withTaskCancellationHandler { try await native.value } onCancel: { native.cancel() }
        let persistenceStart = ContinuousClock.now
        let store = ProjectStore(root: projectsRoot)
        let published = try await store.publish(spec: scene, prompt: item.prompt, glb: files.glb,
                                                usdz: files.usdz, replacing: nil)
        let reopened = ProjectStore(root: projectsRoot)
        let listed = try await reopened.list()
        let project = try XCTUnwrap(listed.first { $0.id == published.project.id })
        let loaded = try await reopened.load(project)
        try require(loaded.project.sceneSpec == scene, "Reopened scene parameters differ from the generated scene")
        try require(try Data(contentsOf: loaded.glbURL) == files.glb, "GLB readback differs from the exported bytes")
        try require(try Data(contentsOf: loaded.usdzURL) == files.usdz, "USDZ readback differs from the exported bytes")
        let persistenceSeconds = Self.seconds(since: persistenceStart)
        let realityStart = ContinuousClock.now
        let entity = try await Entity(contentsOf: loaded.usdzURL)
        let bounds = entity.visualBounds(relativeTo: nil)
        let extents = [bounds.extents.x, bounds.extents.y, bounds.extents.z]
        try require(!bounds.isEmpty && extents.allSatisfy { $0.isFinite && $0 > 0 },
                    "RealityKit could not load a finite three-dimensional result")
        return DeviceSceneResult(id: item.id, validSchema: true, scene: scene, nodeCount: scene.nodes.count,
            firstTokenSeconds: firstToken, generationSeconds: generationSeconds,
            geometrySeconds: files.geometrySeconds, exportSeconds: files.exportSeconds,
            persistenceAndReopenSeconds: persistenceSeconds, realityKitLoadSeconds: Self.seconds(since: realityStart),
            meshCount: files.meshCount, vertices: files.vertices, triangles: files.triangles,
            glbBytes: files.glb.count, usdzBytes: files.usdz.count,
            glbSHA256: project.glbSHA256, usdzSHA256: project.usdzSHA256,
            realityKitBoundsMetres: extents, mlx: await engine.memorySnapshot(),
            physicalFootprintBytes: Self.physicalFootprint(), thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }

    private func awaitGeneration(_ operation: Task<String, Error>, timeoutSeconds: Int) async throws -> String {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await operation.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw DeviceBenchmarkError.timeout
                }
                defer { group.cancelAll(); operation.cancel() }
                return try await group.next()!
            }
        } onCancel: { operation.cancel() }
    }

    private func checkpoint(_ report: inout DeviceAIReport, footprints: DeviceFootprintCapture, output: URL) throws {
        report.footprints = footprints.summary
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    private func require(_ valid: Bool, _ message: String) throws {
        guard valid else { throw DeviceBenchmarkError.requirement(message) }
    }

    private nonisolated static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private nonisolated static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }

    private nonisolated static func physicalFootprint() -> UInt64? {
        var value = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let capacity = Int(count)
        let result = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? value.phys_footprint : nil
    }

    private nonisolated static func hardwareIdentifier() -> String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }

    private static let cases: [DeviceSceneCase] = [
        .init(id: "chair", prompt: "一把简洁的棕色木椅，必须包含坐面、靠背和四条腿，地面Y=0，坐面高度约0.45米，不要增加底部平台。"),
        .init(id: "robot", prompt: "做一个站立的蓝色玩具机器人，包含立方体头、躯干、左右两条手臂和两条腿，以及两个球形黄色眼睛，底部在Y=0。"),
        .init(id: "lamp", prompt: "做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。")
    ]
}

private enum DeviceBenchmarkError: LocalizedError {
    case timeout
    case requirement(String)
    var errorDescription: String? {
        switch self {
        case .timeout: return "Physical-device generation exceeded its 120-second limit"
        case .requirement(let message): return message
        }
    }
}

private struct DeviceSceneCase: Sendable { let id: String; let prompt: String }
private struct DeviceNativeArtifacts: Sendable {
    let glb: Data; let usdz: Data; let meshCount: Int; let vertices: Int; let triangles: Int
    let geometrySeconds: Double; let exportSeconds: Double
}
private struct DeviceSceneResult: Encodable {
    let id: String; let validSchema: Bool; let scene: SceneSpec; let nodeCount: Int
    let firstTokenSeconds: Double; let generationSeconds: Double; let geometrySeconds: Double
    let exportSeconds: Double; let persistenceAndReopenSeconds: Double; let realityKitLoadSeconds: Double
    let meshCount: Int; let vertices: Int; let triangles: Int; let glbBytes: Int; let usdzBytes: Int
    let glbSHA256: String; let usdzSHA256: String; let realityKitBoundsMetres: [Float]
    let mlx: QwenMemorySnapshot; let physicalFootprintBytes: UInt64?; let thermalState: Int
}
private struct DeviceFailure: Encodable { let kind: String; let domain: String; let code: Int }
private struct DeviceAIReport: Encodable {
    let schemaVersion = 1
    let measuredAt = ISO8601DateFormatter().string(from: .now)
    let scope = "Real iPhone; local-only model API after hash verification. System network radios were not disabled by this test; flight-mode acceptance is separate."
    let loadCacheNote = "First model load in this test follows streaming hash verification, which may warm filesystem caches; it is not a cold-storage benchmark."
    let runtime = "Swift MLX / Metal"
    let modelID: String; let hardware: String; let os: String; let physicalMemoryBytes: UInt64
    var status = "running"
    var phase = "starting"
    var weightsVerified = false
    var manifestSHA256: String?
    var verifiedFileCount: Int?
    var verifiedWeightBytes: Int64?
    var weightVerificationSeconds: Double?
    var firstLoadSeconds: Double?
    var reloadSeconds: Double?
    var cases: [DeviceSceneResult] = []
    var reloadCase: DeviceSceneResult?
    var cancellationObserved = false
    var cancellationAfterFirstToken = false
    var cancellationSettleSeconds: Double?
    var cancellationUnloadSeconds: Double?
    var mlxActiveBytesReleasedAfterCancellation: Int?
    var memoryStates: [String: QwenMemorySnapshot] = [:]
    var footprintStates: [String: UInt64] = [:]
    var footprints = DeviceFootprintSummary()
    var failure: DeviceFailure?
}
private struct DeviceFootprintSummary: Encodable {
    let sampleIntervalSeconds = 0.1
    var samples = 0
    var sampledPeakPhysicalFootprintBytes: UInt64?
    var maximumObservedMLXActiveBytes = 0
    var maximumObservedMLXCacheBytes = 0
    var maximumReportedMLXPeakBytes = 0
    var thermalStatesObserved: [Int] = []
}
private final class DeviceFootprintCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var current = DeviceFootprintSummary()
    var summary: DeviceFootprintSummary { lock.withLock { current } }
    func record(physicalBytes: UInt64?, mlx: QwenMemorySnapshot, thermal: Int) {
        lock.withLock {
            current.samples += 1
            if let physicalBytes { current.sampledPeakPhysicalFootprintBytes = max(current.sampledPeakPhysicalFootprintBytes ?? 0, physicalBytes) }
            current.maximumObservedMLXActiveBytes = max(current.maximumObservedMLXActiveBytes, mlx.activeBytes)
            current.maximumObservedMLXCacheBytes = max(current.maximumObservedMLXCacheBytes, mlx.cacheBytes)
            current.maximumReportedMLXPeakBytes = max(current.maximumReportedMLXPeakBytes, mlx.peakBytes)
            if !current.thermalStatesObserved.contains(thermal) { current.thermalStatesObserved.append(thermal); current.thermalStatesObserved.sort() }
        }
    }
}
private final class DeviceTokenMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    var firstTokenSeconds: Double? { lock.withLock { first } }
    func record(_ value: QwenGenerationProgress) { lock.withLock { if first == nil { first = value.firstTokenSeconds } } }
}
private final class DeviceGenerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var operation: Task<String, Error>?
    private var time: ContinuousClock.Instant?
    var requestedAt: ContinuousClock.Instant? { lock.withLock { time } }
    func assign(_ task: Task<String, Error>) { lock.withLock { operation = task } }
    func clear() { lock.withLock { operation = nil } }
    func cancelAfterFirstToken() {
        let task = lock.withLock { () -> Task<String, Error>? in
            guard time == nil, let operation else { return nil }
            time = .now
            return operation
        }
        task?.cancel()
    }
}

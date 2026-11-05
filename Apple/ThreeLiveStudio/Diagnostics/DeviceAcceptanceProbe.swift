#if DEVICE_QA
import Foundation
import CryptoKit
import Darwin
import RealityKit
import UIKit
import CreationCore
import ThreeLiveNative
import QwenNative

@MainActor
enum DeviceAcceptanceProbe {
    static func run(studio: StudioModel) async {
        guard !studio.busy else { studio.notice = "已有任务正在进行，真机验收尚未开始。"; return }
        studio.busy = true; studio.errorMessage = nil; studio.notice = nil; studio.elapsed = 0
        let started = ContinuousClock.now
        let wasIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                studio.elapsed = Self.seconds(since: started)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer {
            ticker.cancel(); studio.elapsed = Self.seconds(since: started); studio.busy = false
            UIApplication.shared.isIdleTimerDisabled = wasIdleDisabled
        }
        await studio.models.unload()
        let documents = URL.documentsDirectory
        let output = documents.appending(path: "Measurements/app-device-acceptance.json")
        let temporary = FileManager.default.temporaryDirectory.appending(path: "AppDeviceQA-" + UUID().uuidString,
                                                                         directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let engine = QwenEngine()
        let footprints = AcceptanceFootprintCapture()
        let sampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                footprints.record(physicalBytes: Self.physicalFootprint(),
                                  mlx: await engine.memorySnapshot(),
                                  thermal: ProcessInfo.processInfo.thermalState.rawValue)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        var report = AcceptanceReport(modelID: ModelManager.modelID, hardware: Self.hardwareIdentifier(),
                                    os: ProcessInfo.processInfo.operatingSystemVersionString,
                                    physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
        report.noTestRunnerInjected = NSClassFromString("XCTestCase") == nil &&
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil &&
            !(ProcessInfo.processInfo.environment["DYLD_INSERT_LIBRARIES"] ?? "").lowercased().contains("xctest")
        report.optimizedAssertionsConfiguration = !_isDebugAssertConfiguration()
        report.appOptimization = report.optimizedAssertionsConfiguration ? "-O" : "-Onone"
        do {
            try require(!Self.isSimulator, "此验收需要真实 iPhone，不能采用模拟器数据。")
            try require(ProcessInfo.processInfo.physicalMemory >= 11 * 1_024 * 1_024 * 1_024,
                        "此版本验收需要 12GB 或以上内存设备。")
            try require(report.noTestRunnerInjected, "需要直接启动原生 App，不能注入 XCTest 测试运行器。")
            try require(report.optimizedAssertionsConfiguration, "需要使用 -O 优化的真机 App 构建。")
            report.phase = "verifying_local_weights"
            try checkpoint(&report, footprints: footprints, output: output, studio: studio)
            let manifestURL = try unwrap(Bundle.main.url(forResource: "LanguageModel", withExtension: "json"), "App 中缺少模型资源清单。")
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
            try checkpoint(&report, footprints: footprints, output: output, studio: studio)
            let loadStart = ContinuousClock.now
            try await engine.load(modelDirectory: directory)
            report.firstLoadSeconds = Self.seconds(since: loadStart)
            report.memoryStates["after_first_load"] = await engine.memorySnapshot()
            report.footprintStates["after_first_load"] = Self.physicalFootprint()
            try checkpoint(&report, footprints: footprints, output: output, studio: studio)

            for item in Self.cases {
                report.phase = "generating_" + item.id
                try checkpoint(&report, footprints: footprints, output: output, studio: studio)
                let result = try await runCase(item, engine: engine, projectsRoot: temporary)
                report.cases.append(result)
                try checkpoint(&report, footprints: footprints, output: output, studio: studio)
            }

            report.phase = "cancelling_after_first_generated_token"
            report.memoryStates["before_cancellation"] = await engine.memorySnapshot()
            report.footprintStates["before_cancellation"] = Self.physicalFootprint()
            try checkpoint(&report, footprints: footprints, output: output, studio: studio)
            let cancellation = AcceptanceCancellation()
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
                throw AcceptanceProbeError.requirement("A deliberately cancelled inference returned success")
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
            try checkpoint(&report, footprints: footprints, output: output, studio: studio)
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
            report.elapsedSeconds = Self.seconds(since: started)
            studio.notice = "真机验收完成，报告已保存在本机。"
            try checkpoint(&report, footprints: footprints, output: output, studio: studio)
        } catch {
            await engine.unload()
            sampler.cancel()
            await sampler.value
            report.status = "failed"
            report.failure = .init(kind: String(reflecting: type(of: error)),
                                   domain: (error as NSError).domain, code: (error as NSError).code)
            report.memoryStates["after_failure_cleanup"] = await engine.memorySnapshot()
            report.footprintStates["after_failure_cleanup"] = Self.physicalFootprint()
            try? checkpoint(&report, footprints: footprints, output: output, studio: studio)
            studio.stage = "真机验收未完成"
            studio.errorMessage = "验收在“\(report.phase)”阶段未完成：" + error.localizedDescription
        }
    }

    private static func runCase(_ item: AcceptanceCase, engine: QwenEngine, projectsRoot: URL) async throws -> AcceptanceResult {
        let measuredProgress = AcceptanceTokenMeasurement()
        let began = ContinuousClock.now
        let generation = Task {
            try await engine.generateJSON(systemPrompt: ScenePrompt.system,
                                          prompt: ScenePrompt.userRequest(item.prompt), maxTokens: 3_072,
                                          onProgress: { measuredProgress.record($0) })
        }
        let response = try await awaitGeneration(generation, timeoutSeconds: 120)
        let generationSeconds = Self.seconds(since: began)
        // Malformed JSON, duplicate keys, invalid ranges and incomplete scenes are hard failures.
        let scene = try SceneSpec.decodeModelResponse(response)
        try scene.validate()
        let firstToken = try unwrap(measuredProgress.firstTokenSeconds, "未采集到真实首 token 时间。")
        let native = Task.detached(priority: .userInitiated) {
            let geometryStart = ContinuousClock.now
            let meshes = try SceneGenerator.generate(for: scene)
            let geometrySeconds = Self.seconds(since: geometryStart)
            let exportStart = ContinuousClock.now
            let glb = try ThreeLiveNative.exportGLB(meshes)
            let usdz = try ThreeLiveNative.exportUSDZ(meshes)
            return AcceptanceArtifacts(glb: glb, usdz: usdz, meshCount: meshes.count,
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
        let project = try unwrap(listed.first { $0.id == published.project.id }, "重新打开后未找到刚保存的作品。")
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
        return AcceptanceResult(id: item.id, validSchema: true, scene: scene, nodeCount: scene.nodes.count,
            firstTokenSeconds: firstToken, generationSeconds: generationSeconds,
            geometrySeconds: files.geometrySeconds, exportSeconds: files.exportSeconds,
            persistenceAndReopenSeconds: persistenceSeconds, realityKitLoadSeconds: Self.seconds(since: realityStart),
            meshCount: files.meshCount, vertices: files.vertices, triangles: files.triangles,
            glbBytes: files.glb.count, usdzBytes: files.usdz.count,
            glbSHA256: project.glbSHA256, usdzSHA256: project.usdzSHA256,
            realityKitBoundsMetres: extents, mlx: await engine.memorySnapshot(),
            physicalFootprintBytes: Self.physicalFootprint(), thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }

    private static func awaitGeneration(_ operation: Task<String, Error>, timeoutSeconds: Int) async throws -> String {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await operation.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    throw AcceptanceProbeError.timeout
                }
                defer { group.cancelAll(); operation.cancel() }
                return try await group.next()!
            }
        } onCancel: { operation.cancel() }
    }

    private static func checkpoint(_ report: inout AcceptanceReport, footprints: AcceptanceFootprintCapture, output: URL, studio: StudioModel) throws {
        report.footprints = footprints.summary
        report.elapsedSeconds = studio.elapsed
        studio.stage = phaseTitle(report.phase)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output, options: .atomic)
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw AcceptanceProbeError.requirement(message) }
        return value
    }

    private static func phaseTitle(_ phase: String) -> String {
        switch phase {
        case "verifying_local_weights": return "真机验收：校验本地模型"
        case "first_model_load_after_hash_verification": return "真机验收：载入本机 AI"
        case "generating_chair": return "真机验收：造型 1 / 3"
        case "generating_robot": return "真机验收：造型 2 / 3"
        case "generating_lamp": return "真机验收：造型 3 / 3"
        case "cancelling_after_first_generated_token": return "真机验收：取消与释放内存"
        case "reload_after_cancel_and_unload": return "真机验收：重新载入与生成"
        case "complete": return "真机验收完成"
        default: return "真机验收进行中"
        }
    }

    private static func require(_ valid: Bool, _ message: String) throws {
        guard valid else { throw AcceptanceProbeError.requirement(message) }
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

    private static let cases: [AcceptanceCase] = [
        .init(id: "chair", prompt: "一把简洁的棕色木椅，必须包含坐面、靠背和四条腿，地面Y=0，坐面高度约0.45米，不要增加底部平台。"),
        .init(id: "robot", prompt: "做一个站立的蓝色玩具机器人，包含立方体头、躯干、左右两条手臂和两条腿，以及两个球形黄色眼睛，底部在Y=0。"),
        .init(id: "lamp", prompt: "做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。")
    ]
}

private enum AcceptanceProbeError: LocalizedError {
    case timeout
    case requirement(String)
    var errorDescription: String? {
        switch self {
        case .timeout: return "Physical-device generation exceeded its 120-second limit"
        case .requirement(let message): return message
        }
    }
}

private struct AcceptanceCase: Sendable { let id: String; let prompt: String }
private struct AcceptanceArtifacts: Sendable {
    let glb: Data; let usdz: Data; let meshCount: Int; let vertices: Int; let triangles: Int
    let geometrySeconds: Double; let exportSeconds: Double
}
private struct AcceptanceResult: Encodable {
    let id: String; let validSchema: Bool; let scene: SceneSpec; let nodeCount: Int
    let firstTokenSeconds: Double; let generationSeconds: Double; let geometrySeconds: Double
    let exportSeconds: Double; let persistenceAndReopenSeconds: Double; let realityKitLoadSeconds: Double
    let meshCount: Int; let vertices: Int; let triangles: Int; let glbBytes: Int; let usdzBytes: Int
    let glbSHA256: String; let usdzSHA256: String; let realityKitBoundsMetres: [Float]
    let mlx: QwenMemorySnapshot; let physicalFootprintBytes: UInt64?; let thermalState: Int
}
private struct AcceptanceFailure: Encodable { let kind: String; let domain: String; let code: Int }
private struct AcceptanceReport: Encodable {
    let schemaVersion = 1
    var appOptimization = "-Onone"
    let qaCompilationFlag = "DEVICE_QA"
    let qaCompilationFlagEnabled = true
    var noTestRunnerInjected = false
    var optimizedAssertionsConfiguration = false
    var elapsedSeconds: Double = 0
    let runID = UUID().uuidString
    let appVersion = Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"
    let appBuild = Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown"
    let measuredAt = ISO8601DateFormatter().string(from: .now)
    let scope = "Optimized native iPhone App; local-only model API after streaming hash verification. Fixed structural prompts do not prove every subject. System network radios were not disabled by this probe; flight-mode acceptance is separate."
    let loadCacheNote = "First model load in this probe follows streaming hash verification, which may warm filesystem caches; it is not a cold-storage benchmark."
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
    var cases: [AcceptanceResult] = []
    var reloadCase: AcceptanceResult?
    var cancellationObserved = false
    var cancellationAfterFirstToken = false
    var cancellationSettleSeconds: Double?
    var cancellationUnloadSeconds: Double?
    var mlxActiveBytesReleasedAfterCancellation: Int?
    var memoryStates: [String: QwenMemorySnapshot] = [:]
    var footprintStates: [String: UInt64] = [:]
    var footprints = AcceptanceFootprintSummary()
    var failure: AcceptanceFailure?
}
private struct AcceptanceFootprintSummary: Encodable {
    let sampleIntervalSeconds = 0.1
    var samples = 0
    var sampledPeakPhysicalFootprintBytes: UInt64?
    var maximumObservedMLXActiveBytes = 0
    var maximumObservedMLXCacheBytes = 0
    var maximumReportedMLXPeakBytes = 0
    var thermalStatesObserved: [Int] = []
}
private final class AcceptanceFootprintCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var current = AcceptanceFootprintSummary()
    var summary: AcceptanceFootprintSummary { lock.withLock { current } }
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
private final class AcceptanceTokenMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Double?
    var firstTokenSeconds: Double? { lock.withLock { first } }
    func record(_ value: QwenGenerationProgress) { lock.withLock { if first == nil { first = value.firstTokenSeconds } } }
}
private final class AcceptanceCancellation: @unchecked Sendable {
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

#endif

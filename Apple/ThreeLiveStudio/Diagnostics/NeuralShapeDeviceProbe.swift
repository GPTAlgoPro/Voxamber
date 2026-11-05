#if DEVICE_QA
import Foundation
import CryptoKit
import Darwin
import os
import VoxamberShapeNative

/// Opt-in Release-only physical-device stage gate. No existing projects or
/// models are changed. This is a shape-stage measurement, not text-to-3D proof.
@MainActor protocol NeuralShapeProbeState: AnyObject, Sendable {
    var busy: Bool { get set }
    var errorMessage: String? { get set }
    var notice: String? { get set }
    var stage: String { get set }
    var elapsed: TimeInterval { get set }
}

private enum ShapeProbeError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

@MainActor enum NeuralShapeDeviceProbe {
    static func run(studio: any NeuralShapeProbeState) async {
        guard !studio.busy else { return }
        studio.busy = true; studio.errorMessage = nil; studio.notice = nil
        let began = Date(), runID = UUID()
        let root = URL.documentsDirectory.appending(path: "NeuralShapeQA")
        let output = URL.documentsDirectory.appending(path: "Measurements/shape-device-" + runID.uuidString)
        let journal = ShapeDeviceJournal(output: output, runID: runID)
        let engine = ShapeEngine(weightProfile: .rebuiltQ4Candidate)
        let timer = Task { @MainActor in
            while !Task.isCancelled {
                studio.elapsed = Date().timeIntervalSince(began)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        let sampler = Task.detached(priority: .utility) {
            var tick = 0
            while !Task.isCancelled {
                journal.sample()
                tick += 1
                if tick.isMultiple(of: 4) { journal.flush() }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { timer.cancel(); studio.elapsed = Date().timeIntervalSince(began); studio.busy = false }
        do {
            #if targetEnvironment(simulator)
            throw ShapeProbeError.message("此项验收需要真实 iPhone。")
            #endif
            guard !_isDebugAssertConfiguration(), ProcessInfo.processInfo.physicalMemory >= 12_000_000_000,
                  NSClassFromString("XCTestCase") == nil else {
                throw ShapeProbeError.message("需要优化构建、12GB iPhone 和直接启动的 App。")
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let png = try Data(contentsOf: root.appending(path: "input-512.png"))
            let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            guard sha == "1bcadef55c9795d68cbce576cf57eabd7d6b7b87a22ba048c6fba8f7ca6521ae" else {
                throw ShapeProbeError.message("诊断输入与已校验参考图不一致。")
            }
            journal.begin(inputSHA: sha)
            studio.stage = "正在验证真机三维生成"
            let result = try await engine.generate(pngData: png,
                shapePackURL: root.appending(path: "model.q4.safetensors"),
                configurationYAML: HunyuanShape21Configuration.bundledYAML, seed: 24301,
                onProgress: { progress in
                    journal.progress(progress)
                    Task { @MainActor in
                        if studio.busy { studio.stage = "三维形体 · \(Int(progress.fraction * 100))%" }
                    }
                })
            await engine.unload()
            let artifacts = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try result.glbData.write(to: output.appending(path: "model.glb"), options: .atomic)
                try Task.checkCancellation()
                try result.usdzData.write(to: output.appending(path: "model.usdz"), options: .atomic)
                try encoder.encode(result.provenance).write(to: output.appending(path: "provenance.json"), options: .atomic)
                try encoder.encode(result.statistics).write(to: output.appending(path: "statistics.json"), options: .atomic)
                try encoder.encode(result.validationReceipt).write(to: output.appending(path: "receipt.json"), options: .atomic)
                try Task.checkCancellation()
            }
            try await withTaskCancellationHandler { try await artifacts.value } onCancel: { artifacts.cancel() }
            try Task.checkCancellation()
            journal.finish(status: "shape-exported-pending-visual-review", result: result)
            studio.stage = "真机三维生成已完成"; studio.notice = "三维阶段诊断完成，等待外观及全流程验收。"
        } catch {
            await engine.unload()
            journal.fail(error)
            studio.stage = error is CancellationError ? "已取消" : "未完成"
            studio.errorMessage = error.localizedDescription
        }
        sampler.cancel(); await sampler.value
        journal.sample(); journal.flush()
    }
}

private final class ShapeDeviceJournal: @unchecked Sendable {
    private let lock = NSLock()
    private let output: URL
    private let began = Date()
    private var peak: UInt64 = 0
    private var samples = 0
    private var entries: [[String: Any]] = []
    private var report: [String: Any]
    init(output: URL, runID: UUID) {
        self.output = output
        report = ["formatVersion": 1, "runID": runID.uuidString, "status": "preflight",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "platform": "physical-iPhone-stage-gate", "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "OS": ProcessInfo.processInfo.operatingSystemVersionString, "steps": 10, "latents": 4096,
            "octreeResolution": 192, "moeTokenChunkSize": 512, "seed": 24301,
            "candidateSHA256": HunyuanShape21WeightProfile.rebuiltQ4Candidate.modelPackSHA256,
            "fullPipelineAccepted": false, "existingProjectsChanged": false, "automaticCancellation": false]
    }
    func begin(inputSHA: String) { lock.withLock { report["inputPNG_SHA256"] = inputSHA }; flush() }
    func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard code == KERN_SUCCESS else { return }
        lock.withLock {
            peak = max(peak, info.phys_footprint); samples += 1
            report["lastPhysicalBytes"] = info.phys_footprint
            report["lastAvailableProcessBytes"] = UInt64(os_proc_available_memory())
            report["thermalState"] = ProcessInfo.processInfo.thermalState.rawValue
        }
    }
    func progress(_ progress: ShapeProgress) {
        sample()
        lock.withLock {
            entries.append(["stage": progress.stage, "fraction": progress.fraction, "seconds": Date().timeIntervalSince(began),
                "physicalBytes": report["lastPhysicalBytes"] ?? 0,
                "availableProcessBytes": report["lastAvailableProcessBytes"] ?? 0])
            report["status"] = "running"
        }
        flush()
    }
    func finish(status: String, result: ShapeResult) {
        lock.withLock {
            report["status"] = status; report["vertices"] = result.mesh.vertexCount
            report["triangles"] = result.mesh.triangleCount
            report["actualNeuralWeightsUsed"] = result.validationReceipt.actualNeuralWeightsUsed
        }
    }
    func fail(_ error: Error) {
        lock.withLock { report["status"] = error is CancellationError ? "cancelled" : "failed"; report["error"] = error.localizedDescription }
    }
    func flush() {
        lock.withLock {
            report["seconds"] = Date().timeIntervalSince(began); report["observedPhysicalPeakBytes"] = peak
            report["physicalSampleCount"] = samples; report["samplerIntervalSeconds"] = 0.25; report["stages"] = entries
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appending(path: "report.json"), options: .atomic)
            } catch { /* Diagnostics do not alter any project. */ }
        }
    }
}
#endif

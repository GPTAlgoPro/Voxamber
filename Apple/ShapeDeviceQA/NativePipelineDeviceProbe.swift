#if DEVICE_QA
import Foundation
import CryptoKit
import Darwin
import os
import ImageIO
import VoxamberCreationNative
import VoxamberShapeNative

/// Explicit diagnostic only. Root's QA App owns launch permission, keep-awake
/// and its outer Task. This never publishes a normal project or imports models.
@MainActor enum NativePipelineDeviceProbe {
    static func run(studio: any NeuralShapeProbeState) async {
        guard !Task.isCancelled, !studio.busy else { return }
        studio.busy = true; studio.errorMessage = nil; studio.notice = nil
        studio.elapsed = 0; studio.stage = "准备完整原生流程诊断"
        let output = URL.documentsDirectory.appending(path: "Measurements/full-native-" + UUID().uuidString)
        let owner = FullNativeProbeOwner(), engine = NativeCreationEngine()
        let journal: FullNativeProbeJournal
        do { journal = try FullNativeProbeJournal(output: output, owner: owner) }
        catch {
            studio.busy = false; studio.stage = "诊断记录未能创建"; studio.errorMessage = error.localizedDescription
            return
        }
        let contractURL = Bundle.main.url(forResource: "IntentQwen08", withExtension: "json", subdirectory: "NeuralModels")
            ?? Bundle.main.url(forResource: "IntentQwen08", withExtension: "json")
        let intentRoot = URL.documentsDirectory.appending(path: "NeuralIntentQA", directoryHint: .isDirectory)
        let imageRoot = URL.documentsDirectory.appending(path: "NeuralFluxQA", directoryHint: .isDirectory)
        let shapeFile = URL.documentsDirectory.appending(path: "NeuralShapeQA/model.q4.safetensors")
        let timer = Task { @MainActor in
            while !Task.isCancelled {
                studio.elapsed = journal.elapsed
                studio.stage = journal.displayStage
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
            }
        }
        let sampler = Task.detached(priority: .utility) {
            var tick = 0
            while !Task.isCancelled {
                journal.sample(); tick += 1
                if tick.isMultiple(of: 4) { journal.flush() }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
        }
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            #if targetEnvironment(simulator)
            throw FullNativeProbeError.message("完整流程诊断需要真实 iPhone。")
            #endif
            guard !_isDebugAssertConfiguration(), ProcessInfo.processInfo.physicalMemory >= 12_000_000_000,
                  NSClassFromString("XCTestCase") == nil else {
                throw FullNativeProbeError.message("需要优化构建、12GB iPhone 和直接启动的诊断 App。")
            }
            guard let contractURL else { throw FullNativeProbeError.message("诊断包缺少固定 IntentQwen08 清单。") }
            journal.setState("verifying-intent", display: "正在逐文件校验构想模型")
            try FullNativeIntentContract.verify(directory: intentRoot, contractURL: contractURL, journal: journal)
            try Task.checkCancellation()
            guard !journal.hasIOFailure else { throw FullNativeProbeError.message("诊断记录写入失败，未启动模型。") }
            journal.markAPICall()
            return try await engine.generate(prompt: FullNativeProbeConstants.request, seed: FullNativeProbeConstants.seed,
                resources: CreationResources(intentModelDirectory: intentRoot, imageModelDirectory: imageRoot,
                    shapeModelFile: shapeFile, imageBackend: .klein4B),
                onProgress: { journal.progress($0) }, onReferenceImage: { journal.reference($0) })
        }
        owner.install(operation)
        let watchdog = Task.detached(priority: .utility) {
            do { try await Task.sleep(for: .seconds(900)) } catch { return }
            owner.cancel(); journal.markTimeout()
        }
        let outcome = await withTaskCancellationHandler { await operation.result } onCancel: { owner.cancel() }
        watchdog.cancel(); await watchdog.value
        journal.setState("unloading", display: "正在收束模型资源")
        await engine.cancel(); await engine.unload()
        let stillRunning = await engine.isRunning
        journal.recordCleanup(stillRunning: stillRunning, cancellationObserved: owner.isCancelled || Task.isCancelled)
        var failure: Error?
        switch outcome {
        case .failure(let error): failure = error
        case .success(let result):
            // Preserve the first actual result before checking the contract.
            // This independent diagnostic directory is never a published work.
            let persistence = Task.detached(priority: .utility) {
                try FullNativeProbeArtifacts.persist(result, output: output, journal: journal)
            }
            do {
                try await withTaskCancellationHandler { try await persistence.value } onCancel: { persistence.cancel() }
                try Task.checkCancellation()
                guard !owner.isCancelled, !stillRunning, !journal.hasIOFailure else {
                    throw FullNativeProbeError.message("本次诊断取消、清理或记录检查未通过。")
                }
            } catch { failure = error }
        }
        if failure == nil, journal.hasIOFailure { failure = FullNativeProbeError.message("诊断记录写入失败。") }
        if failure == nil, stillRunning { failure = FullNativeProbeError.message("模型任务清理后仍在运行。") }
        if failure == nil, owner.isCancelled || Task.isCancelled { failure = CancellationError() }
        if let failure { journal.fail(failure) }
        else { journal.setState("exported-pending-independent-review", display: "完整流程已返回，等待独立验收") }
        sampler.cancel(); await sampler.value
        timer.cancel(); await timer.value
        journal.sample(); journal.flush(); journal.close()
        studio.elapsed = journal.elapsed
        studio.busy = false
        if let failure {
            studio.stage = failure is CancellationError ? "诊断已取消" : "诊断未完成"
            studio.errorMessage = failure.localizedDescription
        } else if journal.hasIOFailure {
            studio.stage = "诊断记录未完成"; studio.errorMessage = "诊断结果写入失败，不能视为验收通过。"
        } else {
            studio.stage = "完整流程已返回"
            studio.notice = "真实图像和三维原物已保留。文件、外观、内存与手机可用性需独立验收。"
        }
    }
}

private enum FullNativeProbeConstants {
    static let request = "做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。"
    static let seed: UInt64 = 24301
    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
private enum FullNativeProbeError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}
private final class FullNativeProbeOwner: @unchecked Sendable {
    private let lock = NSLock(); private var operation: Task<NativeCreationResult, Error>?; private var cancelled = false
    func install(_ task: Task<NativeCreationResult, Error>) {
        lock.lock(); operation = task; let shouldCancel = cancelled; lock.unlock()
        if shouldCancel { task.cancel() }
    }
    func cancel() { lock.lock(); cancelled = true; let task = operation; lock.unlock(); task?.cancel() }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// No App Models dependency. Only the bundled exact intent contract is decoded.
private struct FullNativeIntentContract: Decodable {
    struct File: Decodable { let path: String; let byteCount: Int64; let sha256: String }
    let formatVersion: Int; let group: String; let id: String; let files: [File]
    static func verify(directory: URL, contractURL: URL, journal: FullNativeProbeJournal) throws {
        try Task.checkCancellation()
        let size = try contractURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard (1...262_144).contains(size) else { throw FullNativeProbeError.message("构想模型清单大小无效。") }
        let data = try Data(contentsOf: contractURL), contract = try JSONDecoder().decode(Self.self, from: data)
        guard contract.formatVersion == 1, contract.group == "intent", contract.id == "qwen3.5-0.8b-mlx-int4",
              contract.files.count == 10, directory.isFileURL else { throw FullNativeProbeError.message("构想模型清单不匹配。") }
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw FullNativeProbeError.message("构想模型目录缺失或不安全。") }
        defer { Darwin.close(root) }
        var seen = Set<String>()
        for row in contract.files {
            try Task.checkCancellation()
            let parts = row.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !row.path.hasPrefix("/"), !row.path.contains("\\"), !row.path.contains("%"),
                  !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !row.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(row.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  row.byteCount > 0, row.byteCount <= 16 * 1_024 * 1_024 * 1_024,
                  row.sha256.count == 64, row.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                throw FullNativeProbeError.message("构想模型文件条目无效。")
            }
            var parent = dup(root)
            guard parent >= 0 else { throw FullNativeProbeError.message("无法读取构想模型目录。") }
            defer { Darwin.close(parent) }
            for part in parts.dropLast() {
                let child = openat(parent, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw FullNativeProbeError.message("构想模型路径缺失或不安全。") }
                Darwin.close(parent); parent = child
            }
            let file = openat(parent, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard file >= 0 else { throw FullNativeProbeError.message("构想模型文件缺失或不安全。") }
            defer { Darwin.close(file) }
            var before = stat()
            guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size == row.byteCount else {
                throw FullNativeProbeError.message("构想模型文件大小或类型不匹配。")
            }
            var hasher = SHA256(), bytes: Int64 = 0, buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(file, &buffer, buffer.count)
                guard count >= 0 else { throw FullNativeProbeError.message("构想模型文件读取失败。") }
                if count == 0 { break }
                bytes += Int64(count)
                guard bytes <= row.byteCount else { throw FullNativeProbeError.message("构想模型文件读取期间发生变化。") }
                autoreleasepool { hasher.update(data: Data(buffer.prefix(count))) }
            }
            var after = stat()
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard bytes == row.byteCount, digest == row.sha256, fstat(file, &after) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
                throw FullNativeProbeError.message("构想模型完整 SHA 校验未通过。")
            }
            journal.intentFileVerified(path: row.path, bytes: bytes, sha256: digest)
        }
        journal.intentContractVerified(sha256: FullNativeProbeConstants.sha(data))
    }
}

private enum FullNativeProbeArtifacts {
    static func persist(_ value: NativeCreationResult, output: URL, journal: FullNativeProbeJournal) throws {
        // Deliberately finish first-result diagnostic retention even if this
        // owned worker is cancelled. It is always awaited and never publishes.
        try FullNativeProbeConstants.encode(value.intent, to: output.appending(path: "intent.json"))
        try FullNativeProbeConstants.encode(value.imageStage, to: output.appending(path: "actual-image-stage.json"))
        try value.referencePNG.write(to: output.appending(path: "reference-returned-512.png"), options: .atomic)
        try value.preparedReference.pngData.write(to: output.appending(path: "prepared-512-rgba.png"), options: .atomic)
        try value.shape.glbData.write(to: output.appending(path: "model.glb"), options: .atomic)
        try value.shape.usdzData.write(to: output.appending(path: "model.usdz"), options: .atomic)
        try value.shape.baseMeshData.write(to: output.appending(path: "base.glb"), options: .atomic)
        try FullNativeProbeConstants.encode(value.shape.provenance, to: output.appending(path: "shape-provenance.json"))
        try FullNativeProbeConstants.encode(value.shape.statistics, to: output.appending(path: "shape-statistics.json"))
        try FullNativeProbeConstants.encode(value.shape.validationReceipt, to: output.appending(path: "shape-validation-receipt.json"))
        journal.returned(value)
        let expected = CreationImageBackend.klein4B.receipt(requestedSeed: FullNativeProbeConstants.seed)
        let referenceSize = try pngSize(value.referencePNG), preparedSize = try pngSize(value.preparedReference.pngData)
        let referenceHash = FullNativeProbeConstants.sha(value.referencePNG), preparedHash = FullNativeProbeConstants.sha(value.preparedReference.pngData)
        let glbHash = FullNativeProbeConstants.sha(value.shape.glbData), usdzHash = FullNativeProbeConstants.sha(value.shape.usdzData)
        journal.recordArtifacts(referenceSHA: referenceHash, preparedSHA: preparedHash, glbSHA: glbHash, usdzSHA: usdzHash,
            referenceSize: referenceSize, preparedSize: preparedSize, prepared: value.preparedReference)
        guard value.seed == FullNativeProbeConstants.seed, value.imageStage == expected,
              journal.referenceMatches(referenceHash), referenceSize == [512, 512], preparedSize == [512, 512],
              value.shape.validationReceipt.actualNeuralWeightsUsed, value.shape.validationReceipt.nativeGeometryValidated,
              value.shape.provenance.inputPNG_SHA256 == preparedHash,
              value.shape.provenance.modelPackSHA256 == HunyuanShape21WeightProfile.rebuiltQ4Candidate.modelPackSHA256,
              value.shape.provenance.geometryPostprocessID == "finite-positive-f64-v1",
              value.shape.validationReceipt.glbSHA256 == glbHash, value.shape.validationReceipt.usdzSHA256 == usdzHash else {
            throw FullNativeProbeError.message("实际返回物已保留，但完整流程合同检查未通过。")
        }
        journal.recordContractPassed()
    }
    private static func pngSize(_ data: Data) throws -> [Int] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw FullNativeProbeError.message("实际返回的图片无法解码。") }
        return [image.width, image.height]
    }
}

private final class FullNativeProbeJournal: @unchecked Sendable {
    private let lock = NSLock(), owner: FullNativeProbeOwner
    private let output: URL, memoryFile: FileHandle
    private let start = ProcessInfo.processInfo.systemUptime
    private var report: [String: Any], stages: [[String: Any]] = [], verifiedIntent: [[String: Any]] = []
    private var display = "准备完整原生流程诊断", phase = "preflight", failure: String?, referenceHashes: [String] = []
    private var peak: UInt64 = 0, minimumAvailable = UInt64.max, samples = 0
    private var lastSampleTime: Double?, maximumGap = 0.0
    init(output: URL, owner: FullNativeProbeOwner) throws {
        self.output = output; self.owner = owner
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let memoryURL = output.appending(path: "memory.ndjson")
        guard FileManager.default.createFile(atPath: memoryURL.path, contents: nil) else { throw FullNativeProbeError.message("无法创建内存记录。") }
        memoryFile = try FileHandle(forWritingTo: memoryURL)
        report = ["formatVersion": 1, "runID": output.lastPathComponent, "status": "preflight",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown", "OS": ProcessInfo.processInfo.operatingSystemVersionString,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory, "platform": "physical-iPhone-full-public-pipeline-diagnostic",
            "entryPoint": "NativeCreationEngine.generate", "imageBackend": "flux2-klein4b-q4", "seed": FullNativeProbeConstants.seed,
            "requestSHA256": FullNativeProbeConstants.sha(Data(FullNativeProbeConstants.request.utf8)), "APIRequests": 0,
            "retries": 0, "fallbacks": 0, "watchdogSeconds": 900, "watchdogIsCooperativeNotHardDeadline": true,
            "watchdogTriggered": false,
            "physicalSampleIntervalSeconds": 0.25, "reportPersistenceIntervalSeconds": 1,
            "MLXCountersReadByProbe": false, "normalProjectsPublished": 0, "existingProjectsChanged": false,
            "fullQualityAccepted": false, "phonePerformanceAccepted": false,
            "failedCallObservability": "Public progress/reference only; intent/prepared unavailable without returned result."]
        try Data(FullNativeProbeConstants.request.utf8).write(to: output.appending(path: "fixed-request.txt"), options: .atomic)
        try Self.writeJSON(report, to: output.appending(path: "report.json"))
    }
    var elapsed: TimeInterval { ProcessInfo.processInfo.systemUptime - start }
    var displayStage: String { lock.withLock { display } }
    var hasIOFailure: Bool { lock.withLock { failure != nil } }
    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private func failIO(_ error: Error) { failure = String(reflecting: type(of: error)); owner.cancel() }
    func setState(_ state: String, display: String) { lock.withLock { phase = state; report["status"] = state; self.display = display }; flush() }
    func markAPICall() { lock.withLock { report["APIRequests"] = 1 }; flush() }
    func intentFileVerified(path: String, bytes: Int64, sha256: String) {
        lock.withLock { verifiedIntent.append(["path": path, "byteCount": bytes, "sha256": sha256]); report["verifiedIntentFiles"] = verifiedIntent }
    }
    func intentContractVerified(sha256: String) { lock.withLock { report["intentContractSHA256"] = sha256; report["intentFullSHAVerified"] = true }; flush() }
    func progress(_ value: CreationProgress) {
        let title: String
        switch value.phase {
        case .interpreting: title = "正在理解原始中文请求"
        case .drawingReference: title = "正在生成真实参考图"
        case .preparingSubject: title = "正在提取真实前景"
        case .generatingShape: title = "正在生成真实三维形体"
        case .complete: title = "正在保留实际返回物"
        }
        lock.withLock {
            phase = value.phase.rawValue; display = title; report["status"] = "running"
            var entry: [String: Any] = ["phase": phase, "seconds": elapsed]
            if let n = value.completedSteps { entry["completedSteps"] = n }; if let n = value.totalSteps { entry["totalSteps"] = n }
            if let n = value.fraction, n.isFinite { entry["fraction"] = n }
            stages.append(entry)
        }
        flush()
    }
    func reference(_ data: Data) {
        lock.withLock {
            do {
                guard referenceHashes.isEmpty else { throw FullNativeProbeError.message("参考图回调次数异常。") }
                try data.write(to: output.appending(path: "reference-callback-512.png"), options: .atomic)
                referenceHashes.append(FullNativeProbeConstants.sha(data)); report["referenceCallbackSHA256"] = referenceHashes[0]
                report["referenceCallbackBytes"] = data.count; report["referenceCallbackCount"] = referenceHashes.count
            } catch { failIO(error) }
        }
        flush()
    }
    func referenceMatches(_ sha256: String) -> Bool { lock.withLock { referenceHashes == [sha256] } }
    func markTimeout() { lock.withLock { report["watchdogTriggered"] = true }; flush() }
    func recordCleanup(stillRunning: Bool, cancellationObserved: Bool) {
        lock.withLock { report["engineRunningAfterUnload"] = stillRunning; report["cancellationObservedBeforeArtifactRetention"] = cancellationObserved }
        sample(); flush()
    }
    func returned(_ value: NativeCreationResult) {
        lock.withLock {
            report["actualReturnedArtifactsRetainedBeforeContractValidation"] = true; report["actualReturnedSeed"] = value.seed
            report["stageSeconds"] = value.stageSeconds; report["vertices"] = value.shape.mesh.vertexCount
            report["triangles"] = value.shape.mesh.triangleCount; report["actualNeuralWeightsUsed"] = value.shape.validationReceipt.actualNeuralWeightsUsed
            report["physicalScaleKnown"] = value.shape.provenance.physicalScaleKnown
        }
        flush()
    }
    func recordArtifacts(referenceSHA: String, preparedSHA: String, glbSHA: String, usdzSHA: String,
                         referenceSize: [Int], preparedSize: [Int], prepared: PreparedShapeReference) {
        lock.withLock {
            report["returnedReferenceSHA256"] = referenceSHA; report["preparedSHA256"] = preparedSHA
            report["glbSHA256"] = glbSHA; report["usdzSHA256"] = usdzSHA
            report["referenceSize"] = referenceSize; report["preparedSize"] = preparedSize
            report["preparationMethod"] = prepared.method; report["sourceWidth"] = prepared.sourceWidth
            report["sourceHeight"] = prepared.sourceHeight; report["foregroundBoundsCI"] = prepared.foregroundBounds
            report["referenceCallbackMatchesReturnedBytes"] = referenceHashes == [referenceSHA]
        }
        flush()
    }
    func recordContractPassed() { lock.withLock { report["returnedResultContractPassed"] = true }; flush() }
    func fail(_ error: Error) {
        lock.withLock { report["status"] = error is CancellationError ? "cancelled" : "failed"; report["errorType"] = String(reflecting: type(of: error)); report["error"] = error.localizedDescription }
    }
    func sample() {
        var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        } }
        let available = UInt64(os_proc_available_memory()), time = elapsed
        lock.withLock {
            var row: [String: Any] = ["seconds": time, "phase": phase, "availableProcessBytes": available,
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
            if result == KERN_SUCCESS { row["physicalBytes"] = info.phys_footprint; peak = max(peak, info.phys_footprint); report["lastPhysicalBytes"] = info.phys_footprint }
            minimumAvailable = min(minimumAvailable, available); report["lastAvailableProcessBytes"] = available
            if let lastSampleTime { maximumGap = max(maximumGap, time - lastSampleTime) }; lastSampleTime = time; samples += 1
            do { var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]); data.append(10); try memoryFile.write(contentsOf: data) }
            catch { failIO(error) }
        }
    }
    func flush() {
        lock.withLock {
            report["seconds"] = elapsed; report["stages"] = stages; report["observedPhysicalPeakBytes"] = peak
            report["minimumAvailableProcessBytes"] = minimumAvailable == UInt64.max ? 0 : minimumAvailable
            report["physicalSampleCount"] = samples; report["maximumActualSampleGapSeconds"] = maximumGap
            if let failure { report["telemetryIOFailure"] = failure; report["status"] = "failed-telemetry-IO" }
            do { try memoryFile.synchronize(); try Self.writeJSON(report, to: output.appending(path: "report.json")) }
            catch { failIO(error) }
        }
    }
    func close() {
        lock.withLock {
            do { try memoryFile.synchronize(); try memoryFile.close() } catch { failIO(error) }
            if let failure { report["telemetryIOFailure"] = failure; report["status"] = "failed-telemetry-IO" }
            do { try Self.writeJSON(report, to: output.appending(path: "report.json")) } catch { failIO(error) }
        }
    }
}
#endif

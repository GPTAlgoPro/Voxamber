import Foundation
import CryptoKit
import Darwin
import CoreImage
import ImageIO
import MLX
import VoxamberCreationNative
import VoxamberShapeNative

private let request = "做一盏台灯：红色圆锥灯罩，灰色圆柱底座，细圆柱支杆，可以加一个球形灯泡。底座落地Y=0，整体高约0.8米。"
private let seed: UInt64 = 24301
private enum GateError: Error { case usage, pinMismatch(String), existingOutput, failed }
private struct Pin: Codable { let group: String; let relativePath: String; let byteCount: Int64; let sha256: String }
private struct SourceSnapshot: Decodable { struct File: Decodable { let package: String; let path: String; let bytes: Int; let sha256: String }; let files: [File] }
private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func fingerprint(_ url: URL) throws -> (Int64, String) {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hasher = SHA256(), count: Int64 = 0
    while true {
        let n = try autoreleasepool {
            guard let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty else { return 0 }
            count += Int64(data.count); hasher.update(data: data); return data.count
        }
        if n == 0 { break }
    }
    return (count, hasher.finalize().map { String(format: "%02x", $0) }.joined())
}
private func json(_ value: [String: Any], _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}
private func encode<T: Encodable>(_ value: T, _ url: URL) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
}
private func footprint() -> UInt64? {
    var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    } }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
}
private func pngSummary(_ data: Data, alpha: Bool = false) throws -> [String: Any] {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw GateError.failed }
    var result: [String: Any] = ["width": image.width, "height": image.height, "bytes": data.count, "sha256": sha(data)]
    if alpha {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        context.render(CIImage(cgImage: image), toBitmap: &rgba, rowBytes: image.width * 4,
            bounds: CGRect(x: 0, y: 0, width: image.width, height: image.height), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var zero = 0, opaque = 0
        for i in stride(from: 3, to: rgba.count, by: 4) { if rgba[i] == 0 { zero += 1 }; if rgba[i] == 255 { opaque += 1 } }
        result["zeroAlphaPixels"] = zero; result["opaqueAlphaPixels"] = opaque
        result["partialAlphaPixels"] = image.width * image.height - zero - opaque
        result["diagnosticOnlyNoPixelModification"] = true
    }
    return result
}
private final class Owner: @unchecked Sendable {
    private let lock = NSLock(); private var task: Task<NativeCreationResult, Error>?; private var cancelled = false
    func set(_ value: Task<NativeCreationResult, Error>) { lock.lock(); task = value; let c = cancelled; lock.unlock(); if c { value.cancel() } }
    func cancel() { lock.lock(); cancelled = true; let value = task; lock.unlock(); value?.cancel() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
private final class Telemetry: @unchecked Sendable {
    let start = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock(), owner: Owner
    private let directory: URL, eventFile: FileHandle, memoryFile: FileHandle
    private var phase = "beforePublicAPI", runtimeObserved = false, timeout = false, failure: String?
    private var samples: [[String: Any]] = [], events: [[String: Any]] = [], referenceHashes: [String] = []
    init(_ directory: URL, owner: Owner) throws {
        self.directory = directory; self.owner = owner
        let event = directory.appending(path: "events.ndjson"), memory = directory.appending(path: "memory.ndjson")
        guard FileManager.default.createFile(atPath: event.path, contents: nil), FileManager.default.createFile(atPath: memory.path, contents: nil) else { throw GateError.failed }
        eventFile = try FileHandle(forWritingTo: event); memoryFile = try FileHandle(forWritingTo: memory)
    }
    private func line(_ value: [String: Any], _ file: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]); data.append(10); try file.write(contentsOf: data)
    }
    private func fail(_ error: Error) { failure = String(reflecting: type(of: error)); owner.cancel() }
    private func current() -> [String: Any] {
        lock.lock(); let p = phase, touched = runtimeObserved; lock.unlock()
        var row: [String: Any] = ["elapsed": ProcessInfo.processInfo.systemUptime - start, "phase": p]
        if let n = footprint() { row["physFootprintBytes"] = n }
        if touched { row["mlxActiveBytes"] = Memory.activeMemory; row["mlxCacheBytes"] = Memory.cacheMemory; row["mlxPeakCounterBytes"] = Memory.peakMemory }
        return row
    }
    func event(_ value: CreationProgress) {
        lock.lock(); let changed = phase != value.phase.rawValue; phase = value.phase.rawValue; runtimeObserved = true; lock.unlock()
        var row = current(); row["phaseChanged"] = changed; row["callbackOnMainThread"] = pthread_main_np() != 0
        if let n = value.completedSteps { row["completedSteps"] = n }; if let n = value.totalSteps { row["totalSteps"] = n }
        if let n = value.fraction, n.isFinite { row["fraction"] = n }
        lock.lock(); defer { lock.unlock() }; events.append(row)
        do { try line(row, eventFile); if changed { try eventFile.synchronize(); try memoryFile.synchronize(); try json(row, directory.appending(path: "current-stage.json")) } } catch { fail(error) }
        if changed { print("phase \(value.phase.rawValue)") }
    }
    func reference(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        do {
            guard referenceHashes.isEmpty else { throw GateError.failed }
            try data.write(to: directory.appending(path: "reference-callback-512.png"), options: .atomic)
            let summary = try pngSummary(data)
            guard summary["width"] as? Int == 512, summary["height"] as? Int == 512 else { throw GateError.failed }
            referenceHashes.append(sha(data)); try json(summary, directory.appending(path: "reference-callback.json"))
            try line(["event": "actualPublicReferenceCallback", "elapsed": ProcessInfo.processInfo.systemUptime - start, "sha256": sha(data)], eventFile); try eventFile.synchronize()
        } catch { fail(error) }
    }
    func sample() { let row = current(); lock.lock(); defer { lock.unlock() }; samples.append(row); do { try line(row, memoryFile) } catch { fail(error) } }
    func timeOut() { lock.lock(); timeout = true; lock.unlock(); owner.cancel() }
    func settle() { lock.lock(); defer { lock.unlock() }; for file in [eventFile, memoryFile] { do { try file.synchronize(); try file.close() } catch { fail(error) } } }
    var hasFailure: Bool { lock.lock(); defer { lock.unlock() }; return failure != nil }
    func referenceMatches(_ data: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return referenceHashes == [sha(data)] }
    func report() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let gaps = zip(samples.dropFirst(), samples).compactMap { a, b -> Double? in
            guard let x = a["elapsed"] as? Double, let y = b["elapsed"] as? Double else { return nil }; return x - y
        }
        var peaks: [String: UInt64] = [:]
        for row in samples { if let p = row["phase"] as? String, let n = row["physFootprintBytes"] as? UInt64 { peaks[p] = max(peaks[p] ?? 0, n) } }
        var result: [String: Any] = ["events": events, "sampleCount": samples.count, "nominalSamplingSeconds": 0.2,
            "maximumActualGapSeconds": gaps.max() ?? 0, "phaseSampledPeakFootprintBytes": peaks,
            "sampledPeakFootprintBytes": samples.compactMap { $0["physFootprintBytes"] as? UInt64 }.max() ?? 0,
            "maximumObservedMLXPeakCounterBytes": samples.compactMap { $0["mlxPeakCounterBytes"] as? Int }.max() ?? 0,
            "MLXCounterBoundary": "Read only after first real public phase; individual SDKs may reset peak counters; samples may miss peaks",
            "referenceCallbackCount": referenceHashes.count, "watchdogTriggered": timeout]
        if let failure { result["telemetryIOFailure"] = failure }; return result
    }
}

@main private struct Main {
    static func main() async { do { try await run() } catch { print("complete Klein creation gate failed: \(String(describing: error))"); exit(1) } }
    static func run() async throws {
        guard CommandLine.arguments.count == 4, ["--prepare", "--run"].contains(CommandLine.arguments[1]) else { throw GateError.usage }
        let mode = CommandLine.arguments[1], repository = URL(fileURLWithPath: CommandLine.arguments[2]), runRoot = URL(fileURLWithPath: CommandLine.arguments[3])
        let gate = repository.appending(path: "Apple/.build/NativeKleinCreationGate")
        let resourceRoots = ["intent": repository.appending(path: "Apple/.build/NeuralModels/Qwen3.5-0.8B-4bit"),
            "image": repository.appending(path: "Apple/.build/Flux2Candidate/Models"), "shape": repository.appending(path: "Apple/.build/NeuralModels/Shape21Q4")]
        let pinsURL = gate.appending(path: "resource-pins.json"), snapshotURL = gate.appending(path: "source-snapshot.json")
        let pins = try JSONDecoder().decode([Pin].self, from: Data(contentsOf: pinsURL))
        let snapshot = try JSONDecoder().decode(SourceSnapshot.self, from: Data(contentsOf: snapshotURL))
        func verifySources() throws {
            for row in snapshot.files {
                let url = gate.appending(path: "Packages/" + row.package + "/" + row.path), found = try fingerprint(url)
                guard found.0 == row.bytes, found.1 == row.sha256 else { throw GateError.pinMismatch(row.package + "/" + row.path) }
            }
        }
        func verifyResources() throws {
            guard pins.count == 25 else { throw GateError.pinMismatch("pin count") }
            for row in pins {
                guard let root = resourceRoots[row.group] else { throw GateError.pinMismatch("pin group") }
                let found = try fingerprint(root.appending(path: row.relativePath))
                guard found.0 == row.byteCount, found.1 == row.sha256 else { throw GateError.pinMismatch(row.group + "/" + row.relativePath) }
            }
        }
        try verifySources(); try verifyResources()
        let expectedStage = CreationImageBackend.klein4B.receipt(requestedSeed: seed)
        let yaml = try HunyuanShape21Configuration.bundledYAML
        guard sha(Data(yaml.utf8)) == HunyuanShape21Configuration.configurationSHA256 else { throw GateError.pinMismatch("shape YAML") }
        var identity: [String: Any] = ["caseID": "LP_original_public_klein", "entryPoint": "public NativeCreationEngine.generate",
            "binarySHA256": try fingerprint(URL(fileURLWithPath: CommandLine.arguments[0])).1,
            "snapshotSHA256": try fingerprint(snapshotURL).1, "snapshotFileCount": snapshot.files.count,
            "resourcePinsSHA256": try fingerprint(pinsURL).1, "verifiedResourceFiles": pins.count,
            "requestSHA256": sha(Data(request.utf8)), "requestedSeed": seed, "imageBackend": "flux2-klein4b-q4",
            "imageConfigurationSHA256": try expectedStage.configurationSHA256, "shapeConfigurationSHA256": sha(Data(yaml.utf8)),
            "shapePackSHA256": HunyuanShape21WeightProfile.rebuiltQ4Candidate.modelPackSHA256,
            "shapeGeometryPostprocess": HunyuanShape21WeightProfile.rebuiltQ4Candidate.geometryPostprocessID,
            "APIRequests": 1, "retries": 0, "fallbacks": 0, "platform": "host Mac; not phone", "watchdogSeconds": 900,
            "observationBoundary": "Fresh actual helper/image/Vision/Shape in one public call. Failed result exposes only public progress/reference callbacks, not hidden intent/prepared data.",
            "inferencePerformedByPrepare": false]
        if mode == "--prepare" {
            guard !FileManager.default.fileExists(atPath: runRoot.appending(path: "armed.json").path) else { throw GateError.existingOutput }
            try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: true)
            identity["state"] = "armed_without_inference"; identity["APIRequests"] = 0
            try json(identity, runRoot.appending(path: "armed.json")); try encode(expectedStage, runRoot.appending(path: "expected-image-stage.json"))
            try Data(request.utf8).write(to: runRoot.appending(path: "fixed-request.txt"), options: .atomic)
            print("prepared; 25 resource hashes and SDK snapshot verified; zero model/Vision calls"); return
        }
        let armed = try JSONSerialization.jsonObject(with: Data(contentsOf: runRoot.appending(path: "armed.json"))) as? [String: Any]
        for key in ["binarySHA256", "snapshotSHA256", "resourcePinsSHA256", "requestSHA256", "imageConfigurationSHA256", "shapeConfigurationSHA256"] {
            guard armed?[key] as? String == identity[key] as? String else { throw GateError.pinMismatch("armed " + key) }
        }
        let output = runRoot.appending(path: "FullKleinLP01")
        guard !FileManager.default.fileExists(atPath: output.path) else { throw GateError.existingOutput }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try json(identity, output.appending(path: "condition.json")); try Data(request.utf8).write(to: output.appending(path: "fixed-request.txt"), options: .atomic)
        let owner = Owner(), telemetry = try Telemetry(output, owner: owner), engine = NativeCreationEngine()
        let resources = CreationResources(intentModelDirectory: resourceRoots["intent"]!, imageModelDirectory: resourceRoots["image"]!,
            shapeModelFile: resourceRoots["shape"]!.appending(path: "model.q4.safetensors"), imageBackend: .klein4B)
        let sampler = Task.detached { while !Task.isCancelled { telemetry.sample(); do { try await Task.sleep(for: .milliseconds(200)) } catch { break } } }
        let operation = Task { try await engine.generate(prompt: request, seed: seed, resources: resources,
            onProgress: { telemetry.event($0) }, onReferenceImage: { telemetry.reference($0) }) }
        owner.set(operation)
        let watchdog = Task.detached { do { try await Task.sleep(for: .seconds(900)) } catch { return }; telemetry.timeOut() }
        let outcome = await withTaskCancellationHandler { await operation.result } onCancel: { owner.cancel() }
        watchdog.cancel(); await watchdog.value
        let cancelledBeforeCleanup = owner.isCancelled || Task.isCancelled
        await engine.cancel(); await engine.unload()
        let running = await engine.isRunning
        var report = identity, failed = cancelledBeforeCleanup || running || telemetry.hasFailure
        report["engineRunningAfterUnload"] = running; report["operationCancelledBeforeFinalCleanup"] = cancelledBeforeCleanup
        report["physicalBytesAfterUnload"] = footprint()
        switch outcome {
        case .failure(let error):
            failed = true; report["status"] = "failed_public_pipeline"; report["errorType"] = String(reflecting: type(of: error)); report["error"] = String(describing: error)
        case .success(let value):
            do {
                // Retain the first actual returned values even if contract
                // validation subsequently rejects them. These are diagnostic
                // artifacts, never an App publication or a successful verdict.
                try encode(value.intent, output.appending(path: "intent.json")); try encode(value.imageStage, output.appending(path: "actual-image-stage.json"))
                try value.referencePNG.write(to: output.appending(path: "reference-returned-512.png"), options: .atomic)
                try value.preparedReference.pngData.write(to: output.appending(path: "prepared-512-rgba.png"), options: .atomic)
                try value.shape.glbData.write(to: output.appending(path: "model.glb"), options: .atomic)
                try value.shape.usdzData.write(to: output.appending(path: "model.usdz"), options: .atomic)
                try value.shape.baseMeshData.write(to: output.appending(path: "base.glb"), options: .atomic)
                try encode(value.shape.provenance, output.appending(path: "shape-provenance.json"))
                try encode(value.shape.statistics, output.appending(path: "shape-statistics.json"))
                try encode(value.shape.validationReceipt, output.appending(path: "shape-validation-receipt.json"))
                report["stageSeconds"] = value.stageSeconds; report["vertices"] = value.shape.mesh.vertexCount; report["triangles"] = value.shape.mesh.triangleCount
                report["actualReturnedSeed"] = value.seed
                report["physicalScaleKnown"] = value.shape.provenance.physicalScaleKnown
                report["GLBSHA256"] = sha(value.shape.glbData); report["USDZSHA256"] = sha(value.shape.usdzData)
                report["actualReturnedArtifactsRetainedBeforeContractValidation"] = true
                report["referenceCallbackMatchesReturnedBytes"] = telemetry.referenceMatches(value.referencePNG)
                let referenceSummary = try pngSummary(value.referencePNG), preparedSummary = try pngSummary(value.preparedReference.pngData, alpha: true)
                try json(referenceSummary, output.appending(path: "reference.json"))
                try json(["method": value.preparedReference.method, "sourceWidth": value.preparedReference.sourceWidth,
                    "sourceHeight": value.preparedReference.sourceHeight, "foregroundBoundsCI": value.preparedReference.foregroundBounds,
                    "preparedPNG": preparedSummary], output.appending(path: "preparation.json"))
                guard !failed, !Task.isCancelled, value.seed == seed, value.imageStage == expectedStage,
                      telemetry.referenceMatches(value.referencePNG), value.shape.validationReceipt.actualNeuralWeightsUsed,
                      value.shape.provenance.inputPNG_SHA256 == sha(value.preparedReference.pngData),
                      value.shape.provenance.modelPackSHA256 == HunyuanShape21WeightProfile.rebuiltQ4Candidate.modelPackSHA256,
                      value.shape.provenance.geometryPostprocessID == "finite-positive-f64-v1",
                      referenceSummary["width"] as? Int == 512, referenceSummary["height"] as? Int == 512,
                      preparedSummary["width"] as? Int == 512, preparedSummary["height"] as? Int == 512 else { throw GateError.failed }
                try Task.checkCancellation()
                try await ModelPreview.write(usdzURL: output.appending(path: "model.usdz"), positions: value.shape.mesh.positions,
                    destination: output.appending(path: "front.png"), front: true)
                try Task.checkCancellation()
                try await ModelPreview.write(usdzURL: output.appending(path: "model.usdz"), positions: value.shape.mesh.positions,
                    destination: output.appending(path: "three-quarter.png"))
                report["status"] = "actual_public_pipeline_returned_semantic_visual_quality_pending"
            } catch { failed = true; report["status"] = "failed_contract_artifact_render_or_cancellation"; report["error"] = String(describing: error) }
        }
        telemetry.sample(); sampler.cancel(); await sampler.value; telemetry.settle()
        report["telemetry"] = telemetry.report(); report["seconds"] = ProcessInfo.processInfo.systemUptime - telemetry.start
        do { try verifySources(); try verifyResources(); report["postRunSourceAndResourcesUnchanged"] = true }
        catch { failed = true; report["postRunSourceAndResourcesUnchanged"] = false; report["pinError"] = String(describing: error) }
        if telemetry.hasFailure || Task.isCancelled { failed = true; report["status"] = "failed_telemetry_IO_or_late_cancellation" }
        try json(report, output.appending(path: "pipeline-report.json"))
        if failed { throw GateError.failed }
        print("one complete public pipeline settled; intent, image, segmentation, geometry and visual acceptance remain separate")
    }
}

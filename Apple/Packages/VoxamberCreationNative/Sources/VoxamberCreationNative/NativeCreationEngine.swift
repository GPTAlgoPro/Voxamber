import Foundation
import QwenNative
import VoxamberImageNative
import VoxamberShapeNative

/// A single owned operation runs the three actual model backends sequentially.
/// Resource download/checksum installation is a separate caller-owned boundary.
public actor NativeCreationEngine {
    private struct Job { let id: UUID; let task: Task<NativeCreationResult, Error> }
    private let intentEngine = QwenEngine()
    private let imageEngine = ImageEngine()
    private let shapeEngine = ShapeEngine(weightProfile: .rebuiltQ4Candidate)
    private var job: Job?
    private var cleanupCount = 0
    public var isRunning: Bool { job != nil || cleanupCount > 0 }

    public init() {}

    public func generate(prompt: String, seed: UInt64, resources: CreationResources,
                         onProgress: @escaping @Sendable (CreationProgress) -> Void = { _ in },
                         onReferenceImage: @escaping @Sendable (Data) -> Void = { _ in }) async throws -> NativeCreationResult {
        try Task.checkCancellation()
        guard job == nil, cleanupCount == 0 else { throw CreationError.busy }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= 2000 else { throw CreationError.invalidRequest }
        try Self.validateResourceLayout(resources)
        guard let lease = CreationRuntimeLease.shared.acquire() else { throw CreationError.busy }
        let id = UUID()
        let task = Task { try await run(prompt: prompt, seed: seed, resources: resources,
                                      onProgress: onProgress, onReferenceImage: onReferenceImage) }
        job = Job(id: id, task: task)
        defer {
            if job?.id == id { job = nil }
            CreationRuntimeLease.shared.release(lease)
        }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    public func cancel() { job?.task.cancel() }

    public func unload() async {
        cleanupCount += 1
        defer { cleanupCount -= 1 }
        if let current = job {
            current.task.cancel()
            _ = try? await current.task.value
            if job?.id == current.id { job = nil }
        }
        await intentEngine.unload()
        await shapeEngine.unload()
    }

    private func run(prompt: String, seed: UInt64, resources: CreationResources,
                     onProgress: @escaping @Sendable (CreationProgress) -> Void,
                     onReferenceImage: @escaping @Sendable (Data) -> Void) async throws -> NativeCreationResult {
        do {
            var timings: [String: Double] = [:]
            let start = Date()
            onProgress(.init(phase: .interpreting))
            try await intentEngine.load(modelDirectory: resources.intentModelDirectory)
            let response = try await intentEngine.generateJSON(
                systemPrompt: CreationIntentDecoder.systemPrompt, prompt: prompt, maxTokens: 512,
                jsonSchema: CreationIntentDecoder.schema)
            let intent = try CreationIntentDecoder.decode(response, sourcePrompt: prompt)
            await intentEngine.unload()
            try Task.checkCancellation()
            timings[CreationPhase.interpreting.rawValue] = Date().timeIntervalSince(start)

            let imageStart = Date()
            onProgress(.init(phase: .drawingReference))
            let reference = try await imageEngine.generate(
                positivePrompt: intent.positivePrompt, negativePrompt: intent.negativePrompt,
                seed: UInt32(truncatingIfNeeded: seed), resourcesURL: resources.imageModelDirectory,
                onProgress: { value in
                    switch value {
                    case .denoising(let completed, let total):
                        onProgress(.init(phase: .drawingReference, completedSteps: completed, totalSteps: total))
                    default: break
                    }
                })
            // The Image SDK has already unloaded its model resources on return.
            try Task.checkCancellation()
            timings[CreationPhase.drawingReference.rawValue] = Date().timeIntervalSince(imageStart)
            onReferenceImage(reference)

            let preparationStart = Date()
            onProgress(.init(phase: .preparingSubject))
            let prepared = try await SubjectImagePreparer.prepare(pngData: reference)
            try Task.checkCancellation()
            timings[CreationPhase.preparingSubject.rawValue] = Date().timeIntervalSince(preparationStart)

            let shapeStart = Date()
            onProgress(.init(phase: .generatingShape))
            let shape = try await shapeEngine.generate(
                pngData: prepared.pngData, shapePackURL: resources.shapeModelFile,
                configurationYAML: HunyuanShape21Configuration.bundledYAML, seed: seed,
                onProgress: { value in onProgress(.init(phase: .generatingShape, fraction: value.fraction)) })
            await shapeEngine.unload()
            try Task.checkCancellation()
            timings[CreationPhase.generatingShape.rawValue] = Date().timeIntervalSince(shapeStart)
            timings["total"] = Date().timeIntervalSince(start)
            onProgress(.init(phase: .complete, fraction: 1))
            return NativeCreationResult(intent: intent, referencePNG: reference,
                preparedReference: prepared, shape: shape, seed: seed, stageSeconds: timings)
        } catch {
            // Await cleanup even for a canceled caller. No phase runs on after
            // this method returns, and no partial result is published here.
            await intentEngine.unload()
            await shapeEngine.unload()
            throw error
        }
    }

    private static func validateResourceLayout(_ resources: CreationResources) throws {
        for directory in [resources.intentModelDirectory, resources.imageModelDirectory] {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directory.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else {
                throw CreationError.resourcesUnavailable
            }
        }
        // The lightweight helper is deliberately the 0.8B architecture. A
        // larger installed language model must not silently replace it.
        let configURL = resources.intentModelDirectory.appending(path: "config.json")
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any],
              config["model_type"] as? String == "qwen3_5",
              let text = config["text_config"] as? [String: Any],
              text["hidden_size"] as? Int == 1024, text["num_hidden_layers"] as? Int == 24 else {
            throw CreationError.resourcesUnavailable
        }
        for name in ["model.safetensors", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"] {
            let value = try resources.intentModelDirectory.appending(path: name)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard value.isRegularFile == true, value.isSymbolicLink != true else {
                throw CreationError.resourcesUnavailable
            }
        }
        let shape = try resources.shapeModelFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resources.shapeModelFile.isFileURL, shape.isRegularFile == true, shape.isSymbolicLink != true else {
            throw CreationError.resourcesUnavailable
        }
        try SDXLResources.validateLayout(at: resources.imageModelDirectory)
    }
}

private final class CreationRuntimeLease: @unchecked Sendable {
    static let shared = CreationRuntimeLease()
    private let lock = NSLock()
    private var owner: UUID?

    func acquire() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard owner == nil else { return nil }
        let id = UUID(); owner = id; return id
    }

    func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if owner == id { owner = nil }
    }
}

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FluxCandidateResources
import Flux2Core
import FluxTextEncoders
import MLX
import Darwin

public enum FluxCandidateError: Error, Equatable, Sendable {
    case busy, emptyPrompt, insufficientHeadroom, invalidImage, pngEncodingFailed
}

public struct FluxCandidateProgress: Sendable {
    public let stage: String
    public let step: Int
    public let totalSteps: Int
    public init(stage: String, step: Int = 0, totalSteps: Int = 4) {
        self.stage = stage; self.step = step; self.totalSteps = totalSteps
    }
}

struct FluxCandidateRequest: Sendable {
    let prompt: String
    let seed: UInt64
    let modelRoot: URL
    let progress: @Sendable (FluxCandidateProgress) -> Void
}

/// Serializes the upstream global text-encoder singleton across all candidate engine instances.
actor FluxCandidateRuntimeLease {
    static let shared = FluxCandidateRuntimeLease()
    private var owner: UUID?
    func acquire() throws -> UUID {
        guard owner == nil else { throw FluxCandidateError.busy }
        let id = UUID(); owner = id; return id
    }
    func release(_ id: UUID) { if owner == id { owner = nil } }
}

/// Isolated candidate only. Fixed Klein4B Q4 / Qwen3-4B Q4 / small VAE, 512² / 4 steps / g1.
/// No network, cache discovery, prompt upsampling, image interpretation, LoRA or larger model routes.
public actor FluxImageEngine {
    typealias Worker = @Sendable (FluxCandidateRequest) async throws -> Data
    private let worker: Worker
    private var current: Task<Data, Error>?
    private var currentID: UUID?
    private var unloading = 0

    public init() { worker = Self.execute }
    init(worker: @escaping Worker) { self.worker = worker }

    public var isRunning: Bool { current != nil }

    public func generate(positivePrompt: String, seed: UInt64, modelRoot: URL,
                         onProgress: @escaping @Sendable (FluxCandidateProgress) -> Void = { _ in }) async throws -> Data {
        guard current == nil, unloading == 0 else { throw FluxCandidateError.busy }
        guard !positivePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FluxCandidateError.emptyPrompt }
        try Task.checkCancellation()
        let id = UUID(), factory = worker
        let request = FluxCandidateRequest(prompt: positivePrompt, seed: seed, modelRoot: modelRoot, progress: onProgress)
        let task = Task.detached { try await factory(request) }
        currentID = id; current = task
        defer { if currentID == id { currentID = nil; current = nil } }
        return try await withTaskCancellationHandler {
            let data = try await task.value
            try Task.checkCancellation()
            return data
        } onCancel: { task.cancel() }
    }

    /// Returns only after the owned worker has settled and released its runtime lease.
    /// Idle unload never touches MLX or initializes Metal.
    public func unload() async {
        unloading += 1
        defer { unloading -= 1 }
        guard let task = current else { return }
        let id = currentID
        task.cancel()
        _ = await task.result
        if currentID == id { currentID = nil; current = nil }
    }

    public func cancel() async { await unload() }

    private static func execute(_ request: FluxCandidateRequest) async throws -> Data {
        request.progress(.init(stage: "verifying_resources"))
        let verified = try FluxResourceVerifier.verify(root: request.modelRoot)
        try Task.checkCancellation()
        let lease = FluxCandidateRuntimeLease.shared
        let leaseID = try await lease.acquire()
        do {
            #if os(iOS)
            guard ProcessInfo.processInfo.physicalMemory >= 12_000_000_000,
                  os_proc_available_memory() >= 5_905_580_032 else { throw FluxCandidateError.insufficientHeadroom }
            #endif
            let result = try await executeAdmitted(request, verified: verified)
            await lease.release(leaseID)
            return result
        } catch {
            await lease.release(leaseID)
            throw error
        }
    }

    private static func executeAdmitted(_ request: FluxCandidateRequest, verified: VerifiedFluxResources) async throws -> Data {
        let paths = Flux2LocalResourcePaths(transformerDirectory: verified.transformerDirectory,
                                          textEncoderDirectory: verified.textEncoderDirectory,
                                          vaeDirectory: verified.vaeDirectory)
        let pipeline = try Flux2Pipeline(localResources: paths, model: .klein4B,
            quantization: .init(textEncoder: .mlx4bit, transformer: .int4), memoryOptimization: .aggressive,
            vaeVariant: .smallDecoder, transformerVariantOverride: .klein4B_4bit)
        pipeline.memoryProfile = .conservative
        pipeline.clearCacheEveryNSteps = 1
        pipeline.onLocalPhase = { request.progress(.init(stage: $0)) }
        pipeline.controlCheckpoint = {
            try Task.checkCancellation()
            try verified.assertUnchanged()
        }
        let runtime = FluxCandidateRuntimeScope()
        pipeline.onRuntimeWillTouch = { runtime.markTouched() }
        let result = try await runtime.run(operation: {
            // This candidate's loadModels is pure layout validation; no model/cache/MLX load.
            try await pipeline.loadModels()
            try Task.checkCancellation()
            let image = try await pipeline.generateTextToImage(prompt: request.prompt,
                height: 512, width: 512, steps: 4, guidance: 1, seed: request.seed, upsamplePrompt: false,
                onProgress: { step, total in request.progress(.init(stage: "denoising", step: step, totalSteps: total)) })
            try Task.checkCancellation()
            try verified.assertUnchanged()
            guard image.width == 512, image.height == 512 else { throw FluxCandidateError.invalidImage }
            let png = try encodePNG(image)
            return png
        }, cleanup: {
            request.progress(.init(stage: "unloading"))
            Stream.gpu.synchronize()
            await pipeline.clearAll()
            Stream.gpu.synchronize()
            Memory.clearCache()
            Stream.gpu.synchronize()
        })
        request.progress(.init(stage: "complete"))
        return result
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw FluxCandidateError.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FluxCandidateError.pngEncodingFailed }
        return data as Data
    }
}

/// Shared production lifecycle seam, independently testable without initializing MLX.
final class FluxCandidateRuntimeScope: @unchecked Sendable {
    private let lock = NSLock()
    private var touched = false
    func markTouched() { lock.lock(); touched = true; lock.unlock() }
    private var needsCleanup: Bool { lock.lock(); defer { lock.unlock() }; return touched }

    func run<T: Sendable>(operation: @Sendable () async throws -> T,
                          cleanup: @Sendable () async -> Void) async throws -> T {
        let result: Result<T, Error>
        do { result = .success(try await operation()) } catch { result = .failure(error) }
        if needsCleanup { await cleanup() }
        try Task.checkCancellation()
        return try result.get()
    }
}

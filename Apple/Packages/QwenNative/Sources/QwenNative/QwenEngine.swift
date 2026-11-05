import Foundation
import MLX
import MLXLLM
import MLXLMCommon

public struct QwenGenerationProgress: Sendable {
    public let text: String
    public let elapsedSeconds: Double
    public let firstTokenSeconds: Double?
}

public struct QwenMemorySnapshot: Codable, Sendable {
    public let activeBytes: Int
    public let cacheBytes: Int
    public let peakBytes: Int
}

public enum QwenError: LocalizedError, Sendable {
    case modelNotLoaded
    case busy
    case invalidJSON
    case promptTooLong
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "请先下载并载入本地模型。"
        case .busy: "本地模型正在处理上一项任务。"
        case .invalidJSON: "模型没有返回完整的造型参数，请简化描述后重试。"
        case .promptTooLong: "设计描述过长，请缩短后重试。"
        }
    }
}

/// Native Swift MLX inference. Model weights and tokenizers are local files only.
/// Every request creates a fresh bounded session; history cannot silently grow across generations.
public actor QwenEngine {
    private var model: ModelContainer?
    private var directory: URL?
    private var generationTask: Task<String, Error>?
    private var epoch = UUID()
    private var isLoading = false
    private var isUnloading = false

    public init() {}

    public func memorySnapshot() -> QwenMemorySnapshot {
        QwenMemorySnapshot(activeBytes: Memory.activeMemory,
                           cacheBytes: Memory.cacheMemory, peakBytes: Memory.peakMemory)
    }

    public func load(modelDirectory: URL) async throws {
        guard !isLoading, !isUnloading, generationTask == nil else { throw QwenError.busy }
        if directory == modelDirectory, model != nil { return }
        isLoading = true
        let requestEpoch = epoch
        defer { isLoading = false }
        model = nil
        directory = nil
        Memory.cacheLimit = 32 * 1024 * 1024
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory, using: LocalTokenizerLoader())
        try Task.checkCancellation()
        guard requestEpoch == epoch else { throw CancellationError() }
        model = loaded
        directory = modelDirectory
    }

    public func generateJSON(
        systemPrompt: String,
        prompt: String,
        maxTokens: Int = 1536,
        thinking: Bool = false,
        onProgress: @escaping @Sendable (QwenGenerationProgress) -> Void = { _ in }
    ) async throws -> String {
        guard !isLoading, !isUnloading, generationTask == nil else { throw QwenError.busy }
        guard let model else { throw QwenError.modelNotLoaded }
        guard prompt.count <= 6000, systemPrompt.count <= 8000 else { throw QwenError.promptTooLong }
        try Task.checkCancellation()
        let task = Task<String, Error> {
            let session = ChatSession(model, instructions: systemPrompt,
                generateParameters: GenerateParameters(maxTokens: max(64, min(maxTokens, 3072)),
                                                       maxKVSize: 8192, temperature: 0),
                additionalContext: ["enable_thinking": thinking])
            let started = ContinuousClock.now
            var lastUpdate = started
            var text = ""
            var raw = ""
            var firstTokenSeconds: Double?
            do {
                for try await chunk in session.streamResponse(to: prompt) {
                    try Task.checkCancellation()
                    raw += chunk
                    if raw.utf8.count > 65_536 { throw QwenError.invalidJSON }
                    text = Self.visibleOutput(raw, thinking: thinking)
                    let isFirst = firstTokenSeconds == nil && !text.isEmpty
                    if isFirst { firstTokenSeconds = Self.seconds(since: started) }
                    if text.utf8.count > 16_384 { throw QwenError.invalidJSON }
                    if isFirst || lastUpdate.duration(to: .now) >= .milliseconds(100) {
                        onProgress(QwenGenerationProgress(text: text, elapsedSeconds: Self.seconds(since: started),
                                                          firstTokenSeconds: firstTokenSeconds))
                        lastUpdate = .now
                    }
                }
            } catch {
                // The stream cancels its producer on termination. Wait for GPU work before release.
                await session.synchronize()
                throw error
            }
            await session.synchronize()
            try Task.checkCancellation()
            let result = Self.removeFence(text)
            guard let data = result.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
                throw QwenError.invalidJSON
            }
            onProgress(QwenGenerationProgress(text: result, elapsedSeconds: Self.seconds(since: started),
                                              firstTokenSeconds: firstTokenSeconds))
            return result
        }
        generationTask = task
        defer { generationTask = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    public func unload() async {
        isUnloading = true
        epoch = UUID()
        if let task = generationTask {
            task.cancel()
            _ = try? await task.value
        }
        if let model {
            await model.perform { context in
                context.model.invalidateCompiledTraces()
            }
        }
        Stream.gpu.synchronize()
        model = nil
        directory = nil
        Memory.clearCache()
        isUnloading = false
    }

    private nonisolated static func seconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }

    private nonisolated static func removeFence(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```json\n"), trimmed.hasSuffix("```") {
            return String(trimmed.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if trimmed.hasPrefix("```\n"), trimmed.hasSuffix("```") {
            return String(trimmed.dropFirst(4).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    /// Thinking is an internal model mode; only the final answer reaches the app or reports.
    private nonisolated static func visibleOutput(_ raw: String, thinking: Bool) -> String {
        guard thinking else { return raw }
        if let end = raw.range(of: "</think>") {
            return String(raw[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}

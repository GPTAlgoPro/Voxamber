import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXGuidedGeneration

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
    case unsupportedThinking
    case outputLimit
    case grammarFailure
    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "请先下载并载入本地模型。"
        case .busy: "本地模型正在处理上一项任务。"
        case .invalidJSON: "模型没有返回完整的造型参数，请简化描述后重试。"
        case .promptTooLong: "设计描述过长，请缩短后重试。"
        case .unsupportedThinking: "当前单轮生成通道不支持思考模式。"
        case .outputLimit: "造型参数超过本次生成长度，请简化描述后重试。"
        case .grammarFailure: "本次造型参数未能通过格式约束，请重试。"
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
    private let grammarCache = NativeJSONGrammarCache()

    public init() {}

    /// Thread-safe global allocator scalars; sampling must not wait behind actor-bound prefill.
    public nonisolated func memorySnapshot() -> QwenMemorySnapshot {
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
        grammarCache.reset()
        Memory.cacheLimit = 32 * 1024 * 1024
        // The current Qwen3.5 compiled-trace path retains buffers across model reloads.
        // Use native Metal operators without graph trace/fusion until lifecycle evidence is stable.
        MLX.compile(enable: false)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: modelDirectory, using: LocalTokenizerLoader())
        try Task.checkCancellation()
        guard requestEpoch == epoch else { throw CancellationError() }
        model = loaded
        directory = modelDirectory
    }

    /// Uses the phone-verified single-turn path, then validates a complete JSON object.
    /// The direct method owns the sole task/cache lifecycle; this wrapper adds no nested task.
    /// Optional grammar enforces structure. Floating-point schema bounds are deferred
    /// to the caller's native ScenePlan validation; see completion.grammar metadata.
    public func generateJSON(
        systemPrompt: String,
        prompt: String,
        maxTokens: Int = 3072,
        jsonSchema: String? = nil,
        thinking: Bool = false,
        onProgress: @escaping @Sendable (QwenGenerationProgress) -> Void = { _ in },
        onCompletion: @escaping @Sendable (QwenGenerationCompletion) -> Void = { _ in }
    ) async throws -> String {
        guard !thinking else { throw QwenError.unsupportedThinking }
        let capture = QwenCompletionCapture()
        let raw = try await generateJSONDirect(systemPrompt: systemPrompt, prompt: prompt,
            maxTokens: maxTokens, prefillStepSize: 128, jsonSchema: jsonSchema,
            onProgress: onProgress,
            onCompletion: { completion in capture.record(completion); onCompletion(completion) })
        try Task.checkCancellation()
        if capture.completion?.reason == .outputLimit { throw QwenError.outputLimit }
        guard raw.utf8.count <= 16_384 else { throw QwenError.invalidJSON }
        let result = Self.removeFence(raw)
        guard let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            throw QwenError.invalidJSON
        }
        return result
    }

    /// Phone-verified single-turn raw implementation shared by formal and diagnostic calls.
    /// Returns decoded output, which may be partial at a small token limit; the caller owns JSON validation.
    /// Stage/progress callbacks contain timings and counts only, never input or generated content.
    public func generateJSONDirect(
        systemPrompt: String,
        prompt: String,
        maxTokens: Int = 64,
        prefillStepSize: Int = 128,
        jsonSchema: String? = nil,
        onStage: @escaping @Sendable (String) -> Void = { _ in },
        onProgress: @escaping @Sendable (QwenGenerationProgress) -> Void = { _ in },
        onCompletion: @escaping @Sendable (QwenGenerationCompletion) -> Void = { _ in }
    ) async throws -> String {
        guard !isLoading, !isUnloading, generationTask == nil else { throw QwenError.busy }
        guard let model else { throw QwenError.modelNotLoaded }
        guard prompt.count <= 6000, systemPrompt.count <= 8000 else { throw QwenError.promptTooLong }
        try Task.checkCancellation()
        let reporter = DirectStageReporter(began: .now, callback: onStage)
        let tokenLimit = max(1, min(maxTokens, 3072))
        let grammarCache = grammarCache
        reporter.emit("direct_begin")
        let task = Task<String, Error> {
            try await model.perform { context in
                var streamSettled = false
                // Prefill can throw before a producer exists (including chunked
                // cancellation). Settle any submitted Metal work on that path too.
                defer { if !streamSettled { Stream.defaultStream.synchronize() } }
                reporter.emit("tokenizer_prepare_begin")
                let input = try await context.processor.prepare(input: UserInput(
                    chat: [.system(systemPrompt), .user(prompt)],
                    additionalContext: ["enable_thinking": false]))
                let inputCount = input.text.tokens.size
                reporter.emit("tokenizer_prepare_done", inputTokens: inputCount)
                guard inputCount <= 8192 else { throw QwenError.promptTooLong }
                try Task.checkCancellation()
                let grammar: NativeJSONGrammarSession?
                if let jsonSchema {
                    reporter.emit("grammar_prepare_begin", inputTokens: inputCount)
                    do {
                        guard let eosID = context.tokenizer.eosTokenId else { throw QwenError.grammarFailure }
                        grammar = try grammarCache.session(schema: jsonSchema, eosID: eosID) {
                            let vocab = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
                            return try GrammarTokenizer(vocab: vocab.vocab, vocabType: vocab.vocabType,
                                                        eosTokenId: Int32(eosID))
                        }
                    } catch {
                        onCompletion(QwenGenerationCompletion(reason: .grammarFailure,
                            inputTokenCount: inputCount, generatedTokenCount: 0, tokenLimit: tokenLimit,
                            grammarEnabled: true, grammarTerminated: false))
                        reporter.emit("grammar_prepare_failed", inputTokens: inputCount)
                        throw QwenError.grammarFailure
                    }
                    reporter.emit("grammar_prepare_ready", inputTokens: inputCount)
                } else { grammar = nil }
                try Task.checkCancellation()
                let prefill = PrefillParameters(stepSize: max(1, min(prefillStepSize, 1024)),
                    chunking: .balanced, progress: { processed, total in
                        reporter.emit("prefill_submitted processed=\(processed)", inputTokens: total)
                    })
                let parameters = GenerateParameters(maxTokens: tokenLimit,
                    maxKVSize: 8192, temperature: 0, prefill: prefill)
                reporter.emit("kv_cache_begin", inputTokens: inputCount)
                let cache = try context.model.newCache(parameters: parameters)
                reporter.emit("kv_cache_ready", inputTokens: inputCount)
                reporter.emit("prefill_begin", inputTokens: inputCount)
                let iterator = try TokenIterator(input: input, model: context.model,
                    cache: cache, parameters: parameters, components: grammar?.components ?? .init())
                if grammar?.state.snapshot.failure != nil {
                    Stream.defaultStream.synchronize()
                    streamSettled = true
                    onCompletion(QwenGenerationCompletion(reason: .grammarFailure,
                        inputTokenCount: inputCount, generatedTokenCount: 0, tokenLimit: tokenLimit,
                        grammarEnabled: true, grammarTerminated: false, grammar: grammar?.template.metadata))
                    throw QwenError.grammarFailure
                }
                reporter.emit("prefill_ready", inputTokens: inputCount)
                let (stream, producer) = MLXLMCommon.generateTokenTask(
                    promptTokenCount: inputCount, modelConfiguration: context.configuration,
                    tokenizer: context.tokenizer, iterator: iterator)
                reporter.emit("raw_stream_ready", inputTokens: inputCount)
                var tokens: [Int] = []
                var firstTokenSeconds: Double?
                var nativeStopReason: GenerateStopReason?
                var lastProgress = ContinuousClock.now
                await withTaskCancellationHandler {
                    for await event in stream {
                        if Task.isCancelled { producer.cancel(); break }
                        if grammar?.state.snapshot.failure != nil { producer.cancel(); break }
                        switch event {
                        case .token(let token):
                            tokens.append(token)
                            if firstTokenSeconds == nil {
                                firstTokenSeconds = reporter.elapsed
                                reporter.emit("first_raw_token", inputTokens: inputCount, generatedTokens: 1)
                            }
                            if tokens.count == 1 || lastProgress.duration(to: .now) >= .milliseconds(100) {
                                onProgress(QwenGenerationProgress(text: "", elapsedSeconds: reporter.elapsed,
                                    firstTokenSeconds: firstTokenSeconds))
                                lastProgress = .now
                            }
                        case .info(let info):
                            nativeStopReason = info.stopReason
                            reporter.emit("native_generation_complete", inputTokens: info.promptTokenCount,
                                          generatedTokens: info.generationTokenCount)
                        }
                    }
                    if Task.isCancelled { producer.cancel() }
                    // The public task settles its actual generation stream before completing.
                    await producer.value
                } onCancel: { producer.cancel() }
                Stream.defaultStream.synchronize()
                streamSettled = true
                reporter.emit("raw_stream_finished", inputTokens: inputCount, generatedTokens: tokens.count)
                let grammarSnapshot = grammar?.state.snapshot
                let reason: QwenTerminationReason
                if Task.isCancelled { reason = .cancelled }
                else if grammarSnapshot?.failure != nil { reason = .grammarFailure }
                else {
                    switch nativeStopReason {
                    case .stop: reason = grammar != nil && grammarSnapshot?.terminated != true ? .grammarFailure : .stop
                    case .length: reason = .outputLimit
                    case .cancelled, nil: reason = .cancelled
                    }
                }
                onCompletion(QwenGenerationCompletion(reason: reason,
                    inputTokenCount: inputCount, generatedTokenCount: tokens.count, tokenLimit: tokenLimit,
                    grammarEnabled: grammar != nil, grammarTerminated: grammarSnapshot?.terminated ?? false,
                    grammar: grammar?.template.metadata))
                reporter.emit("direct_termination reason=\(reason.rawValue)", inputTokens: inputCount,
                              generatedTokens: tokens.count)
                try Task.checkCancellation()
                if reason == .grammarFailure { throw QwenError.grammarFailure }
                if reason == .cancelled { throw CancellationError() }
                let result = context.tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)
                reporter.emit("direct_finished", inputTokens: inputCount, generatedTokens: tokens.count)
                return result
            }
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
        grammarCache.reset()
        model = nil
        directory = nil
        Memory.clearCache()
        isUnloading = false
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


}

private struct DirectStageReporter: Sendable {
    let began: ContinuousClock.Instant
    let callback: @Sendable (String) -> Void
    var elapsed: Double {
        let value = began.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    func emit(_ stage: String, inputTokens: Int = 0, generatedTokens: Int = 0) {
        callback("\(stage) elapsed=\(String(format: "%.3f", elapsed)) inputTokenCount=\(inputTokens) generatedTokenCount=\(generatedTokens)")
    }
}

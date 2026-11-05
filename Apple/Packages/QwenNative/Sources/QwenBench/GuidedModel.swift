import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXGuidedGeneration
import QwenNative

/// Experimental native schema-constrained adapter. No generated code is interpreted.
actor GuidedModel: BenchModel {
    private var model: ModelContainer?
    private var grammarTokenizer: GrammarTokenizer?
    private let schema: String
    init() throws {
        schema = try String(contentsOf: Bundle.module.url(forResource: "plan-schema", withExtension: "json")!, encoding: .utf8)
    }
    func load(_ directory: URL) async throws {
        MLX.compile(enable: false)
        Memory.cacheLimit = 32 * 1024 * 1024
        let loaded = try await LLMModelFactory.shared.loadContainer(from: directory, using: BenchTokenizerLoader())
        grammarTokenizer = try await loaded.perform { context in
            let vocabulary = TokenizerVocabExtractor.extractForGrammar(from: context.tokenizer)
            return try GrammarTokenizer(vocab: vocabulary.vocab, vocabType: vocabulary.vocabType,
                                        eosTokenId: Int32(context.tokenizer.eosTokenId ?? 0))
        }
        model = loaded
    }
    func benchGenerate(systemPrompt: String, prompt: String, maxTokens: Int,
                       onProgress: @escaping @Sendable (BenchProgress) -> Void) async throws -> String {
        guard let model, let grammarTokenizer else { throw QwenError.modelNotLoaded }
        let schema = schema
        return try await model.perform { context in
            let began = Date()
            let input = try await context.processor.prepare(input: UserInput(
                chat: [.system(systemPrompt), .user(prompt)], additionalContext: ["enable_thinking": false]))
            let constraint = try GrammarConstraint(tokenizer: grammarTokenizer, jsonSchema: schema,
                                                   fastForward: true, hostTokenizer: context.tokenizer)
            let close = ClosingTokenBias.compute(tokenizer: context.tokenizer,
                                                 eosTokenId: context.tokenizer.eosTokenId)
            let whitespace = WhitespaceTokenBias.compute(tokenizer: context.tokenizer)
            var output = ""
            var first: Double?
            try GuidedGenerationLoop.run(input: input, context: context, constraint: constraint,
                maxTokens: min(maxTokens, 3072), vocabSize: grammarTokenizer.vocabSize,
                kvCache: .init(capacity: try .init(maxTokens: 8192)),
                completionReserve: 128, hardReserve: 64, closingBias: close,
                whitespaceBias: whitespace.bias, whitespaceTokenIDs: whitespace.tokenIDs) { delta in
                    if Task.isCancelled { return false }
                    output += delta
                    if first == nil, !delta.isEmpty { first = Date().timeIntervalSince(began) }
                    onProgress(BenchProgress(text: output, firstTokenSeconds: first))
                    return output.utf8.count <= 32_768
                }
            Stream.defaultStream.synchronize()
            return output
        }
    }
    func benchMemorySnapshot() -> BenchMemory { BenchMemory(activeBytes: Memory.activeMemory, peakBytes: Memory.peakMemory) }
    func unload() async {
        if let model { await model.perform { context in context.model.invalidateCompiledTraces() } }
        Stream.gpu.synchronize(); model = nil; grammarTokenizer = nil; Memory.clearCache()
    }
}

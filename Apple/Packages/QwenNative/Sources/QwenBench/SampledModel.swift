import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import QwenNative

struct BenchMemory: Sendable {
    let activeBytes: Int
    let peakBytes: Int
}

struct BenchProgress: Sendable {
    let text: String
    let firstTokenSeconds: Double?
}

protocol BenchModel: Sendable {
    func benchGenerate(systemPrompt: String, prompt: String, maxTokens: Int,
                       onProgress: @escaping @Sendable (BenchProgress) -> Void) async throws -> String
    func benchMemorySnapshot() async -> BenchMemory
    func unload() async
}

extension QwenEngine: BenchModel {
    func benchGenerate(systemPrompt: String, prompt: String, maxTokens: Int,
                       onProgress: @escaping @Sendable (BenchProgress) -> Void) async throws -> String {
        try await generateJSON(systemPrompt: systemPrompt, prompt: prompt, maxTokens: maxTokens) {
            onProgress(BenchProgress(text: $0.text, firstTokenSeconds: $0.firstTokenSeconds))
        }
    }
    func benchMemorySnapshot() async -> BenchMemory {
        let memory = memorySnapshot()
        return BenchMemory(activeBytes: memory.activeBytes, peakBytes: memory.peakBytes)
    }
}

/// Isolated Mac research driver: does not alter the frozen app engine's sampling behavior.
actor SampledModel: BenchModel {
    private var model: ModelContainer?
    private let ccoreSettings: Bool
    init(ccoreSettings: Bool) { self.ccoreSettings = ccoreSettings }

    func load(_ directory: URL) async throws {
        MLX.compile(enable: false)
        Memory.cacheLimit = 32 * 1024 * 1024
        model = try await LLMModelFactory.shared.loadContainer(from: directory, using: BenchTokenizerLoader())
    }

    func benchGenerate(systemPrompt: String, prompt: String, maxTokens: Int,
                       onProgress: @escaping @Sendable (BenchProgress) -> Void) async throws -> String {
        guard let model else { throw QwenError.modelNotLoaded }
        let parameters = GenerateParameters(maxTokens: maxTokens, maxKVSize: 8192,
            temperature: ccoreSettings ? 0.6 : 0.7, topP: ccoreSettings ? 0.95 : 0.8,
            topK: 20, minP: 0, presencePenalty: ccoreSettings ? nil : 1.5,
            presenceContextSize: 2048, seed: 42)
        let session = ChatSession(model, instructions: systemPrompt, generateParameters: parameters,
                                  additionalContext: ["enable_thinking": false])
        var text = ""
        let began = Date()
        var first: Double?
        do {
            for try await chunk in session.streamResponse(to: prompt) {
                try Task.checkCancellation()
                text += chunk
                if first == nil, !chunk.isEmpty { first = Date().timeIntervalSince(began) }
                onProgress(BenchProgress(text: text, firstTokenSeconds: first))
                if text.utf8.count > 32_768 { throw QwenError.invalidJSON }
            }
        } catch {
            await session.synchronize(); await session.clear(); throw error
        }
        await session.synchronize(); await session.clear()
        var final = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = final.range(of: "</think>") { final = String(final[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) }
        if final.hasPrefix("```json\n"), final.hasSuffix("```") { final = String(final.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let data = final.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data), json is [String: Any] else { throw QwenError.invalidJSON }
        return final
    }

    func benchMemorySnapshot() -> BenchMemory { BenchMemory(activeBytes: Memory.activeMemory, peakBytes: Memory.peakMemory) }
    func unload() async {
        if let model { await model.perform { context in context.model.invalidateCompiledTraces() } }
        Stream.gpu.synchronize(); model = nil; Memory.clearCache()
    }
}

// Same native tokenizer bridge as the production adapter; no remote downloader or macros.
struct BenchTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        BenchTokenizer(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}
private struct BenchTokenizer: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
    }
}

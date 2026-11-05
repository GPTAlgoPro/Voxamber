import Foundation
import MLX
import MLXNN
import MLXLMCommon
import XCTest
@testable import QwenNative

final class JSONCompletionTests: XCTestCase {
    func testNativeProducerStopsCompleteObjectBeforeEndlessWhitespaceAndSettles() async throws {
        let vocab = ["<eos>", "{", "\"x\"", ":", "1", "}", " "]
        let run = try makeProducer(vocab: vocab, tokens: [1,2,3,4,5,6], limit: 3072)
        let result = await QwenTokenStream.collect(stream: run.stream, producer: run.task,
            tokenizer: CompletionTokenizer(vocab: vocab), stopAtCompleteJSON: true)
        Stream.defaultStream.synchronize()
        XCTAssertEqual(result.tokens, [1,2,3,4,5])
        XCTAssertEqual(result.termination(isCancelled: false, grammarFailed: false,
            grammarEnabled: false, grammarTerminated: false), .jsonComplete)
        XCTAssertLessThan(run.model.calls, 64)
        let settledCalls = run.model.calls
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(run.model.calls, settledCalls, "Returned only after the actual native producer settled")
        XCTAssertFalse(Task.isCancelled, "An internal completion stop must not cancel its caller")
    }

    func testDirectDefaultModePreservesRawTokensAndLengthReason() async throws {
        let vocab = ["<eos>", "{}", " "]
        let run = try makeProducer(vocab: vocab, tokens: [1,2], limit: 12)
        let result = await QwenTokenStream.collect(stream: run.stream, producer: run.task,
            tokenizer: CompletionTokenizer(vocab: vocab), stopAtCompleteJSON: false)
        Stream.defaultStream.synchronize()
        XCTAssertEqual(result.tokens, [1] + Array(repeating: 2, count: 11))
        XCTAssertFalse(result.jsonComplete)
        XCTAssertEqual(result.termination(isCancelled: false, grammarFailed: false,
            grammarEnabled: false, grammarTerminated: false), .outputLimit)
    }

    func testBracesInsideEscapedStringsDoNotCompleteOrDiscardNestedContent() async throws {
        let vocab = ["<eos>", #"{"text":"brace } [ and escaped \" {"#,
                     #"","nested":[{"x":1}]}"#, " "]
        XCTAssertNil(QwenJSONObject.complete(vocab[1]))
        let run = try makeProducer(vocab: vocab, tokens: [1,2,3], limit: 100)
        let result = await QwenTokenStream.collect(stream: run.stream, producer: run.task,
            tokenizer: CompletionTokenizer(vocab: vocab), stopAtCompleteJSON: true)
        Stream.defaultStream.synchronize()
        XCTAssertEqual(result.tokens, [1,2])
        let value = try XCTUnwrap(QwenJSONObject.complete(vocab[1] + vocab[2]))
        XCTAssertTrue(value.contains(#""nested":[{"x":1}]"#))
    }

    func testFencesMustBeCompleteAndSameTokenTrailingGarbageIsRejected() async throws {
        for invalid in ["```json\n{}", "```\n{}", "{} trailing", "{}{}", "[{}]", "{\"x\":{}} trailing"] {
            XCTAssertNil(QwenJSONObject.complete(invalid), invalid)
        }
        XCTAssertEqual(QwenJSONObject.complete("```json\n{}\n```"), "{}")
        XCTAssertEqual(QwenJSONObject.complete("```\n{}\n```"), "{}")
        let vocab = ["<eos>", "```json\n", "{}", "\n```", " "]
        let run = try makeProducer(vocab: vocab, tokens: [1,2,3,4], limit: 100)
        let result = await QwenTokenStream.collect(stream: run.stream, producer: run.task,
            tokenizer: CompletionTokenizer(vocab: vocab), stopAtCompleteJSON: true)
        Stream.defaultStream.synchronize()
        XCTAssertEqual(result.tokens, [1,2,3])
        XCTAssertTrue(result.jsonComplete)
    }

    func testIncompleteAtLengthLimitRejectsAndExactlyCompleteAtLimitIsAccepted() async throws {
        let vocab = ["<eos>", "{", "\"x\"", ":", "1", "}"]
        for limit in [4,5] {
            let run = try makeProducer(vocab: vocab, tokens: [1,2,3,4,5], limit: limit)
            let result = await QwenTokenStream.collect(stream: run.stream, producer: run.task,
                tokenizer: CompletionTokenizer(vocab: vocab), stopAtCompleteJSON: true)
            Stream.defaultStream.synchronize()
            let reason = result.termination(isCancelled: false, grammarFailed: false,
                grammarEnabled: false, grammarTerminated: false)
            let raw = CompletionTokenizer(vocab: vocab).decode(tokenIds: result.tokens, skipSpecialTokens: false)
            if limit == 4 {
                XCTAssertEqual(reason, .outputLimit)
                XCTAssertThrowsError(try QwenJSONObject.validate(raw, termination: reason)) {
                    guard case QwenError.outputLimit = $0 else { return XCTFail("Incomplete output must retain its length failure") }
                }
            } else {
                XCTAssertEqual(reason, .jsonComplete)
                XCTAssertEqual(try QwenJSONObject.validate(raw, termination: reason), #"{"x":1}"#)
            }
        }
        // Even if the SDK's length event wins, a fully complete raw object is valid.
        XCTAssertEqual(try QwenJSONObject.validate("{}  \n", termination: .outputLimit), "{}")
        XCTAssertNil(QwenJSONObject.complete("{\"x\":1} garbage"))
    }

    func testActualUserCancellationWinsOverObjectCompletionAndSettlesProducer() async throws {
        let vocab = ["<eos>", "{}", " "]
        let run = try makeProducer(vocab: vocab, tokens: [1,2], limit: 3072)
        let stream = run.stream, producer = run.task
        let owner = CancellationOwner()
        let task = Task { () -> (QwenTokenStreamResult, Bool) in
            await owner.waitUntilInstalled()
            let result = await QwenTokenStream.collect(stream: stream, producer: producer,
                tokenizer: CompletionTokenizer(vocab: vocab), stopAtCompleteJSON: true,
                onFirstToken: { owner.cancel() })
            Stream.defaultStream.synchronize()
            return (result, Task.isCancelled)
        }
        owner.install(task)
        let (result, cancelled) = await task.value
        owner.clear()
        XCTAssertTrue(cancelled)
        XCTAssertTrue(result.jsonComplete, "The same token races a valid object with an actual caller cancellation")
        XCTAssertEqual(result.termination(isCancelled: cancelled, grammarFailed: false,
            grammarEnabled: false, grammarTerminated: false), .cancelled)
        let calls = run.model.calls; try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(run.model.calls, calls)
    }

    func testCompletionMetadataAndGrammarFailurePrecedenceAreExplicit() throws {
        let result = QwenTokenStreamResult(tokens: [1], nativeStopReason: nil, jsonComplete: true)
        XCTAssertEqual(result.termination(isCancelled: false, grammarFailed: true,
            grammarEnabled: true, grammarTerminated: false), .grammarFailure)
        let completion = QwenGenerationCompletion(reason: .jsonComplete, inputTokenCount: 3,
            generatedTokenCount: 1, tokenLimit: 3072, grammarEnabled: true, grammarTerminated: false)
        let encoded = try JSONEncoder().encode(completion)
        let decoded = try JSONDecoder().decode(QwenGenerationCompletion.self, from: encoded)
        XCTAssertEqual(decoded.reason, .jsonComplete); XCTAssertFalse(decoded.grammarTerminated)
        XCTAssertNil(QwenJSONObject.complete(String(repeating: " ", count: QwenJSONObject.maximumUTF8Bytes) + "{}"))
    }

    private func makeProducer(vocab: [String], tokens: [Int], limit: Int) throws ->
        (stream: AsyncStream<TokenGeneration>, task: Task<Void, Never>, model: CompletionModel) {
        MLX.compile(enable: false)
        let model = CompletionModel(tokens: tokens, vocabularySize: vocab.count)
        let iterator = try TokenIterator(input: LMInput(tokens: MLXArray([1])), model: model,
            parameters: GenerateParameters(maxTokens: limit, temperature: 0))
        let (stream, task) = MLXLMCommon.generateTokenTask(promptTokenCount: 1,
            modelConfiguration: ModelConfiguration(id: "synthetic-json-completion"),
            tokenizer: CompletionTokenizer(vocab: vocab), iterator: iterator)
        return (stream, task, model)
    }
}

private final class CancellationOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<(QwenTokenStreamResult, Bool), Never>?
    func install(_ task: Task<(QwenTokenStreamResult, Bool), Never>) { lock.withLock { self.task = task } }
    func cancel() { lock.withLock { task?.cancel() } }
    func clear() { lock.withLock { task = nil } }
    func waitUntilInstalled() async { while lock.withLock({ task == nil }) { await Task.yield() } }
}

private struct CompletionTokenizer: MLXLMCommon.Tokenizer {
    let vocab: [String]
    var bosToken: String? { nil }; var eosToken: String? { vocab.first }; var unknownToken: String? { nil }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { tokenIds.map { vocab[$0] }.joined() }
    func convertTokenToId(_ token: String) -> Int? { vocab.firstIndex(of: token) }
    func convertIdToToken(_ id: Int) -> String? { vocab.indices.contains(id) ? vocab[id] : nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}

private final class CompletionModel: Module, LanguageModel, KVCacheDimensionProvider {
    let vocabularySize: Int
    let tokens: [Int]
    private let lock = NSLock()
    private var cursor = 0
    var calls: Int { lock.withLock { cursor } }
    var kvHeads: [Int] { [] }
    init(tokens: [Int], vocabularySize: Int) { self.tokens = tokens; self.vocabularySize = vocabularySize; super.init() }
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?, prefill: PrefillParameters) throws -> PrepareResult { .tokens(input.text) }
    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let token = lock.withLock { let value = tokens[min(cursor, tokens.count-1)]; cursor += 1; return value }
        Thread.sleep(forTimeInterval: 0.001) // Keep this native mock producer genuinely live until cancellation.
        var logits = [Float](repeating: -10, count: vocabularySize); logits[token] = 100
        return MLXArray(logits, [1,1,vocabularySize])
    }
}

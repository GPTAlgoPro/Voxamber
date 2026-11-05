import Foundation
import MLX
import MLXNN
import MLXLMCommon
import MLXGuidedGeneration
import XCTest
@testable import QwenNative

final class NativeJSONGrammarTests: XCTestCase {
    // Small literal vocab exercises the real vendored native matcher without
    // downloading/loading a model. Token zero is the native stop token.
    private let vocab = ["<eos>", "{", "}", "\"x\"", ":", "1", "2", ",", " ", "[", "]", "bad"]
    private let schema = #"{"type":"object","properties":{"x":{"type":"integer","enum":[1,2]}},"required":["x"],"additionalProperties":false}"#

    private func tokenizer() throws -> GrammarTokenizer {
        try GrammarTokenizer(vocab: vocab, vocabType: .raw, eosTokenId: 0)
    }
    private func template() throws -> NativeGrammarTemplate {
        try NativeGrammarTemplate(tokenizer: tokenizer(), schema: schema)
    }
    private func sample(_ processor: NativeJSONGrammarProcessor, preferred id: Int,
                        padded: Int = 0) -> Int {
        var scores = [Float](repeating: -10, count: vocab.count + padded)
        scores[id] = 100
        let token = argMax(processor.process(logits: MLXArray(scores)), axis: -1)
        processor.didSample(token: token)
        return token.item(Int.self)
    }
    private func prefix(_ processor: NativeJSONGrammarProcessor) {
        for id in [1, 3, 4] { XCTAssertEqual(sample(processor, preferred: id), id) }
    }

    func testRealGrammarMasksInvalidAndPaddedTokens() throws {
        let processor = NativeJSONGrammarProcessor(template: try template(), eosID: 0, vocabSize: vocab.count)
        processor.prompt(MLXArray([11, 11, 11])) // prompt must not become JSON response state
        XCTAssertEqual(sample(processor, preferred: 11), 1)
        XCTAssertEqual(sample(processor, preferred: 3), 3)
        XCTAssertEqual(sample(processor, preferred: 4), 4)
        XCTAssertEqual(sample(processor, preferred: 5), 5)
        XCTAssertEqual(sample(processor, preferred: 2), 2)
        XCTAssertEqual(sample(processor, preferred: vocab.count + 4, padded: 8), 0)
        XCTAssertTrue(processor.state.snapshot.terminated)
        XCTAssertNil(processor.state.snapshot.failure)
    }

    func testEOSLookaheadIsIdempotentAndOnlyEOSRemainsAllowed() throws {
        let processor = NativeJSONGrammarProcessor(template: try template(), eosID: 0, vocabSize: vocab.count)
        prefix(processor)
        for id in [5, 2, 0, 0, 0] { XCTAssertEqual(sample(processor, preferred: id), id) }
        XCTAssertEqual(sample(processor, preferred: 11), 0)
        XCTAssertTrue(processor.state.snapshot.terminated)
        XCTAssertNil(processor.state.snapshot.failure)
    }

    func testCopyAndNewRequestHaveIndependentMatcherAndFailureState() throws {
        let template = try template()
        let original = NativeJSONGrammarProcessor(template: template, eosID: 0, vocabSize: vocab.count)
        prefix(original)
        let fork = original.copy()
        for id in [5, 2, 0] { XCTAssertEqual(sample(original, preferred: id), id) }
        XCTAssertFalse(fork.state.snapshot.terminated)
        for id in [6, 2, 0] { XCTAssertEqual(sample(fork, preferred: id), id) }
        fork.didSample(token: MLXArray(11)) // a post-EOS non-stop token is rejected
        XCTAssertNotNil(fork.state.snapshot.failure)
        XCTAssertNil(original.state.snapshot.failure)
        let next = NativeJSONGrammarProcessor(template: template, eosID: 0, vocabSize: vocab.count)
        XCTAssertFalse(next.state.snapshot.terminated)
        XCTAssertEqual(sample(next, preferred: 1), 1)
    }

    func testRejectedCommitFailsClosedAndPreservesFailure() throws {
        let processor = NativeJSONGrammarProcessor(template: try template(), eosID: 0, vocabSize: vocab.count)
        processor.didSample(token: MLXArray(11)) // deliberately bypass sampling mask
        XCTAssertEqual(processor.state.snapshot.failure, .rejectedToken)
        XCTAssertEqual(sample(processor, preferred: 1), 0)
        XCTAssertFalse(processor.state.snapshot.terminated)
        XCTAssertEqual(processor.state.snapshot.failure, .rejectedToken)
    }

    func testPackedMaskSignedBoundaryPaddingAndMalformedMasks() throws {
        let mask = try NativeJSONGrammarProcessor.additiveMask(mask: [Int32.min, 1], needsApply: true,
                                                               vocabSize: 33, logitCount: 40)
        XCTAssertEqual(mask[31], 0)
        XCTAssertEqual(mask[32], 0)
        XCTAssertEqual(mask[0], -.infinity)
        XCTAssertEqual(mask[39], -.infinity)
        let unrestricted = try NativeJSONGrammarProcessor.additiveMask(mask: [], needsApply: false,
                                                                       vocabSize: 3, logitCount: 5)
        XCTAssertEqual(unrestricted, [0, 0, 0, -.infinity, -.infinity])
        let trimmed = try NativeJSONGrammarProcessor.additiveMask(mask: [1, 0], needsApply: true,
                                                                  vocabSize: 33, logitCount: 2)
        XCTAssertEqual(trimmed, [0, -.infinity])
        XCTAssertThrowsError(try NativeJSONGrammarProcessor.additiveMask(mask: [], needsApply: true,
                                                                        vocabSize: 33, logitCount: 40))
        XCTAssertThrowsError(try NativeJSONGrammarProcessor.additiveMask(mask: [0], needsApply: true,
                                                                        vocabSize: 12, logitCount: 12))
    }

    func testFloatCompatibilityChangesOnlySchemaNumberBounds() throws {
        let source = #"{"type":"object","properties":{"value":{"type":"number","minimum":0,"maximum":1,"exclusiveMinimum":-1,"exclusiveMaximum":2},"index":{"type":"integer","minimum":0,"maximum":1023},"literal":{"const":{"type":"number","minimum":7}}},"required":["value"],"additionalProperties":false,"maxProperties":3}"#
        let normalized = try NativeGrammarSchema(source)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(normalized.text.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(properties["value"]).keys), ["type"])
        XCTAssertEqual(properties["index"]?["maximum"] as? Int, 1023)
        XCTAssertEqual((properties["literal"]?["const"] as? [String: Any])?["minimum"] as? Int, 7)
        XCTAssertEqual(root["additionalProperties"] as? Bool, false)
        XCTAssertEqual(root["maxProperties"] as? Int, 3)
        XCTAssertTrue(normalized.metadata.floatBoundsRequireNativeValidation)
        XCTAssertNotEqual(normalized.metadata.originalSchemaSHA256, normalized.metadata.compiledSchemaSHA256)
        let unchanged = try NativeGrammarSchema(schema)
        XCTAssertFalse(unchanged.metadata.floatBoundsRequireNativeValidation)
        XCTAssertEqual(try NativeGrammarSchema(unchanged.text).text, unchanged.text)
    }

    func testCompilerOrderUsesRequiredThenSortedOptionalWithoutInterpretingLiterals() throws {
        let literal: [String: Any] = [
            "type": "number", "minimum": 7,
            "properties": ["z": ["type": "number", "minimum": 8], "a": ["type": "integer"]],
            "required": ["z", "a"]
        ]
        let child: [String: Any] = [
            "type": "object", "properties": ["z": ["type": "integer"], "a": ["type": "integer"],
                                                "optionalZ": [:], "optionalA": [:]],
            "required": ["z", "a"], "const": literal, "default": literal,
            "enum": [literal], "examples": [literal]
        ]
        let sourceObject: [String: Any] = [
            "type": "object", "properties": ["z": child, "a": ["type": "string"],
                                                "optionalZ": [:], "optionalA": [:]],
            "required": ["z", "a"], "$defs": ["nested": child],
            "allOf": [child], "if": child, "then": child, "else": child,
            "items": child, "prefixItems": [child], "additionalProperties": child,
            "dependentSchemas": ["nested": child], "patternProperties": ["nested": child]
        ]
        let source = String(decoding: try JSONSerialization.data(withJSONObject: sourceObject,
            options: [.sortedKeys]), as: UTF8.self)
        let result = try NativeGrammarSchema(source)
        let decoded = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? NSDictionary
        XCTAssertEqual(decoded, sourceObject as NSDictionary, "Ordering must not change schema values")
        XCTAssertFalse(result.metadata.floatBoundsRequireNativeValidation,
                       "Literal type:number payloads must not trigger bound normalization")
        XCTAssertTrue(result.text.contains(#""properties":{"z":{"type":"integer"},"a":{"type":"integer"},"optionalA":{},"optionalZ":{}}"#))
        XCTAssertTrue(result.text.contains(#""properties":{"a":{"type":"integer"},"z":{"minimum":8,"type":"number"}}"#),
                      "Literal properties/required objects stay literal JSON")
        XCTAssertNotEqual(result.metadata.originalSchemaSHA256, result.metadata.compiledSchemaSHA256)
        XCTAssertEqual(try NativeGrammarSchema(result.text).text, result.text)
    }

    func testCacheReusesTemplateButResetReleasesNativeOwners() throws {
        let cache = NativeJSONGrammarCache()
        var builds = 0
        weak var weakTokenizer: GrammarTokenizer?
        weak var weakTemplate: NativeGrammarTemplate?
        try autoreleasepool {
            let a = try cache.session(schema: schema, eosID: 0) { builds += 1; return try tokenizer() }
            let b = try cache.session(schema: schema, eosID: 0) { builds += 1; return try tokenizer() }
            XCTAssertTrue(a.template === b.template)
            XCTAssertFalse(a.state === b.state)
            XCTAssertEqual(builds, 1)
            weakTokenizer = cache.cachedObjects.0
            weakTemplate = cache.cachedObjects.1
            cache.reset()
            XCTAssertNotNil(weakTemplate) // sessions legitimately pin their template
        }
        XCTAssertNil(weakTemplate)
        XCTAssertNil(weakTokenizer)
        XCTAssertNil(cache.cachedObjects.0)
        XCTAssertNil(cache.cachedObjects.1)
    }

    func testInvalidSchemaFailsClosedAndDropsPreviousTemplate() throws {
        let cache = NativeJSONGrammarCache()
        _ = try cache.session(schema: schema, eosID: 0, makeTokenizer: tokenizer)
        XCTAssertThrowsError(try cache.session(schema: #"{"type":42}"#, eosID: 0,
                                              makeTokenizer: tokenizer)) { error in
            guard case QwenError.grammarFailure = error else { return XCTFail("Unsanitized error") }
        }
        XCTAssertNil(cache.cachedObjects.1)
        _ = try cache.session(schema: schema, eosID: 0, makeTokenizer: tokenizer)
        XCTAssertNotNil(cache.cachedObjects.1)
        cache.reset()
    }

    func testRepeatedNativeCacheCyclesReleaseAllTemplates() throws {
        let cache = NativeJSONGrammarCache()
        for _ in 0..<30 {
            weak var owner: NativeGrammarTemplate?
            try autoreleasepool {
                let session = try cache.session(schema: schema, eosID: 0, makeTokenizer: tokenizer)
                owner = session.template
                let processor = NativeJSONGrammarProcessor(template: session.template, eosID: 0,
                                                           vocabSize: vocab.count)
                prefix(processor)
                for id in [5, 2, 0] { XCTAssertEqual(sample(processor, preferred: id), id) }
                cache.reset()
            }
            XCTAssertNil(owner)
        }
        Stream.defaultStream.synchronize()
        Memory.clearCache()
    }

    func testActualTokenIteratorComponentsHandleOneTokenLookahead() throws {
        MLX.compile(enable: false)
        let session = NativeJSONGrammarSession(template: try template(), eosID: 0, vocabSize: vocab.count)
        let model = ScriptedGrammarModel(tokens: [1, 3, 4, 5, 2, 0, 0], vocabularySize: vocab.count + 4)
        var iterator = try TokenIterator(input: LMInput(tokens: MLXArray([11])), model: model,
            parameters: GenerateParameters(maxTokens: 16, temperature: 0), components: session.components)
        var received: [Int] = []
        while let token = iterator.next() {
            if token == 0 { break }
            received.append(token)
        }
        XCTAssertEqual(received, [1, 3, 4, 5, 2])
        XCTAssertTrue(session.state.snapshot.terminated)
        XCTAssertNil(session.state.snapshot.failure)
        Stream.defaultStream.synchronize()
    }

    func testPublicRawProducerReportsStopVersusLengthWithGrammar() async throws {
        for limit in [3, 16] {
            let session = NativeJSONGrammarSession(template: try template(), eosID: 0, vocabSize: vocab.count)
            let model = ScriptedGrammarModel(tokens: [1, 3, 4, 5, 2, 0, 0], vocabularySize: vocab.count)
            let iterator = try TokenIterator(input: LMInput(tokens: MLXArray([11])), model: model,
                parameters: GenerateParameters(maxTokens: limit, temperature: 0), components: session.components)
            let (stream, producer) = MLXLMCommon.generateTokenTask(promptTokenCount: 1,
                modelConfiguration: ModelConfiguration(id: "synthetic-grammar-test"),
                tokenizer: LiteralTestTokenizer(vocab: vocab), iterator: iterator)
            var received: [Int] = []
            var info: GenerateCompletionInfo?
            for await event in stream {
                switch event {
                case .token(let token): received.append(token)
                case .info(let value): info = value
                }
            }
            await producer.value
            Stream.defaultStream.synchronize()
            XCTAssertNil(session.state.snapshot.failure)
            XCTAssertEqual(info?.generationTokenCount, received.count)
            if limit == 3 {
                XCTAssertEqual(received, [1, 3, 4])
                guard case .length = info?.stopReason else { return XCTFail("Expected SDK length") }
                XCTAssertFalse(session.state.snapshot.terminated)
            } else {
                XCTAssertEqual(received, [1, 3, 4, 5, 2])
                guard case .stop = info?.stopReason else { return XCTFail("Expected SDK stop") }
                XCTAssertTrue(session.state.snapshot.terminated)
            }
        }
    }

    func testPublicRawProducerCancellationSettlesWithGrammar() async throws {
        let session = NativeJSONGrammarSession(template: try template(), eosID: 0, vocabSize: vocab.count)
        let model = ScriptedGrammarModel(tokens: [8], vocabularySize: vocab.count)
        let iterator = try TokenIterator(input: LMInput(tokens: MLXArray([11])), model: model,
            parameters: GenerateParameters(maxTokens: 3072, temperature: 0), components: session.components)
        let (stream, producer) = MLXLMCommon.generateTokenTask(promptTokenCount: 1,
            modelConfiguration: ModelConfiguration(id: "synthetic-cancellation-test"),
            tokenizer: LiteralTestTokenizer(vocab: vocab), iterator: iterator)
        var cancelBegan: ContinuousClock.Instant?
        for await event in stream {
            if case .token = event {
                cancelBegan = .now
                producer.cancel()
                break
            }
        }
        await producer.value
        Stream.defaultStream.synchronize()
        XCTAssertNotNil(cancelBegan)
        if let cancelBegan { XCTAssertLessThan(cancelBegan.duration(to: .now), .seconds(2)) }
        XCTAssertNil(session.state.snapshot.failure)
    }
}

private struct LiteralTestTokenizer: MLXLMCommon.Tokenizer {
    let vocab: [String]
    var bosToken: String? { nil }
    var eosToken: String? { vocab.first }
    var unknownToken: String? { nil }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        tokenIds.filter { !skipSpecialTokens || $0 != 0 }.map { vocab[$0] }.joined()
    }
    func convertTokenToId(_ token: String) -> Int? { vocab.firstIndex(of: token) }
    func convertIdToToken(_ id: Int) -> String? { vocab.indices.contains(id) ? vocab[id] : nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] { [] }
}

private final class ScriptedGrammarModel: Module, LanguageModel, KVCacheDimensionProvider {
    let vocabularySize: Int
    let tokens: [Int]
    private var cursor = 0
    var kvHeads: [Int] { [] }
    init(tokens: [Int], vocabularySize: Int) {
        self.tokens = tokens
        self.vocabularySize = vocabularySize
        super.init()
    }
    func prepare(_ input: LMInput, cache: [KVCache], state: LMOutput.State?,
                 prefill: PrefillParameters) throws -> PrepareResult { .tokens(input.text) }
    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let next = tokens[min(cursor, tokens.count - 1)]
        cursor += 1
        var logits = [Float](repeating: -10, count: vocabularySize)
        logits[next] = 100
        return MLXArray(logits, [1, 1, vocabularySize])
    }
}

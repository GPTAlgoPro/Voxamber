import Foundation
import CryptoKit
import MLX
import MLXGuidedGeneration
import MLXLMCommon

/// Stable, content-free failure categories. Never expose xgrammar's diagnostic strings:
/// they can contain schema fragments or sampled token IDs.
enum NativeGrammarFailure: String, Sendable {
    case tokenizer, schema, clone, mask, rejectedToken, vocabulary, incomplete
}

/// Compile compatibility for vendored xgrammar v0.1.30: bounded `number`
/// grammars incorrectly cap precision at six decimals and exclude exponents.
/// Remove only floating-point bounds at this boundary; the authoritative schema
/// is untouched. ScenePlan must check ALL numeric bounds after decoding. Integer
/// bounds, array cardinalities, patterns, required fields and extra-key rules stay.
/// This compiler also enforces schema property order. Serialize each `properties`
/// map with required[] keys first in their declared order, then sorted optional
/// keys. This changes generation order only, not the authoritative contract.
struct NativeGrammarSchema {
    let text: String
    let metadata: QwenGrammarMetadata

    init(_ source: String) throws {
        var changed = false
        func visit(_ value: Any) -> Any {
            guard var object = value as? [String: Any] else { return value }
            if object["type"] as? String == "number" {
                for key in ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"] {
                    if object.removeValue(forKey: key) != nil { changed = true }
                }
            }
            // Traverse schema positions only. `const`, `enum`, defaults and
            // annotations can contain arbitrary objects and must remain literal.
            for key in ["$defs", "definitions", "properties", "patternProperties", "dependentSchemas"] {
                if let children = object[key] as? [String: Any] {
                    object[key] = children.mapValues(visit)
                }
            }
            for key in ["items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
                        "propertyNames", "contains", "not", "if", "then", "else"] {
                if let child = object[key] {
                    if let children = child as? [Any] { object[key] = children.map(visit) }
                    else { object[key] = visit(child) }
                }
            }
            for key in ["anyOf", "oneOf", "allOf", "prefixItems"] {
                if let children = object[key] as? [Any] { object[key] = children.map(visit) }
            }
            return object
        }
        func literalJSON(_ value: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        }
        func schemaJSON(_ value: Any) throws -> String {
            guard let object = value as? [String: Any] else { return try literalJSON(value) }
            func schemaMap(_ children: [String: Any], keys: [String]) throws -> String {
                let pairs = try keys.map { key in
                    try literalJSON(key) + ":" + schemaJSON(children[key]!)
                }
                return "{" + pairs.joined(separator: ",") + "}"
            }
            let pairs = try object.keys.sorted().map { key -> String in
                let child = object[key]!
                let encoded: String
                switch key {
                case "properties":
                    if let children = child as? [String: Any] {
                        var seen: Set<String> = []
                        let required = (object["required"] as? [String] ?? []).filter {
                            children[$0] != nil && seen.insert($0).inserted
                        }
                        let optional = children.keys.filter { !seen.contains($0) }.sorted()
                        encoded = try schemaMap(children, keys: required + optional)
                    } else { encoded = try literalJSON(child) }
                case "$defs", "definitions", "patternProperties", "dependentSchemas":
                    if let children = child as? [String: Any] {
                        encoded = try schemaMap(children, keys: children.keys.sorted())
                    } else { encoded = try literalJSON(child) }
                case "items", "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
                     "propertyNames", "contains", "not", "if", "then", "else":
                    if let children = child as? [Any] {
                        encoded = try "[" + children.map(schemaJSON).joined(separator: ",") + "]"
                    } else { encoded = try schemaJSON(child) }
                case "anyOf", "oneOf", "allOf", "prefixItems":
                    if let children = child as? [Any] {
                        encoded = try "[" + children.map(schemaJSON).joined(separator: ",") + "]"
                    } else { encoded = try literalJSON(child) }
                default:
                    // Literal const/default/enum objects may themselves contain
                    // properties/required/type keys. Never treat them as schemas.
                    encoded = try literalJSON(child)
                }
                return try literalJSON(key) + ":" + encoded
            }
            return "{" + pairs.joined(separator: ",") + "}"
        }
        do {
            let object = try JSONSerialization.jsonObject(with: Data(source.utf8), options: [.fragmentsAllowed])
            let normalized = visit(object)
            text = try schemaJSON(normalized)
            func hash(_ value: String) -> String {
                SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            metadata = QwenGrammarMetadata(originalSchemaSHA256: hash(source),
                compiledSchemaSHA256: hash(text), floatBoundsRequireNativeValidation: changed)
        } catch { throw QwenError.grammarFailure }
    }
}

/// The pinned 3.32.3 Swift bridge exposes clone(), but its vendored xgrammar
/// v0.1.30 C shim deliberately returns forkFailed. Recompile/replay is the
/// supported fallback; never share a mutable matcher between requests/copies.
final class NativeGrammarTemplate: @unchecked Sendable {
    private let tokenizer: GrammarTokenizer
    private let schema: String
    let metadata: QwenGrammarMetadata
    private let lock = NSLock()
    private var compiled: GrammarConstraint?

    init(tokenizer: GrammarTokenizer, schema: String) throws {
        self.tokenizer = tokenizer
        let normalized = try NativeGrammarSchema(schema)
        self.schema = normalized.text
        self.metadata = normalized.metadata
        compiled = try GrammarConstraint(tokenizer: tokenizer, jsonSchema: normalized.text, fastForward: false)
    }

    func freshConstraint() throws -> GrammarConstraint {
        try lock.withLock {
            if let compiled {
                do { return try compiled.clone() }
                catch GrammarError.forkFailed {
                    // Hand off the pristine original exactly once. Keeping it
                    // cached would retain a mutable request's entire matcher.
                    self.compiled = nil
                    return compiled
                }
            }
            return try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schema, fastForward: false)
        }
    }

    func copyConstraint(_ current: GrammarConstraint, replaying tokens: [Int32]) throws -> GrammarConstraint {
        do { return try current.clone() }
        catch GrammarError.forkFailed {
            let rebuilt = try GrammarConstraint(tokenizer: tokenizer, jsonSchema: schema, fastForward: false)
            for token in tokens { _ = try rebuilt.commitToken(token) }
            return rebuilt
        }
    }
}

/// Read by the stream consumer while the SDK's generation worker owns the matcher.
final class NativeGrammarState: @unchecked Sendable {
    private let lock = NSLock()
    private var failureValue: NativeGrammarFailure?
    private var terminatedValue = false

    var snapshot: (failure: NativeGrammarFailure?, terminated: Bool) {
        lock.withLock { (failureValue, terminatedValue) }
    }
    func fail(_ failure: NativeGrammarFailure) {
        lock.withLock { if failureValue == nil { failureValue = failure } }
    }
    func terminate() { lock.withLock { terminatedValue = true } }
    func independentCopy() -> NativeGrammarState {
        let value = snapshot
        let result = NativeGrammarState()
        if let failure = value.failure { result.fail(failure) }
        if value.terminated { result.terminate() }
        return result
    }
}

/// One tokenizer and one schema recipe per loaded model. A pristine compiled
/// template is shared only if native forking works; the pinned fallback hands it
/// off once, then recompiles. Replacing the schema/unload drops all cached owners.
final class NativeJSONGrammarCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tokenizer: GrammarTokenizer?
    private var schema: String?
    private var template: NativeGrammarTemplate?

    func session(schema: String, eosID: Int,
                 makeTokenizer: () throws -> GrammarTokenizer) throws -> NativeJSONGrammarSession {
        try lock.withLock {
            guard eosID >= 0, eosID <= Int(Int32.max) else { throw QwenError.grammarFailure }
            if tokenizer == nil {
                do { tokenizer = try makeTokenizer() }
                catch { throw QwenError.grammarFailure }
            }
            guard let tokenizer, eosID < tokenizer.vocabSize else { throw QwenError.grammarFailure }
            if self.schema != schema || template == nil {
                // Do not retain an old compiled template after a replacement fails.
                template = nil
                self.schema = nil
                do {
                    template = try NativeGrammarTemplate(tokenizer: tokenizer, schema: schema)
                    self.schema = schema
                } catch { throw QwenError.grammarFailure }
            }
            guard let template else { throw QwenError.grammarFailure }
            return NativeJSONGrammarSession(template: template, eosID: eosID,
                                            vocabSize: tokenizer.vocabSize)
        }
    }

    func reset() {
        lock.withLock { template = nil; schema = nil; tokenizer = nil }
    }

    // Weak-reference lifecycle tests inspect these without retaining cache contents.
    var cachedObjects: (GrammarTokenizer?, NativeGrammarTemplate?) {
        lock.withLock { (tokenizer, template) }
    }
}

struct NativeJSONGrammarSession: Sendable {
    let template: NativeGrammarTemplate
    let eosID: Int
    let vocabSize: Int
    let state = NativeGrammarState()

    var components: GenerationComponents {
        GenerationComponents(logitProcessorFactory: {
            NativeJSONGrammarProcessor(template: template, eosID: eosID,
                                       vocabSize: vocabSize, state: state)
        })
    }
}

/// Adapter for the existing TokenIterator. Fast-forward is disabled: every accepted
/// token must travel through that iterator's normal output and KV-cache path.
final class NativeJSONGrammarProcessor: LogitProcessor {
    private let constraint: GrammarConstraint?
    private let template: NativeGrammarTemplate
    private let eosID: Int
    private let vocabSize: Int
    private var acceptedTokens: [Int32] = []
    let state: NativeGrammarState

    init(template: NativeGrammarTemplate, eosID: Int, vocabSize: Int,
         state: NativeGrammarState = NativeGrammarState()) {
        self.eosID = eosID
        self.vocabSize = vocabSize
        self.state = state
        self.template = template
        do { constraint = try template.freshConstraint() }
        catch { constraint = nil; state.fail(.clone) }
    }

    private init(constraint: GrammarConstraint?, template: NativeGrammarTemplate,
                 eosID: Int, vocabSize: Int, state: NativeGrammarState, acceptedTokens: [Int32]) {
        self.constraint = constraint
        self.template = template
        self.eosID = eosID
        self.vocabSize = vocabSize
        self.state = state
        self.acceptedTokens = acceptedTokens
    }

    // A factory supplies a fresh matcher. Prompt tokens are context, not response
    // grammar tokens, and must never be committed to the matcher.
    func prompt(_ prompt: MLXArray) {}

    func process(logits: MLXArray) -> MLXArray {
        let count = logits.shape.last ?? 0
        guard state.snapshot.failure == nil, let constraint else { return forcedEOS(logits: logits) }
        if state.snapshot.terminated { return forcedEOS(logits: logits) }
        do {
            let mask = try constraint.computeMask()
            if mask.isTerminated { state.terminate(); return forcedEOS(logits: logits) }
            let values = try Self.additiveMask(mask: mask.mask, needsApply: mask.needsApply,
                                               vocabSize: vocabSize, logitCount: count)
            return logits + MLXArray(values).asType(logits.dtype)
        } catch {
            state.fail(.mask)
            return forcedEOS(logits: logits)
        }
    }

    func didSample(token: MLXArray) {
        guard state.snapshot.failure == nil else { return }
        let id = token.item(Int.self)
        // TokenIterator samples one token ahead of the token it emits. After the
        // matcher accepts EOS it can be asked for another EOS before the producer
        // observes the first one. Do not double-commit it to a terminated matcher.
        if state.snapshot.terminated {
            if id != eosID { state.fail(.rejectedToken) }
            return
        }
        guard id >= 0, id < vocabSize, let constraint else {
            state.fail(.vocabulary); return
        }
        do {
            let result = try constraint.commitToken(Int32(id))
            guard result.tokens.isEmpty else { state.fail(.rejectedToken); return }
            acceptedTokens.append(Int32(id))
            if result.isTerminated { state.terminate() }
        } catch { state.fail(.rejectedToken) }
    }

    func copy() -> NativeJSONGrammarProcessor {
        let copiedState = state.independentCopy()
        let copiedConstraint: GrammarConstraint?
        do {
            if let constraint { copiedConstraint = try template.copyConstraint(constraint, replaying: acceptedTokens) }
            else { copiedConstraint = nil }
        }
        catch { copiedConstraint = nil; copiedState.fail(.clone) }
        return NativeJSONGrammarProcessor(constraint: copiedConstraint, template: template, eosID: eosID,
                                           vocabSize: vocabSize, state: copiedState, acceptedTokens: acceptedTokens)
    }

    private func forcedEOS(logits: MLXArray) -> MLXArray {
        // Failure is communicated separately and the consumer throws after awaiting
        // the producer. The deterministic EOS prevents unconstrained continuation.
        let count = logits.shape.last ?? 0
        var values = [Float](repeating: -.infinity, count: max(1, count))
        if eosID >= 0, eosID < count { values[eosID] = 0 }
        else { values[0] = 0; state.fail(.vocabulary) }
        return broadcast(MLXArray(values).asType(logits.dtype), to: logits.shape)
    }

    /// Packed-mask conversion follows the SDK's GuidedGenerationLoop, with explicit
    /// size/no-legal-token checks. Padded model logits always remain forbidden,
    /// including when xgrammar reports an otherwise unrestricted mask.
    static func additiveMask(mask: [Int32], needsApply: Bool,
                             vocabSize: Int, logitCount: Int) throws -> [Float] {
        guard vocabSize > 0, logitCount > 0,
              !needsApply || mask.count >= (vocabSize + 31) / 32 else {
            throw QwenError.grammarFailure
        }
        var values = [Float](repeating: -.infinity, count: logitCount)
        var allowed = false
        for id in 0..<min(vocabSize, logitCount) {
            if !needsApply || (UInt32(bitPattern: mask[id / 32]) >> UInt32(id % 32)) & 1 != 0 {
                values[id] = 0
                allowed = true
            }
        }
        guard allowed else { throw QwenError.grammarFailure }
        return values
    }
}

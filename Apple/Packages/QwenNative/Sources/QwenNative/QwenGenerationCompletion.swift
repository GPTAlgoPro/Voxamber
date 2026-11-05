import Foundation

/// Only the SDK's documented distinction is preserved: `stop` can mean EOS or
/// unknown token, and must not be reported as a confirmed EOS for raw generation.
public enum QwenTerminationReason: String, Codable, Sendable {
    case stop, outputLimit, cancelled, grammarFailure
    /// A valid complete object was emitted; the owned producer was stopped and
    /// awaited. This is not evidence of EOS or of native scene validity.
    case jsonComplete
}

public struct QwenGrammarMetadata: Codable, Sendable {
    public let originalSchemaSHA256: String
    public let compiledSchemaSHA256: String
    /// The pinned compiler limits bounded floats to six decimal places. Only
    /// those bounds are deferred; callers must validate decoded numeric values.
    public let floatBoundsRequireNativeValidation: Bool
}

/// Content-free terminal evidence. Counts cover consumed output tokens and
/// exclude the SDK's discarded stop token. On jsonComplete the producer may
/// already have buffered lookahead; no unconsumed tokens are reported as output.
/// grammarTerminated refers to matcher acceptance, including its one-token lookahead.
public struct QwenGenerationCompletion: Codable, Sendable {
    public let reason: QwenTerminationReason
    public let inputTokenCount: Int
    public let generatedTokenCount: Int
    public let tokenLimit: Int
    public let grammarEnabled: Bool
    public let grammarTerminated: Bool
    public let grammar: QwenGrammarMetadata?

    public init(reason: QwenTerminationReason, inputTokenCount: Int, generatedTokenCount: Int,
                tokenLimit: Int, grammarEnabled: Bool, grammarTerminated: Bool,
                grammar: QwenGrammarMetadata? = nil) {
        self.reason = reason
        self.inputTokenCount = inputTokenCount
        self.generatedTokenCount = generatedTokenCount
        self.tokenLimit = tokenLimit
        self.grammarEnabled = grammarEnabled
        self.grammarTerminated = grammarTerminated
        self.grammar = grammar
    }
}

final class QwenCompletionCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: QwenGenerationCompletion?
    func record(_ value: QwenGenerationCompletion) { lock.withLock { self.value = value } }
    var completion: QwenGenerationCompletion? { lock.withLock { value } }
}

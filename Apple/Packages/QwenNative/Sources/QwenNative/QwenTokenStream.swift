import Foundation
import MLXLMCommon

/// Accepts only the entire emitted value. It never extracts a balanced prefix,
/// closes brackets/fences, or repairs a model response.
enum QwenJSONObject {
    static let maximumUTF8Bytes = 16_384

    static func complete(_ raw: String) -> String? {
        guard raw.utf8.count <= maximumUTF8Bytes else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String
        if trimmed.hasPrefix("```json\n"), trimmed.hasSuffix("```") {
            value = String(trimmed.dropFirst(8).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if trimmed.hasPrefix("```\n"), trimmed.hasSuffix("```") {
            value = String(trimmed.dropFirst(4).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { value = trimmed }
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else { return nil }
        return value
    }

    static func validate(_ raw: String, termination: QwenTerminationReason?) throws -> String {
        try Task.checkCancellation()
        // A complete object at the exact output boundary is still complete.
        if let value = complete(raw) { return value }
        if termination == .outputLimit { throw QwenError.outputLimit }
        throw QwenError.invalidJSON
    }
}

struct QwenTokenStreamResult: Sendable {
    let tokens: [Int]
    let nativeStopReason: GenerateStopReason?
    let jsonComplete: Bool

    func termination(isCancelled: Bool, grammarFailed: Bool,
                     grammarEnabled: Bool, grammarTerminated: Bool) -> QwenTerminationReason {
        if isCancelled { return .cancelled }
        if grammarFailed { return .grammarFailure }
        if jsonComplete { return .jsonComplete }
        switch nativeStopReason {
        case .stop: return grammarEnabled && !grammarTerminated ? .grammarFailure : .stop
        case .length: return .outputLimit
        case .cancelled, nil: return .cancelled
        }
    }
}

/// Shared by production and native scripted-producer tests. Internal object
/// completion cancels only the producer, then awaits it; caller cancellation is
/// left intact and takes precedence when the engine reports termination.
enum QwenTokenStream {
    static func collect(
        stream: AsyncStream<TokenGeneration>, producer: Task<Void, Never>,
        tokenizer: any Tokenizer, stopAtCompleteJSON: Bool,
        elapsed: @escaping @Sendable () -> Double = { 0 },
        shouldAbort: @escaping @Sendable () -> Bool = { false },
        onFirstToken: @escaping @Sendable () -> Void = {},
        onProgress: @escaping @Sendable (QwenGenerationProgress) -> Void = { _ in },
        onInfo: @escaping @Sendable (GenerateCompletionInfo) -> Void = { _ in }
    ) async -> QwenTokenStreamResult {
        var tokens: [Int] = []
        var firstTokenSeconds: Double?
        var nativeStopReason: GenerateStopReason?
        var jsonComplete = false
        var lastProgress = ContinuousClock.now
        var lastJSONCheck = ContinuousClock.now
        await withTaskCancellationHandler {
            eventLoop: for await event in stream {
                if Task.isCancelled || shouldAbort() { producer.cancel(); break }
                switch event {
                case .token(let token):
                    tokens.append(token)
                    if firstTokenSeconds == nil { firstTokenSeconds = elapsed(); onFirstToken() }
                    if tokens.count == 1 || lastProgress.duration(to: .now) >= .milliseconds(100) {
                        onProgress(QwenGenerationProgress(text: "", elapsedSeconds: elapsed(), firstTokenSeconds: firstTokenSeconds))
                        lastProgress = .now
                    }
                    if stopAtCompleteJSON {
                        // Byte-BPE/SentencePiece decoding can revise a prefix;
                        // validate a complete decode, rather than concatenate
                        // decoded tokens. Do not re-decode every ordinary token.
                        let piece = tokenizer.convertIdToToken(token) ?? ""
                        if tokens.count == 1 || piece.contains("}") || piece.contains("`") ||
                            lastJSONCheck.duration(to: .now) >= .milliseconds(100) {
                            lastJSONCheck = .now
                            if QwenJSONObject.complete(tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false)) != nil {
                                jsonComplete = true
                                producer.cancel()
                                break eventLoop
                            }
                        }
                    }
                case .info(let info): nativeStopReason = info.stopReason; onInfo(info)
                }
            }
            if Task.isCancelled { producer.cancel() }
            await producer.value
        } onCancel: { producer.cancel() }
        return QwenTokenStreamResult(tokens: tokens, nativeStopReason: nativeStopReason, jsonComplete: jsonComplete)
    }
}

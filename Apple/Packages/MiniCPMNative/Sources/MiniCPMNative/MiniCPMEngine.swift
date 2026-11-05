import Foundation
import CMiniCPM

public struct GenerationProgress: Sendable {
    public let text: String
    public let generatedTokens: Int
    public let elapsedSeconds: Double
}

public enum MiniCPMError: LocalizedError, Sendable {
    case unavailable(String)
    case invalidJSON
    case outputLimit
    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): message
        case .invalidJSON: "模型没有生成完整的场景，请简化描述后重试。"
        case .outputLimit: "场景生成超过长度限制，请减少物体数量后重试。"
        }
    }
}

private final class Cancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    init() { pointer = mcpm_cancellation_create()! }
    func cancel() { mcpm_cancellation_cancel(pointer) }
    deinit { mcpm_cancellation_destroy(pointer) }
}

// The pointer is owned and touched only on queue. Cancellation has its own atomic native flag.
private final class Worker: @unchecked Sendable {
    let queue = DispatchQueue(label: "cn.mojie.minicpm.inference", qos: .userInitiated)
    var session: OpaquePointer?
    var loadedPath: String?
    deinit { if let session { mcpm_free(session) } }

    func error(_ message: UnsafeMutablePointer<CChar>?) -> MiniCPMError {
        defer { if let message { mcpm_string_free(message) } }
        return .unavailable(message.map { String(cString: $0) } ?? "面壁模型暂时无法运行。")
    }
}

/// Fully local, Metal-accelerated MiniCPM-V 4.7 text inference (35B LES or dense 1B).
/// Tasks may be cancelled during prefill or decode. Unload always waits for native work to exit.
public actor MiniCPMEngine {
    private let worker = Worker()
    private var active: [UUID: Cancellation] = [:]

    public init() {}

    public func load(modelURL: URL, expertsURL: URL? = nil,
                     expertCacheSlots: Int = 48, prefetchDepth: Int = 4) async throws {
        let worker = worker
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.queue.async {
                let identity = modelURL.path + ":" + (expertsURL?.path ?? "") + ":\(expertCacheSlots):\(prefetchDepth)"
                if worker.loadedPath == identity, worker.session != nil {
                    continuation.resume(); return
                }
                if let session = worker.session { mcpm_free(session) }
                worker.session = nil
                worker.loadedPath = nil
                var message: UnsafeMutablePointer<CChar>?
                let session = modelURL.path.withCString { model in
                    (expertsURL?.path ?? "").withCString { experts in
                        mcpm_load(model, experts, 4096, Int32(clamping: expertCacheSlots),
                                  Int32(clamping: prefetchDepth), &message)
                    }
                }
                guard let session else { continuation.resume(throwing: worker.error(message)); return }
                worker.session = session
                worker.loadedPath = identity
                continuation.resume()
            }
        }
        try Task.checkCancellation()
    }

    /// Returns only a complete JSON object. Partial or truncated output is never returned as success.
    /// The caller validates its scene schema separately, or supplies a narrower GBNF grammar.
    public func generateJSON(
        systemPrompt: String,
        prompt: String,
        grammar: String = JSONGrammar.object,
        maxTokens: Int = 1536,
        onProgress: @escaping @Sendable (GenerationProgress) -> Void = { _ in }
    ) async throws -> String {
        try Task.checkCancellation()
        let identifier = UUID()
        let cancellation = Cancellation()
        active[identifier] = cancellation
        defer { active.removeValue(forKey: identifier) }
        let worker = worker
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                worker.queue.async {
                    guard let session = worker.session else {
                        continuation.resume(throwing: MiniCPMError.unavailable("请先下载并载入面壁模型。")); return
                    }
                    let started = ContinuousClock.now
                    var message: UnsafeMutablePointer<CChar>?
                    let begin = systemPrompt.withCString { system in
                        prompt.withCString { prompt in
                            grammar.withCString { grammar in
                                mcpm_begin(session, system, prompt, grammar, cancellation.pointer, &message)
                            }
                        }
                    }
                    defer { mcpm_end(session) }
                    if begin == -2 { continuation.resume(throwing: CancellationError()); return }
                    guard begin == 0 else { continuation.resume(throwing: worker.error(message)); return }
                    var data = Data()
                    var tokenCount = 0
                    var lastUpdate = started
                    for _ in 0..<max(1, min(maxTokens, 3072)) {
                        var bytes: UnsafeMutablePointer<UInt8>?
                        var length: Int32 = 0
                        message = nil
                        let status = mcpm_next(session, &bytes, &length, &message)
                        if let bytes {
                            data.append(bytes, count: Int(length))
                            mcpm_string_free(bytes)
                        }
                        if status == -2 { continuation.resume(throwing: CancellationError()); return }
                        guard status >= 0 else { continuation.resume(throwing: worker.error(message)); return }
                        if status == 0 {
                            guard let result = String(data: data, encoding: .utf8),
                                  let json = try? JSONSerialization.jsonObject(with: data), json is [String: Any] else {
                                continuation.resume(throwing: MiniCPMError.invalidJSON); return
                            }
                            onProgress(GenerationProgress(text: result, generatedTokens: tokenCount,
                                elapsedSeconds: Self.seconds(since: started)))
                            continuation.resume(returning: result); return
                        }
                        tokenCount += 1
                        // Update at <= 12.5 Hz and preserve partial UTF-8 bytes until complete.
                        if lastUpdate.duration(to: .now) >= .milliseconds(80),
                           let partial = String(data: data, encoding: .utf8) {
                            onProgress(GenerationProgress(text: partial, generatedTokens: tokenCount,
                                elapsedSeconds: Self.seconds(since: started)))
                            lastUpdate = .now
                        }
                    }
                    continuation.resume(throwing: MiniCPMError.outputLimit)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Cancels all queued/in-flight turns and releases weights on the inference queue.
    /// Call when the app moves into the background or receives a memory warning.
    public func unload() async {
        for cancellation in active.values { cancellation.cancel() }
        let worker = worker
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            worker.queue.async {
                if let session = worker.session { mcpm_free(session) }
                worker.session = nil
                worker.loadedPath = nil
                continuation.resume()
            }
        }
    }

    private nonisolated static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    }
}

public enum JSONGrammar {
    // Adapted from llama.cpp's MIT-licensed JSON grammar. Root is deliberately an object.
    public static let object = #"""
    root ::= object
    value ::= object | array | string | number | "true" ws | "false" ws | "null" ws
    object ::= "{" ws (string ":" ws value ("," ws string ":" ws value)*)? "}" ws
    array ::= "[" ws (value ("," ws value)*)? "]" ws
    string ::= "\"" char* "\"" ws
    char ::= [^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F])
    number ::= "-"? ("0" | [1-9] [0-9]*) ("." [0-9]+)? ([eE] [-+]? [0-9]+)? ws
    ws ::= [ \t\n\r]*
    """#
}

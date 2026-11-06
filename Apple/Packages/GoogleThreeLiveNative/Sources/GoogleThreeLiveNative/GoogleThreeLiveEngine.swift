import Foundation
import CryptoKit
import ThreeLiveCompiler
import ThreeLiveNative

public enum GoogleThreeLiveEngineError: Error, Equatable, Sendable {
    case busy
    case emptySource
    case sourceTooLarge(byteCount: Int)
    case embeddedNUL(byteOffset: Int)
}

/// Identities of the exact official dependency selected by this package. There
/// is no upstream runtime-version query; verify resolved revision/checksum at build.
public enum GoogleThreeLiveSDKIdentity {
    public static let version = "1.2.3"
    public static let sourceRevision = "c0ff24b628795286a175f1a71611673df5dbc05d"
    public static let xcframeworkArchiveSHA256 = "382fd2fbaa3909fe87e90e9f4ceabaec25fcd22faeb09f91e3490e9021280c59"
}

public struct GoogleThreeLiveResult: Sendable {
    /// Original source, without trimming, fence removal, normalization or repair.
    public let source: String
    public let glb: Data
    public let usdz: Data
    public let sourceSHA256: String
    public let glbSHA256: String
    public let usdzSHA256: String
    /// Hash before metadata repair, useful for explaining changed container bytes.
    public let officialUSDZSHA256: String
    public let metadataRepairApplied: Bool
    public let sdkVersion: String
    public let sdkSourceRevision: String
}

/// Executes user-supplied supported Three-Live scene code through the genuine
/// Google SDK. This actor admits one operation per instance. The official SDK's
/// persistent worker serializes native calls across instances as well.
public actor GoogleThreeLiveEngine {
    public static let maximumSourceBytes = 1_048_576
    private struct Operation: Sendable { let id: UUID; let task: Task<GoogleThreeLiveResult, Error> }
    private let compiler: OfficialCompilerOperations
    private var operation: Operation?

    public init() { compiler = .official }
    // A small internal seam tests real admission/ownership without claiming a
    // scripted compiler is the official VM. Public construction always uses SDK.
    init(compiler: OfficialCompilerOperations) { self.compiler = compiler }

    public var isRunning: Bool { operation != nil }

    public func compile(source: String) async throws -> GoogleThreeLiveResult {
        try Task.checkCancellation()
        guard operation == nil else { throw GoogleThreeLiveEngineError.busy }
        let sourceBytes = try Self.validate(source)
        let id = UUID(), compiler = self.compiler
        let task = Task.detached(priority: .userInitiated) {
            try await Self.execute(source: source, sourceBytes: sourceBytes, compiler: compiler)
        }
        operation = Operation(id: id, task: task)
        defer { if operation?.id == id { operation = nil } }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: { task.cancel() }
    }

    /// Signals the owned operation and joins it. Upstream native calls cannot
    /// be interrupted; this method waits for an in-flight call to return before
    /// advertising idle. It does not unload the persistent official VM/thread.
    public func cancelAndWait() async {
        guard let current = operation else { return }
        current.task.cancel()
        _ = await current.task.result
        if operation?.id == current.id { operation = nil }
    }

    private nonisolated static func validate(_ source: String) throws -> Data {
        let count = source.utf8.count
        guard count > 0 else { throw GoogleThreeLiveEngineError.emptySource }
        guard count <= maximumSourceBytes else { throw GoogleThreeLiveEngineError.sourceTooLarge(byteCount: count) }
        let bytes = Data(source.utf8)
        if let offset = bytes.firstIndex(of: 0) { throw GoogleThreeLiveEngineError.embeddedNUL(byteOffset: offset) }
        return bytes
    }

    private nonisolated static func execute(source: String, sourceBytes: Data,
                                            compiler: OfficialCompilerOperations) async throws -> GoogleThreeLiveResult {
        do {
            try Task.checkCancellation()
            // The only source execution. Never compileUSDZ(source) a second time:
            // user scripts may contain randomness or other nondeterminism.
            let glb = try await compiler.compileGLB(source)
            try Task.checkCancellation()
            let rawUSDZ = try await compiler.glbToUSDZ(glb)
            try Task.checkCancellation()
            let usdz = try OfficialUSDZCompatibility.repair(rawUSDZ)
            try Task.checkCancellation()
            let sourceHash = digest(sourceBytes), glbHash = digest(glb)
            let rawHash = digest(rawUSDZ), usdzHash = digest(usdz)
            try Task.checkCancellation()
            return GoogleThreeLiveResult(source: source, glb: glb, usdz: usdz,
                sourceSHA256: sourceHash, glbSHA256: glbHash, usdzSHA256: usdzHash,
                officialUSDZSHA256: rawHash, metadataRepairApplied: usdz != rawUSDZ,
                sdkVersion: GoogleThreeLiveSDKIdentity.version,
                sdkSourceRevision: GoogleThreeLiveSDKIdentity.sourceRevision)
        } catch {
            // Waited official failures retain their native diagnostics unless
            // this caller explicitly cancelled while that call was in flight.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct OfficialCompilerOperations: Sendable {
    let compileGLB: @Sendable (String) async throws -> Data
    let glbToUSDZ: @Sendable (Data) async throws -> Data
    static let official = Self(
        compileGLB: { try await ThreeCompiler.compileGLB($0) },
        glbToUSDZ: { try await ThreeCompiler.glbToUSDZ($0) }
    )
}

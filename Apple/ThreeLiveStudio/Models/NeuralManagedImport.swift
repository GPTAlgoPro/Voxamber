import Foundation

enum NeuralManagedImportError: LocalizedError, Sendable {
    case cleanupIncomplete
    var errorDescription: String? {
        "完整模型已保留在本机，但 Apple 下载副本清理未完成。请重试下载以先清理该组旧副本。"
    }
}

/// A successful private commit transfers ownership to the private store. Its
/// redundant managed copy must then be settled even if the import caller was
/// cancelled immediately after that commit. This never removes private files.
enum NeuralManagedImport {
    static func perform<Result: Sendable>(
        importPrivate: @Sendable () async throws -> Result,
        removeManaged: @escaping @Sendable () async throws -> Void
    ) async throws -> Result {
        let result = try await importPrivate()
        // This owned unstructured task deliberately does not inherit the
        // caller's cancelled flag. Await it before releasing the operation slot.
        let cleanup = Task { try await removeManaged() }
        do { try await cleanup.value }
        catch { throw NeuralManagedImportError.cleanupIncomplete }
        // External cancellation wins over publishing readiness, after cleanup.
        try Task.checkCancellation()
        return result
    }
}

import Foundation

/// Revocation and the small commit pointer share one linearization point.
/// This lock never encloses generation, GPU work, large file copies or hashing.
final class PublicationPermit: @unchecked Sendable {
    enum State: Equatable, Sendable { case active, revoked, committed }
    private let lock = NSLock()
    private var value: State = .active

    var state: State { lock.withLock { value } }

    /// False means the commit already won; callers must report the saved result.
    @discardableResult func revoke() -> Bool {
        lock.withLock {
            guard value != .committed else { return false }
            value = .revoked
            return true
        }
    }

    func check() throws {
        try Task.checkCancellation()
        try lock.withLock { if value == .revoked { throw CancellationError() } }
    }

    func commit<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            guard value == .active, !Task.isCancelled else { throw CancellationError() }
            let result = try body()
            value = .committed
            return result
        }
    }
}

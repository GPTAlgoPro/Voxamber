import Foundation
import XCTest
#if canImport(ThreeLiveStudio)
@testable import ThreeLiveStudio
#else
@testable import NeuralAssetStoreHarness
#endif

/// Scripted ownership tests only: no Apple API, downloaded pack or neural model.
@MainActor final class NeuralManagedImportTests: XCTestCase {
    func testCancellationAfterPrivateCommitStillAwaitsUncancelledScopedCleanup() async throws {
        let gate = ManagedImportGate()
        let privateFile = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let privateBytes = Data("immutable verified private payload".utf8)
        try privateBytes.write(to: privateFile)
        defer { try? FileManager.default.removeItem(at: privateFile) }
        let owner = Task {
            do {
                let result = try await NeuralManagedImport.perform {
                    await gate.privateCommittedAndWait()
                    return privateFile
                } removeManaged: { await gate.cleanupAndWait() }
                await gate.markOwnerFinished()
                return result
            } catch {
                await gate.markOwnerFinished()
                throw error
            }
        }
        await gate.waitUntilCommitted()
        owner.cancel()
        await gate.releaseImportReturn()
        await gate.waitUntilCleanupStarted()
        let during = await gate.snapshot()
        XCTAssertFalse(during.cleanupWasCancelled)
        XCTAssertEqual(during.cleanupCalls, 1)
        XCTAssertFalse(during.ownerFinished, "Cancellation must not release the owner while cleanup is blocked")
        XCTAssertEqual(try Data(contentsOf: privateFile), privateBytes)
        await gate.releaseCleanup()
        do { _ = try await owner.value; XCTFail("External cancellation must win over readiness") }
        catch { XCTAssertTrue(error is CancellationError) }
        let after = await gate.snapshot()
        XCTAssertTrue(after.cleanupFinished)
        XCTAssertEqual(after.cleanupCalls, 1)
        XCTAssertEqual(try Data(contentsOf: privateFile), privateBytes)
    }

    func testFailedPrivateImportDoesNotRemoveManagedCopy() async {
        let calls = ManagedImportCalls()
        do {
            let _: URL = try await NeuralManagedImport.perform {
                throw CocoaError(.fileReadCorruptFile)
            } removeManaged: { await calls.record() }
            XCTFail("Import failure must propagate")
        } catch { XCTAssertFalse(error is NeuralManagedImportError) }
        let count = await calls.count; XCTAssertEqual(count, 0)
    }

    func testCleanupFailureIsExplicitEvenWhenOwnerWasCancelled() async {
        let gate = ManagedImportGate()
        let owner = Task {
            try await NeuralManagedImport.perform {
                await gate.privateCommittedAndWait(); return 1
            } removeManaged: { throw CocoaError(.fileWriteUnknown) }
        }
        await gate.waitUntilCommitted(); owner.cancel(); await gate.releaseImportReturn()
        do { _ = try await owner.value; XCTFail("Cleanup failure must remain visible") }
        catch { XCTAssertTrue(error is NeuralManagedImportError); XCTAssertFalse(error is CancellationError) }
    }

    func testSuccessfulPrivateCommitReturnsOnlyAfterOneCleanup() async throws {
        let calls = ManagedImportCalls()
        let result = try await NeuralManagedImport.perform { "committed" } removeManaged: { await calls.record() }
        XCTAssertEqual(result, "committed")
        let count = await calls.count; XCTAssertEqual(count, 1)
    }
}

private actor ManagedImportCalls {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor ManagedImportGate {
    struct Snapshot: Sendable {
        let cleanupWasCancelled: Bool
        let cleanupCalls: Int
        let cleanupFinished: Bool
        let ownerFinished: Bool
    }
    private var committed = false
    private var importReturn: CheckedContinuation<Void, Never>?
    private var cleanupReturn: CheckedContinuation<Void, Never>?
    private var cleanupCalls = 0
    private var cleanupWasCancelled = false
    private var cleanupFinished = false
    private var ownerFinished = false
    func privateCommittedAndWait() async {
        committed = true
        await withCheckedContinuation { importReturn = $0 }
    }
    func waitUntilCommitted() async { while !committed { await Task.yield() } }
    func releaseImportReturn() { importReturn?.resume(); importReturn = nil }
    func cleanupAndWait() async {
        cleanupCalls += 1; cleanupWasCancelled = Task.isCancelled
        await withCheckedContinuation { cleanupReturn = $0 }
        cleanupFinished = true
    }
    func waitUntilCleanupStarted() async { while cleanupCalls == 0 { await Task.yield() } }
    func releaseCleanup() { cleanupReturn?.resume(); cleanupReturn = nil }
    func markOwnerFinished() { ownerFinished = true }
    func snapshot() -> Snapshot {
        Snapshot(cleanupWasCancelled: cleanupWasCancelled, cleanupCalls: cleanupCalls,
                 cleanupFinished: cleanupFinished, ownerFinished: ownerFinished)
    }
}

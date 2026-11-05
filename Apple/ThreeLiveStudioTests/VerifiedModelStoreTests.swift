import Foundation
import CryptoKit
import XCTest
@testable import ThreeLiveStudio

@MainActor
final class VerifiedModelStoreTests: XCTestCase {
    func testImportsAllFilesAndPublishesOnlyCompleteVerifiedDirectory() async throws {
        try await withFixture { store, root, source in
            let payloads = [("config.json", Data("{\"model_type\":\"qwen3\"}".utf8)),
                            ("weights/model.safetensors", Data(repeating: 0xa3, count: 16_384))]
            let manifest = try write(payloads, id: "qwen-test", into: source)
            try Data("must not be imported".utf8).write(to: source.appending(path: "unlisted.bin"))
            let progress = ProgressCapture()
            let destination = try await store.importDirectory(source, manifest: manifest, progress: { progress.record($0) })
            XCTAssertEqual(destination, root.appending(path: "qwen-test", directoryHint: .isDirectory))
            for (path, expected) in payloads {
                XCTAssertEqual(try Data(contentsOf: destination.appending(path: path)), expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "unlisted.bin").path))
            let verified = try await VerifiedModelStore(root: root).verifyInstalled(manifest: manifest)
            XCTAssertEqual(verified, destination)
            XCTAssertEqual(progress.values.last, 1)
            XCTAssertTrue(progress.values.allSatisfy { (0...1).contains($0) })
            XCTAssertTrue(try pendingDirectories(root).isEmpty)
        }
    }

    func testHashFailureCannotReplaceAnExistingCompletePack() async throws {
        try await withFixture { store, root, source in
            let old = try write([("model.safetensors", Data("old verified weights".utf8))], id: "same-pack", into: source)
            let destination = try await store.importDirectory(source, manifest: old)
            let original = try Data(contentsOf: destination.appending(path: "model.safetensors"))
            let replacement = try write([("model.safetensors", Data("new verified weights".utf8))], id: "same-pack", into: source)
            try Data("bad verified weights".utf8).write(to: source.appending(path: "model.safetensors"))
            do { _ = try await store.importDirectory(source, manifest: replacement); XCTFail("Wrong hash must fail") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: destination.appending(path: "model.safetensors")), original)
            _ = try await store.verifyInstalled(manifest: old)
        }
    }

    func testRetryReusesPreviouslyVerifiedFilesWithoutReadingTheirSourceAgain() async throws {
        try await withFixture { store, root, source in
            let config = Data("valid config".utf8), weights = Data("valid weights".utf8)
            let manifest = try write([("config.json", config), ("model.safetensors", weights)], id: "resume-pack", into: source)
            try Data("wrong weights".utf8).write(to: source.appending(path: "model.safetensors"))
            do { _ = try await store.importDirectory(source, manifest: manifest); XCTFail("Corrupt final file must fail") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: manifest.id).path))
            let pending = try XCTUnwrap(try pendingDirectories(root).first)
            XCTAssertEqual(try Data(contentsOf: pending.appending(path: "config.json")), config)
            try FileManager.default.removeItem(at: source.appending(path: "config.json"))
            try weights.write(to: source.appending(path: "model.safetensors"))
            let destination = try await VerifiedModelStore(root: root).importDirectory(source, manifest: manifest)
            XCTAssertEqual(try Data(contentsOf: destination.appending(path: "config.json")), config)
            _ = try await store.verifyInstalled(manifest: manifest)
        }
    }

    func testCancellingDuringPrivateCopyPreservesOldPackAndCleansIncomingFile() async throws {
        try await withFixture { store, root, source in
            let old = try write([("weights.bin", Data("old model".utf8))], id: "cancel-pack", into: source)
            let destination = try await store.importDirectory(source, manifest: old)
            let replacement = try write([("weights.bin", Data(repeating: 0xe1, count: 8 * 1_024 * 1_024))],
                                        id: "cancel-pack", into: source)
            let cancellation = InstallationCancellation()
            let task = Task {
                try await store.importDirectory(source, manifest: replacement, progress: { value in
                    if value > 0 && value < 1 { cancellation.cancel() }
                })
            }
            cancellation.assign(task)
            defer { cancellation.clear() }
            do { _ = try await task.value; XCTFail("Cancelled copy must not publish") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: destination.appending(path: "weights.bin")), Data("old model".utf8))
            _ = try await store.verifyInstalled(manifest: old)
            for pending in try pendingDirectories(root) {
                let children = try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)
                XCTAssertFalse(children.contains(where: { $0.lastPathComponent.hasPrefix(".incoming-") }))
            }
        }
    }

    func testUnsafeRelativePathsAndIdentifiersAreRejectedBeforeTouchingOtherFiles() async throws {
        try await withFixture { store, root, source in
            let bytes = Data("protected".utf8)
            let outside = root.deletingLastPathComponent().appending(path: "outside.bin")
            try bytes.write(to: outside)
            for path in ["../outside.bin", "/absolute.bin", "weights/../outside.bin", "a\\b", "./weights", "a//b", "a%2fb", ""] {
                let file = modelFile(path, data: bytes)
                do { _ = try await store.importDirectory(source, manifest: .init(id: "safe", files: [file])); XCTFail("Rejected path: \(path)") }
                catch { XCTAssertFalse(error is CancellationError) }
            }
            let valid = modelFile("weights.bin", data: bytes)
            do { _ = try await store.importDirectory(source, manifest: .init(id: "../escape", files: [valid])); XCTFail("Unsafe ID must fail") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: outside), bytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "safe").path))
        }
    }

    func testImportRejectsSymlinksEvenWhenTheirTargetHasTheExpectedHash() async throws {
        try await withFixture { store, root, source in
            let payload = Data("correct bytes outside selected directory".utf8)
            let outside = root.deletingLastPathComponent().appending(path: "external-model.bin")
            try payload.write(to: outside)
            try FileManager.default.createSymbolicLink(at: source.appending(path: "model.bin"), withDestinationURL: outside)
            let manifest = LocalModelManifest(id: "symlink-pack", files: [modelFile("model.bin", data: payload)])
            do { _ = try await store.importDirectory(source, manifest: manifest); XCTFail("Symlinks must not be imported") }
            catch { XCTAssertFalse(error is CancellationError) }
            XCTAssertEqual(try Data(contentsOf: outside), payload)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: manifest.id).path))
        }
    }

    func testInstalledCorruptionIsRejectedAndACompleteReimportAtomicallyRepairsIt() async throws {
        try await withFixture { store, root, source in
            let payload = Data(repeating: 0x37, count: 4_096)
            let manifest = try write([("model.bin", payload)], id: "repair-pack", into: source)
            let destination = try await store.importDirectory(source, manifest: manifest)
            var corrupted = payload; corrupted[100] ^= 0x10
            try corrupted.write(to: destination.appending(path: "model.bin"), options: .atomic)
            do { _ = try await store.verifyInstalled(manifest: manifest); XCTFail("Corruption must be detected") }
            catch { XCTAssertFalse(error is CancellationError) }
            let repaired = try await store.importDirectory(source, manifest: manifest)
            XCTAssertEqual(repaired, destination)
            XCTAssertEqual(try Data(contentsOf: destination.appending(path: "model.bin")), payload)
            _ = try await store.verifyInstalled(manifest: manifest)
            XCTAssertTrue(try pendingDirectories(root).isEmpty)
        }
    }

    func testRemoveDoesNotDeleteAnotherPackOrItsResumableFiles() async throws {
        try await withFixture { store, root, source in
            let payload = Data("retained model bytes".utf8)
            let a = try write([("model.bin", payload)], id: "pack", into: source)
            _ = try await store.importDirectory(source, manifest: a)
            let b = try write([("model.bin", payload)], id: "pack-extra", into: source)
            let destinationB = try await store.importDirectory(source, manifest: b)
            let pendingB = root.appending(path: ".pending-pack-extra-" + String(repeating: "a", count: 64))
            try FileManager.default.createDirectory(at: pendingB, withIntermediateDirectories: true)
            let partial = pendingB.appending(path: "already-verified.bin")
            try payload.write(to: partial)
            try await store.remove(id: a.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: a.id).path))
            XCTAssertEqual(try Data(contentsOf: partial), payload)
            XCTAssertEqual(try Data(contentsOf: destinationB.appending(path: "model.bin")), payload)
            _ = try await store.verifyInstalled(manifest: b)
        }
    }

    func testUnexpectedWeightShardIsRejectedAndReimportDoesNotRetainIt() async throws {
        try await withFixture { store, _, source in
            let payload = Data("current valid weights".utf8)
            let manifest = try write([("model.safetensors", payload)], id: "exact-pack", into: source)
            let destination = try await store.importDirectory(source, manifest: manifest)
            let unexpected = destination.appending(path: "model-obsolete.safetensors")
            try Data("obsolete weights must never reach the engine".utf8).write(to: unexpected)
            do { _ = try await store.verifyInstalled(manifest: manifest); XCTFail("Unexpected shards must fail verification") }
            catch { XCTAssertFalse(error is CancellationError) }
            _ = try await store.importDirectory(source, manifest: manifest)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unexpected.path))
            XCTAssertEqual(try Data(contentsOf: destination.appending(path: "model.safetensors")), payload)
        }
    }

    private func modelFile(_ path: String, data: Data) -> ModelFile {
        ModelFile(path: path, url: URL(string: "https://example.invalid/" + UUID().uuidString)!,
                  byteCount: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func write(_ files: [(String, Data)], id: String, into directory: URL) throws -> LocalModelManifest {
        for (path, bytes) in files {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url, options: .atomic)
        }
        return .init(id: id, files: files.map { modelFile($0.0, data: $0.1) })
    }

    private func pendingDirectories(_ root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".pending-") }
    }

    private func withFixture(_ test: @MainActor (VerifiedModelStore, URL, URL) async throws -> Void) async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "VerifiedModelStoreTests-" + UUID().uuidString,
                                                                   directoryHint: .isDirectory)
        let root = base.appending(path: "installed", directoryHint: .isDirectory)
        let source = base.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try await test(VerifiedModelStore(root: root), root, source)
    }
}

private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    var values: [Double] { lock.withLock { recorded } }
    func record(_ value: Double) { lock.withLock { recorded.append(value) } }
}

private final class InstallationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL, Error>?
    func assign(_ value: Task<URL, Error>) { lock.withLock { task = value } }
    func clear() { lock.withLock { task = nil } }
    func cancel() { lock.withLock { task?.cancel() } }
}
